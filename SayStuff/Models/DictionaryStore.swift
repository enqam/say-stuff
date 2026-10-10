import Foundation
import Combine

/// A word the user cares about, plus the ways the speech model tends to mishear it.
struct DictionaryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var term: String
    var heardAs: [String] = []
    var learned = false
    var added = Date()
}

final class DictionaryStore: ObservableObject {
    static let shared = DictionaryStore()

    @Published private(set) var entries: [DictionaryEntry] = [] {
        didSet { save() }
    }

    private let fileURL: URL
    private let migratedKey = "DictionaryMigratedLegacyProfiles"

    init() {
        fileURL = AppPaths.support.appendingPathComponent("dictionary.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            entries = decoded
        }
        migrateLegacyProfilePrompts()
    }

    func add(term: String, heardAs: [String] = [], learned: Bool = false) {
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        let variants = heardAs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(term) != .orderedSame }

        if let index = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) {
            var entry = entries[index]
            for variant in variants where !entry.heardAs.contains(where: { $0.caseInsensitiveCompare(variant) == .orderedSame }) {
                entry.heardAs.append(variant)
            }
            entries[index] = entry
        } else {
            entries.insert(DictionaryEntry(term: term, heardAs: variants, learned: learned), at: 0)
        }
    }

    /// Undoes a learned correction: drops the variant, and the word too if it was new.
    func forget(term: String, heardAs heard: String, removeTerm: Bool) {
        guard let index = entries.firstIndex(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) else { return }
        if removeTerm {
            entries.remove(at: index)
        } else {
            entries[index].heardAs.removeAll { $0.caseInsensitiveCompare(heard) == .orderedSame }
        }
    }

    func remove(_ id: DictionaryEntry.ID) {
        entries.removeAll { $0.id == id }
    }

    /// Vocabulary hint for the speech model (whisper's initial prompt is capped at ~224 tokens).
    var vocabularyPrompt: String? {
        var prompt = ""
        for entry in entries {
            let next = prompt.isEmpty ? entry.term : prompt + ", " + entry.term
            if next.count > 600 { break }
            prompt = next
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// A snapshot of the mishearing fixes, safe to use off the main thread.
    /// Swaps known mishearings for the correct term (whole words, case-insensitive).
    func replacer() -> (String) -> String { Self.replacer(for: entries) }

    /// Explicit words remain valid even if an older entry lists one as an alias.
    static func replacer(for entries: [DictionaryEntry]) -> (String) -> String {
        let canonical = Set(entries.map { $0.term.lowercased() })
        let rules: [(NSRegularExpression, String)] = entries.flatMap { entry in
            entry.heardAs.compactMap { variant in
                guard !canonical.contains(variant.lowercased()) else { return nil }
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: variant) + "(?![\\p{L}\\p{N}])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
                return (regex, NSRegularExpression.escapedTemplate(for: entry.term))
            }
        }
        return { text in
            rules.reduce(text) { result, rule in
                rule.0.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: rule.1)
            }
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            print("[DictionaryStore] Failed to save: \(error)")
        }
    }

    /// Old profiles carried a free-form whisper prompt. Prompts that were plain word lists
    /// ("Claude, Kcaly, zsh") become dictionary words; sentence-style prompts are skipped.
    private func migrateLegacyProfilePrompts() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        struct LegacyProfile: Decodable { let whisperPrompt: String? }
        let url = AppPaths.support.appendingPathComponent("profiles.json")
        guard let data = try? Data(contentsOf: url),
              let legacy = try? JSONDecoder().decode([LegacyProfile].self, from: data) else { return }

        for prompt in legacy.compactMap(\.whisperPrompt) {
            let pieces = prompt.split(whereSeparator: { $0 == "," || $0 == "\n" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let looksLikeWordList = pieces.allSatisfy { piece in
                piece.split(separator: " ").count <= 3 && !(piece.last.map { ".?!".contains($0) } ?? false)
            }
            guard looksLikeWordList else { continue }
            for piece in pieces.reversed() { add(term: piece) }
        }
    }
}
