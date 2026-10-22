import Foundation

/// Minimal, local cleanup of spoken text: hesitation sounds and words said twice while
/// thinking. Nothing is reworded, so it's safe to run on every dictation.
enum TextCleanup {
    static func removeDisfluencies(_ text: String) -> String {
        removeRepeats(removeFillers(text))
    }

    // um, umm, uhm, uh, erm, hmm, mmm; Russian э, ээ, эм, ммм. Not "mm"/"мм", which can be millimeters.
    private static let filler = try! NSRegularExpression(
        pattern: #"(?:,\s*)?(?<![\p{L}\p{N}'’-])(?:u+h*m+|u+h+|e+r+m+|h+m+|m{3,}|э+м*|м{3,})(?![\p{L}\p{N}'’-])(?:\s*,|\.{3}|…)?"#,
        options: .caseInsensitive)
    private static let sentenceStart = try! NSRegularExpression(pattern: #"(?:^|[.!?…]\s*)$"#)

    static func removeFillers(_ text: String) -> String {
        let source = text as NSString
        var result = text
        // Back to front, so earlier ranges stay valid.
        for match in filler.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let before = String(result[..<range.lowerBound])
            result.replaceSubrange(range, with: " ")
            // "Um, so we…" starts a sentence: the next word takes over the capital.
            let startsSentence = sentenceStart.firstMatch(
                in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil
            if startsSentence, let next = result[range.lowerBound...].firstIndex(where: \.isLetter) {
                result.replaceSubrange(next...next, with: result[next].uppercased())
            }
        }
        return tidy(result)
    }

    // Allowed doubles: "had had", "that that", "no no", "да да", "очень очень".
    private static let allowedDoubles: Set<String> = [
        "had", "that", "very", "no", "yeah", "yes", "bye", "so", "ha", "well", "really",
        "да", "нет", "очень", "так", "ну",
    ]
    private static let repeatedWord = try! NSRegularExpression(
        pattern: #"(?<![\p{L}'’])(\p{L}+(?:['’]\p{L}+)?)(?:,?\s+\1)+(?![\p{L}'’])"#, options: .caseInsensitive)
    private static let repeatedPair = try! NSRegularExpression(
        pattern: #"(?<![\p{L}'’])(\p{L}+\s+\p{L}+)(?:,?\s+\1)+(?![\p{L}'’])"#, options: .caseInsensitive)

    static func removeRepeats(_ text: String) -> String {
        var result = text
        for regex in [repeatedPair, repeatedWord] {
            let source = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: source.length)).reversed() {
                let first = source.substring(with: match.range(at: 1))
                if allowedDoubles.contains(first.lowercased()) { continue }
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: first)
            }
        }
        return result
    }

    /// Collapses the spaces and stray punctuation a removal leaves behind.
    private static func tidy(_ text: String) -> String {
        var text = text.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" +([,.!?;:…])"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"^[,;:]\s*"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"([.!?])[,;:]"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<!\.)([.!?])\.(?!\.)"#, with: "$1", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}
