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

    // Mask to extract only the modifier keys we care about
    private let modifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    deinit {
        unregister()
    }

    func register(modifiers: [String], key: String, onDown: @escaping () -> Void, onUp: @escaping () -> Void) {
        self.onKeyDown = onDown
        self.onKeyUp = onUp

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

        // Convert key to keycode
        registeredKeyCode = keyCodeForString(key)

        print("[HotkeyManager] Registering: modifiers=\(modifiers) key=\(key) keyCode=\(registeredKeyCode)")
        print("[HotkeyManager] Registered modifier flags: \(registeredModifiers.rawValue)")

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

    private func keyCodeForString(_ key: String) -> CGKeyCode {
        let keyMap: [String: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A),
            "b": CGKeyCode(kVK_ANSI_B),
            "c": CGKeyCode(kVK_ANSI_C),
            "d": CGKeyCode(kVK_ANSI_D),
            "e": CGKeyCode(kVK_ANSI_E),
            "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G),
            "h": CGKeyCode(kVK_ANSI_H),
            "i": CGKeyCode(kVK_ANSI_I),
            "j": CGKeyCode(kVK_ANSI_J),
            "k": CGKeyCode(kVK_ANSI_K),
            "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M),
            "n": CGKeyCode(kVK_ANSI_N),
            "o": CGKeyCode(kVK_ANSI_O),
            "p": CGKeyCode(kVK_ANSI_P),
            "q": CGKeyCode(kVK_ANSI_Q),
            "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S),
            "t": CGKeyCode(kVK_ANSI_T),
            "u": CGKeyCode(kVK_ANSI_U),
            "v": CGKeyCode(kVK_ANSI_V),
            "w": CGKeyCode(kVK_ANSI_W),
            "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y),
            "z": CGKeyCode(kVK_ANSI_Z),
            "space": CGKeyCode(kVK_Space),
        ]

        return keyMap[key.lowercased()] ?? CGKeyCode(kVK_ANSI_V)
    }
}
