import SwiftUI

/// The menu bar popover: status, output profile, the three settings you change often,
/// and recent transcriptions. Everything else lives in Settings.
struct MenuBarView: View {
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var profileStore = ProfileStore.shared
    @ObservedObject private var history = TranscriptionStore.shared
    @ObservedObject private var devices = AudioDeviceManager.shared

    /// `.some(nil)` means the pointer is over "Raw".
    @State private var hoveredProfileID: UUID??
    @State private var copiedID: UUID?
    @State private var hasAccessibility = AXIsProcessTrusted()

    private var settings: AppSettings { settingsManager.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            if !hasAccessibility {
                accessibilityWarning
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            Divider()
            profiles.padding(8)
            Divider()
            quickSettings.padding(.horizontal, 14).padding(.vertical, 10)

            if !history.transcriptions.isEmpty {
                Divider()
                recent.padding(8)
            }

            Divider()
            footer.padding(8)
        }
        .frame(width: 300)
        .onAppear { hasAccessibility = AXIsProcessTrusted() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("SayStuff")
                    .font(.system(size: 13, weight: .semibold))
                statusText
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                AppDelegate.shared.openSettings(.general)
            } label: {
                KeyCaps(combo: settings.hotkey, size: 10.5)
            }
            .buttonStyle(.plain)
            .help("Change shortcut")
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch dictation.phase {
        case .idle:
            Text(settings.hotkeyMode == .hold ? "Hold the shortcut to talk" : "Press the shortcut to talk")
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                Text("Listening · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
            }
        case .processing:
            Text("Transcribing…")
        }
    }

    private var statusColor: Color {
        switch dictation.phase {
        case .idle: return .accentColor
        case .recording: return .red
        case .processing: return .orange
        }
    }

    private var accessibilityWarning: some View {
        Button {
            AppDelegate.shared.showOnboarding()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-paste is off")
                        .font(.system(size: 12, weight: .medium))
                    Text("Allow Accessibility access to paste into apps.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(MenuRowButtonStyle())
    }

    // MARK: Profiles

    private var profileChoices: [Profile?] {
        [nil] + profileStore.profiles.map { Optional($0) }
    }

    private var previewProfile: Profile? {
        if let hovered = hoveredProfileID { return profileStore.profile(id: hovered) }
        return profileStore.profile(id: settings.activeProfileID)
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Output")

            ForEach(profileChoices, id: \.?.id) { profile in
                Button {
                    settingsManager.settings.activeProfileID = profile?.id
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: profile?.symbol ?? "text.alignleft")
                            .font(.system(size: 12))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(profile?.name ?? "Raw")
                            .font(.system(size: 13))
                        Text(profile?.summary ?? "Exactly what you said")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if settings.activeProfileID == profile?.id {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .buttonStyle(MenuRowButtonStyle())
                .onHover { inside in
                    if inside {
                        hoveredProfileID = .some(profile?.id)
                    } else if hoveredProfileID == .some(profile?.id) {
                        hoveredProfileID = nil
                    }
                }
            }

            ProfilePreview(profile: previewProfile, compact: true)
                .frame(height: 112, alignment: .top)
                .clipped()
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .animation(.easeOut(duration: 0.12), value: previewProfile?.id)
        }
    }

    // MARK: Quick settings

    private var quickSettings: some View {
        VStack(spacing: 8) {
            row("Engine") {
                Picker("Engine", selection: $settingsManager.settings.engine) {
                    Text("Local").tag(TranscriptionEngine.local)
                    Text("Cloud").tag(TranscriptionEngine.cloud)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }
            row("Language") {
                Picker("Language", selection: $settingsManager.settings.language) {
                    ForEach(allSupportedLanguages) { language in
                        Text(language.code == "auto" ? "Auto" : language.name).tag(language.code)
                    }
                }
                .frame(width: 140)
            }
            row("Microphone") {
                Picker("Microphone", selection: $settingsManager.settings.selectedAudioDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices.inputDevices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                .frame(width: 140)
            }
        }
        .labelsHidden()
        .controlSize(.small)
    }

    private func row<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            control()
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                sectionTitle("Recent")
                Spacer()
                Button("Show all") { AppDelegate.shared.openSettings(.history) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
            }

            ForEach(history.transcriptions.prefix(3)) { item in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copiedID = item.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copiedID == item.id { copiedID = nil }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(item.text)
                            .font(.system(size: 12.5))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if copiedID == item.id {
                            Text("Copied")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text(item.date.shortRelative)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .buttonStyle(MenuRowButtonStyle())
                .help("Click to copy")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                AppDelegate.shared.openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(MenuRowButtonStyle())
            .keyboardShortcut(",", modifiers: .command)

            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(MenuRowButtonStyle())
            .frame(width: 70)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
    }
}
