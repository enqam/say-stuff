import AVFoundation
import CoreAudio

class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioFile: AVAudioFile?
    private var audioFileURL: URL?
    private let recPath = "/tmp/saystuff_recording.wav"
    private let processingQueue = DispatchQueue(label: "com.saystuff.audio", qos: .userInitiated)

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0

    func startRecording() throws {
        // Clean up any existing session
        stopAndCleanup()

        // Remove old recording
        try? FileManager.default.removeItem(atPath: recPath)

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
        audioFileURL = URL(fileURLWithPath: recPath)

        // Start session
        session.startRunning()
        captureSession = session
        audioOutput = output
        isRecording = true
        print("[AudioRecorder] Recording started")
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

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let pcmBuffer = createPCMBuffer(from: sampleBuffer) else { return }

        // Calculate audio level
        if let channelData = pcmBuffer.floatChannelData?[0] {
            let frames = pcmBuffer.frameLength
            var sum: Float = 0
            for i in 0..<Int(frames) {
                let sample = channelData[i]
                sum += sample * sample
            }
            let rms = sqrt(sum / Float(frames))
            let linearLevel = min(1.0, rms * 25.0)
            let level = sqrt(linearLevel)
            DispatchQueue.main.async {
                self.audioLevel = level
            }
        }

        // Convert to mono and write
        let monoBuffer: AVAudioPCMBuffer
        if pcmBuffer.format.channelCount > 1 {
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: AVAudioFormat(
                    commonFormat: pcmBuffer.format.commonFormat,
                    sampleRate: pcmBuffer.format.sampleRate,
                    channels: 1,
                    interleaved: false
                )!,
                frameCapacity: pcmBuffer.frameLength
            ) else { return }

            mono.frameLength = pcmBuffer.frameLength

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

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

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
                // Non-interleaved float
                for ch in 0..<channelCount {
                    if let dst = pcmBuffer.floatChannelData?[ch] {
                        memcpy(dst, floatData.advanced(by: ch * frameCount), frameCount * MemoryLayout<Float>.size)
                    }
                }
            } else {
                // Interleaved float - deinterleave
                for frame in 0..<frameCount {
                    for ch in 0..<channelCount {
                        pcmBuffer.floatChannelData?[ch][frame] = floatData[frame * channelCount + ch]
                    }
                }
            }
        } else if asbd.mBitsPerChannel == 16 {
            // Source is 16-bit integer
            let int16Data = UnsafeRawPointer(data).assumingMemoryBound(to: Int16.self)
            let scale: Float = 1.0 / 32768.0

            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                // Non-interleaved int16
                for ch in 0..<channelCount {
                    if let dst = pcmBuffer.floatChannelData?[ch] {
                        for frame in 0..<frameCount {
                            dst[frame] = Float(int16Data[ch * frameCount + frame]) * scale
                        }
                    }
                }
            } else {
                // Interleaved int16 - deinterleave and convert
                for frame in 0..<frameCount {
                    for ch in 0..<channelCount {
                        pcmBuffer.floatChannelData?[ch][frame] = Float(int16Data[frame * channelCount + ch]) * scale
                    }
                }
            }
        } else if asbd.mBitsPerChannel == 32 && asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 {
            // Source is 32-bit integer
            let int32Data = UnsafeRawPointer(data).assumingMemoryBound(to: Int32.self)
            let scale: Float = 1.0 / 2147483648.0

            for frame in 0..<frameCount {
                for ch in 0..<channelCount {
                    pcmBuffer.floatChannelData?[ch][frame] = Float(int32Data[frame * channelCount + ch]) * scale
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
    }

    func stopRecording() -> URL? {
        guard captureSession != nil else { return nil }

        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        audioFile = nil
        isRecording = false

        let url = URL(fileURLWithPath: recPath)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: recPath),
           let size = attrs[.size] as? Int, size > 512 {
            print("[AudioRecorder] Recording saved: \(size) bytes")
            return url
        }

        print("[AudioRecorder] Recording too small or missing")
        return nil
    }
}

enum AudioRecorderError: Error {
    case invalidFormat
    case deviceSetupFailed
}
