import AVFoundation
import CoreAudio
import Accelerate
import os

private let log = Logger(subsystem: "com.saystuff.app", category: "audio")

/// Monotonic stage timings only; never records audio, clipboard contents, or transcripts.
struct LatencyTrace: Sendable {
    private static let logger = Logger(subsystem: "com.saystuff.app", category: "latency")
    let id = String(UUID().uuidString.prefix(8))
    private let started = ProcessInfo.processInfo.systemUptime

    func mark(_ stage: String) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
        Self.logger.notice("\(id, privacy: .public) \(stage, privacy: .public) \(milliseconds, format: .fixed(precision: 2))ms")
    }
}

struct Recording {
    let url: URL
    /// Length of the written audio, after silence trimming.
    let duration: TimeInterval
    /// False unless enough sustained sound above the room's noise floor was heard:
    /// a cough, a click or a breath isn't speech, and the models invent text for them.
    let containsSpeech: Bool
    /// Most of the signal was pinned at full scale: the device sent garbage, not speech.
    var garbled = false
    /// The same audio as the file (16 kHz mono), so engines can skip reading it back.
    var samples: [Float] = []
    /// Samples already handed out as streaming chunks; the rest is the final chunk.
    var streamedSamples = 0
    /// Whether anything was said after the last streaming chunk.
    var tailHasSpeech = true
    /// Speaking pace, measured on the untrimmed capture.
    var speech = SpeechTiming()

    var tail: [Float] { Array(samples[min(streamedSamples, samples.count)...]) }
}

/// Timing of the speech in one recording, before silence trimming, for the speaking-rate stats.
struct SpeechTiming: Codable, Sendable {
    /// First loud sample to last loud sample: talking time including natural pauses.
    var spanSeconds: Double = 0
    /// Time above the speech threshold (rough: decided per ~20 ms buffer).
    var voicedSeconds: Double = 0
    /// Silences of at least `SpeechTiming.pauseThreshold` between words, and their total length.
    var pauses = 0
    var pauseSeconds: Double = 0
    var longestPauseSeconds: Double = 0

    static let pauseThreshold: Double = 0.5
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
    /// A device was plugged in or removed since the session was configured.
    private var sessionStale = false
    private var deviceObservers: [NSObjectProtocol] = []

    // audioQueue state
    private var isCapturing = false
    private var startTrace: LatencyTrace?
    private var fileURL: URL?
    private var audioFile: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var sampleRate: Double = 0
    private var heardSpeech = false
    /// Samples louder than the speech threshold, and the longest unbroken stretch of them.
    private var loudSamples = 0
    private var loudRun = 0
    private var longestLoudRun = 0
    private var totalBuffers = 0
    private var pinnedBuffers = 0
    private var loggedFormat: AVAudioFormat?
    private var noiseFloor: Float = -60
    /// Silent samples since the last speech, not yet written.
    private var pendingSilence: [Float] = []
    /// Everything written to the file, kept for in-memory transcription.
    private var written: [Float] = []
    /// Receives each finished stretch of speech (on the audio queue) while recording.
    private var onChunk: (([Float]) -> Void)?
    private var chunkStart = 0
    private var speechSinceCut = false
    /// Untrimmed position in the capture, and where speech started and last ended there.
    private var capturedFrames = 0
    private var firstLoudFrame = 0
    private var lastLoudFrame = 0
    private var silenceRun = 0
    private var timing = SpeechTiming()

    private enum Trim {
        static let leadIn: Double = 0.3        // seconds kept before the first word
        static let tail: Double = 0.35         // seconds kept after the last word
        static let pauseSide: Double = 0.4     // a long pause keeps this much on each side
        static let maxPending: Double = 5      // cap on buffered silence
    }

    /// The least a recording needs to count as speech. One short word is about 0.3 s loud.
    private enum Speech {
        static let total: Double = 0.25
        static let sustained: Double = 0.1     // clicks and taps are shorter than this
    }

    /// Where streaming cuts the audio. Whisper reads up to 30 s at a time.
    private enum Chunk {
        static let minimum: Double = 3         // shorter chunks lose too much context
        static let pause: Double = 0.6         // a pause this long ends a chunk
        static let long: Double = 15           // past this, a shorter pause will do
        static let shortPause: Double = 0.25
        static let hardLimit: Double = 28      // cut even mid-speech
    }

    // Reusable buffers so the audio callback doesn't allocate
    private var reusableInputBuffer: AVAudioPCMBuffer?
    private var reusableWriteBuffer: AVAudioPCMBuffer?
    private var reusableResampledBuffer: AVAudioPCMBuffer?

    // Everything is written as 16 kHz mono: what Whisper uses internally, and a third of
    // the upload size of 48 kHz for the cloud engine.
    private static let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?

    override init() {
        super.init()
        // A reconnected mic is a new device even with the same UID, so a session configured
        // before can't be reused. Mark it rather than tear it down: a recording may be running.
        deviceObservers = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async { self.sessionStale = true }
            }
        }
    }

    deinit {
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
    }

    /// `preferredUID`/`preferredName` identify the chosen mic; nil follows the system input.
    /// `onChunk` turns on streaming: it's called on the audio queue with each stretch of speech
    /// as soon as a pause ends it, so words aren't split between chunks.
    func start(preferredUID: String?, preferredName: String?, onChunk: (([Float]) -> Void)? = nil,
               trace: LatencyTrace? = nil, completion: @escaping (Error?) -> Void) {
        trace?.mark("recorder.start.requested")
        sessionQueue.async { [self] in
            trace?.mark("recorder.startQueue.entered")
            do {
                let session = try preparedSession(preferredUID: preferredUID, preferredName: preferredName)
                trace?.mark("recorder.sessionPrepared")
                audioQueue.sync {
                    beginFile()
                    self.onChunk = onChunk
                    startTrace = trace
                }
                if !session.isRunning { session.startRunning() }
                trace?.mark("recorder.hardwareStarted")
                guard session.isRunning else { throw AudioRecorderError.deviceSetupFailed }
                DispatchQueue.main.async { completion(nil) }
            } catch {
                audioQueue.sync { discardFile() }
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// Stops capture and hands back the finished file (nil if nothing was captured).
    /// The file is handed over before the hardware stops: `stopRunning()` can block for
    /// 50–300 ms and nothing after the stop press is kept anyway.
    func stop(trace: LatencyTrace? = nil, completion: @escaping (Recording?) -> Void) {
        trace?.mark("recorder.stop.requested")
        sessionQueue.async { [self] in
            trace?.mark("recorder.sessionQueue.entered")
            let recording = audioQueue.sync {
                trace?.mark("recorder.audioQueue.entered")
                let recording = finishFile()
                trace?.mark("recorder.fileFinalized")
                return recording
            }
            DispatchQueue.main.async {
                trace?.mark("recorder.mainCallback")
                completion(recording)
            }
            session?.stopRunning()
            trace?.mark("recorder.hardwareStopped")
        }
    }

    /// Configures the session for the current mic ahead of time so the next start is instant.
    func prepare(preferredUID: String?, preferredName: String?) {
        sessionQueue.async { [self] in
            guard session?.isRunning != true else { return }
            _ = try? preparedSession(preferredUID: preferredUID, preferredName: preferredName)
        }
    }

    /// Drops the configured session so the next recording reconnects to the device from scratch.
    func resetSession() {
        sessionQueue.async { [self] in
            session?.stopRunning()
            session = nil
            sessionDeviceID = nil
            sessionStale = false
        }
    }

    func cancel() {
        sessionQueue.async { [self] in
            session?.stopRunning()
            audioQueue.sync { discardFile() }
        }
    }

    // MARK: - Session

    private func preparedSession(preferredUID: String?, preferredName: String?) throws -> AVCaptureSession {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
            throw AudioRecorderError.permissionDenied
        }

        guard let microphone = AudioDeviceManager.microphone(preferredUID: preferredUID, preferredName: preferredName),
              let device = AVCaptureDevice(uniqueID: microphone.uid) else {
            throw AudioRecorderError.noInputDevice
        }

        if let session, !sessionStale, sessionDeviceID == device.uniqueID, device.isConnected {
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
        sessionStale = false
        return session
    }

    // MARK: - File (audioQueue only)

    private func beginFile() {
        discardFile()
        converter?.reset()
        fileURL = RecordingArchive.newURL()
        framesWritten = 0
        heardSpeech = false
        loudSamples = 0
        loudRun = 0
        longestLoudRun = 0
        totalBuffers = 0
        pinnedBuffers = 0
        noiseFloor = -60
        pendingSilence.removeAll(keepingCapacity: true)
        written = []
        onChunk = nil
        chunkStart = 0
        speechSinceCut = false
        capturedFrames = 0
        firstLoudFrame = 0
        lastLoudFrame = 0
        silenceRun = 0
        timing = SpeechTiming()
        isCapturing = true
    }

    private func finishFile() -> Recording? {
        isCapturing = false
        if heardSpeech {
            write(pendingSilence.prefix(samples(Trim.tail)))
        }
        pendingSilence.removeAll(keepingCapacity: true)
        audioFile = nil  // Releasing the file finalizes the WAV header.
        defer {
            fileURL = nil
            written = []
            onChunk = nil
        }
        guard let url = fileURL else { return nil }
        guard framesWritten > 0, sampleRate > 0 else {
            try? FileManager.default.removeItem(at: url)
            return heardSpeech ? nil : Recording(url: url, duration: 0, containsSpeech: false)
        }
        let garbled = totalBuffers > 5 && pinnedBuffers * 2 > totalBuffers
        if garbled {
            log.error("Garbled input: \(self.pinnedBuffers)/\(self.totalBuffers) buffers at full scale")
        }
        let spoke = loudSamples >= samples(Speech.total) && longestLoudRun >= samples(Speech.sustained)
        if heardSpeech, !spoke {
            log.notice("Not speech: \(Double(self.loudSamples) / self.sampleRate, format: .fixed(precision: 2))s loud, longest \(Double(self.longestLoudRun) / self.sampleRate, format: .fixed(precision: 2))s")
        }
        timing.spanSeconds = Double(lastLoudFrame - firstLoudFrame) / sampleRate
        timing.voicedSeconds = Double(loudSamples) / sampleRate
        return Recording(url: url, duration: Double(framesWritten) / sampleRate,
                         containsSpeech: spoke && !garbled, garbled: garbled,
                         samples: written, streamedSamples: chunkStart, tailHasSpeech: speechSinceCut,
                         speech: timing)
    }

    private func discardFile() {
        isCapturing = false
        startTrace = nil
        audioFile = nil
        written = []
        onChunk = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }

    // MARK: - Capture callback

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isCapturing, let url = fileURL else { return }
        if let trace = startTrace {
            trace.mark("recorder.firstBuffer")
            startTrace = nil
        }
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

        capturedFrames += frames.count
        if decibels > speechThreshold {
            if !heardSpeech {
                firstLoudFrame = capturedFrames - frames.count
            } else if silenceRun >= samples(SpeechTiming.pauseThreshold) {
                let pause = Double(silenceRun) / sampleRate
                timing.pauses += 1
                timing.pauseSeconds += pause
                timing.longestPauseSeconds = max(timing.longestPauseSeconds, pause)
            }
            silenceRun = 0
            lastLoudFrame = capturedFrames
            loudSamples += frames.count
            loudRun += frames.count
            longestLoudRun = max(longestLoudRun, loudRun)
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
            speechSinceCut = true
            write(frames[...])
            if onChunk != nil, written.count - chunkStart >= samples(Chunk.hardLimit) { cutChunk(tail: []) }
        } else {
            loudRun = 0
            silenceRun += frames.count
            pendingSilence.append(contentsOf: frames)
            let overflow = pendingSilence.count - samples(Trim.maxPending)
            if overflow > 0 {
                // Keep the start (tail of the last word) and the most recent audio; drop the middle.
                let keepHead = heardSpeech ? samples(Trim.pauseSide) : 0
                pendingSilence.removeSubrange(keepHead..<(keepHead + overflow))
            }
            if onChunk != nil, speechSinceCut {
                let length = written.count - chunkStart
                let pause = length >= samples(Chunk.long) ? Chunk.shortPause : Chunk.pause
                if length >= samples(Chunk.minimum), pendingSilence.count >= samples(pause) {
                    cutChunk(tail: pendingSilence.prefix(samples(Trim.tail)))
                }
            }
        }
    }

    /// Hands out the speech since the last cut, plus a little of the pause after it.
    private func cutChunk(tail: ArraySlice<Float>) {
        let chunk = Array(written[chunkStart...]) + tail
        chunkStart = written.count
        speechSinceCut = false
        onChunk?(chunk)
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
                written.append(contentsOf: UnsafeBufferPointer(start: destination, count: count))
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
        case .noInputDevice: return "No microphone found. Choose one in the menu"
        case .deviceSetupFailed: return "Couldn't start the microphone"
        }
    }
}

/// The last two weeks of dictation audio, each with a .txt of what came of it, kept as real
/// cases to test engines and thresholds against.
enum RecordingArchive {
    static let keepDays: Double = 14

    static let directory: URL = {
        let directory = AppPaths.support.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    static func newURL() -> URL {
        directory.appendingPathComponent("\(stamp.string(from: Date()))_\(UUID().uuidString.prefix(4)).wav")
    }

    private static var lastPrune = Date.distantPast

    /// Writes what the recording turned into (the pasted text, or why nothing was) next to it.
    /// Main thread only.
    static func note(_ text: String, for recording: URL) {
        if Date().timeIntervalSince(lastPrune) > 86_400 { prune() }
        DispatchQueue.global(qos: .utility).async {
            try? text.write(to: recording.deletingPathExtension().appendingPathExtension("txt"),
                            atomically: true, encoding: .utf8)
        }
    }

    static func prune() {
        lastPrune = Date()
        DispatchQueue.global(qos: .utility).async {
            let cutoff = Date().addingTimeInterval(-keepDays * 86_400)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in files {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantFuture
                if created < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
    }
}
