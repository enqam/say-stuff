import AVFoundation
import CoreAudio
import Accelerate
import os

private let log = Logger(subsystem: "com.saystuff.app", category: "audio")

struct Recording {
    let url: URL
    /// Length of the written audio, after silence trimming.
    let duration: TimeInterval
    /// False when nothing louder than the room's noise floor was heard.
    let containsSpeech: Bool
    /// Most of the signal was pinned at full scale: the device sent garbage, not speech.
    var garbled = false
}

/// Captures the microphone to a mono WAV file.
///
/// Silence is trimmed as it's captured: leading and trailing silence is dropped and long
/// pauses are shortened. Whisper invents text ("Thank you.") on silent stretches, and less
/// audio also means faster transcription.
///
/// Session start/stop happens on `sessionQueue` (AVCaptureSession calls block for 50–300 ms),
/// sample processing on `audioQueue`. The main thread never waits on either.
final class AudioRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Called on the audio queue with a 0...1 loudness value for each captured buffer.
    var onLevel: ((Float) -> Void)?

    private let sessionQueue = DispatchQueue(label: "com.saystuff.capture-session", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.saystuff.audio", qos: .userInteractive)

    // sessionQueue state. The session stays configured between recordings so the next
    // start only has to call startRunning().
    private var session: AVCaptureSession?
    private var sessionDeviceID: String?

    // audioQueue state
    private var isCapturing = false
    private var fileURL: URL?
    private var audioFile: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var heardSpeech = false
    private var totalBuffers = 0
    private var pinnedBuffers = 0
    private var loggedFormat: AVAudioFormat?
    private var noiseFloor: Float = -60
    /// Silent samples since the last speech, not yet written.
    private var pendingSilence: [Float] = []

    private enum Trim {
        static let leadIn: Double = 0.3        // seconds kept before the first word
        static let tail: Double = 0.35         // seconds kept after the last word
        static let pauseSide: Double = 0.4     // a long pause keeps this much on each side
        static let maxPending: Double = 5      // cap on buffered silence
    }

    // Reusable buffers so the audio callback doesn't allocate
    private var reusableInputBuffer: AVAudioPCMBuffer?
    private var reusableWriteBuffer: AVAudioPCMBuffer?
    private var reusableResampledBuffer: AVAudioPCMBuffer?

    // Everything is written as 16 kHz mono: what Whisper uses internally, and a third of
    // the upload size of 48 kHz for the cloud engine.
    private static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    func start(deviceUID: String?, completion: @escaping (Error?) -> Void) {
        sessionQueue.async { [self] in
            do {
                let session = try preparedSession(deviceUID: deviceUID)
                audioQueue.sync { beginFile() }
                if !session.isRunning { session.startRunning() }
                guard session.isRunning else { throw AudioRecorderError.deviceSetupFailed }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                audioQueue.sync { discardFile() }
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Stops capture and hands back the finished file (nil if nothing was captured).
    func stop(completion: @escaping (Recording?) -> Void) {
        sessionQueue.async { [self] in
            session?.stopRunning()
            let recording = audioQueue.sync { finishFile() }
            DispatchQueue.main.async { completion(recording) }
        }
    }

    /// Drops the configured session so the next recording reconnects to the device from scratch.
    func resetSession() {
        sessionQueue.async { [self] in
            session?.stopRunning()
            session = nil
            sessionDeviceID = nil
        }
    }

    func cancel() {
        sessionQueue.async { [self] in
            session?.stopRunning()
            audioQueue.sync { discardFile() }
        }
    }

    // MARK: - Session

    private func preparedSession(deviceUID: String?) throws -> AVCaptureSession {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            throw AudioRecorderError.permissionDenied
        }

        let selected = deviceUID.flatMap { AVCaptureDevice(uniqueID: $0) }
        guard let device = selected ?? AVCaptureDevice.default(for: .audio) else {
            throw AudioRecorderError.noInputDevice
        }

        if let session, sessionDeviceID == device.uniqueID, device.isConnected {
            return session
        }

        print("[AudioRecorder] Configuring capture with: \(device.localizedName)")
        let session = AVCaptureSession()
        session.beginConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw AudioRecorderError.deviceSetupFailed }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        // Let Core Audio convert to what we write (16 kHz mono float) so no device-specific
        // decoding happens here; USB mics in particular use formats and split buffers that
        // hand-decoding got wrong.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.outputFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
        guard session.canAddOutput(output) else { throw AudioRecorderError.deviceSetupFailed }
        session.addOutput(output)

        session.commitConfiguration()

        self.session?.stopRunning()
        self.session = session
        sessionDeviceID = device.uniqueID
        return session
    }

    // MARK: - File (audioQueue only)

    private func beginFile() {
        discardFile()
        converter?.reset()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("saystuff_recording_\(UUID().uuidString).wav")
        framesWritten = 0
        heardSpeech = false
        totalBuffers = 0
        pinnedBuffers = 0
        noiseFloor = -60
        pendingSilence.removeAll(keepingCapacity: true)
        isCapturing = true
    }

    private func finishFile() -> Recording? {
        isCapturing = false
        if heardSpeech {
            write(pendingSilence.prefix(samples(Trim.tail)))
        }
        pendingSilence.removeAll(keepingCapacity: true)
        audioFile = nil  // Releasing the file finalizes the WAV header.
        defer { fileURL = nil }
        guard let url = fileURL else { return nil }
        guard framesWritten > 0, sampleRate > 0 else {
            try? FileManager.default.removeItem(at: url)
            return heardSpeech ? nil : Recording(url: url, duration: 0, containsSpeech: false)
        }
        let garbled = totalBuffers > 5 && pinnedBuffers * 2 > totalBuffers
        if garbled {
            log.error("Garbled input: \(self.pinnedBuffers)/\(self.totalBuffers) buffers at full scale")
        }
        return Recording(url: url, duration: Double(framesWritten) / sampleRate,
                         containsSpeech: heardSpeech && !garbled, garbled: garbled)
    }

    private func discardFile() {
        isCapturing = false
        audioFile = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }

    // MARK: - Capture callback

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isCapturing, let url = fileURL else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return }

        // Copy with Core Media (handles non-contiguous block buffers and every PCM layout),
        // into a buffer of exactly the format the sample buffer says it has.
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        if loggedFormat != format {
            loggedFormat = format
            log.notice("Capture format: \(format.description, privacy: .public)")
        }
        guard let input = reusableBuffer(&reusableInputBuffer, format: format, frames: frameCount) else { return }
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount), into: input.mutableAudioBufferList)
        guard status == noErr else {
            log.error("Couldn't copy audio samples: \(status)")
            return
        }
        guard let buffer = resampled(input) else { return }

        if audioFile == nil {
            sampleRate = Self.outputFormat.sampleRate
            do {
                audioFile = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: sampleRate,
                        AVNumberOfChannelsKey: 1,
                        AVLinearPCMBitDepthKey: 16,
                        AVLinearPCMIsFloatKey: false,
                        AVLinearPCMIsBigEndianKey: false
                    ]
                )
            } catch {
                print("[AudioRecorder] Failed to create audio file: \(error)")
                return
            }
        }

        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let frames = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))

        var rms: Float = 0
        vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frames.count))
        totalBuffers += 1
        if rms > 0.7 { pinnedBuffers += 1 }  // real speech almost never sits near full scale
        let decibels = 20 * log10(max(rms, 0.000_001))
        // -55 dB (room tone) ... -12 dB (loud speech) mapped to 0...1 for the waveform
        onLevel?(min(max((decibels + 55) / 43, 0), 1))

        // Noise floor follows quiet stretches quickly and loud ones slowly.
        noiseFloor = decibels < noiseFloor ? decibels : noiseFloor + (decibels - noiseFloor) * 0.002
        let speechThreshold = min(max(noiseFloor + 12, -55), -35)

        if decibels > speechThreshold {
            if heardSpeech {
                if pendingSilence.count <= samples(Trim.pauseSide * 2) {
                    write(pendingSilence[...])
                } else {
                    write(pendingSilence.prefix(samples(Trim.pauseSide)))
                    write(pendingSilence.suffix(samples(Trim.pauseSide)))
                }
            } else {
                write(pendingSilence.suffix(samples(Trim.leadIn)))
            }
            pendingSilence.removeAll(keepingCapacity: true)
            heardSpeech = true
            write(frames[...])
        } else {
            pendingSilence.append(contentsOf: frames)
            let overflow = pendingSilence.count - samples(Trim.maxPending)
            if overflow > 0 {
                // Keep the start (tail of the last word) and the most recent audio; drop the middle.
                let keepHead = heardSpeech ? samples(Trim.pauseSide) : 0
                pendingSilence.removeSubrange(keepHead..<(keepHead + overflow))
            }
        }
    }

    /// Converts to 16 kHz mono float if the device didn't already deliver that.
    private func resampled(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let output = Self.outputFormat
        if input.format.commonFormat == .pcmFormatFloat32,
           input.format.channelCount == 1,
           input.format.sampleRate == output.sampleRate {
            return input
        }
        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: output)
            converter?.downmix = true
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * output.sampleRate / input.format.sampleRate) + 64
        guard let buffer = reusableBuffer(&reusableResampledBuffer, format: output, frames: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: buffer, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow  // keep filter state for the next buffer
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else {
            print("[AudioRecorder] Resample failed: \(String(describing: error))")
            return nil
        }
        return buffer
    }

    private func samples(_ seconds: Double) -> Int {
        Int(seconds * sampleRate)
    }

    private func write<C: Collection>(_ samples: C) where C.Element == Float {
        guard !samples.isEmpty, let audioFile else { return }
        let format = audioFile.processingFormat
        let chunk = 4096
        var index = samples.startIndex
        while index != samples.endIndex {
            let end = samples.index(index, offsetBy: chunk, limitedBy: samples.endIndex) ?? samples.endIndex
            let count = samples.distance(from: index, to: end)
            guard let buffer = reusableBuffer(&reusableWriteBuffer, format: format, frames: AVAudioFrameCount(count)),
                  let destination = buffer.floatChannelData?[0] else { return }
            let copied: Void? = samples[index..<end].withContiguousStorageIfAvailable { source in
                destination.update(from: source.baseAddress!, count: count)
            }
            if copied == nil {
                for (offset, sample) in samples[index..<end].enumerated() { destination[offset] = sample }
            }
            do {
                try audioFile.write(from: buffer)
                framesWritten += AVAudioFramePosition(count)
            } catch {
                print("[AudioRecorder] Write error: \(error)")
                return
            }
            index = end
        }
    }

    // MARK: - Conversion

    private func reusableBuffer(_ slot: inout AVAudioPCMBuffer?, format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let existing = slot, existing.format == format, existing.frameCapacity >= frames {
            existing.frameLength = frames
            return existing
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        slot = buffer
        return buffer
    }

}

enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case noInputDevice
    case deviceSetupFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Microphone access is off"
        case .noInputDevice: return "No microphone found"
        case .deviceSetupFailed: return "Couldn't start the microphone"
        }
    }
}
