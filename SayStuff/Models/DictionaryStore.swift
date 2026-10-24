import AppKit
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
        didSet {
            save()
            prepareLookups()
        }
    }

    /// Vocabulary hint for the speech model (whisper's initial prompt is capped at ~224 tokens).
    private(set) var vocabularyPrompt: String?
    /// Puts dictionary words back where the speech model misheard them (see `replacer(for:)`).
    /// Safe to call off the main thread.
    private(set) var replacer: @Sendable (String) async -> String = { $0 }
    private var lookupsVersion = 0

    private let fileURL: URL
    private let migratedKey = "DictionaryMigratedLegacyProfiles"

    init() {
        fileURL = AppPaths.support.appendingPathComponent("dictionary.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data) {
            entries = decoded
        }
        migrateLegacyProfilePrompts()
        // Built here, not off main: the store is created at launch (DictationController.start),
        // and the first dictation must not catch the identity replacer before an async build
        // lands. (It did: created lazily as that dictation stopped, it pasted unfixed words.)
        lookupsVersion += 1
        vocabularyPrompt = Self.vocabularyPrompt(for: entries)
        replacer = Self.replacer(for: entries)
    }

    /// Rebuilds the prompt and the replacer off the main thread when the words change:
    /// compiling the regexes took ~20 ms for 26 words (measured), and it used to happen on
    /// the main thread the moment each dictation stopped, mid-animation.
    private func prepareLookups() {
        lookupsVersion += 1
        let version = lookupsVersion, entries = entries
        DispatchQueue.global(qos: .userInitiated).async {
            let prompt = Self.vocabularyPrompt(for: entries), replacer = Self.replacer(for: entries)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lookupsVersion == version else { return }
                self.vocabularyPrompt = prompt
                self.replacer = replacer
            }
        }
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

    private static func vocabularyPrompt(for entries: [DictionaryEntry]) -> String? {
        var prompt = ""
        var length = 0
        for entry in entries {
            let next = length + (prompt.isEmpty ? 0 : 2) + entry.term.count
            if next > 600 { break }
            prompt += prompt.isEmpty ? entry.term : ", " + entry.term
            length = next
        }
        return prompt.isEmpty ? nil : prompt
    }

    /// Known mishearings first (whole words, case-insensitive), then made-up words that sound
    /// like a dictionary word or one of its mishearings: Parakeet spells a name it doesn't
    /// know differently nearly every time ("ClotMD", then "GlottemD", for claude.md), so the
    /// list alone kept missing.
    static func replacer(for entries: [DictionaryEntry]) -> @Sendable (String) async -> String {
        let exact = exactReplacer(for: entries)
        let soundAlike = SoundAlike(entries: entries)
        return { text in await soundAlike.fix(exact(text)) }
    }

    /// Explicit words remain valid even if an older entry lists one as an alias.
    static func exactReplacer(for entries: [DictionaryEntry]) -> @Sendable (String) -> String {
        let canonical = Set(entries.map { $0.term.lowercased() })
        let rules: [(NSRegularExpression, String)] = entries.flatMap { entry in
            entry.heardAs.compactMap { variant in
                guard !canonical.contains(variant.lowercased()) else { return nil }
                let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: variant) + "(?![\\p{L}\\p{N}])"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
                return (regex, entry.term)
            }
        }
        return { text in
            rules.reduce(text) { result, rule in
                let (regex, term) = rule
                let output = NSMutableString(string: result)
                for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                    // An all-lowercase term ("discrete") is capitalized at a sentence start. Not after any
                    // capital: Parakeet capitalizes misheard names mid-sentence ("I edited Quad MD").
                    let before = output.substring(to: match.range.location).trimmingCharacters(in: .whitespacesAndNewlines)
                    let capital = term == term.lowercased() && (before.isEmpty || ".!?".contains(before.last!))
                        && output.substring(with: match.range).first?.isUppercase == true
                    output.replaceCharacters(in: match.range, with: capital ? term.prefix(1).uppercased() + term.dropFirst() : term)
                }
                return output as String
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

/// Matches words by sound. Replaces 1-3 adjacent words when all of them are unknown to the
/// English spell checker (or capitalized acronym letters: "M D", "US") and they sound and
/// look like a dictionary word or a mishearing of one. Over every archived dictation
/// (629, 2026-10-24) this fixed 8 words and touched no ordinary ones; looser thresholds
/// (sound 0.6, letters 0.35) or allowing known words ("pixely If" → piece/slice, "iCloud" →
/// Claude) started replacing real speech. FluidAudio's acoustic vocabulary boosting was
/// worse on the same recordings ("include" → Claude, "little bit" → fitbit) and cost
/// 150-1150 ms per dictation.
struct SoundAlike: Sendable {
    private struct Form: Sendable {
        let term: String
        let letters: [Character]
        let key: [Character]
    }

    private let forms: [Form]
    private let terms: Set<String>
    private static let minimumSound = 0.75
    private static let minimumLetters = 0.5
    private static let token = try! NSRegularExpression(pattern: "[A-Za-z0-9]+(?:[._'/-][A-Za-z0-9]+)*")

    init(entries: [DictionaryEntry]) {
        terms = Set(entries.map { $0.term.lowercased() })
        forms = entries.flatMap { entry in
            ([entry.term] + entry.heardAs).compactMap { form in
                let letters = Array(form.lowercased().filter { $0.isLetter || $0.isNumber })
                let key = Array(Self.soundKey(form))
                return key.count >= 3 && letters.count >= 4 ? Form(term: entry.term, letters: letters, key: key) : nil
            }
        }
    }

    func fix(_ text: String) async -> String {
        guard !forms.isEmpty else { return text }
        let ns = text as NSString
        let words = Self.token.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        // Spans of adjacent words (only spaces between) that sound like a form, longest first.
        var candidates: [(start: Int, count: Int, term: String)] = []
        for start in words.indices {
            for count in stride(from: min(3, words.count - start), through: 1, by: -1) {
                let span = words[start..<start + count]
                guard zip(span, span.dropFirst()).allSatisfy({ a, b in
                    ns.substring(with: NSRange(location: a.upperBound, length: b.location - a.upperBound)).allSatisfy { $0 == " " }
                }) else { continue }
                let spoken = span.map { ns.substring(with: $0) }
                guard !spoken.contains(where: { terms.contains($0.lowercased()) }),
                      let term = match(spoken.joined(separator: " ")) else { continue }
                candidates.append((start, count, term))
            }
        }
        guard !candidates.isEmpty else { return text }

        // Rare (a few words a day), so the spell checker, which isn't documented as safe off
        // the main thread, runs there.
        let checked = Set(candidates.flatMap { c in words[c.start..<c.start + c.count].map { ns.substring(with: $0) } })
        let unknown = await MainActor.run { checked.filter { !Self.isKnownWord($0) } }

        var replacements: [(NSRange, String)] = []
        var next = 0
        for c in candidates where c.start >= next {
            let spoken = words[c.start..<c.start + c.count].map { ns.substring(with: $0) }
            guard spoken.contains(where: { unknown.contains($0) }),
                  spoken.allSatisfy({ unknown.contains($0) || ($0.count <= 3 && $0.allSatisfy(\.isUppercase)) })
            else { continue }
            let first = words[c.start], last = words[c.start + c.count - 1]
            replacements.append((NSRange(location: first.location, length: last.upperBound - first.location), c.term))
            next = c.start + c.count
        }
        let result = NSMutableString(string: text)
        for (range, term) in replacements.reversed() { result.replaceCharacters(in: range, with: term) }
        return result as String
    }

    private func match(_ spoken: String) -> String? {
        let letters = Array(spoken.lowercased().filter { $0.isLetter || $0.isNumber })
        let key = Array(Self.soundKey(spoken))
        guard key.count >= 3 else { return nil }
        var best: (term: String, score: Double)?
        for form in forms {
            // Similarity can't reach the minimum across a bigger length difference.
            guard Double(min(key.count, form.key.count)) >= Self.minimumSound * Double(max(key.count, form.key.count)) else { continue }
            let sound = Self.similarity(key, form.key)
            guard sound >= Self.minimumSound else { continue }
            let look = Self.similarity(letters, form.letters)
            guard look >= Self.minimumLetters, best == nil || sound + look > best!.score else { continue }
            best = (form.term, sound + look)
        }
        return best?.term
    }

    /// The spell checker passes any word with inner capitals ("ClotMD"), so those count as
    /// made up unless they start lowercase ("iCloud", "macOS").
    @MainActor private static func isKnownWord(_ word: String) -> Bool {
        if let first = word.first, first.isUppercase, zip(word, word.dropFirst()).contains(where: { $0.isLowercase && $1.isUppercase }) {
            return false
        }
        return NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                                   inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Consonant skeleton of how a word sounds: "Quad" → "kd", "Claude" → "kld".
    static func soundKey(_ text: String) -> String {
        var s = text.lowercased().filter(\.isLetter)
        for (from, to) in [("ph", "f"), ("ck", "k"), ("qu", "k"), ("gh", "g"), ("x", "ks"),
                           ("c", "k"), ("q", "k"), ("z", "s")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        var key = ""
        for (index, char) in s.enumerated() {
            if index > 0, "aeiouyhw".contains(char) { continue }
            if key.last != char { key.append(char) }
        }
        return key
    }

    static func similarity(_ a: String, _ b: String) -> Double { similarity(Array(a), Array(b)) }

    private static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }
}
