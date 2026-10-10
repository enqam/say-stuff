import Foundation

/// One billable API call, priced at the moment it happened from the provider's
/// published rate and the exact quantity the provider reported.
struct UsageRecord: Codable, Identifiable {
    enum Service: String, Codable {
        case transcription
        case formatting
    }

    var id = UUID()
    var date = Date()
    var service: Service
    var provider: String
    /// Audio seconds for transcription, tokens for formatting.
    var quantity: Double
    var costUSD: Decimal
    /// True when the provider bills by compute time and the cost was derived from request time.
    var isEstimate = false
}

final class UsageLedger: ObservableObject {
    static let shared = UsageLedger()

    @Published private(set) var records: [UsageRecord] = []

    private let fileURL: URL

    init() {
        fileURL = AppPaths.support.appendingPathComponent("usage.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([UsageRecord].self, from: data) {
            records = decoded
        }
    }

    func add(_ record: UsageRecord) {
        records.append(record)
        save()
    }

    func reset() {
        records.removeAll()
        save()
    }

    func records(since start: Date) -> [UsageRecord] {
        records.filter { $0.date >= start }
    }

    /// Monthly cost at the recent pace: spend over the last 7 days (or since the first
    /// record, if newer) scaled to 30 days. nil until there's spend to extrapolate from.
    var projectedMonthlyCost: Decimal? {
        guard let first = records.map(\.date).min() else { return nil }
        let now = Date()
        let windowStart = max(first, now.addingTimeInterval(-7 * 86_400))
        let days = max(now.timeIntervalSince(windowStart) / 86_400, 1)  // at least a day, so one burst isn't ×720
        let spent = records.filter { $0.date >= windowStart }.reduce(Decimal(0)) { $0 + $1.costUSD }
        guard spent > 0 else { return nil }
        return spent / Decimal(days) * 30
    }

    static var startOfMonth: Date {
        Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    }

    private func save() {
        do {
            try JSONEncoder().encode(records).write(to: fileURL, options: .atomic)
        } catch {
            print("[UsageLedger] Failed to save: \(error)")
        }
    }
}
