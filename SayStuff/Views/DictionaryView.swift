import SwiftUI

struct DictionaryPane: View {
    @ObservedObject private var store = DictionaryStore.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var term = ""
    @State private var heardAs = ""
    @FocusState private var termFocused: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Word or name", text: $term, prompt: Text("Word or name, e.g. Kcaly"))
                        .labelsHidden()
                        .focused($termFocused)
                    TextField("Heard as", text: $heardAs, prompt: Text("Often heard as (optional)"))
                        .labelsHidden()
                    Button("Add", action: add)
                        .disabled(term.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Add a word")
            } footer: {
                Text("Words are passed to the speech model as hints. If you also add how it usually mishears a word, SayStuff fixes it automatically.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Learn from my corrections", isOn: $settingsManager.settings.learnCorrections)
                ComingNextNote(text: "When you fix a word right after it's pasted, SayStuff adds it here and shows a small notice. Connected in the next step.")
            }

            Section("Words") {
                if store.entries.isEmpty {
                    Text("No words yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.entries) { entry in
                        DictionaryRow(entry: entry) { store.remove(entry.id) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let variants = heardAs.split(separator: ",").map(String.init)
        store.add(term: term, heardAs: variants)
        term = ""
        heardAs = ""
        termFocused = true
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.term)
            if !entry.heardAs.isEmpty {
                Text("← " + entry.heardAs.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if entry.learned {
                Badge("Learned")
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .help("Remove")
        }
        .onHover { isHovering = $0 }
    }
}
