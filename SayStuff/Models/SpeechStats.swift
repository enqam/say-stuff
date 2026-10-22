import Foundation
import NaturalLanguage

/// How one dictation was spoken. Stays on this Mac (Application Support/SayStuff/speech.json).
struct SpeechSample: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// Words as transcribed, before filler removal, the dictionary and formatting.
    var words: Int
    /// Hesitations ("um", "uh") and words said twice, found in the transcript.
    var fillers: Int
    var timing: SpeechTiming
    /// Hotkey press to release.
    var recordingSeconds: Double
    /// Language code: the forced one, or recognized from the text.
    var language: String?
    /// The app dictated into.
    var app: String?
    var appBundleID: String?
    /// "Local · Small", "Groq", …
    var setup: String
    var profile: String?

    /// Too short to say anything about pace (a word or two, or under a second).
    var isRateSample: Bool { words >= 3 && timing.spanSeconds >= 1 }
}

final class SpeechStats: ObservableObject {
    static let shared = SpeechStats()

    @Published private(set) var samples: [SpeechSample] = []

    private let fileURL = AppPaths.support.appendingPathComponent("speech.json")
    /// About ten years of heavy use; the file stays a few MB.
    private let maxCount = 100_000

    /// Fixed samples, not saved (UI snapshots).
    init(fixture: [SpeechSample]) {
        samples = fixture
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([SpeechSample].self, from: data) {
            samples = decoded
        }
    }

    func record(_ sample: SpeechSample) {
        guard self === Self.shared else { return }
        samples.append(sample)
        if samples.count > maxCount { samples.removeFirst(samples.count - maxCount) }
        let snapshot = samples
        DispatchQueue.global(qos: .utility).async { [fileURL] in
            try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        }
        print(String(format: "[Speech] %d words in %.1fs → %.2f words/s, %d pauses, %d fillers, %@ in %@",
                     sample.words, sample.timing.spanSeconds, Double(sample.words) / max(sample.timing.spanSeconds, 0.1),
                     sample.timing.pauses, sample.fillers, sample.language ?? "?", sample.app ?? "?"))
    }

    func samples(since start: Date?) -> [SpeechSample] {
        guard let start else { return samples }
        return samples.filter { $0.date >= start }
    }

    // MARK: - Measuring a transcript

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// The forced language, else the likeliest of the user's languages for this text.
    static func language(of text: String, candidates: [String]) -> String? {
        if candidates.count == 1 { return candidates[0] }
        let recognizer = NLLanguageRecognizer()
        if !candidates.isEmpty { recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) } }
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    // MARK: - Summaries

    /// Pooled over a set of dictations: total words over total time, so long dictations
    /// weigh more than a three-word reply.
    struct Pace {
        let dictations: Int
        let words: Int
        /// Words per second from first to last word.
        let rate: Double
        /// Words per second of voiced time (pauses left out).
        let articulation: Double
        let pausesPerMinute: Double
        let meanPause: Double
        /// Share of transcribed words that were fillers.
        let fillerShare: Double

        init?(_ samples: [SpeechSample]) {
            guard !samples.isEmpty else { return nil }
            dictations = samples.count
            words = samples.reduce(0) { $0 + $1.words }
            let paced = samples.filter(\.isRateSample)
            guard !paced.isEmpty else { return nil }
            let pacedWords = Double(paced.reduce(0) { $0 + $1.words })
            let span = paced.reduce(0) { $0 + $1.timing.spanSeconds }
            let voiced = paced.reduce(0) { $0 + $1.timing.voicedSeconds }
            let pauses = paced.reduce(0) { $0 + $1.timing.pauses }
            rate = pacedWords / max(span, 0.1)
            articulation = pacedWords / max(voiced, 0.1)
            pausesPerMinute = Double(pauses) / max(span / 60, 0.01)
            meanPause = pauses == 0 ? 0 : paced.reduce(0) { $0 + $1.timing.pauseSeconds } / Double(pauses)
            fillerShare = Double(samples.reduce(0) { $0 + $1.fillers }) / Double(max(words, 1))
        }
    }

    struct Day: Identifiable {
        let date: Date
        let rate: Double
        let words: Int
        var id: Date { date }
    }

    static func days(_ samples: [SpeechSample]) -> [Day] {
        let calendar = Calendar.current
        return Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
            .compactMap { date, group in Pace(group).map { Day(date: date, rate: $0.rate, words: $0.words) } }
            .sorted { $0.date < $1.date }
    }

    enum Grouping: String, CaseIterable {
        case language = "Language"
        case app = "App"
        case timeOfDay = "Time of day"
        case engine = "Engine"
    }

    struct Group: Identifiable {
        let name: String
        let pace: Pace
        var id: String { name }
    }

    static func groups(_ samples: [SpeechSample], by grouping: Grouping) -> [Group] {
        let calendar = Calendar.current
        let key: (SpeechSample) -> String = {
            switch grouping {
            case .language:
                return $0.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Unknown"
            case .app:
                return $0.app ?? "Unknown"
            case .timeOfDay:
                switch calendar.component(.hour, from: $0.date) {
                case 5..<12: return "Morning"
                case 12..<17: return "Afternoon"
                case 17..<22: return "Evening"
                default: return "Night"
                }
            case .engine:
                return $0.setup
            }
        }
        return Dictionary(grouping: samples, by: key)
            .compactMap { name, group in Pace(group).map { Group(name: name, pace: $0) } }
            .sorted { $0.pace.words > $1.pace.words }
    }

    // MARK: - Export

    func csv() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var lines = ["date,words,fillers,span_s,voiced_s,recording_s,pauses,pause_s,longest_pause_s,words_per_s,language,app,bundle_id,setup,profile"]
        for s in samples {
            let fields: [String] = [
                iso.string(from: s.date), "\(s.words)", "\(s.fillers)",
                String(format: "%.2f", s.timing.spanSeconds), String(format: "%.2f", s.timing.voicedSeconds),
                String(format: "%.2f", s.recordingSeconds), "\(s.timing.pauses)",
                String(format: "%.2f", s.timing.pauseSeconds), String(format: "%.2f", s.timing.longestPauseSeconds),
                String(format: "%.3f", Double(s.words) / max(s.timing.spanSeconds, 0.1)),
                s.language ?? "", s.app ?? "", s.appBundleID ?? "", s.setup, s.profile ?? "",
            ]
            lines.append(fields.map(Self.escape).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
