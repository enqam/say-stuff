import SwiftUI

/// Month-to-date API spend, from per-request records (fal audio length or compute time, Groq tokens).
struct UsageCard: View {
    @ObservedObject private var ledger = UsageLedger.shared
    @State private var allTime = false

    private var records: [UsageRecord] {
        allTime ? ledger.records : ledger.records(since: UsageLedger.startOfMonth)
    }

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(total(records).usdString)
                    .font(.mono(28, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if records.contains(where: \.isEstimate) {
                    Text("≈")
                        .font(.mono(14))
                        .foregroundStyle(Theme.textTertiary)
                        .help("Some fal requests are billed by compute time; those use measured request time.")
                }
                Spacer()
                ChipPicker(options: [(false, "This month"), (true, "All time")], selection: $allTime)
            }
            .padding(14)
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14)

            breakdown(.transcription, title: "Transcription", provider: "Groq / fal.ai Whisper") { seconds in
                String(format: "%.1f min audio", seconds / 60)
            }
            breakdown(.formatting, title: "Formatting", provider: "Groq gpt-oss-20b", last: true) { tokens in
                "\(Int(tokens).formatted()) tokens"
            }
        }
    }

    private func breakdown(_ service: UsageRecord.Service, title: String, provider: String, last: Bool = false,
                           quantity: (Double) -> String) -> some View {
        let items = records.filter { $0.service == service }
        return CardRow(title: title, detail: "\(provider) · \(items.count) requests · \(quantity(items.reduce(0) { $0 + $1.quantity }))",
                       showsDivider: !last) {
            Text(total(items).usdString)
                .font(.mono(12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func total(_ records: [UsageRecord]) -> Decimal {
        records.reduce(Decimal(0)) { $0 + $1.costUSD }
    }
}
