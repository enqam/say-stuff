import AVFoundation
import CoreAudio

struct AudioDevice: Identifiable, Hashable, Codable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    /// Core Audio transport type (`kAudioDeviceTransportType…`); 0 when unknown.
    var transport: UInt32 = 0

    private enum CodingKeys: String, CodingKey { case id, name, uid }

    /// Bluetooth headsets drop playback to call quality while their mic is open, and iPhone
    /// mics come and go; neither is ever picked unless the user chose it.
    var isAutoSelectable: Bool {
        ![kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
          kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless]
            .contains(transport)
    }

    /// Core Audio makes private "CADefaultDeviceAggregate-<pid>-<n>" devices for other apps'
    /// audio sessions; they vanish with that app, so they're never offered as mics.
    static func isTransient(uid: String) -> Bool {
        uid.hasPrefix("CADefaultDeviceAggregate")
    }

    /// True for the device the user chose, even after it reconnects on another USB port
    /// (USB UIDs end in the port's location) or with a new UID.
    func matches(uid preferredUID: String, name preferredName: String?) -> Bool {
        if uid == preferredUID { return true }
        if let key = Self.portIndependentKey(uid), key == Self.portIndependentKey(preferredUID) { return true }
        return name == preferredName
    }

    /// "AppleUSBAudioEngine:COMICA:Comica_VM40 RX MIC:100000:1" → "AppleUSBAudioEngine:COMICA:Comica_VM40 RX MIC"
    private static func portIndependentKey(_ uid: String) -> String? {
        guard uid.hasPrefix("AppleUSBAudioEngine:") else { return nil }
        let parts = uid.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count > 3 else { return nil }
        return parts.dropLast(2).joined(separator: ":")
    }

    /// Compact label for chips: "Sasha’s AirPods Pro #3" → "AirPods Pro #3", "MacBook Pro Microphone" → "MacBook Pro".
    var shortName: String {
        var result = name
        for apostrophe in ["’s ", "'s "] {
            if let range = result.range(of: apostrophe) { result = String(result[range.upperBound...]) }
        }
        result = result.replacingOccurrences(of: #"\s*Microphone$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return result.isEmpty ? name : result
    }

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

    /// Device changes are read on this queue: each property read is a round trip to coreaudiod
    /// (1-5 ms per scan, 60 ms seen), and Core Audio announces several changes per dictation
    /// as the mic and sounds start and stop.
    private let scanQueue = DispatchQueue(label: "com.saystuff.devices", qos: .userInitiated)

    func refreshDevices() {
        update(Self.currentInputDevices())
    }

    /// Publishes only real changes, so a dictation's temporary devices don't wake the UI.
    private func update(_ devices: [AudioDevice]) {
        func key(_ list: [AudioDevice]) -> [String] { list.map { "\($0.id)|\($0.uid)|\($0.name)" } }
        guard key(devices) != key(inputDevices) else { return }
        inputDevices = devices
    }

    /// Safe to call from any thread.
    static func currentInputDevices() -> [AudioDevice] {
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
                        if let name = getDeviceName(deviceID), let uid = getDeviceUID(deviceID),
                           !AudioDevice.isTransient(uid: uid) {
                            inputDevices.append(AudioDevice(id: deviceID, name: name, uid: uid, transport: transportType(deviceID)))
                        }
                    }
                }
            }
        }

        return inputDevices
    }

    private static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &name
        )

        guard status == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func transportType(_ deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        return status == noErr ? transport : 0
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// The mic to record from: the chosen one whenever it's connected; otherwise the system
    /// input, the built-in mic, or another wired mic, in that order. Safe to call from any thread.
    static func microphone(preferredUID: String?, preferredName: String?) -> AudioDevice? {
        let devices = currentInputDevices()
        if let preferredUID {
            let chosen = devices.first { $0.uid == preferredUID }
                ?? devices.first { $0.matches(uid: preferredUID, name: preferredName) }
            if let chosen { return chosen }
        }
        let candidates = devices.filter(\.isAutoSelectable)
        let systemDefault = defaultInputDeviceID()
        return candidates.first { $0.id == systemDefault }
            ?? candidates.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? candidates.first {
                $0.transport != kAudioDeviceTransportTypeAggregate && $0.transport != kAudioDeviceTransportTypeVirtual
            }
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
            scanQueue
        ) { [weak self] _, _ in
            let devices = Self.currentInputDevices()
            DispatchQueue.main.async { self?.update(devices) }
        }
    }
}

/// Undoes macOS's own device switches that SayStuff's users never want:
/// - a mic plugged into the headphone jack also shows up as "External Headphones", and macOS
///   makes it the output (plug-in, AirPods disconnecting, login). Plain headphones (no mic on
///   the jack) are left alone.
/// - AirPods and iPhones become the system input when they connect; the Sound pane's level
///   meter then opens their mic, which drops AirPods playback to call quality.
/// A switch soon after devices come or go is macOS's; one chosen in Sound settings later is kept.
final class AutoSwitchGuard {
    static let shared = AutoSwitchGuard()

    private static let jackOutputUID = "BuiltInHeadphoneOutputDevice"
    private static let jackInputUID = "BuiltInHeadphoneInputDevice"
    private static let automaticWindow: TimeInterval = 3

    private let queue = DispatchQueue(label: "com.saystuff.auto-switch-guard", qos: .userInitiated)
    private var lastDeviceChange = Date.distantPast
    /// What to go back to: the last default that wasn't unwanted.
    private var lastGoodOutput: AudioDeviceID?
    private var lastGoodInput: AudioDeviceID?

    func start() {
        queue.async { [self] in
            // Whatever macOS picked before launch (login, AirPods connecting) counts as automatic.
            lastDeviceChange = Date()
            listen(kAudioHardwarePropertyDevices) { [self] in
                lastDeviceChange = Date()
                check()
            }
            listen(kAudioHardwarePropertyDefaultOutputDevice) { [self] in check() }
            listen(kAudioHardwarePropertyDefaultInputDevice) { [self] in check() }
            check()
        }
    }

    private func check() {
        let automatic = Date().timeIntervalSince(lastDeviceChange) < Self.automaticWindow

        if let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) {
            if Self.uid(output) != Self.jackOutputUID || Self.device(uid: Self.jackInputUID) == nil {
                lastGoodOutput = output
            } else if automatic, let replacement = Self.present(lastGoodOutput) ?? Self.device(uid: "BuiltInSpeakerDevice") {
                Self.setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: replacement)
                if Self.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) == output {
                    Self.setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, to: replacement)
                }
            }
        }

        if let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) {
            let devices = AudioDeviceManager.currentInputDevices()
            if devices.first(where: { $0.id == input })?.isAutoSelectable ?? true {
                lastGoodInput = input
            } else if automatic, let replacement = Self.present(lastGoodInput)
                        ?? AudioDeviceManager.microphone(preferredUID: nil, preferredName: nil)?.id {
                Self.setDefault(kAudioHardwarePropertyDefaultInputDevice, to: replacement)
            }
        }
    }

    /// The device, if it's still connected.
    private static func present(_ deviceID: AudioDeviceID?) -> AudioDeviceID? {
        deviceID.flatMap { uid($0) != nil ? $0 : nil }
    }

    private func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { _, _ in handler() }
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, to deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var deviceID = deviceID
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
    }

    private static func uid(_ deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func device(uid: String) -> AudioDeviceID? {
        var cfUID = uid as CFString
        var deviceID: AudioDeviceID = 0
        var translation = AudioValueTranslation(
            mInputData: &cfUID, mInputDataSize: UInt32(MemoryLayout<CFString>.size),
            mOutputData: &deviceID, mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size))
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &translation)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }
}
