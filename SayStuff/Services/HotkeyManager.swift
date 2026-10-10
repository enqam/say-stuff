import Foundation
import Carbon.HIToolbox

/// Thin wrapper over Carbon global hotkeys. Reports raw press/release per hotkey id;
/// what a press *means* (hold vs. toggle) is decided by the caller.
final class HotkeyManager {
    struct ID: Hashable {
        let rawValue: UInt32
        static let dictation = ID(rawValue: 1)
        static func language(_ index: Int) -> ID { ID(rawValue: 100 + UInt32(index)) }
    }

    var onEvent: ((ID, _ isPress: Bool) -> Void)?

    private var refs: [ID: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private static let signature = OSType(0x53595354) // "SYST"

    init() {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        if status != noErr {
            print("[HotkeyManager] InstallEventHandler failed: \(status)")
        }
    }

    deinit {
        refs.values.forEach { UnregisterEventHotKey($0) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }

    /// Returns false if the shortcut couldn't be registered (usually: another app owns it).
    @discardableResult
    func register(_ id: ID, keyCode: UInt16, modifiers: UInt32) -> Bool {
        unregister(id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id.rawValue),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            print("[HotkeyManager] RegisterEventHotKey(\(id)) failed: \(status)")
            return false
        }
        refs[id] = ref
        return true
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    private static let handler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == signature else {
            return OSStatus(eventNotHandledErr)
        }
        let id = ID(rawValue: hotKeyID.id)

        let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        manager.onEvent?(id, isPress)
        return noErr
    }
}
