import Foundation

struct AppSettings: Codable {
    var modelSize: WhisperModel = .largeTurbo
    var whisperPath: String = "/usr/local/bin/whisper-cli"
    var modelDirectory: String = "~/Library/Application Support/SayStuff/models"
    var selectedAudioDeviceUID: String? = nil  // nil = system default
    var hotkeyModifiers: [String] = ["option", "cmd"]
    var hotkeyKey: String = "v"
    var showMenuBarIcon: Bool = true
    var playSounds: Bool = true
    var hasCompletedOnboarding: Bool = false
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet {
            save()
        }
    }

    private let defaults = UserDefaults.standard
    private let settingsKey = "AppSettings"

    init() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    var modelPath: String {
        URL(fileURLWithPath: settings.modelDirectory).appendingPathComponent(settings.modelSize.filename).path
    }

    var whisperBinaryPath: String {
        settings.whisperPath
    }
}
