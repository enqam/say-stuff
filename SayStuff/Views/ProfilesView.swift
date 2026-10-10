import SwiftUI

/// Pick, preview and edit output profiles. The selected profile is the active one.
struct ProfilesPane: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var store = ProfileStore.shared
    @ObservedObject private var keys = APIKeys.shared

    @State private var previewText: [UUID: String] = [:]
    @State private var previewError: String?
    @State private var isPreviewing = false

    private var activeID: UUID? { settingsManager.settings.activeProfileID }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 16) {
                list.frame(width: 150)
                detail.frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsSection(title: "Groq key",
                            footnote: "Profiles rewrite your words with openai/gpt-oss-20b on Groq at temperature 0, usually in well under a second. Raw needs no key.") {
                Card { APIKeyRow(provider: .groq).padding(14) }
            }
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 4) {
            row(nil)
            ForEach(store.profiles) { row($0) }
            Button {
                let profile = store.addCustom()
                settingsManager.settings.activeProfileID = profile.id
            } label: {
                Label("New profile", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(HoverRowStyle())
        }
    }

    private func row(_ profile: Profile?) -> some View {
        let isActive = activeID == profile?.id
        return Button {
            settingsManager.settings.activeProfileID = profile?.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: profile?.symbol ?? "text.alignleft")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isActive ? Theme.accent : Theme.textTertiary)
                    .frame(width: 16)
                Text(profile?.name ?? "Raw")
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isActive ? Theme.accentSoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let id = activeID, let index = store.index(of: id) {
            editor(for: $store.profiles[index])
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Raw").font(.display(22)).foregroundStyle(Theme.text)
                Text("Pastes exactly what the speech model heard, with its punctuation. Fastest, and no API key needed.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ProfilePreview(profile: nil)
            }
        }
    }

    private func editor(for profile: Binding<Profile>) -> some View {
        let value = profile.wrappedValue
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                if value.isBuiltIn {
                    Text(value.name).font(.display(22)).foregroundStyle(Theme.text)
                } else {
                    TextField("", text: profile.name)
                        .textFieldStyle(.plain)
                        .font(.display(22))
                        .foregroundStyle(Theme.text)
                }
                Spacer()
                if value.isBuiltIn {
                    Button("Reset") { store.resetBuiltIn(value.id) }.buttonStyle(PillButtonStyle())
                } else {
                    Button("Delete") { store.delete(value.id) }.buttonStyle(PillButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Eyebrow("Instructions")
                TextEditor(text: profile.instructions)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .scrollContentBackground(.hidden)
                    .frame(height: 120)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Eyebrow(previewText[value.id] == nil ? "Preview" : "Preview · live")
                    Spacer()
                    Button {
                        runPreview(value)
                    } label: {
                        if isPreviewing {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Run", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(!keys.hasKey(.groq) || isPreviewing)
                    .help(keys.hasKey(.groq) ? "Run the sample through this profile" : "Add a Groq key below")
                }
                ProfilePreview(profile: value, liveOutput: previewText[value.id])
                if let previewError {
                    Text(previewError).font(.system(size: 11.5)).foregroundStyle(Theme.accent)
                }
            }
        }
    }

    private func runPreview(_ profile: Profile) {
        guard let key = APIKeys.shared.key(.groq) else { return }
        isPreviewing = true
        previewError = nil
        Task {
            do {
                let result = try await GroqFormatter().format(ProfileSample.spoken, profile: profile,
                                                              vocabulary: DictionaryStore.shared.vocabularyPrompt, key: key)
                previewText[profile.id] = result.text
                UsageLedger.shared.add(UsageRecord(service: .formatting, provider: "Groq gpt-oss-20b",
                                                   quantity: Double(result.promptTokens + result.completionTokens),
                                                   costUSD: result.cost))
            } catch {
                previewError = error.localizedDescription
            }
            isPreviewing = false
        }
    }
}
