import Foundation
import Carbon.HIToolbox

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?

    // Toggle mode support
    private var hotkeyMode: HotkeyMode = .hold
    private var isToggleActive = false
    private var toggleTimeoutTimer: Timer?
    private var toggleTimeout: Double = 30.0

    private var registeredModifiers: UInt32 = 0
    private var registeredKeyCode: UInt32 = 0

    private let hotKeyID = EventHotKeyID(signature: OSType(0x53595354), id: 1) // "SYST"

    deinit {
        unregister()
    }

    /// Register hotkey using raw keyCode (preferred for F-keys and special keys)
    func register(modifiers: [String], keyCode: UInt16, mode: HotkeyMode = .hold, timeout: Double = 30.0, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onKeyDown = onDown
        self.onKeyUp = onUp
        self.hotkeyMode = mode
        self.toggleTimeout = timeout
        self.isToggleActive = false

        unregister()

        // Convert modifiers to Carbon modifiers
        registeredModifiers = 0
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command":
                registeredModifiers |= UInt32(cmdKey)
            case "shift":
                registeredModifiers |= UInt32(shiftKey)
            case "option", "alt":
                registeredModifiers |= UInt32(optionKey)
            case "control", "ctrl":
                registeredModifiers |= UInt32(controlKey)
            default:
                break
            }
        }

        registeredKeyCode = UInt32(keyCode)

        print("[HotkeyManager] Registering: modifiers=\(modifiers) keyCode=\(keyCode) mode=\(mode)")
        print("[HotkeyManager] Registered modifier flags: \(registeredModifiers)")

        installEventHandler()
        registerHotKey()
    }

    /// Legacy register method for backward compatibility (string-based key)
    func register(modifiers: [String], key: String, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        let keyCode = keyCodeForString(key)
        register(modifiers: modifiers, keyCode: keyCode, mode: .hold, timeout: 30.0, onDown: onDown, onUp: onUp)
    }

    func unregister() {
        toggleTimeoutTimer?.invalidate()
        toggleTimeoutTimer = nil

        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func installEventHandler() {
        var eventTypes: [EventTypeSpec] = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            print("[HotkeyManager] ERROR: InstallEventHandler failed: \(status)")
        }
    }

    private func registerHotKey() {
        let status = RegisterEventHotKey(
            registeredKeyCode,
            registeredModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            print("[HotkeyManager] ERROR: RegisterEventHotKey failed: \(status)")
        } else {
            print("[HotkeyManager] Hotkey registered - ready!")
        }
    }

    private func handleHotKeyEvent(kind: UInt32) {
        switch hotkeyMode {
        case .hold:
            if kind == UInt32(kEventHotKeyPressed) {
                print("[HotkeyManager] Hotkey DOWN detected!")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            } else if kind == UInt32(kEventHotKeyReleased) {
                print("[HotkeyManager] Hotkey UP detected!")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
        case .toggle:
            if kind == UInt32(kEventHotKeyPressed) {
                if !isToggleActive {
                    isToggleActive = true
                    print("[HotkeyManager] Toggle ON - starting recording")
                    DispatchQueue.main.async { [weak self] in
                        self?.onKeyDown?()
                        self?.startToggleTimeout()
                    }
                } else {
                    stopToggle()
                }
            }
        }
    }

    private func startToggleTimeout() {
        toggleTimeoutTimer?.invalidate()
        toggleTimeoutTimer = Timer.scheduledTimer(withTimeInterval: toggleTimeout, repeats: false) { [weak self] _ in
            print("[HotkeyManager] Toggle timeout reached, stopping recording")
            self?.stopToggle()
        }
    }

    private func stopToggle() {
        guard isToggleActive else { return }
        isToggleActive = false
        toggleTimeoutTimer?.invalidate()
        toggleTimeoutTimer = nil
        print("[HotkeyManager] Toggle OFF - stopping recording")
        DispatchQueue.main.async { [weak self] in
            self?.onKeyUp?()
        }
    }

    private static let hotKeyEventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()

        let kind = GetEventKind(event)
        manager.handleHotKeyEvent(kind: kind)
        return noErr
    }

    private func keyCodeForString(_ key: String) -> UInt16 {
        let keyMap: [String: UInt16] = [
            "a": UInt16(kVK_ANSI_A),
            "b": UInt16(kVK_ANSI_B),
            "c": UInt16(kVK_ANSI_C),
            "d": UInt16(kVK_ANSI_D),
            "e": UInt16(kVK_ANSI_E),
            "f": UInt16(kVK_ANSI_F),
            "g": UInt16(kVK_ANSI_G),
            "h": UInt16(kVK_ANSI_H),
            "i": UInt16(kVK_ANSI_I),
            "j": UInt16(kVK_ANSI_J),
            "k": UInt16(kVK_ANSI_K),
            "l": UInt16(kVK_ANSI_L),
            "m": UInt16(kVK_ANSI_M),
            "n": UInt16(kVK_ANSI_N),
            "o": UInt16(kVK_ANSI_O),
            "p": UInt16(kVK_ANSI_P),
            "q": UInt16(kVK_ANSI_Q),
            "r": UInt16(kVK_ANSI_R),
            "s": UInt16(kVK_ANSI_S),
            "t": UInt16(kVK_ANSI_T),
            "u": UInt16(kVK_ANSI_U),
            "v": UInt16(kVK_ANSI_V),
            "w": UInt16(kVK_ANSI_W),
            "x": UInt16(kVK_ANSI_X),
            "y": UInt16(kVK_ANSI_Y),
            "z": UInt16(kVK_ANSI_Z),
            "space": UInt16(kVK_Space),
            // F-keys for backward compatibility
            "f1": UInt16(kVK_F1), "f2": UInt16(kVK_F2), "f3": UInt16(kVK_F3),
            "f4": UInt16(kVK_F4), "f5": UInt16(kVK_F5), "f6": UInt16(kVK_F6),
            "f7": UInt16(kVK_F7), "f8": UInt16(kVK_F8), "f9": UInt16(kVK_F9),
            "f10": UInt16(kVK_F10), "f11": UInt16(kVK_F11), "f12": UInt16(kVK_F12),
            "f13": UInt16(kVK_F13), "f14": UInt16(kVK_F14), "f15": UInt16(kVK_F15),
            "f16": UInt16(kVK_F16), "f17": UInt16(kVK_F17), "f18": UInt16(kVK_F18),
            "f19": UInt16(kVK_F19), "f20": UInt16(kVK_F20),
        ]

        return keyMap[key.lowercased()] ?? UInt16(kVK_ANSI_V)
    }
}
