import Foundation
@main struct DefaultsSmoke {
    static func main() throws {
        let settings = AppSettings()
        assert(settings.modelSize == .small)
        assert(settings.hotkeyKeyCode == 0 && settings.hotkeyKey == "a")
        assert(Set(settings.hotkeyModifiers) == Set(["cmd", "shift", "option", "control"]))
        assert(settings.hotkeyMode == .toggle && settings.toggleTimeout == 300)
        assert(settings.selectedAudioDeviceUID == nil)
        assert(!settings.hasCompletedOnboarding)
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        assert(restored.modelSize == .small && restored.hotkeyMode == .toggle)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{\"modelSize\":\"medium\",\"hotkeyMode\":\"hold\",\"hotkeyKeyCode\":9}".utf8))
        assert(old.modelSize == .medium && old.hotkeyMode == .hold && old.hotkeyKeyCode == 9)
        print("PASS: Small, Hyper+A, toggle, system mic, onboarding, and preserved existing settings")
    }
}
