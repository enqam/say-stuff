import Foundation

struct Profile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var language: String  // "en", "ru", "auto", etc.
    var whisperPrompt: String?
    var formatting: FormattingOptions

    static var defaultEnglish: Profile {
        Profile(
            id: UUID(),
            name: "English",
            language: "en",
            whisperPrompt: nil,
            formatting: FormattingOptions()
        )
    }

    static var defaultAuto: Profile {
        Profile(
            id: UUID(),
            name: "Auto-detect",
            language: "auto",
            whisperPrompt: nil,
            formatting: FormattingOptions()
        )
    }
}

struct FormattingOptions: Codable, Hashable {
    var trimWhitespace: Bool = true
    var collapseNewlines: Bool = true
    var addTrailingSpace: Bool = true
}

class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sayStuffDir = appSupport.appendingPathComponent("SayStuff")
        try? FileManager.default.createDirectory(at: sayStuffDir, withIntermediateDirectories: true)
        fileURL = sayStuffDir.appendingPathComponent("profiles.json")

        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Create default profiles
            profiles = [Profile.defaultEnglish, Profile.defaultAuto]
            save()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode([Profile].self, from: data)
        } catch {
            print("Failed to load profiles: \(error)")
            profiles = [Profile.defaultEnglish, Profile.defaultAuto]
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save profiles: \(error)")
        }
    }
}
