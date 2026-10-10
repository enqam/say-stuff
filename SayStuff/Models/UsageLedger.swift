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
