import Foundation

/// Timing for one dictation. Stays on this Mac (Application Support/SayStuff/metrics.json).
struct DictationMetric: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    /// "Local · Small", "Local · Turbo", "Groq", "fal.ai"
    var setup: String
    /// "auto" or the forced language code
    var languageMode: String
    var audioSeconds: Double
    var transcribeSeconds: Double
    var formatSeconds: Double?
    /// Stop pressed → text pasted
    var totalSeconds: Double = 0
    var coldStart = false
    var retriedLanguage = false
    var fellBack = false
}

final class Telemetry: ObservableObject {
    static let shared = Telemetry()

    @Published private(set) var metrics: [DictationMetric] = []

    private let fileURL = AppPaths.support.appendingPathComponent("metrics.json")
    private let maxCount = 2_000

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([DictationMetric].self, from: data) {
            metrics = decoded
        }
    }

    func record(_ metric: DictationMetric) {
        metrics.append(metric)
        if metrics.count > maxCount { metrics.removeFirst(metrics.count - maxCount) }
        let snapshot = metrics
        DispatchQueue.global(qos: .utility).async { [fileURL] in
            try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        }
        print(String(format: "[Telemetry] %@ %@ audio %.1fs → transcribe %.2fs%@, total %.2fs%@%@",
                     metric.setup, metric.languageMode, metric.audioSeconds, metric.transcribeSeconds,
                     metric.formatSeconds.map { String(format: " + format %.2fs", $0) } ?? "",
                     metric.totalSeconds, metric.coldStart ? " (cold)" : "", metric.retriedLanguage ? " (retried)" : ""))
    }

    func reset() {
        metrics.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    struct Summary: Identifiable {
        let setup: String
        let languageMode: String
        let count: Int
        let coldStarts: Int
        let retries: Int
        let medianTranscribe: Double
        let medianTotal: Double
        let p90Total: Double
        /// Seconds of transcription per second of audio (lower is better).
        let medianRealtimeFactor: Double
        var id: String { setup + languageMode }
    }

    /// Per setup and language mode. Cold starts are counted but kept out of the timings,
    /// so model loading doesn't skew the comparison.
    var summaries: [Summary] {
        Dictionary(grouping: metrics) { "\($0.setup)|\($0.languageMode)" }
            .compactMap { _, group -> Summary? in
                guard let first = group.first else { return nil }
                let warm = group.filter { !$0.coldStart }
                let sample = warm.isEmpty ? group : warm
                return Summary(
                    setup: first.setup,
                    languageMode: first.languageMode,
                    count: group.count,
                    coldStarts: group.count - warm.count,
                    retries: group.filter(\.retriedLanguage).count,
                    medianTranscribe: Self.percentile(sample.map(\.transcribeSeconds), 0.5),
                    medianTotal: Self.percentile(sample.map(\.totalSeconds), 0.5),
                    p90Total: Self.percentile(sample.map(\.totalSeconds), 0.9),
                    medianRealtimeFactor: Self.percentile(sample.map { $0.transcribeSeconds / max($0.audioSeconds, 0.1) }, 0.5)
                )
            }
            .sorted { $0.medianTotal < $1.medianTotal }
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}
