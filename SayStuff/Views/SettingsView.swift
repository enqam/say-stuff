import SwiftUI
import Carbon.HIToolbox

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
            Section("Hotkey") {
                HStack {
                    Text("Current:")
                    Text(hotkeyDisplayString)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                }

                Button(isRecording ? "Press any key..." : "Record New Hotkey") {
                    if isRecording {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(isRecording ? .orange : .accentColor)
            }

            Section("Mode") {
                Picker("Recording Mode", selection: $settingsManager.settings.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if settingsManager.settings.hotkeyMode == .toggle {
                    HStack {
                        Text("Auto-stop after:")
                        Slider(value: $settingsManager.settings.toggleTimeout, in: 5...120, step: 5)
                        Text("\(Int(settingsManager.settings.toggleTimeout))s")
                            .frame(width: 35, alignment: .trailing)
                            .monospacedDigit()
                    }
                }

                Text(helpText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onDisappear {
            stopRecording()
        }
    }

    private var helpText: String {
        switch settingsManager.settings.hotkeyMode {
        case .hold:
            return "Hold the hotkey to record, release to transcribe"
        case .toggle:
            return "Press once to start recording, press again to stop and transcribe"
        }
    }

    private var hotkeyDisplayString: String {
        var parts: [String] = []
        let mods = settingsManager.settings.hotkeyModifiers
        if mods.contains("control") { parts.append("⌃") }
        if mods.contains("option") { parts.append("⌥") }
        if mods.contains("shift") { parts.append("⇧") }
        if mods.contains("cmd") { parts.append("⌘") }
        parts.append(keyNameFromKeyCode(settingsManager.settings.hotkeyKeyCode))
        return parts.joined()
    }

    /// Convert keyCode to human-readable name
    private func keyNameFromKeyCode(_ keyCode: UInt16) -> String {
        // F-keys
        let fKeyMap: [UInt16: String] = [
            UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
            UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
            UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
            UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
            UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15",
            UInt16(kVK_F16): "F16", UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18",
            UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
        ]
        if let fKey = fKeyMap[keyCode] { return fKey }

        // Special keys
        let specialMap: [UInt16: String] = [
            UInt16(kVK_Space): "Space",
            UInt16(kVK_Return): "Return",
            UInt16(kVK_Tab): "Tab",
            UInt16(kVK_Escape): "Esc",
            UInt16(kVK_Delete): "Delete",
            UInt16(kVK_ForwardDelete): "Fwd Del",
        ]
        if let special = specialMap[keyCode] { return special }

        // Letter keys (A-Z)
        let letterMap: [UInt16: String] = [
            UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
            UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
            UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
            UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
            UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
            UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
            UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
            UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
            UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        ]
        if let letter = letterMap[keyCode] { return letter }

        // Fallback: use the legacy hotkeyKey string if available
        let legacyKey = SettingsManager.shared.settings.hotkeyKey.uppercased()
        return legacyKey.isEmpty ? "?" : legacyKey
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

        // Use raw keyCode instead of charactersIgnoringModifiers
        // This correctly captures F-keys and other special keys
        let keyCode = event.keyCode

        // Accept any key (with or without modifiers)
        // F-keys work standalone, letters typically need modifiers
        settingsManager.settings.hotkeyModifiers = modifiers
        settingsManager.settings.hotkeyKeyCode = keyCode
        // Also update legacy hotkeyKey for backward compatibility
        settingsManager.settings.hotkeyKey = event.charactersIgnoringModifiers?.lowercased() ?? ""
        stopRecording()
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
