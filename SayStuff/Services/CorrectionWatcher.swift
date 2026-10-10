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
    private let vocabulary: Set<String>
    private let prefixWordCount: Int
    private let context: [String]
    private var lastValue: String
    private var lastChange: Date
    private var analyzedValue: String
    private var learned: Set<String> = []
    private(set) var finished = false
    private let settleDelay: TimeInterval = 1.5

    init?(pasted: String, initialValue: String, vocabulary: [String] = [], now: Date = Date()) {
        let text = Self.normalize(pasted).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Self.normalize(initialValue)
        let words = Self.words(text)
        guard !words.isEmpty, let range = value.range(of: text, options: .backwards) else { return nil }
        pastedWords = words
        self.vocabulary = Set(vocabulary.map { $0.lowercased() })
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
            guard !learned.contains(key), isLearnable(old: heard, new: term) else { continue }
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

    private func isLearnable(old: String, new: String) -> Bool {
        guard old.lowercased() != new.lowercased(), new.count >= 3 else { return false }
        // Must look like a respelling of what was heard, not a different word.
        guard Self.similarity(old.lowercased(), new.lowercased()) >= 0.45 else { return false }
        // Keep explicitly listed names distinct (for example Grok and Groq).
        guard !vocabulary.contains(old.lowercased()) else { return false }
        // Explicit dictionary terms remain learnable even if macOS already knows
        // their spelling. The unknown-word filter protects ordinary grammar edits.
        if vocabulary.contains(new.lowercased()) { return true }
        let checker = NSSpellChecker.shared
        return Self.words(new).contains { word in
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
    var onTextChanged: (() -> Void)?
    private(set) var correctionAnchor: NSRect?
    private(set) var correctedWordFrame: NSRect?
    private(set) var textFieldFrame: NSRect?
    private var observedValue = ""
    private var editedRange: NSRange?
    private var editedWordFrame: NSRect?

    private var element: AXUIElement?
    private var session: CorrectionLearningSession?
    private var vocabulary: [String] = []
    private var timer: Timer?
    private var observer: AXObserver?
    private var deadline = Date()
    private var generation = UUID()
    private let watchDuration: TimeInterval = 30

    func watch(pasted: String, vocabulary: [String] = []) {
        cancel()
        self.vocabulary = vocabulary
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
        vocabulary = []
        timer?.invalidate()
        timer = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        element = nil
        observedValue = ""
        editedRange = nil
        editedWordFrame = nil
        correctionAnchor = nil
        correctedWordFrame = nil
        textFieldFrame = nil
    }

    /// Check immediately after paste, then retry while the target app applies it.
    private func attach(text: String, attempt: Int, generation expected: UUID) {
        guard generation == expected else { return }
        let focused = Self.focusedElement()
        if let focused, let value = Self.value(of: focused),
           let session = CorrectionLearningSession(pasted: text, initialValue: value, vocabulary: vocabulary) {
            element = focused
            self.session = session
            observedValue = value
            textFieldFrame = Self.frame(of: focused)
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
        if value != observedValue { onTextChanged?() }
        if value != observedValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editedRange = Self.changedWordRange(from: observedValue, to: value)
            editedWordFrame = editedRange.flatMap { Self.bounds(for: $0, in: element) }
            observedValue = value
            textFieldFrame = Self.frame(of: element) ?? textFieldFrame
        }
        let corrections = session.observe(value)
        self.session = session
        deliver(corrections)
        if session.finished { cancel() }
    }

    private func deliver(_ corrections: [CorrectionLearningSession.Correction]) {
        for correction in corrections {
            let range = Self.termRange(correction.term, in: observedValue, near: editedRange?.location)
            let currentValue = element.flatMap(Self.value)
            let stillPresent = currentValue == observedValue
            let exactFrame = stillPresent ? range.flatMap { range in element.flatMap { Self.bounds(for: range, in: $0, includeTextRuns: true) } } : nil
            correctionAnchor = exactFrame ?? editedWordFrame
            correctedWordFrame = stillPresent ? exactFrame ?? editedWordFrame : nil
            onLearn?(correction.term, correction.heardAs)
        }
        if !corrections.isEmpty {
            log.notice("Learned \(corrections.count) dictionary correction(s)")
        }
    }

    /// Use UTF-16 ranges because Accessibility text ranges use NSString offsets.
    static func changedWordRange(from old: String, to new: String) -> NSRange? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard !b.isEmpty, a != b else { return nil }
        var start = 0
        while start < min(a.count, b.count), a[start] == b[start] { start += 1 }
        var end = b.count
        var oldEnd = a.count
        while end > start, oldEnd > start, b[end - 1] == a[oldEnd - 1] { end -= 1; oldEnd -= 1 }
        let text = new as NSString
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'’-_.")).inverted
        let left = text.rangeOfCharacter(from: separators, options: .backwards,
                                         range: NSRange(location: 0, length: start))
        let right = text.rangeOfCharacter(from: separators, options: [],
                                          range: NSRange(location: end, length: text.length - end))
        let lower = left.location == NSNotFound ? 0 : NSMaxRange(left)
        let upper = right.location == NSNotFound ? text.length : right.location
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// Repeated names are anchored to the occurrence closest to the edit, not the last one.
    static func termRange(_ term: String, in value: String, near location: Int?) -> NSRange? {
        let text = value as NSString
        var search = NSRange(location: 0, length: text.length)
        var matches: [NSRange] = []
        while search.length > 0 {
            let range = text.range(of: term, options: .caseInsensitive, range: search)
            guard range.location != NSNotFound, range.length > 0 else { break }
            matches.append(range)
            search = NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))
        }
        guard let location else { return matches.last }
        return matches.min { abs($0.location - location) < abs($1.location - location) }
    }

    private static func bounds(for range: NSRange, in element: AXUIElement, includeTextRuns: Bool = false) -> NSRect? {
        if let rect = nativeBounds(for: range, in: element),
           !isSameRect(rect, frame(of: element)) { return rect }
        // Chromium contenteditable fields expose range bounds on their inner
        // static text runs. The editor-level API can return the entire field.
        // Walk only this composer, and only once the correction settles.
        guard includeTextRuns, let value = value(of: element) else { return nil }
        let text = value as NSString
        guard NSMaxRange(range) <= text.length else { return nil }
        let deadline = Date().addingTimeInterval(0.1)
        var visited = 0
        var cursor = 0
        func search(_ node: AXUIElement, depth: Int) -> NSRect? {
            guard depth <= 8, visited < 256, Date() < deadline else { return nil }
            visited += 1
            if role(of: node) == kAXStaticTextRole, let run = Self.value(of: node), !run.isEmpty {
                let occurrence = text.range(of: run, range: NSRange(location: cursor, length: text.length - cursor))
                if occurrence.location != NSNotFound {
                    cursor = NSMaxRange(occurrence)
                    if range.location >= occurrence.location, NSMaxRange(range) <= cursor {
                        let local = NSRange(location: range.location - occurrence.location, length: range.length)
                        if let rect = nativeBounds(for: local, in: node),
                           local.length == (run as NSString).length || !isSameRect(rect, frame(of: node)) {
                            return rect
                        }
                    }
                }
                return nil
            }
            var children: AnyObject?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success,
               let children = children as? [AXUIElement] {
                for child in children {
                    if let rect = search(child, depth: depth + 1) { return rect }
                    if cursor > NSMaxRange(range) { break }
                }
            }
            return nil
        }
        return search(element, depth: 0)
    }

    private static func isSameRect(_ rect: NSRect, _ other: NSRect?) -> Bool {
        guard let other else { return false }
        return abs(rect.minX - other.minX) < 2 && abs(rect.minY - other.minY) < 2
            && abs(rect.width - other.width) < 2 && abs(rect.height - other.height) < 2
    }

    private static func nativeBounds(for range: NSRange, in element: AXUIElement) -> NSRect? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0,
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
        return screenRect(rect)
    }

    private static func frame(of element: AXUIElement) -> NSRect? {
        var position: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return screenRect(CGRect(origin: point, size: dimensions))
    }

    private static func screenRect(_ rect: CGRect) -> NSRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
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
