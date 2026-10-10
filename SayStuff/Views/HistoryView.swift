import SwiftUI

struct HistoryPane: View {
    @ObservedObject private var store = TranscriptionStore.shared
    @State private var copiedID: UUID?

    var body: some View {
        Form {
            Section {
                if store.transcriptions.isEmpty {
                    Text("Your last \(50) transcriptions show up here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.transcriptions) { item in
                        HistoryRow(item: item, isCopied: copiedID == item.id, onCopy: { copy(item) }, onDelete: { store.remove(item.id) })
                    }
                }
            } footer: {
                if !store.transcriptions.isEmpty {
                    HStack {
                        Spacer()
                        Button("Clear History", role: .destructive) { store.clear() }
                    }
                }
            }
        }
        .formStyle(.grouped)
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
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(action: onCopy) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                }
                .help("Copy")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isCopied ? 1 : 0)
        }
        .onHover { isHovering = $0 }
    }
}
