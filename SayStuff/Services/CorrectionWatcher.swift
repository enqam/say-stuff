import AppKit
import ApplicationServices

/// Learns dictionary words from corrections the user makes right after a paste.
///
/// After a paste it reads the focused text field through Accessibility (twice a second, for
/// up to 30 s). Once the user stops typing, it diffs the pasted words against what's there now.
/// A replaced word is learned when the new spelling resembles the old one and isn't an
/// ordinary dictionary word (names and jargon: "Cerebrus" → "Cerebras"), so grammar fixes
/// like "there" → "their" are ignored.
@MainActor
final class CorrectionWatcher {
    /// Called with (correct term, what was pasted instead).
    var onLearn: ((String, String) -> Void)?

    private var element: AXUIElement?
    private var pastedWords: [String] = []
    private var prefix = ""
    private var lastValue = ""
    private var lastChange = Date()
    private var analyzedValue = ""
    private var learned: Set<String> = []
    private var timer: Timer?
    private var deadline = Date()

    private let watchDuration: TimeInterval = 30
    private let settleDelay: TimeInterval = 1.5

    func watch(pasted: String) {
        cancel()
        let text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        pastedWords = Self.words(text)
        guard !pastedWords.isEmpty else { return }
        deadline = Date().addingTimeInterval(watchDuration)
        attach(text: text, attempt: 0)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        element = nil
        learned = []
    }

    // MARK: - Finding the pasted text

    /// Apps apply a paste asynchronously, so look for the text a few times before giving up.
    private func attach(text: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            guard let element = Self.focusedElement(), let value = Self.value(of: element) else {
                if attempt < 5 { self.attach(text: text, attempt: attempt + 1) }
                return
            }
            guard let range = value.range(of: text, options: .backwards) else {
                if attempt < 5 { self.attach(text: text, attempt: attempt + 1) }
                return
            }
            self.element = element
            self.prefix = String(value[..<range.lowerBound])
            self.lastValue = value
            self.analyzedValue = value
            self.lastChange = Date()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
        }
    }

    private func poll() {
        guard let element, Date() < deadline, let value = Self.value(of: element) else {
            cancel()
            return
        }
        if value != lastValue {
            lastValue = value
            lastChange = Date()
            return
        }
        // Text is stable: analyze once per settled state.
        guard value != analyzedValue, Date().timeIntervalSince(lastChange) >= settleDelay else { return }
        analyzedValue = value
        analyze(value)
    }

    // MARK: - Diffing

    private func analyze(_ value: String) {
        // The pasted text starts where it was pasted; everything before it must be untouched.
        guard value.hasPrefix(prefix) else { return }
        let after = Self.words(String(value.dropFirst(prefix.count)))
        let current = Array(after.prefix(pastedWords.count + 3))  // ignore text typed after it

        for (old, new) in Self.replacements(from: pastedWords, to: current) {
            let oldPhrase = old.joined(separator: " ")
            let newPhrase = new.joined(separator: " ")
            guard !learned.contains(newPhrase.lowercased()), Self.isLearnable(old: oldPhrase, new: newPhrase) else { continue }
            learned.insert(newPhrase.lowercased())
            onLearn?(newPhrase, oldPhrase)
        }
    }

    /// Word replacements (1–3 words each side) between two word lists, via LCS alignment.
    private static func replacements(from old: [String], to new: [String]) -> [([String], [String])] {
        let a = old.map { $0.lowercased() }, b = new.map { $0.lowercased() }
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var result: [([String], [String])] = []
        var i = 0, j = 0
        var removed: [String] = [], added: [String] = []
        func flush() {
            if (1...3).contains(removed.count), (1...3).contains(added.count) { result.append((removed, added)) }
            removed = []
            added = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                added.append(new[j])
                j += 1
            } else {
                removed.append(old[i])
                i += 1
            }
        }
        flush()
        return result
    }

    private static func isLearnable(old: String, new: String) -> Bool {
        guard old.lowercased() != new.lowercased(), new.count >= 3 else { return false }
        // Must look like a respelling of what was heard, not a different word.
        guard similarity(old.lowercased(), new.lowercased()) >= 0.45 else { return false }
        // Names and jargon only: at least one word the system dictionary doesn't know.
        let checker = NSSpellChecker.shared
        return words(new).contains { word in
            checker.checkSpelling(of: word, startingAt: 0).location != NSNotFound
                || word.contains(where: \.isUppercase) && word != word.capitalized
        }
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
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

    private static func words(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-_.")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Accessibility

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let app = NSWorkspace.shared.frontmostApplication {
            // Electron apps only expose their text to Accessibility when asked.
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
