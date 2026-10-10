import SwiftUI

struct UsagePane: View {
    @ObservedObject private var ledger = UsageLedger.shared
    @State private var range: Range = .month

    enum Range: String, CaseIterable {
        case month = "This month"
        case all = "All time"
    }

    private var records: [UsageRecord] {
        range == .month ? ledger.records(since: UsageLedger.startOfMonth) : ledger.records
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(total(records), format: .currency(code: "USD").precision(.fractionLength(2...4)))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(Range.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.vertical, 2)
            } footer: {
                Text("Calculated from each provider's published price and the exact audio length or token count of every request. Local transcription is free.")
                    .foregroundStyle(.secondary)
            }

            Section("Breakdown") {
                breakdownRow(
                    title: "Transcription",
                    provider: "fal.ai · Wizper v3",
                    detail: minutes(records.filter { $0.service == .transcription }),
                    cost: total(records.filter { $0.service == .transcription })
                )
                breakdownRow(
                    title: "Formatting",
                    provider: "Groq · gpt-oss-20b",
                    detail: tokens(records.filter { $0.service == .formatting }),
                    cost: total(records.filter { $0.service == .formatting })
                )
            }

            Section {
                ComingNextNote(text: "Costs start counting once the cloud engine and formatting are connected.")
                if !ledger.records.isEmpty {
                    Button("Reset Usage", role: .destructive) { ledger.reset() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func breakdownRow(title: String, provider: String, detail: String, cost: Decimal) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(provider) · \(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                .monospacedDigit()
        }
    }

    private func total(_ records: [UsageRecord]) -> Decimal {
        records.reduce(Decimal(0)) { $0 + $1.costUSD }
    }

    private func minutes(_ records: [UsageRecord]) -> String {
        let seconds = records.reduce(0) { $0 + $1.quantity }
        return String(format: "%.1f min", seconds / 60)
    }

    private func tokens(_ records: [UsageRecord]) -> String {
        let count = Int(records.reduce(0) { $0 + $1.quantity })
        return "\(count.formatted()) tokens"
    }
}
