import Foundation
import Carbon.HIToolbox

struct SupportedLanguage: Identifiable {
    let code: String
    let name: String
    var id: String { code }
}

let allSupportedLanguages: [SupportedLanguage] = [
    SupportedLanguage(code: "auto", name: "Detect automatically"),
    SupportedLanguage(code: "en", name: "English"),
    SupportedLanguage(code: "ru", name: "Russian"),
    SupportedLanguage(code: "uk", name: "Ukrainian"),
    SupportedLanguage(code: "es", name: "Spanish"),
    SupportedLanguage(code: "ca", name: "Catalan"),
    SupportedLanguage(code: "fr", name: "French"),
    SupportedLanguage(code: "de", name: "German"),
    SupportedLanguage(code: "it", name: "Italian"),
    SupportedLanguage(code: "pt", name: "Portuguese"),
    SupportedLanguage(code: "nl", name: "Dutch"),
    SupportedLanguage(code: "pl", name: "Polish"),
    SupportedLanguage(code: "tr", name: "Turkish"),
    SupportedLanguage(code: "ja", name: "Japanese"),
    SupportedLanguage(code: "ko", name: "Korean"),
    SupportedLanguage(code: "zh", name: "Chinese"),
]

enum HotkeyMode: String, Codable, CaseIterable {
    case hold
    case toggle

    var displayName: String {
        switch self {
        case .hold: return "Hold to talk"
        case .toggle: return "Press to start and stop"
        }
    }
}

enum TranscriptionEngine: String, Codable, CaseIterable {
    case local
    case cloud

    var displayName: String {
        switch self {
        case .local: return "On this Mac"
        case .cloud: return "Cloud"
        }
    }
}

enum CloudProvider: String, Codable, CaseIterable {
    case groq
    case fal

    var displayName: String {
        switch self {
        case .groq: return "Groq Whisper"
        case .fal: return "fal.ai Wizper"
        }
    }

    var keyProvider: APIKeys.Provider {
        switch self {
        case .groq: return .groq
        case .fal: return .fal
        }
    }
}

struct AppSettings: Codable, Equatable {
    // Transcription
    var engine: TranscriptionEngine = .local
    var cloudProvider: CloudProvider = .groq
    var modelSize: WhisperModel = .small
    var whisperPath: String = "/usr/local/bin/whisper-cli"
    var modelDirectory: String = "~/Library/Application Support/SayStuff/models"
    var language: String = "auto"
    /// Languages offered as one-click chips in the menu, most recent first.
    var recentLanguages: [String] = ["en", "ru"]
    var addTrailingSpace: Bool = true

    // Output
    var activeProfileID: UUID? = nil  // nil = raw transcript
    var learnCorrections: Bool = true

    // Shortcut
    var hotkeyModifiers: [String] = ["cmd", "shift", "option", "control"]
    var hotkeyKey: String = "a"
    var hotkeyKeyCode: UInt16 = UInt16(kVK_ANSI_A)
    var hotkeyMode: HotkeyMode = .toggle
    var toggleTimeout: Double = 300.0  // seconds; recording stops automatically after this

    // Audio & feedback
    var selectedAudioDeviceUID: String? = nil  // nil = system default
    var playSounds: Bool = true
    var attenuateAudio: Bool = true
    var attenuationLevel: Float = 0.25
    var showScreenBorder: Bool = false

    var hasCompletedOnboarding: Bool = false

    var hotkey: KeyCombo {
        KeyCombo(modifiers: hotkeyModifiers, keyCode: hotkeyKeyCode, fallbackKey: hotkeyKey)
    }

    init() {}

    // Every field falls back to its default, so adding settings never invalidates a saved blob.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        engine = value(.engine, d.engine)
        cloudProvider = value(.cloudProvider, d.cloudProvider)
        modelSize = value(.modelSize, d.modelSize)
        whisperPath = value(.whisperPath, d.whisperPath)
        modelDirectory = value(.modelDirectory, d.modelDirectory)
        language = value(.language, UserDefaults.standard.string(forKey: "selectedLanguage") ?? d.language)
        recentLanguages = value(.recentLanguages, d.recentLanguages)
        addTrailingSpace = value(.addTrailingSpace, d.addTrailingSpace)
        activeProfileID = value(.activeProfileID, d.activeProfileID)
        learnCorrections = value(.learnCorrections, d.learnCorrections)
        hotkeyModifiers = value(.hotkeyModifiers, d.hotkeyModifiers)
        hotkeyKey = value(.hotkeyKey, d.hotkeyKey)
        hotkeyKeyCode = value(.hotkeyKeyCode, d.hotkeyKeyCode)
        hotkeyMode = value(.hotkeyMode, d.hotkeyMode)
        toggleTimeout = value(.toggleTimeout, d.toggleTimeout)
        selectedAudioDeviceUID = value(.selectedAudioDeviceUID, d.selectedAudioDeviceUID)
        attenuateAudio = value(.attenuateAudio, d.attenuateAudio)
        attenuationLevel = value(.attenuationLevel, d.attenuationLevel)
        showScreenBorder = value(.showScreenBorder, d.showScreenBorder)
        hasCompletedOnboarding = value(.hasCompletedOnboarding, d.hasCompletedOnboarding)
        playSounds = value(.playSounds, d.playSounds)
    }

    /// Picks the spoken language and keeps it in the menu's quick chips.
    mutating func selectLanguage(_ code: String) {
        language = code
        guard code != "auto" else { return }
        recentLanguages.removeAll { $0 == code }
        recentLanguages.insert(code, at: 0)
        recentLanguages = Array(recentLanguages.prefix(3))
    }
}

final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
        }
    }

    private let defaults = UserDefaults.standard
    private let settingsKey = "AppSettings"

    // Common locations where whisper-cli might be installed
    private static let whisperSearchPaths: [String] = [
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cli",
        "~/whisper.cpp/build/bin/whisper-cli",
        "~/whisper/build/bin/whisper-cli",
        "/usr/bin/whisper-cli",
        "~/.local/bin/whisper-cli"
    ]

    // Common locations where whisper models might be
    private static let modelSearchPaths: [String] = [
        "~/Library/Application Support/SayStuff/models",
        "~/whisper.cpp/models",
        "~/whisper/models",
        "/usr/local/share/whisper/models"
    ]

    init() {
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }

        // Auto-locate whisper-cli if saved path doesn't exist
        let expandedWhisperPath = (settings.whisperPath as NSString).expandingTildeInPath
        if let bundled = Self.bundledWhisperCLIPath(), FileManager.default.isExecutableFile(atPath: bundled) {
            settings.whisperPath = bundled
        } else if !FileManager.default.isExecutableFile(atPath: expandedWhisperPath) {
            if let foundPath = Self.findWhisperCLI() {
                settings.whisperPath = foundPath
                print("[SettingsManager] Auto-located whisper-cli at: \(foundPath)")
            }
        } else if settings.whisperPath != expandedWhisperPath {
            // Normalize "~" to an absolute path so Process() can execute it
            settings.whisperPath = expandedWhisperPath
        }

        // Auto-locate models directory if current one is empty or doesn't exist
        let expandedModelDir = (settings.modelDirectory as NSString).expandingTildeInPath
        if !Self.directoryHasModels(expandedModelDir) {
            if let foundDir = Self.findModelsDirectory() {
                settings.modelDirectory = foundDir
                print("[SettingsManager] Auto-located models at: \(foundDir)")
            }
        }

        try? FileManager.default.createDirectory(at: expandedModelDirectory, withIntermediateDirectories: true)
    }

    /// Checks if a directory contains any .bin model files
    private static func directoryHasModels(_ path: String) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return false }
        return contents.contains { $0.hasSuffix(".bin") }
    }

    /// Finds a directory containing whisper models
    static func findModelsDirectory() -> String? {
        for path in modelSearchPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if directoryHasModels(expanded) {
                return path  // Return unexpanded for portability
            }
        }
        return nil
    }

    /// Searches common locations for whisper-cli and returns the first valid path found
    static func findWhisperCLI() -> String? {
        let fm = FileManager.default

        // Prefer a bundled whisper-cli if present (for self-contained releases)
        if let bundled = bundledWhisperCLIPath(), fm.isExecutableFile(atPath: bundled) {
            return bundled
        }

        for path in whisperSearchPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        // Fallback: try `which whisper-cli`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["whisper-cli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, fm.isExecutableFile(atPath: output) {
                return output
            }
        } catch {}

        return nil
    }

    private static func bundledWhisperCLIPath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent("whisper-cli").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(settings) {
            defaults.set(encoded, forKey: settingsKey)
        }
    }

    func modelURL(for model: WhisperModel) -> URL {
        let local = expandedModelDirectory.appendingPathComponent(model.filename)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        if let bundled = Bundle.main.url(forResource: model.filename, withExtension: nil) {
            return bundled
        }
        for directory in Self.modelSearchPaths {
            let candidate = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
                .appendingPathComponent(model.filename)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return local
    }

    var modelPath: String { modelURL(for: settings.modelSize).path }

    var whisperBinaryPath: String {
        (settings.whisperPath as NSString).expandingTildeInPath
    }

    var expandedModelDirectory: URL {
        URL(fileURLWithPath: (settings.modelDirectory as NSString).expandingTildeInPath)
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: model).path)
    }
}
