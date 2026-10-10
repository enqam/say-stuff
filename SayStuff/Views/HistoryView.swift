import SwiftUI

struct HistoryPane: View {
    @ObservedObject private var store = TranscriptionStore.shared
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpeedCard()
                .padding(.bottom, 12)
            HStack {
                Eyebrow("Last \(store.transcriptions.count) of 50")
                Spacer()
                if !store.transcriptions.isEmpty {
                    Button("Clear") { store.clear() }.buttonStyle(PillButtonStyle())
                }
            }

            if store.transcriptions.isEmpty {
                Text("Your transcriptions show up here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Card {
                    ForEach(store.transcriptions) { item in
                        HistoryRow(item: item, isCopied: copiedID == item.id, isLast: item.id == store.transcriptions.last?.id,
                                   onCopy: { copy(item) }, onDelete: { store.remove(item.id) })
                    }
                }
            }
        }
    }

    private func copy(_ item: RecentTranscription) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        copiedID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if copiedID == item.id { copiedID = nil }
        }
    }
}

private struct HistoryRow: View {
    let item: RecentTranscription
    let isCopied: Bool
    let isLast: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.date, format: .dateTime.hour().minute())
                    if let seconds = item.seconds {
                        Text("\(item.source ?? "") \(String(format: "%.1fs", seconds))")
                    }
                }
                .font(.mono(10.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 1)
                .help("Engine and time from stop to paste")
                Text(item.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 0) {
                    IconButton(symbol: isCopied ? "checkmark" : "doc.on.doc", help: "Copy", action: onCopy)
                    IconButton(symbol: "trash", help: "Delete", action: onDelete)
                }
                .opacity(isHovering || isCopied ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            if !isLast {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 90)
            }
        }
        .onHover { isHovering = $0 }
    }
}

/// Median timings per engine setup, from local telemetry. Warm runs only; cold starts are counted.
private struct SpeedCard: View {
    @ObservedObject private var telemetry = Telemetry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Speed")
                Spacer()
                if !telemetry.metrics.isEmpty {
                    Button("Reset") { telemetry.reset() }.buttonStyle(PillButtonStyle())
                }
            }
            if telemetry.metrics.isEmpty {
                Text("Dictate with different engines and models to compare them here.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Card {
                    header
                    ForEach(telemetry.summaries) { row($0, last: $0.id == telemetry.summaries.last?.id) }
                }
                Text("Medians of warm runs. Total = stop to paste, including formatting. Speed = transcription time per second of audio.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Setup").frame(maxWidth: .infinity, alignment: .leading)
                Text("Runs").frame(width: 44, alignment: .trailing)
                Text("Transcribe").frame(width: 76, alignment: .trailing)
                Text("Total").frame(width: 56, alignment: .trailing)
                Text("p90").frame(width: 52, alignment: .trailing)
                Text("Speed").frame(width: 56, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private func row(_ summary: Telemetry.Summary, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.setup).font(.system(size: 12.5, weight: .medium))
                    Text(detail(summary)).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(summary.count)").frame(width: 44, alignment: .trailing)
                Text(seconds(summary.medianTranscribe)).frame(width: 76, alignment: .trailing)
                Text(seconds(summary.medianTotal)).frame(width: 56, alignment: .trailing)
                    .foregroundStyle(Theme.text)
                Text(seconds(summary.p90Total)).frame(width: 52, alignment: .trailing)
                Text(String(format: "%.2f×", summary.medianRealtimeFactor)).frame(width: 56, alignment: .trailing)
            }
            .font(.mono(12))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            if !last { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14) }
        }
    }

    private func detail(_ summary: Telemetry.Summary) -> String {
        var parts = [summary.languageMode == "auto" ? "Auto language" : summary.languageMode.uppercased()]
        if summary.coldStarts > 0 { parts.append("\(summary.coldStarts) cold") }
        if summary.retries > 0 { parts.append("\(summary.retries) retried") }
        return parts.joined(separator: " · ")
    }

    private func seconds(_ value: Double) -> String {
        String(format: "%.2fs", value)
    }
}
