import SwiftUI
import ServiceManagement

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, speech, profiles, dictionary, cloud, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .speech: return "Speech"
        case .profiles: return "Profiles"
        case .dictionary: return "Dictionary"
        case .cloud: return "Cloud"
        case .history: return "History"
        }
    }
}

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var pane: SettingsPane = .general
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared
    @Namespace private var tabSelection

    var body: some View {
        ScrollView {
            Group {
                switch router.pane {
                case .general: GeneralPane()
                case .speech: SpeechPane()
                case .profiles: ProfilesPane()
                case .dictionary: DictionaryPane()
                case .cloud: CloudPane()
                case .history: HistoryPane()
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 64)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The tab bar floats over the content in the title bar area, like a toolbar.
        .overlay(alignment: .top) {
            tabs.padding(.top, 9)
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(SettingsPane.allCases) { pane in
                let isSelected = router.pane == pane
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { router.pane = pane }
                } label: {
                    Text(pane.title)
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Theme.raised)
                                    .matchedGeometryEffect(id: "tab", in: tabSelection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassSurface(Capsule())
    }
}

/// Eyebrow label over a card.
struct SettingsSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title).padding(.leading, 2)
            content
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var devices = AudioDeviceManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var settings: Binding<AppSettings> { $settingsManager.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Shortcut", footnote: dictation.hotkeyError) {
                Card {
                    CardRow(title: "Dictate") { ShortcutRecorder() }
                    CardRow(title: "Mode") {
                        ChipPicker(options: [(HotkeyMode.hold, "Hold to talk"), (.toggle, "Press to toggle")],
                                   selection: settings.hotkeyMode)
                    }
                    CardRow(title: "Stop automatically after", showsDivider: false) {
                        ChipPicker(options: [(60.0, "1m"), (120, "2m"), (300, "5m"), (600, "10m")],
                                   selection: settings.toggleTimeout, mono: true)
                    }
                }
            }

            SettingsSection(title: "Sound") {
                Card {
                    CardRow(title: "Sounds", detail: "One when you start, another when the text lands") {
                        Switch(isOn: settings.playSounds)
                    }
                    CardRow(title: "Lower other audio while recording", showsDivider: settingsManager.settings.attenuateAudio) {
                        Switch(isOn: settings.attenuateAudio)
                    }
                    if settingsManager.settings.attenuateAudio {
                        CardRow(title: "Lower to", showsDivider: false) {
                            HStack(spacing: 10) {
                                Slider(value: settings.attenuationLevel, in: 0...0.8, step: 0.05)
                                    .tint(Theme.accent)
                                    .frame(width: 150)
                                Text("\(Int(settingsManager.settings.attenuationLevel * 100))%")
                                    .font(.mono(11))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 34, alignment: .trailing)
                            }
                        }
                    }
                }
            }

            SettingsSection(title: "Microphone") {
                Card {
                    micRow(name: "System default", uid: nil, last: devices.inputDevices.isEmpty)
                    ForEach(devices.inputDevices) { device in
                        micRow(name: device.name, uid: device.uid, last: device == devices.inputDevices.last)
                    }
                }
            }

            SettingsSection(title: "System") {
                Card {
                    CardRow(title: "Red border around the screen while recording") {
                        Switch(isOn: settings.showScreenBorder)
                    }
                    CardRow(title: "Open at login", showsDivider: false) {
                        Switch(isOn: $launchAtLogin)
                            .onChange(of: launchAtLogin) { _, enabled in
                                do {
                                    if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                } catch {
                                    print("[Settings] Login item change failed: \(error)")
                                    launchAtLogin = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                }
            }

            HStack(spacing: 14) {
                Text("SayStuff \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                Button("Check for updates") { AppDelegate.shared.checkForUpdates() }.buttonStyle(.plain)
                Button("Run setup again") { AppDelegate.shared.showOnboarding() }.buttonStyle(.plain)
                Button("App data") { NSWorkspace.shared.open(AppPaths.support) }.buttonStyle(.plain)
            }
            .font(.mono(10.5))
            .foregroundStyle(Theme.textTertiary)
            .padding(.leading, 2)
        }
    }

    private func micRow(name: String, uid: String?, last: Bool) -> some View {
        let isSelected = settingsManager.settings.selectedAudioDeviceUID == uid
        return Button {
            settingsManager.settings.selectedAudioDeviceUID = uid
        } label: {
            CardRow(title: name, showsDivider: !last) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Speech

struct SpeechPane: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var keys = APIKeys.shared
    @State private var showsFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                engineCard(.local, symbol: "laptopcomputer", title: "On this Mac", detail: "Private, offline, free")
                engineCard(.cloud, symbol: "bolt.fill", title: "Cloud", detail: "Whisper on Groq or fal.ai")
            }

            if settingsManager.settings.engine == .local {
                SettingsSection(title: "Model") {
                    Card {
                        ForEach(WhisperModel.allCases, id: \.self) { model in
                            ModelRow(model: model)
                        }
                        CardRow(title: "Keep model in memory",
                                detail: "Loads while you start talking, then frees its memory (\(settingsManager.settings.modelSize.memoryString)) when idle.") {
                            ChipPicker(options: [(5.0, "5 min"), (30, "30 min"), (0, "Always")],
                                       selection: $settingsManager.settings.modelIdleMinutes)
                        }
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showsFiles.toggle() }
                        } label: {
                            CardRow(title: "Engine files", showsDivider: showsFiles) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .rotationEffect(.degrees(showsFiles ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if showsFiles {
                            VStack(alignment: .leading, spacing: 8) {
                                ThemedField(placeholder: "whisper-cli path", text: $settingsManager.settings.whisperPath, mono: true)
                                HStack {
                                    ThemedField(placeholder: "Models folder", text: $settingsManager.settings.modelDirectory, mono: true)
                                    IconButton(symbol: "folder", help: "Show in Finder") {
                                        NSWorkspace.shared.open(settingsManager.expandedModelDirectory)
                                    }
                                }
                            }
                            .padding(14)
                        }
                    }
                }
            } else {
                let provider = settingsManager.settings.cloudProvider
                let hasKey = keys.hasKey(provider.keyProvider)
                Card {
                    CardRow(title: "Provider") {
                        ChipPicker(options: [(CloudProvider.groq, "Groq · fastest"), (.fal, "fal.ai")],
                                   selection: $settingsManager.settings.cloudProvider)
                    }
                    CardRow(title: provider == .groq ? "whisper-large-v3-turbo" : "Wizper v3",
                            detail: hasKey
                                ? "Falls back to your local model if the cloud can't be reached."
                                : "Add your \(provider.keyProvider.displayName) key to transcribe in the cloud.",
                            showsDivider: false) {
                        Button(hasKey ? "Manage key" : "Add key") { SettingsRouter.shared.pane = .cloud }
                            .buttonStyle(PillButtonStyle(prominent: !hasKey))
                    }
                }
            }

            SettingsSection(title: "Languages you speak",
                            footnote: "Auto picks only among these, so short phrases don't land in the wrong language. Pick one in the menu bar to force it.") {
                FlowLayout(spacing: 6) {
                    ForEach(allSupportedLanguages.filter { $0.code != "auto" }) { language in
                        let isOn = settingsManager.settings.spokenLanguages.contains(language.code)
                        Chip(title: language.name, isSelected: isOn) {
                            // Keep at least one.
                            guard !isOn || settingsManager.settings.spokenLanguages.count > 1 else { return }
                            settingsManager.settings.toggleSpokenLanguage(language.code)
                        }
                    }
                }
            }

            SettingsSection(title: "Language shortcuts",
                            footnote: "Dictates straight into that language and skips detection (about 0.1 s faster on Small, 0.5 s on Turbo). Your main shortcut keeps using Auto.") {
                Card {
                    let spoken = settingsManager.settings.spokenLanguages
                    ForEach(spoken, id: \.self) { code in
                        CardRow(title: allSupportedLanguages.first { $0.code == code }?.name ?? code.uppercased(),
                                detail: dictation.languageHotkeyErrors[code],
                                showsDivider: code != spoken.last) {
                            ShortcutRecorder(combo: Binding(
                                get: { settingsManager.settings.languageHotkeys[code] },
                                set: { settingsManager.settings.languageHotkeys[code] = $0 }
                            ))
                        }
                    }
                }
            }

            Card {
                CardRow(title: "Add a space after inserted text", showsDivider: false) {
                    Switch(isOn: $settingsManager.settings.addTrailingSpace)
                }
            }

        }
    }

    private func engineCard(_ engine: TranscriptionEngine, symbol: String, title: String, detail: String) -> some View {
        let isSelected = settingsManager.settings.engine == engine
        return Button {
            settingsManager.settings.engine = engine
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.display(16)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? Theme.accentSoft : Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.55) : Theme.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cloud

/// Every API key in one place, plus what they've cost.
struct CloudPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSection(title: "Groq", footnote: "Cloud speech-to-text (whisper-large-v3-turbo) and profile rewriting (openai/gpt-oss-20b).") {
                Card { APIKeyRow(provider: .groq).padding(14) }
            }
            SettingsSection(title: "fal.ai", footnote: "Optional second cloud speech provider (Wizper v3). Slower: audio is uploaded before it's transcribed.") {
                Card { APIKeyRow(provider: .fal).padding(14) }
            }
            SettingsSection(title: "Spend") { UsageCard() }
            Text("Keys are stored in your Keychain.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}
