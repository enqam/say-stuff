import SwiftUI

struct DictionaryPane: View {
    @ObservedObject private var store = DictionaryStore.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var term = ""
    @State private var heardAs = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Add a word",
                            footnote: "Words are passed to the speech model as hints. Add what it usually mishears and SayStuff swaps it for you.") {
                HStack(spacing: 8) {
                    ThemedField(placeholder: "Word or name — Kcaly", text: $term)
                        .onSubmit(add)
                    ThemedField(placeholder: "Heard as — Kaylee, Kayley", text: $heardAs)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Card {
                CardRow(title: "Learn from my corrections",
                        detail: "When you fix a misheard name or term right after it's pasted, SayStuff adds it here.",
                        showsDivider: false) {
                    Switch(isOn: $settingsManager.settings.learnCorrections)
                }
            }

            SettingsSection(title: "Words · \(store.entries.count)") {
                if store.entries.isEmpty {
                    Text("Nothing yet.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(store.entries) { entry in
                            WordChip(entry: entry) { store.remove(entry.id) }
                        }
                    }
                }
            }
        }
    }

    private func add() {
        store.add(term: term, heardAs: heardAs.split(separator: ",").map(String.init))
        term = ""
        heardAs = ""
    }
}

private struct WordChip: View {
    let entry: DictionaryEntry
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.term)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.text)
            if !entry.heardAs.isEmpty {
                Text("← " + entry.heardAs.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1 : 0)
            .frame(width: isHovering ? nil : 0)
            .help("Remove")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(entry.learned ? Theme.accentSoft : (isHovering ? Theme.raised : Theme.surface)))
        .onHover { isHovering = $0 }
    }
}
