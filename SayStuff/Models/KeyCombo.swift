import Carbon.HIToolbox
import AppKit

/// A global shortcut: modifier names ("cmd", "shift", "option", "control") plus a raw key code.
struct KeyCombo: Codable, Equatable {
    var modifiers: [String]
    var keyCode: UInt16
    /// Character captured when the shortcut was recorded; used for keys we have no name for.
    var fallbackKey: String = ""

    /// Same physical shortcut (ignores the cached display character).
    func sameKeys(as other: KeyCombo) -> Bool {
        keyCode == other.keyCode && Set(modifiers) == Set(other.modifiers)
    }

    var isHyper: Bool {
        Set(modifiers) == ["cmd", "shift", "option", "control"]
    }

    var carbonModifiers: UInt32 {
        modifiers.reduce(into: UInt32(0)) { flags, name in
            switch name {
            case "cmd": flags |= UInt32(cmdKey)
            case "shift": flags |= UInt32(shiftKey)
            case "option": flags |= UInt32(optionKey)
            case "control": flags |= UInt32(controlKey)
            default: break
            }
        }
    }

    /// Key caps to render, e.g. ["⌥", "⌘", "V"] or ["Hyper", "A"].
    var parts: [String] {
        var parts: [String] = []
        if isHyper {
            parts.append("Hyper")
        } else {
            if modifiers.contains("control") { parts.append("⌃") }
            if modifiers.contains("option") { parts.append("⌥") }
            if modifiers.contains("shift") { parts.append("⇧") }
            if modifiers.contains("cmd") { parts.append("⌘") }
        }
        parts.append(keyName)
        return parts
    }

    var displayString: String {
        isHyper ? "Hyper+\(keyName)" : parts.joined()
    }

    var keyName: String {
        if let name = Self.names[keyCode] { return name }
        let fallback = fallbackKey.uppercased()
        return fallback.isEmpty ? "?" : fallback
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys.contains(keyCode)
    }

    static func modifierNames(from flags: NSEvent.ModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.command) { names.append("cmd") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.control) { names.append("control") }
        return names
    }

    private static let functionKeys: Set<UInt16> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ].reduce(into: Set<UInt16>()) { $0.insert(UInt16($1)) }

    private static let names: [UInt16: String] = {
        var map: [UInt16: String] = [:]
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"), (kVK_ANSI_E, "E"),
            (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"), (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"),
            (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"), (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"),
            (kVK_ANSI_P, "P"), (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
            (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"), (kVK_ANSI_Y, "Y"),
            (kVK_ANSI_Z, "Z"),
            (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"), (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"),
            (kVK_ANSI_5, "5"), (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"),
            (kVK_F1, "F1"), (kVK_F2, "F2"), (kVK_F3, "F3"), (kVK_F4, "F4"), (kVK_F5, "F5"),
            (kVK_F6, "F6"), (kVK_F7, "F7"), (kVK_F8, "F8"), (kVK_F9, "F9"), (kVK_F10, "F10"),
            (kVK_F11, "F11"), (kVK_F12, "F12"), (kVK_F13, "F13"), (kVK_F14, "F14"), (kVK_F15, "F15"),
            (kVK_F16, "F16"), (kVK_F17, "F17"), (kVK_F18, "F18"), (kVK_F19, "F19"), (kVK_F20, "F20"),
            (kVK_Space, "Space"), (kVK_Return, "↩"), (kVK_Tab, "⇥"), (kVK_Escape, "⎋"),
            (kVK_Delete, "⌫"), (kVK_ForwardDelete, "⌦"),
            (kVK_LeftArrow, "←"), (kVK_RightArrow, "→"), (kVK_UpArrow, "↑"), (kVK_DownArrow, "↓"),
        ]
        for (code, name) in letters { map[UInt16(code)] = name }
        return map
    }()
}
