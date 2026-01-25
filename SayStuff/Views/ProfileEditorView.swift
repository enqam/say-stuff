import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var profileManager: ProfileManager
    @State private var selectedProfileId: UUID?

    var body: some View {
        HStack(spacing: 0) {
            // Profile list
            VStack(alignment: .leading, spacing: 0) {
                List(profileManager.profiles, selection: $selectedProfileId) { profile in
                    Text(profile.name)
                        .tag(profile.id)
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button(action: addProfile) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)

                    Button(action: removeProfile) {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedProfileId == nil || profileManager.profiles.count <= 1)

                    Spacer()
                }
                .padding(8)
            }
            .frame(width: 180)

            Divider()

            // Profile editor
            if let index = selectedProfileIndex {
                ProfileDetailView(
                    profile: $profileManager.profiles[index],
                    onSave: { profileManager.save() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Text("Select a profile to edit")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 600, height: 400)
        .onAppear {
            selectedProfileId = profileManager.profiles.first?.id
        }
    }

    private var selectedProfileIndex: Int? {
        guard let id = selectedProfileId else { return nil }
        return profileManager.profiles.firstIndex(where: { $0.id == id })
    }

    private func addProfile() {
        let newProfile = Profile(
            id: UUID(),
            name: "New Profile",
            language: "auto",
            whisperPrompt: nil,
            formatting: FormattingOptions()
        )
        profileManager.profiles.append(newProfile)
        selectedProfileId = newProfile.id
        profileManager.save()
    }

    private func removeProfile() {
        guard let id = selectedProfileId else { return }
        profileManager.profiles.removeAll { $0.id == id }
        selectedProfileId = profileManager.profiles.first?.id
        profileManager.save()
    }
}

struct ProfileDetailView: View {
    @Binding var profile: Profile
    var onSave: () -> Void

    var body: some View {
        Form {
            Section("Basic") {
                TextField("Name", text: $profile.name)
                    .onChange(of: profile.name) { _ in onSave() }

                Picker("Language", selection: $profile.language) {
                    Text("Auto-detect").tag("auto")
                    Divider()
                    Text("English").tag("en")
                    Text("Russian").tag("ru")
                    Text("Spanish").tag("es")
                    Text("French").tag("fr")
                    Text("German").tag("de")
                    Text("Italian").tag("it")
                    Text("Portuguese").tag("pt")
                    Text("Chinese").tag("zh")
                    Text("Japanese").tag("ja")
                    Text("Korean").tag("ko")
                }
                .onChange(of: profile.language) { _ in onSave() }
            }

            Section("Whisper Prompt") {
                TextEditor(text: Binding(
                    get: { profile.whisperPrompt ?? "" },
                    set: { profile.whisperPrompt = $0.isEmpty ? nil : $0 }
                ))
                .frame(height: 80)
                .font(.system(.body, design: .monospaced))
                .onChange(of: profile.whisperPrompt) { _ in onSave() }

                Text("An initial prompt helps Whisper understand context and improves accuracy for specific vocabulary or topics.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Formatting") {
                Toggle("Trim whitespace", isOn: $profile.formatting.trimWhitespace)
                    .onChange(of: profile.formatting.trimWhitespace) { _ in onSave() }

                Toggle("Collapse multiple newlines", isOn: $profile.formatting.collapseNewlines)
                    .onChange(of: profile.formatting.collapseNewlines) { _ in onSave() }

                Toggle("Add trailing space", isOn: $profile.formatting.addTrailingSpace)
                    .onChange(of: profile.formatting.addTrailingSpace) { _ in onSave() }
            }
        }
        .padding()
    }
}

#Preview {
    ProfileEditorView(profileManager: ProfileManager.shared)
}
