import SwiftUI

struct HistoryPane: View {
    @ObservedObject private var store = TranscriptionStore.shared
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                Text(item.date, format: .dateTime.hour().minute())
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 44, alignment: .leading)
                    .padding(.top, 1)
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
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 70)
            }
        }
        .onHover { isHovering = $0 }
    }
}
