import AVFoundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable, Codable {
    let id: AudioDeviceID
    let name: String
    let uid: String

    func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid
    }
}

class AudioDeviceManager: ObservableObject {
    static let shared = AudioDeviceManager()

    @Published var inputDevices: [AudioDevice] = []
    @Published var selectedDeviceUID: String?

    init() {
        refreshDevices()
        setupDeviceChangeListener()
    }

    func refreshDevices() {
        inputDevices = getInputDevices()
        print("[AudioDeviceManager] Found \(inputDevices.count) input devices:")
        for device in inputDevices {
            print("  - \(device.name) (UID: \(device.uid))")
        }
    }

    private func getInputDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else { return [] }

        var inputDevices: [AudioDevice] = []

        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )

            var inputSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)

            if status == noErr && inputSize > 0 {
                let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
                defer { bufferListPtr.deallocate() }

                status = AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &inputSize, bufferListPtr)

                if status == noErr {
                    let bufferList = bufferListPtr.pointee
                    var hasInput = false

                    withUnsafePointer(to: bufferList.mBuffers) { ptr in
                        for i in 0..<Int(bufferList.mNumberBuffers) {
                            let buffer = ptr.advanced(by: i).pointee
                            if buffer.mNumberChannels > 0 {
                                hasInput = true
                                break
                            }
                        }
                    }

                    if hasInput {
                        if let name = getDeviceName(deviceID), let uid = getDeviceUID(deviceID) {
                            inputDevices.append(AudioDevice(id: deviceID, name: name, uid: uid))
                        }
                    }
                }
            }
        }

        return inputDevices
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &name
        )

        return status == noErr ? name as String? : nil
    }

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &uid
        )

        return status == noErr ? uid as String? : nil
    }

    func getDeviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices.first { $0.uid == uid }?.id
    }

    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            self?.refreshDevices()
        }
    }
}
