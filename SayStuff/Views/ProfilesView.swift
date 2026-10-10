import SwiftUI

/// Output profiles: pick how dictation is reshaped, preview it, edit the instructions.
struct ProfilesPane: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var store = ProfileStore.shared
    @State private var groqKey = ""

    private var activeID: UUID? { settingsManager.settings.activeProfileID }

    var body: some View {
        Form {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    card(nil)
                    ForEach(store.profiles) { card($0) }
                    newCard
                }
                .padding(.vertical, 4)
            } header: {
                Text("Output profile")
            } footer: {
                Text("Profiles clean up and restructure what you said with a fast language model before it's pasted. Raw pastes the transcript as is.")
                    .foregroundStyle(.secondary)
            }

            Section("Preview") {
                ProfilePreview(profile: store.profile(id: activeID))
            }

            if let id = activeID, let index = store.index(of: id) {
                editor(for: $store.profiles[index])
            }

            Section {
                LabeledContent("Provider", value: "Groq · gpt-oss-20b")
                SecureField("API key", text: $groqKey, prompt: Text("Groq key"))
                    .disabled(true)
                ComingNextNote(text: "Formatting is connected in the next step. Until then, every profile pastes the raw transcript.")
            } header: {
                Text("Formatting model")
            }
        }
        .formStyle(.grouped)
    }

    private func card(_ profile: Profile?) -> some View {
        let isActive = activeID == profile?.id
        return Button {
            settingsManager.settings.activeProfileID = profile?.id
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: profile?.symbol ?? "text.alignleft")
                    .font(.system(size: 15))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(profile?.name ?? "Raw")
                    .font(.system(size: 13, weight: .semibold))
                Text(profile?.summary ?? "Exactly what you said")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isActive ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newCard: some View {
        Button {
            let profile = store.addCustom()
            settingsManager.settings.activeProfileID = profile.id
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 15))
                Text("New profile")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 74)
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func editor(for profile: Binding<Profile>) -> some View {
        Section {
            if !profile.wrappedValue.isBuiltIn {
                TextField("Name", text: profile.name)
                TextField("Description", text: profile.summary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions")
                TextEditor(text: profile.instructions)
                    .font(.system(size: 12))
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }
            HStack {
                if profile.wrappedValue.isBuiltIn {
                    Button("Reset to Default") { store.resetBuiltIn(profile.wrappedValue.id) }
                } else {
                    Button("Delete Profile", role: .destructive) { store.delete(profile.wrappedValue.id) }
                }
                Spacer()
            }
        } header: {
            Text(profile.wrappedValue.name)
        }
    }
}
