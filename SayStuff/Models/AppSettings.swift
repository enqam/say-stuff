import Foundation
import Carbon.HIToolbox

struct SupportedLanguage: Identifiable {
    let code: String
    let shortLabel: String
    let name: String
    var id: String { code }
}

let allSupportedLanguages: [SupportedLanguage] = [
    SupportedLanguage(code: "auto", shortLabel: "AUTO", name: "Auto-detect"),
    SupportedLanguage(code: "en", shortLabel: "EN", name: "English"),
    SupportedLanguage(code: "ru", shortLabel: "RU", name: "Russian"),
    SupportedLanguage(code: "es", shortLabel: "ES", name: "Spanish"),
    SupportedLanguage(code: "fr", shortLabel: "FR", name: "French"),
    SupportedLanguage(code: "de", shortLabel: "DE", name: "German"),
]

enum HotkeyMode: String, Codable, CaseIterable {
    case hold = "hold"
    case toggle = "toggle"

    var displayName: String {
        switch self {
        case .hold: return "Hold to Record"
        case .toggle: return "Toggle (Press to Start/Stop)"
        }
    }
}

struct AppSettings: Codable {
    var modelSize: WhisperModel = .small
    var whisperPath: String = "/usr/local/bin/whisper-cli"
    var modelDirectory: String = "~/Library/Application Support/SayStuff/models"
    var selectedAudioDeviceUID: String? = nil  // nil = system default
    var hotkeyModifiers: [String] = ["cmd", "shift", "option", "control"]
    var hotkeyKey: String = "a"
    var hotkeyKeyCode: UInt16 = UInt16(kVK_ANSI_A)  // Raw keyCode for F-keys etc.
    var hotkeyMode: HotkeyMode = .toggle
    var toggleTimeout: Double = 300.0  // seconds, for toggle mode
    var showMenuBarIcon: Bool = true
    var playSounds: Bool = true
    var hasCompletedOnboarding: Bool = false
    var showLogoInMenu: Bool = true
    var menuLanguages: [String] = ["en", "ru", "auto"]
    var attenuateAudio: Bool = true
    var attenuationLevel: Float = 0.25

    // Custom decoder that handles missing keys gracefully
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelSize = try container.decodeIfPresent(WhisperModel.self, forKey: .modelSize) ?? .largeTurbo
        whisperPath = try container.decodeIfPresent(String.self, forKey: .whisperPath) ?? "/usr/local/bin/whisper-cli"
        modelDirectory = try container.decodeIfPresent(String.self, forKey: .modelDirectory) ?? "~/Library/Application Support/SayStuff/models"
        selectedAudioDeviceUID = try container.decodeIfPresent(String.self, forKey: .selectedAudioDeviceUID)
        hotkeyModifiers = try container.decodeIfPresent([String].self, forKey: .hotkeyModifiers) ?? ["option", "cmd"]
        hotkeyKey = try container.decodeIfPresent(String.self, forKey: .hotkeyKey) ?? "v"
        hotkeyKeyCode = try container.decodeIfPresent(UInt16.self, forKey: .hotkeyKeyCode) ?? UInt16(kVK_ANSI_V)
        hotkeyMode = try container.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? .hold
        toggleTimeout = try container.decodeIfPresent(Double.self, forKey: .toggleTimeout) ?? 30.0
        showMenuBarIcon = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        playSounds = try container.decodeIfPresent(Bool.self, forKey: .playSounds) ?? true
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        showLogoInMenu = try container.decodeIfPresent(Bool.self, forKey: .showLogoInMenu) ?? true
        menuLanguages = try container.decodeIfPresent([String].self, forKey: .menuLanguages) ?? ["en", "ru", "auto"]
        attenuateAudio = try container.decodeIfPresent(Bool.self, forKey: .attenuateAudio) ?? true
        attenuationLevel = try container.decodeIfPresent(Float.self, forKey: .attenuationLevel) ?? 0.25
    }

    // Default initializer
    init() {}
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var settings: AppSettings {
        didSet {
            save()
        }
    }

    @Published var downloadingModels: Set<WhisperModel> = []
    @Published var downloadProgress: [WhisperModel: Double] = [:]

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

        ensureModelDirectoryExists()
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
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, fm.isExecutableFile(atPath: output) {
                return output
            }
        } catch {}

        return nil
    }

    /// Returns all valid whisper-cli paths found on the system
    static func findAllWhisperCLIPaths() -> [String] {
        let fm = FileManager.default
        var found: [String] = []

        if let bundled = bundledWhisperCLIPath(), fm.isExecutableFile(atPath: bundled) {
            found.append(bundled)
        }

        for path in whisperSearchPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                found.append(expanded)
            }
        }

        // Also try `which`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["whisper-cli"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty, fm.isExecutableFile(atPath: output), !found.contains(output) {
                found.append(output)
            }
        } catch {}

        return found
    }

    private static func bundledWhisperCLIPath() -> String? {
        let fm = FileManager.default
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let path = resourceURL.appendingPathComponent("whisper-cli").path
        return fm.fileExists(atPath: path) ? path : nil
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
        let path = (settings.modelDirectory as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    private func ensureModelDirectoryExists() {
        try? FileManager.default.createDirectory(at: expandedModelDirectory, withIntermediateDirectories: true)
    }

    func isModelDownloaded(_ model: WhisperModel) -> Bool {
        let path = modelURL(for: model).path
        return FileManager.default.fileExists(atPath: path)
    }

    func downloadModel(_ model: WhisperModel) {
        guard !downloadingModels.contains(model) else { return }

        downloadingModels.insert(model)
        downloadProgress[model] = 0

        let destinationURL = expandedModelDirectory.appendingPathComponent(model.filename)

        let task = URLSession.shared.downloadTask(with: model.downloadURL) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                self?.downloadingModels.remove(model)
                self?.downloadProgress.removeValue(forKey: model)

                guard let tempURL = tempURL, error == nil else {
                    print("[SettingsManager] Download failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }

                do {
                    // Remove existing file if present
                    try? FileManager.default.removeItem(at: destinationURL)
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    print("[SettingsManager] Downloaded \(model.displayName) to \(destinationURL.path)")
                    // Trigger UI update
                    self?.objectWillChange.send()
                } catch {
                    print("[SettingsManager] Failed to save model: \(error)")
                }
            }
        }

        // Observe progress
        let observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.downloadProgress[model] = progress.fractionCompleted
            }
        }

        // Store observation to keep it alive (in practice you'd want to manage this better)
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)

        task.resume()
    }
}
