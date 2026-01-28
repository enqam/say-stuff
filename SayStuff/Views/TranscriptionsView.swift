import SwiftUI

struct TranscriptionsView: View {
    @ObservedObject var store = TranscriptionStore.shared
    @State private var expandedId: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Transcriptions")
                .font(.headline)
                .padding()

            if store.transcriptions.isEmpty {
                Text("No transcriptions yet")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.transcriptions) { item in
                            TranscriptionRow(
                                item: item,
                                isExpanded: expandedId == item.id,
                                onTap: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedId = expandedId == item.id ? nil : item.id
                                    }
                                },
                                onCopy: {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.text, forType: .string)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 400, height: 350)
    }
}

struct TranscriptionRow: View {
    let item: RecentTranscription
    let isExpanded: Bool
    let onTap: () -> Void
    let onCopy: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(item.text)
                    .font(.system(size: 12))
                    .lineLimit(isExpanded ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isHovering {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy to clipboard")
                }
            }

            if isExpanded {
                Text(item.date, style: .relative)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isExpanded ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isExpanded ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
    }
}

#Preview {
    TranscriptionsView()
}
