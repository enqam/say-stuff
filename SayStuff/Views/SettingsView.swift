import SwiftUI
import ServiceManagement

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, transcription, profiles, dictionary, history, usage, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .transcription: return "Transcription"
        case .profiles: return "Output"
        case .dictionary: return "Dictionary"
        case .history: return "History"
        case .usage: return "Usage"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .profiles: return "text.badge.star"
        case .dictionary: return "character.book.closed"
        case .history: return "clock"
        case .usage: return "dollarsign.circle"
        case .about: return "info.circle"
        }
    }
}

final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var pane: SettingsPane = .general
}

struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { router.pane },
                set: { if let pane = $0 { router.pane = pane } }
            )) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch router.pane {
                case .general: GeneralPane()
                case .transcription: TranscriptionPane()
                case .profiles: ProfilesPane()
                case .dictionary: DictionaryPane()
                case .history: HistoryPane()
                case .usage: UsagePane()
                case .about: AboutPane()
                }
            }
            .navigationTitle(router.pane.title)
        }
        .modifier(HideSidebarToggle())
        .frame(minWidth: 640, minHeight: 440)
    }
}

private struct HideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var devices = AudioDeviceManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let sounds = SoundPlayer()

    var body: some View {
        Form {
            Section {
                LabeledContent("Shortcut") { ShortcutRecorder() }
                Picker("Mode", selection: $settingsManager.settings.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Stop automatically after", selection: $settingsManager.settings.toggleTimeout) {
                    ForEach([60.0, 120, 300, 600], id: \.self) { Text("\(Int($0 / 60)) min").tag($0) }
                }
                if let error = dictation.hotkeyError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Dictation")
            } footer: {
                Text("Press Esc while recording to cancel.")
                    .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Microphone", selection: $settingsManager.settings.selectedAudioDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices.inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Picker("Start and stop sound", selection: $settingsManager.settings.feedbackSound) {
                    Text("None").tag("")
                    ForEach(SoundPlayer.choices, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: settingsManager.settings.feedbackSound) { sounds.play($0) }

                Toggle("Lower other audio while recording", isOn: $settingsManager.settings.attenuateAudio)
                if settingsManager.settings.attenuateAudio {
                    LabeledContent("Lower to") {
                        HStack {
                            Slider(value: $settingsManager.settings.attenuationLevel, in: 0...0.8, step: 0.05)
                                .frame(width: 160)
                            Text("\(Int(settingsManager.settings.attenuationLevel * 100))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }
            }

            Section {
                Toggle("Show a red border around the screen while recording", isOn: $settingsManager.settings.showScreenBorder)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            print("[Settings] Login item change failed: \(error)")
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Transcription

struct TranscriptionPane: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var falKey = ""

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: $settingsManager.settings.engine) {
                    ForEach(TranscriptionEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settingsManager.settings.engine == .local
                     ? "Private and works offline. Speed depends on the model."
                     : "Audio is sent to fal.ai for transcription. Fast on long dictations.")
                    .foregroundStyle(.secondary)
            }

            if settingsManager.settings.engine == .local {
                Section("Model") {
                    ForEach(WhisperModel.allCases, id: \.self) { ModelRow(model: $0) }
                }
            } else {
                Section {
                    LabeledContent("Provider", value: "fal.ai · Wizper v3")
                    SecureField("API key", text: $falKey, prompt: Text("fal.ai key"))
                        .disabled(true)
                    ComingNextNote(text: "Cloud transcription is connected in the next step. Until then, dictation runs on this Mac.")
                } header: {
                    Text("Cloud")
                }
            }

            Section {
                Picker("Spoken language", selection: $settingsManager.settings.language) {
                    ForEach(allSupportedLanguages) { Text($0.name).tag($0.code) }
                }
                Toggle("Add a space after inserted text", isOn: $settingsManager.settings.addTrailingSpace)
            }

            Section("Local engine files") {
                LabeledContent("whisper-cli") {
                    TextField("whisper-cli", text: $settingsManager.settings.whisperPath)
                        .labelsHidden()
                        .font(.system(size: 11.5, design: .monospaced))
                }
                LabeledContent("Models folder") {
                    HStack {
                        TextField("Models folder", text: $settingsManager.settings.modelDirectory)
                            .labelsHidden()
                            .font(.system(size: 11.5, design: .monospaced))
                        Button {
                            NSWorkspace.shared.open(settingsManager.expandedModelDirectory)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("Show in Finder")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("SayStuff").font(.title3.weight(.semibold))
                        Text(version).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Button("Check for Updates…") { AppDelegate.shared.checkForUpdates() }
                Button("Run Setup Again…") { AppDelegate.shared.showOnboarding() }
                Button("Show App Data in Finder") { NSWorkspace.shared.open(AppPaths.support) }
            }
        }
        .formStyle(.grouped)
    }
}
