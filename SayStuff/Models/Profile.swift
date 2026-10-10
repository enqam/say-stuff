import Foundation

/// An output profile: how a transcript is reshaped before it's pasted.
/// "Raw" isn't a profile — it's the absence of one (`activeProfileID == nil`).
struct Profile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var summary: String
    var instructions: String
    var isBuiltIn: Bool

    static let promptID = UUID(uuidString: "6B1F3A52-1C0E-4C55-9A0B-5A11F0000001")!
    static let formalID = UUID(uuidString: "6B1F3A52-1C0E-4C55-9A0B-5A11F0000002")!

    static let prompt = Profile(
        id: promptID,
        name: "Prompt",
        symbol: "list.bullet",
        summary: "Organized into clear steps",
        instructions: """
        Restructure the dictation into the clearest possible written form, like a prompt for an AI assistant.
        - When the speaker lists things ("first… then… finally…"), turn them into a numbered list, one item per line.
        - When the speaker corrects or overrides something later ("actually, don't do it that way, do this"), \
        keep it as a separate plain line after the list, not as a list item.
        - Remove filler words and false starts. Keep every requirement and detail; never add new ones.
        - Output only the rewritten text.
        """,
        isBuiltIn: true
    )

    static let formal = Profile(
        id: formalID,
        name: "Formal",
        symbol: "envelope",
        summary: "Polished, like an email",
        instructions: """
        Rewrite the dictation as clean, formal written language, as if it were part of an email.
        - Fix punctuation, capitalization and grammar. Remove filler words and false starts.
        - Keep the speaker's wording and meaning; change as little as possible.
        - Don't add greetings, sign-offs or content that wasn't said.
        - Output only the rewritten text.
        """,
        isBuiltIn: true
    )

    static let builtIns: [Profile] = [prompt, formal]

    static func newCustom() -> Profile {
        Profile(
            id: UUID(),
            name: "New profile",
            symbol: "sparkles",
            summary: "Custom",
            instructions: "Describe how the dictation should be rewritten.",
            isBuiltIn: false
        )
    }
}

/// A fixed spoken sample used to preview what each profile produces.
enum ProfileSample {
    static let spoken = "um so first I want the login page fixed then add dark mode and finally update the readme actually no skip the readme do the changelog instead"

    static let raw = "Um, so first I want the login page fixed, then add dark mode and finally update the readme. Actually no, skip the readme, do the changelog instead."

    static func output(for profile: Profile?) -> String? {
        guard let profile else { return raw }
        switch profile.id {
        case Profile.promptID:
            return """
            1. Fix the login page.
            2. Add dark mode.
            3. Update the changelog.

            Skip the README; do the changelog instead.
            """
        case Profile.formalID:
            return "First, I would like the login page fixed, then dark mode added, and finally the README updated. Actually, please skip the README and update the changelog instead."
        default:
            return nil  // Custom profiles get a live preview once the formatter is connected.
        }
    }
}

final class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [Profile] = [] {
        didSet { save() }
    }

    private let fileURL: URL

    init() {
        fileURL = AppPaths.support.appendingPathComponent("output-profiles.json")
        load()
    }

    func profile(id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? {
        profiles.firstIndex { $0.id == id }
    }

    @discardableResult
    func addCustom() -> Profile {
        let profile = Profile.newCustom()
        profiles.append(profile)
        return profile
    }

    func delete(_ id: UUID) {
        if SettingsManager.shared.settings.activeProfileID == id {
            SettingsManager.shared.settings.activeProfileID = nil
        }
        profiles.removeAll { $0.id == id && !$0.isBuiltIn }
    }

    func resetBuiltIn(_ id: UUID) {
        guard let original = Profile.builtIns.first(where: { $0.id == id }),
              let index = index(of: id) else { return }
        profiles[index] = original
    }

    private func load() {
        var loaded: [Profile] = []
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            loaded = decoded
        }
        // Built-ins always exist and come first; edits to them are kept.
        let builtIns = Profile.builtIns.map { builtIn in
            loaded.first { $0.id == builtIn.id } ?? builtIn
        }
        profiles = builtIns + loaded.filter { !$0.isBuiltIn }
    }

    private func save() {
        do {
            try JSONEncoder().encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            print("[ProfileStore] Failed to save: \(error)")
        }
    }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("SayStuff", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
