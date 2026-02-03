import AVFoundation
import CoreAudio
import Accelerate

class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private let recordingFilename = "saystuff_recording.wav"
    private let processingQueue = DispatchQueue(label: "com.saystuff.audio", qos: .userInitiated)

    // Pre-allocated reusable buffers to avoid allocations in audio callback
    private var reusablePCMBuffer: AVAudioPCMBuffer?
    private var reusableMonoBuffer: AVAudioPCMBuffer?
    private var lastPCMFormat: AVAudioFormat?
    private var lastMonoFormat: AVAudioFormat?

    @Published var isRecording = false
    // Temporary buffer for int16 -> float conversion (avoids per-callback allocation)
    private var conversionBuffer: [Float] = []

    func startRecording() throws {
        // Clean up any existing session
        stopAndCleanup()

        // Remove old recording
        try? FileManager.default.removeItem(at: recordingURL())

        // Create capture session
        let session = AVCaptureSession()
        session.beginConfiguration()

        // Get the selected device or fall back to default
        let device: AVCaptureDevice?
        if let deviceUID = SettingsManager.shared.settings.selectedAudioDeviceUID {
            // Use AVCaptureDeviceDiscoverySession to find audio devices
            let discoverySession = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInMicrophone, .externalUnknown],
                mediaType: .audio,
                position: .unspecified
            )
            device = discoverySession.devices.first { $0.uniqueID == deviceUID }
            if device != nil {
                print("[AudioRecorder] Using selected device: \(device!.localizedName)")
            } else {
                print("[AudioRecorder] Selected device not found, using default")
            }
        } else {
            device = nil
        }

        // Use selected device or default
        let audioDevice = device ?? AVCaptureDevice.default(for: .audio)

        guard let audioDevice = audioDevice else {
            print("[AudioRecorder] No audio input device available")
            throw AudioRecorderError.deviceSetupFailed
        }

        print("[AudioRecorder] Recording with: \(audioDevice.localizedName)")

        // Add input
        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
        guard session.canAddInput(audioInput) else {
            throw AudioRecorderError.deviceSetupFailed
        }
        session.addInput(audioInput)

        // Add output
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: processingQueue)
        guard session.canAddOutput(output) else {
            throw AudioRecorderError.deviceSetupFailed
        }
        session.addOutput(output)

        session.commitConfiguration()

        // We'll create the audio file when we receive the first buffer (to get the correct format)
        audioFileURL = recordingURL()

        // Start session
        session.startRunning()
        captureSession = session
        audioOutput = output
        isRecording = true
        print("[AudioRecorder] Recording started")
    }

    // MARK: - Buffer Reuse Helpers

    private func getOrCreatePCMBuffer(format: AVAudioFormat, frameCount: Int) -> AVAudioPCMBuffer? {
        // Reuse existing buffer if format matches and capacity is sufficient
        if let existing = reusablePCMBuffer,
           existing.format == format,
           existing.frameCapacity >= AVAudioFrameCount(frameCount) {
            existing.frameLength = AVAudioFrameCount(frameCount)
            return existing
        }

        // Allocate new buffer (only when format changes or first time)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        reusablePCMBuffer = buffer
        lastPCMFormat = format
        return buffer
    }

    private func getOrCreateMonoBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        // Reuse existing buffer if format matches and capacity is sufficient
        if let existing = reusableMonoBuffer,
           existing.format == format,
           existing.frameCapacity >= frameCount {
            existing.frameLength = frameCount
            return existing
        }

        // Allocate new buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        reusableMonoBuffer = buffer
        lastMonoFormat = format
        return buffer
    }

    // Called for each audio buffer from the capture session
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording else { return }

        // Create audio file on first buffer if needed
        if audioFile == nil, let url = audioFileURL {
            guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee

            if let asbd = asbd {
                print("[AudioRecorder] Audio format: \(asbd.mSampleRate)Hz, \(asbd.mChannelsPerFrame)ch")

                do {
                    audioFile = try AVAudioFile(
                        forWriting: url,
                        settings: [
                            AVFormatIDKey: kAudioFormatLinearPCM,
                            AVSampleRateKey: asbd.mSampleRate,
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
        }

        guard let audioFile = audioFile else { return }

        // Convert CMSampleBuffer to AVAudioPCMBuffer (uses buffer reuse)
        guard let pcmBuffer = createPCMBuffer(from: sampleBuffer) else { return }

        // Convert to mono and write (uses buffer reuse)
        let monoBuffer: AVAudioPCMBuffer
        if pcmBuffer.format.channelCount > 1 {
            guard let monoFormat = AVAudioFormat(
                commonFormat: pcmBuffer.format.commonFormat,
                sampleRate: pcmBuffer.format.sampleRate,
                channels: 1,
                interleaved: false
            ) else { return }

            guard let mono = getOrCreateMonoBuffer(format: monoFormat, frameCount: pcmBuffer.frameLength) else { return }

            if let src = pcmBuffer.floatChannelData?[0],
               let dst = mono.floatChannelData?[0] {
                memcpy(dst, src, Int(pcmBuffer.frameLength) * MemoryLayout<Float>.size)
            }
            monoBuffer = mono
        } else {
            monoBuffer = pcmBuffer
        }

        do {
            try audioFile.write(from: monoBuffer)
        } catch {
            print("[AudioRecorder] Write error: \(error)")
        }
    }

    private func createPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee else {
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.mSampleRate,
            channels: AVAudioChannelCount(asbd.mChannelsPerFrame),
            interleaved: false
        ) else { return nil }

        // Use buffer reuse instead of allocating every callback
        guard let pcmBuffer = getOrCreatePCMBuffer(format: format, frameCount: frameCount) else {
            return nil
        }

        // Get audio data
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer else { return nil }

        // Convert based on source format
        let channelCount = Int(asbd.mChannelsPerFrame)

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Source is float
            let floatData = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                // Non-interleaved float - use memcpy (already fast)
                for ch in 0..<channelCount {
                    if let dst = pcmBuffer.floatChannelData?[ch] {
                        memcpy(dst, floatData.advanced(by: ch * frameCount), frameCount * MemoryLayout<Float>.size)
                    }
                }
            } else {
                // Interleaved float - deinterleave by copying with stride
                for ch in 0..<channelCount {
                    if let dst = pcmBuffer.floatChannelData?[ch] {
                        // Copy every channelCount-th sample starting at offset ch
                        let src = floatData.advanced(by: ch)
                        cblas_scopy(Int32(frameCount), src, Int32(channelCount), dst, 1)
                    }
                }
            }
        } else if asbd.mBitsPerChannel == 16 {
            // Source is 16-bit integer
            // Source is 16-bit integer
            let int16Data = UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self)
            var scale: Float = 1.0 / 32768.0

            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                // Non-interleaved int16 - convert each channel with vDSP
                for ch in 0..<channelCount {
                    if let dst = pcmBuffer.floatChannelData?[ch] {
                        let src = int16Data.advanced(by: ch * frameCount)
                        // Convert int16 to float
                        vDSP_vflt16(src, 1, dst, 1, vDSP_Length(frameCount))
                        // Scale to -1.0...1.0
                        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
                    }
                }
            } else {
                // Interleaved int16 - deinterleave and convert with vDSP
                // Ensure conversion buffer is large enough
                if conversionBuffer.count < frameCount {
                    conversionBuffer = [Float](repeating: 0, count: frameCount)
                }

                for ch in 0..<channelCount {
                    if let dst = pcmBuffer.floatChannelData?[ch] {
                        // Extract channel samples at stride, convert, and scale
                        let src = int16Data.advanced(by: ch)
                        vDSP_vflt16(src, vDSP_Stride(channelCount), dst, 1, vDSP_Length(frameCount))
                        vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
                    }
                }
            }
        } else if asbd.mBitsPerChannel == 32 && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            // Source is 32-bit integer - convert with vDSP
            let int32Data = UnsafeRawPointer(data).assumingMemoryBound(to: Int32.self)
            var scale: Float = 1.0 / 2147483648.0

            for ch in 0..<channelCount {
                if let dst = pcmBuffer.floatChannelData?[ch] {
                    let src = int32Data.advanced(by: ch)
                    // Convert int32 to float
                    vDSP_vflt32(src, vDSP_Stride(channelCount), dst, 1, vDSP_Length(frameCount))
                    // Scale to -1.0...1.0
                    vDSP_vsmul(dst, 1, &scale, dst, 1, vDSP_Length(frameCount))
                }
            }
        } else {
            print("[AudioRecorder] Unsupported audio format: bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags)")
            return nil
        }

        return pcmBuffer
    }

    private func stopAndCleanup() {
        if let session = captureSession {
            session.stopRunning()
        }
        captureSession = nil
        audioOutput = nil
        audioFile = nil
        audioFileURL = nil
        isRecording = false

        // Clear reusable buffers
        reusablePCMBuffer = nil
        reusableMonoBuffer = nil
        lastPCMFormat = nil
        lastMonoFormat = nil
        conversionBuffer = []
    }

    func stopRecording() -> URL? {
        guard captureSession != nil else { return nil }

        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        audioFile = nil
        isRecording = false

        // Clear reusable buffers
        reusablePCMBuffer = nil
        reusableMonoBuffer = nil

        let url = recordingURL()

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 512 {
            print("[AudioRecorder] Recording saved: \(size) bytes")
            return url
        }

        print("[AudioRecorder] Recording too small or missing")
        return nil
    }

    private func recordingURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(recordingFilename)
    }
}

enum AudioRecorderError: Error {
    case invalidFormat
    case deviceSetupFailed
}
