import AppKit

@main struct CorrectionLearningSmoke {
    @MainActor static func main() {
        let now = Date(timeIntervalSince1970: 100)
        typealias Correction = CorrectionLearningSession.Correction
        let wanted = Correction(term: "Cerebras", heardAs: "Cerebrus")

        var quick = CorrectionLearningSession(pasted: "Cerebrus.", initialValue: "Cerebrus.", now: now)!
        assert(quick.observe("Cerebras.", now: now.addingTimeInterval(0.2)).isEmpty)
        assert(quick.observe("", now: now.addingTimeInterval(0.3)) == [wanted])
        assert(quick.finished)
        assert(quick.observe("Another message", now: now.addingTimeInterval(2)).isEmpty)
        assert(quick.finish().isEmpty)

        var settled = CorrectionLearningSession(pasted: "Cerebrus", initialValue: "Cerebrus", now: now)!
        assert(settled.observe("Cerebras", now: now.addingTimeInterval(0.2)).isEmpty)
        assert(settled.observe("Cerebras", now: now.addingTimeInterval(0.8)).isEmpty)
        assert(settled.observe("Cerebras", now: now.addingTimeInterval(1.8)) == [wanted])
        assert(settled.observe("", now: now.addingTimeInterval(1.9)).isEmpty)

        var unchanged = CorrectionLearningSession(pasted: "Cerebrus", initialValue: "Cerebrus", now: now)!
        assert(unchanged.observe("", now: now.addingTimeInterval(0.2)).isEmpty)

        var deletion = CorrectionLearningSession(pasted: "Use Cerebrus now", initialValue: "Use Cerebrus now", now: now)!
        assert(deletion.observe("Use now", now: now.addingTimeInterval(0.2)).isEmpty)
        assert(deletion.observe("", now: now.addingTimeInterval(0.3)).isEmpty)

        var grammar = CorrectionLearningSession(pasted: "there", initialValue: "there", now: now)!
        assert(grammar.observe("their", now: now.addingTimeInterval(0.2)).isEmpty)
        assert(grammar.observe("", now: now.addingTimeInterval(0.3)).isEmpty)

        var unrelated = CorrectionLearningSession(pasted: "Cerebrus", initialValue: "Cerebrus", now: now)!
        assert(unrelated.observe("Completely different sentence", now: now.addingTimeInterval(0.2)).isEmpty)
        assert(unrelated.observe("", now: now.addingTimeInterval(0.3)).isEmpty)

        var nextRecording = CorrectionLearningSession(pasted: "Cerebrus", initialValue: "Cerebrus", now: now)!
        _ = nextRecording.observe("Cerebras", now: now.addingTimeInterval(0.2))
        assert(nextRecording.finish() == [wanted])
        assert(nextRecording.finish().isEmpty)

        var prefix = CorrectionLearningSession(pasted: "Use Cerebrus now", initialValue: "Earlier text. Use Cerebrus now", now: now)!
        _ = prefix.observe("Earlier changed text. Use Cerebras now", now: now.addingTimeInterval(0.2))
        assert(prefix.observe("", now: now.addingTimeInterval(0.3)) == [wanted])

        var normalized = CorrectionLearningSession(pasted: "Use Cerebrus", initialValue: "Use\u{00a0}Cerebrus\u{200b}", now: now)!
        _ = normalized.observe("Use\u{00a0}Cerebras\u{200b}", now: now.addingTimeInterval(0.2))
        assert(normalized.observe("", now: now.addingTimeInterval(0.3)) == [wanted])

        assert(CorrectionLearningSession(pasted: "Cerebrus", initialValue: "Something else", now: now) == nil)
        let repeated = "Cerebras Cerebras"
        assert(CorrectionWatcher.termRange("Cerebras", in: repeated, near: 0) == NSRange(location: 0, length: 8))
        assert(CorrectionWatcher.termRange("Cerebras", in: repeated, near: 10) == NSRange(location: 9, length: 8))
        assert(CorrectionWatcher.changedWordRange(from: "Use Cerebrus now", to: "Use Cerebras now") == NSRange(location: 4, length: 8))
        assert(CorrectionWatcher.changedWordRange(from: "😀 Cerebrus", to: "😀 Cerebras") == NSRange(location: 3, length: 8))
        assert(CorrectionWatcher.changedWordRange(from: "Керебрус", to: "Керебрас") == NSRange(location: 0, length: 8))
        assert(CorrectionWatcher.changedWordRange(from: "same", to: "same") == nil)
        print("PASS: quick send, settled edits, no duplicates, unchanged send, deletion, grammar, unrelated edits, next recording, prefix edits, normalized fields")
    }
}
