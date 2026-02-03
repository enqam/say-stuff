import Cocoa
import Carbon.HIToolbox

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?

    private var registeredModifiers: CGEventFlags = []
    private var registeredKeyCode: CGKeyCode = 0
    private var isKeyDown = false

    // Toggle mode support
    private var hotkeyMode: HotkeyMode = .hold
    private var isToggleActive = false
    private var toggleTimeoutTimer: Timer?
    private var toggleTimeout: Double = 30.0

    // Mask to extract only the modifier keys we care about
    private let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

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

        // Convert modifiers to CGEventFlags
        registeredModifiers = []
        for mod in modifiers {
            switch mod.lowercased() {
            case "cmd", "command":
                registeredModifiers.insert(.maskCommand)
            case "shift":
                registeredModifiers.insert(.maskShift)
            case "option", "alt":
                registeredModifiers.insert(.maskAlternate)
            case "control", "ctrl":
                registeredModifiers.insert(.maskControl)
            default:
                break
            }
        }

        // Use raw keyCode directly
        registeredKeyCode = CGKeyCode(keyCode)

        print("[HotkeyManager] Registering: modifiers=\(modifiers) keyCode=\(keyCode) mode=\(mode)")
        print("[HotkeyManager] Registered modifier flags: \(registeredModifiers.rawValue)")

        setupEventTap()
    }

    /// Legacy register method for backward compatibility (string-based key)
    func register(modifiers: [String], key: String, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        let keyCode = keyCodeForString(key)
        register(modifiers: modifiers, keyCode: keyCode, mode: .hold, timeout: 30.0, onDown: onDown, onUp: onUp)
    }

    private func setupEventTap() {
        // Clean up any existing tap
        unregister()

        // Create event tap
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyManager] ERROR: Failed to create event tap!")
            print("[HotkeyManager] Make sure Accessibility permission is granted for THIS app")
            print("[HotkeyManager] System Preferences > Privacy & Security > Accessibility")
            return
        }

        print("[HotkeyManager] Event tap created successfully")

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            print("[HotkeyManager] Added to main run loop")
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyManager] Event tap enabled - ready!")
    }

    func unregister() {
        toggleTimeoutTimer?.invalidate()
        toggleTimeoutTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if it gets disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            print("[HotkeyManager] Tap was disabled, re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Extract only the modifier flags we care about
        let currentModifiers = flags.intersection(modifierMask)
        let modifiersMatch = currentModifiers == registeredModifiers
        let keyMatches = keyCode == registeredKeyCode

        switch hotkeyMode {
        case .hold:
            return handleHoldMode(type: type, modifiersMatch: modifiersMatch, keyMatches: keyMatches, flags: flags, event: event)
        case .toggle:
            return handleToggleMode(type: type, modifiersMatch: modifiersMatch, keyMatches: keyMatches, event: event)
        }
    }

    private func handleHoldMode(type: CGEventType, modifiersMatch: Bool, keyMatches: Bool, flags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Key down
        if type == .keyDown && modifiersMatch && keyMatches {
            if !isKeyDown {
                isKeyDown = true
                print("[HotkeyManager] Hotkey DOWN detected!")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                }
            }
            // Consume the event so it doesn't reach other apps
            return nil
        }

        // Key up
        if type == .keyUp && keyMatches && isKeyDown {
            isKeyDown = false
            print("[HotkeyManager] Hotkey UP detected!")
            DispatchQueue.main.async { [weak self] in
                self?.onKeyUp?()
            }
            // Consume the event
            return nil
        }

        // Detect modifier release while key might still be conceptually "held"
        if type == .flagsChanged && isKeyDown {
            let currentMods = flags.intersection(modifierMask)
            if currentMods != registeredModifiers {
                isKeyDown = false
                print("[HotkeyManager] Modifiers released, triggering UP")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyUp?()
                }
            }
        }

        // Pass through all other events
        return Unmanaged.passRetained(event)
    }

    private func handleToggleMode(type: CGEventType, modifiersMatch: Bool, keyMatches: Bool, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Only respond to keyDown for toggle mode
        if type == .keyDown && modifiersMatch && keyMatches {
            if !isToggleActive {
                // First press: start recording
                isToggleActive = true
                print("[HotkeyManager] Toggle ON - starting recording")
                DispatchQueue.main.async { [weak self] in
                    self?.onKeyDown?()
                    self?.startToggleTimeout()
                }
            } else {
                // Second press: stop recording
                stopToggle()
            }
            // Consume the event
            return nil
        }

        // Pass through all other events
        return Unmanaged.passRetained(event)
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
