import SwiftUI

struct SettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            HotkeySettingsView()
                .tabItem {
                    Label("Hotkey", systemImage: "keyboard")
                }

            ModelSettingsView()
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
        }
        .frame(width: 450, height: 300)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared

    var body: some View {
        Form {
            Section("Audio Input") {
                Picker("Microphone", selection: $settingsManager.settings.selectedAudioDeviceUID) {
                    Text("System Default").tag(nil as String?)
                    Divider()
                    ForEach(audioDeviceManager.inputDevices) { device in
                        Text(device.name).tag(device.uid as String?)
                    }
                }

                Button("Refresh Devices") {
                    audioDeviceManager.refreshDevices()
                }
            }

            Section("Feedback") {
                Toggle("Show menu bar icon", isOn: $settingsManager.settings.showMenuBarIcon)
                Toggle("Play sounds", isOn: $settingsManager.settings.playSounds)
            }
        }
        .padding()
    }
}

struct HotkeySettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        Form {
            Section("Push-to-Talk Hotkey") {
                HStack {
                    Text("Current:")
                    Text(hotkeyDisplayString)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                Button(isRecording ? "Cancel" : "Record New Hotkey") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .orange : .accentColor)

                Text("Hold this key combination to record, release to transcribe")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onDisappear {
            stopRecording()
        }
    }

    private var hotkeyDisplayString: String {
        var parts: [String] = []
        let mods = settingsManager.settings.hotkeyModifiers
        if mods.contains("control") { parts.append("⌃") }
        if mods.contains("option") { parts.append("⌥") }
        if mods.contains("shift") { parts.append("⇧") }
        if mods.contains("cmd") { parts.append("⌘") }
        parts.append(settingsManager.settings.hotkeyKey.uppercased())
        return parts.joined()
    }

    private func startRecording() {
        isRecording = true
        // Use local monitor (captures when Settings window has focus)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            captureHotkey(event: event)
            return nil // Consume the event so macOS doesn't process it
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
    }

    private func captureHotkey(event: NSEvent) {
        var modifiers: [String] = []

        if event.modifierFlags.contains(.command) { modifiers.append("cmd") }
        if event.modifierFlags.contains(.shift) { modifiers.append("shift") }
        if event.modifierFlags.contains(.option) { modifiers.append("option") }
        if event.modifierFlags.contains(.control) { modifiers.append("control") }

        // Get the key character
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Only accept if there's at least one modifier and a key
        if !modifiers.isEmpty && !key.isEmpty {
            settingsManager.settings.hotkeyModifiers = modifiers
            settingsManager.settings.hotkeyKey = key
            stopRecording()
        }
    }
}

struct ModelSettingsView: View {
    @ObservedObject private var settingsManager = SettingsManager.shared

    var body: some View {
        Form {
            Section("Whisper Model") {
                Picker("Model Size", selection: $settingsManager.settings.modelSize) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                Text(settingsManager.settings.modelSize.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Paths") {
                HStack {
                    Text("whisper-cli:")
                    TextField("Path", text: $settingsManager.settings.whisperPath)
                }

                HStack {
                    Text("Models dir:")
                    TextField("Path", text: $settingsManager.settings.modelDirectory)
                }
            }
        }
        .padding()
    }
}

#Preview {
    SettingsView()
}
