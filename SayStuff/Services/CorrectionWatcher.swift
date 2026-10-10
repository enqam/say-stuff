import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "com.saystuff.app", category: "corrections")

/// Learns edits to the pasted text. Keep the last observed edit so sending a message
/// before the typing debounce finishes does not discard its correction.
@MainActor
struct CorrectionLearningSession {
    struct Correction: Equatable {
        let term: String
        let heardAs: String
    }

    private let pastedWords: [String]
    private let prefixWordCount: Int
    private let context: [String]
    private var lastValue: String
    private var lastChange: Date
    private var analyzedValue: String
    private var learned: Set<String> = []
    private(set) var finished = false
    private let settleDelay: TimeInterval = 1.5

    init?(pasted: String, initialValue: String, now: Date = Date()) {
        let text = Self.normalize(pasted).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Self.normalize(initialValue)
        let words = Self.words(text)
        guard !words.isEmpty, let range = value.range(of: text, options: .backwards) else { return nil }
        pastedWords = words
        let before = Self.words(String(value[..<range.lowerBound]))
        prefixWordCount = before.count
        context = Array(before.suffix(3))
        lastValue = value
        analyzedValue = value
        lastChange = now
    }

    mutating func observe(_ rawValue: String, now: Date = Date()) -> [Correction] {
        guard !finished else { return [] }
        let value = Self.normalize(rawValue)
        if value != lastValue {
            if Self.words(value).isEmpty {
                // Chat composers clear on Send. Evaluate the preceding snapshot, not
                // the empty field, before ending this paste's learning session.
                return finish()
            }
            lastValue = value
            lastChange = now
            return []
        }
        guard now.timeIntervalSince(lastChange) >= settleDelay else { return [] }
        return analyzeLastValue()
    }

    mutating func finish() -> [Correction] {
        guard !finished else { return [] }
        finished = true
        return analyzeLastValue()
    }

    private mutating func analyzeLastValue() -> [Correction] {
        guard lastValue != analyzedValue else { return [] }
        analyzedValue = lastValue
        let all = Self.words(lastValue)
        let start = min(max(0, prefixWordCount - context.count), all.count)
        let end = min(all.count, start + context.count + pastedWords.count + 4)
        let edits = Self.replacements(from: context + pastedWords, to: Array(all[start..<end]))
        var result: [Correction] = []
        for (old, new) in edits {
            let heard = old.joined(separator: " ")
            let term = new.joined(separator: " ")
            let key = heard.lowercased() + "\u{0}" + term.lowercased()
            guard !learned.contains(key), Self.isLearnable(old: heard, new: term) else { continue }
            learned.insert(key)
            result.append(Correction(term: term, heardAs: heard))
        }
        return result
    }

    /// Web fields may use non-breaking spaces and invisible formatting characters.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
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

}

/// Accessibility reads and notifications stay outside the testable learning session.
@MainActor
final class CorrectionWatcher {
    var onLearn: ((String, String) -> Void)?

    private var element: AXUIElement?
    private var session: CorrectionLearningSession?
    private var timer: Timer?
    private var observer: AXObserver?
    private var deadline = Date()
    private var generation = UUID()
    private let watchDuration: TimeInterval = 30

    func watch(pasted: String) {
        cancel()
        let text = CorrectionLearningSession.normalize(pasted).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        deadline = Date().addingTimeInterval(watchDuration)
        attach(text: text, attempt: 0, generation: generation)
    }

    func cancel() {
        generation = UUID()
        if var session {
            deliver(session.finish())
        }
        session = nil
        timer?.invalidate()
        timer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        element = nil
    }

    /// Check immediately after paste, then retry while the target app applies it.
    private func attach(text: String, attempt: Int, generation expected: UUID) {
        guard generation == expected else { return }
        let focused = Self.focusedElement()
        if let focused, let value = Self.value(of: focused),
           let session = CorrectionLearningSession(pasted: text, initialValue: value) {
            element = focused
            self.session = session
            let notifications = observeChanges(in: focused)
            // Notifications capture quick edits before Send; polling also covers apps
            // that do not emit Accessibility value-change notifications.
            timer = Timer.scheduledTimer(withTimeInterval: notifications ? 0.5 : 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            log.notice("Watching \(Self.role(of: focused), privacy: .public) for corrections (notifications: \(notifications))")
            return
        }
        guard attempt < 54, Date() < deadline else {
            log.notice("Could not attach correction learning to pasted text")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.attach(text: text, attempt: attempt + 1, generation: expected)
        }
    }

    private func observeChanges(in element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return false }
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<CorrectionWatcher>.fromOpaque(context).takeUnretainedValue()
            // The observer's source is installed only on the main run loop.
            MainActor.assumeIsolated { watcher.poll() }
        }, &created)
        guard status == .success, let created else { return false }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let values = AXObserverAddNotification(created, element, kAXValueChangedNotification as CFString, context) == .success
        _ = AXObserverAddNotification(created, element, kAXUIElementDestroyedNotification as CFString, context)
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        return values
    }

    private func poll() {
        guard let element, Date() < deadline, let value = Self.value(of: element), var session else {
            cancel()
            return
        }
        let corrections = session.observe(value)
        self.session = session
        deliver(corrections)
        if session.finished { cancel() }
    }

    private func deliver(_ corrections: [CorrectionLearningSession.Correction]) {
        for correction in corrections {
            onLearn?(correction.term, correction.heardAs)
        }
        if !corrections.isEmpty {
            log.notice("Learned \(corrections.count) dictionary correction(s)")
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        if let app = NSWorkspace.shared.frontmostApplication {
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
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let string = value as? String else { return nil }
        return string
    }

    private static func role(of element: AXUIElement) -> String {
        var role: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return role as? String ?? "?"
    }
}
