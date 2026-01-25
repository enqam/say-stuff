import AVFoundation
import CoreAudio

class AudioRecorder: ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private let recPath = "/tmp/saystuff_recording.wav"

    @Published var isRecording = false
    @Published var audioLevel: Float = 0.0  // 0.0 to 1.0

    func startRecording() throws {
        guard audioEngine == nil else { return }

        // Remove old recording
        try? FileManager.default.removeItem(atPath: recPath)

        // Set system input device BEFORE creating engine
        if let deviceUID = SettingsManager.shared.settings.selectedAudioDeviceUID,
           let deviceID = AudioDeviceManager.shared.getDeviceID(forUID: deviceUID) {
            setSystemInputDevice(deviceID)
            print("[AudioRecorder] Set system input to device: \(deviceUID)")
        } else {
            print("[AudioRecorder] Using system default input device")
        }

        // Create fresh engine after device is set
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Get the format AFTER engine is created with correct device
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 else {
            print("[AudioRecorder] Invalid input format: \(inputFormat)")
            throw AudioRecorderError.invalidFormat
        }

        print("[AudioRecorder] Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount)ch")

        // Create output file with matching sample rate
        let outputURL = URL(fileURLWithPath: recPath)

        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        )

        // Install tap using the input node's native format
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self, let audioFile = self.audioFile else { return }

            // Calculate audio level (RMS)
            if let channelData = buffer.floatChannelData?[0] {
                let frames = buffer.frameLength
                var sum: Float = 0
                for i in 0..<Int(frames) {
                    let sample = channelData[i]
                    sum += sample * sample
                }
                let rms = sqrt(sum / Float(frames))
                // Linear scaling first
                let linearLevel = min(1.0, rms * 25.0)
                // Non-linear curve: sqrt boosts quiet sounds, compresses loud ones
                let level = sqrt(linearLevel)
                DispatchQueue.main.async {
                    self.audioLevel = level
                }
            }

            // Convert to mono if needed
            let monoBuffer: AVAudioPCMBuffer
            if buffer.format.channelCount > 1 {
                guard let mono = AVAudioPCMBuffer(
                    pcmFormat: AVAudioFormat(
                        commonFormat: buffer.format.commonFormat,
                        sampleRate: buffer.format.sampleRate,
                        channels: 1,
                        interleaved: false
                    )!,
                    frameCapacity: buffer.frameLength
                ) else { return }

                mono.frameLength = buffer.frameLength

                if let src = buffer.floatChannelData?[0],
                   let dst = mono.floatChannelData?[0] {
                    memcpy(dst, src, Int(buffer.frameLength) * MemoryLayout<Float>.size)
                }
                monoBuffer = mono
            } else {
                monoBuffer = buffer
            }

            do {
                try audioFile.write(from: monoBuffer)
            } catch {
                print("[AudioRecorder] Write error: \(error)")
            }
        }

        try engine.start()
        audioEngine = engine
        isRecording = true
        print("[AudioRecorder] Recording started")
    }

    private func setSystemInputDevice(_ deviceID: AudioDeviceID) {
        var deviceIDVar = deviceID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceIDVar
        )

        if status != noErr {
            print("[AudioRecorder] Warning: Failed to set system input device: \(status)")
        }
    }

    func stopRecording() -> URL? {
        guard let engine = audioEngine else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioEngine = nil
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
