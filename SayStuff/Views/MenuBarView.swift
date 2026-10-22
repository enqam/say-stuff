import SwiftUI

/// The menu bar panel. Everything here is one click: profile, engine, language, copy a recent result.
struct MenuBarView: View {
    var onHeightChange: (CGFloat) -> Void = { _ in }
    var maximumHeight: CGFloat = 720
    var initiallyShowsPreview = false
    #if DEBUG
    var snapshot: MenuSnapshotFixture? = nil
    #endif

    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var profileStore = ProfileStore.shared
    @ObservedObject private var history = TranscriptionStore.shared
    @ObservedObject private var keys = APIKeys.shared
    @ObservedObject private var ledger = UsageLedger.shared

    /// `.some(nil)` means the pointer is over "Raw".
    @State private var hoveredProfileID: UUID??
    @State private var copiedID: UUID?
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var showsPreview = false
    @State private var contentHeight: CGFloat = 400

    private var settings: AppSettings {
        #if DEBUG
        if let snapshot { return snapshot.settings }
        #endif
        return settingsManager.settings
    }

    private var inputDevices: [AudioDevice] {
        #if DEBUG
        if let snapshot { return snapshot.devices }
        #endif
        return devices.inputDevices
    }

    private var recentTranscriptions: [RecentTranscription] {
        #if DEBUG
        if let snapshot { return snapshot.recent }
        #endif
        return history.transcriptions
    }
    static let width: CGFloat = 360

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .frame(height: 64)
            separator

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !hasAccessibility { accessibilityBanner }
                    profiles
                    separator
                    models
                    languages
                    microphones
                    if !recentTranscriptions.isEmpty {
                        separator
                        recent
                    }
                }
                .padding(14)
                .frame(width: Self.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
            }
            .frame(height: min(contentHeight, max(1, maximumHeight - 120)))
            .onPreferenceChange(ContentHeightKey.self) { height in
                if height > 0 { contentHeight = height }
            }

            separator
            footer
                .padding(.horizontal, 12)
                .frame(height: 54)
        }
        .frame(width: Self.width)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HeightKey.self, perform: onHeightChange)
        .onAppear {
            hasAccessibility = AXIsProcessTrusted()
            #if DEBUG
            if snapshot != nil { hasAccessibility = true }
            #endif
            showsPreview = initiallyShowsPreview
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 14)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(statusTint.opacity(0.18))
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(statusTint)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("SayStuff")
                    .font(.system(size: 14, weight: .semibold))
                status
            }
            Spacer()
            EngineSwitch(engine: settings.engine)
                .fixedSize()
        }
    }

    private var statusTint: Color {
        switch dictation.phase {
        case .idle: return Theme.textSecondary
        case .recording: return Theme.accent
        case .processing: return Theme.warning
        }
    }

    @ViewBuilder
    private var status: some View {
        Group {
            switch dictation.phase {
            case .idle:
                Text("\(settings.hotkey.displayString) to talk")
            case .recording(let since):
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                    let language = dictation.recordingLanguage.map { " · \($0.uppercased())" } ?? ""
                    Text("Listening\(language) · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .foregroundStyle(Theme.accent)
                }
            case .processing:
                Text("Transcribing…")
            }
        }
        .font(.mono(11.5))
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(Theme.textSecondary)
    }

    private var accessibilityBanner: some View {
        Button {
            AppDelegate.shared.showOnboarding()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.warning)
                Text("Allow Accessibility so SayStuff can paste")
                    .font(.system(size: 12))
                Spacer(minLength: 4)
                Text("Fix")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.warning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Profiles

    private var profileChoices: [Profile?] {
        #if DEBUG
        if let snapshot { return [nil] + snapshot.profiles.map { Optional($0) } }
        #endif
        return [nil] + profileStore.profiles.map { Optional($0) }
    }

    private var previewProfile: Profile? {
        let id: UUID?
        if let hovered = hoveredProfileID { id = hovered } else { id = settings.activeProfileID }
        return profileChoices.compactMap { $0 }.first { $0.id == id }
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Output")
                Spacer()
                Button {
                    showsPreview.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Preview")
                        Image(systemName: showsPreview ? "chevron.up" : "chevron.down")
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsPreview ? "Hide output preview" : "Show output preview")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(profileChoices, id: \.?.id) { profile in
                    ProfileTile(profile: profile, isSelected: settings.activeProfileID == profile?.id) {
                        settingsManager.settings.activeProfileID = profile?.id
                    }
                    .onHover { inside in
                        if inside {
                            hoveredProfileID = .some(profile?.id)
                        } else if hoveredProfileID == .some(profile?.id) {
                            hoveredProfileID = nil
                        }
                    }
                }
            }

            Text(previewProfile?.summary ?? "As spoken, without rewriting")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if showsPreview {
                ProfilePreview(profile: previewProfile, compact: true)
            }

            if previewProfile != nil, !keys.hasKey(.groq) {
                Button {
                    AppDelegate.shared.openSettings(.cloud)
                } label: {
                    Label("Profiles need a Groq key", systemImage: "key")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
    }

    // MARK: Model

    @ObservedObject private var downloader = ModelDownloader.shared

    private var downloadedModels: [WhisperModel] {
        #if DEBUG
        if let snapshot { return snapshot.models }
        #endif
        _ = downloader.completedCount
        return WhisperModel.allCases.filter { settingsManager.isModelDownloaded($0) }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading(settings.engine == .local ? "Local model" : "Cloud provider",
                           action: settings.engine == .local ? "Manage" : "API keys") {
                AppDelegate.shared.openSettings(settings.engine == .local ? .speech : .cloud)
            }
            if settings.engine == .local {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(downloadedModels, id: \.self) { model in
                        MenuChoice(title: model.shortName, isSelected: settings.modelSize == model) {
                            settingsManager.settings.modelSize = model
                        }
                        .help(model.displayName + " · " + model.description)
                    }
                }
                if downloadedModels.isEmpty {
                    Button("Download a model…") { AppDelegate.shared.openSettings(.speech) }
                        .buttonStyle(PillButtonStyle())
                } else if !downloadedModels.contains(settings.modelSize) {
                    Text("\(settings.modelSize.shortName) is not downloaded. Choose an installed model or open Manage.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(CloudProvider.allCases, id: \.self) { provider in
                        MenuChoice(title: provider == .groq ? "Groq" : "fal.ai", isSelected: settings.cloudProvider == provider) {
                            settingsManager.settings.cloudProvider = provider
                            if !keys.hasKey(provider.keyProvider) { AppDelegate.shared.openSettings(.cloud) }
                        }
                    }
                }
            }
        }
    }

    private func sectionHeading(_ title: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack {
            Eyebrow(title)
            Spacer()
            Button(action, action: perform)
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Microphone

    @ObservedObject private var devices = AudioDeviceManager.shared

    private var microphones: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Microphone", action: "Refresh") { devices.refreshDevices() }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                MenuChoice(title: "System default", isSelected: settings.selectedAudioDeviceUID == nil) {
                    settingsManager.settings.selectMicrophone(nil)
                }
                .help("Follows the system input, except Bluetooth headsets and iPhones")
                ForEach(inputDevices) { device in
                    MenuChoice(title: device.shortName, isSelected: settings.selectedAudioDeviceUID == device.uid) {
                        settingsManager.settings.selectMicrophone(device)
                    }
                    .help(device.name)
                    .accessibilityLabel(device.name)
                }
            }
            if let selectedUID = settings.selectedAudioDeviceUID,
               !inputDevices.contains(where: { $0.uid == selectedUID }) {
                Text("\(settings.selectedAudioDeviceName ?? "Selected microphone") is disconnected. SayStuff switches back to it when it reconnects.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Language

    private var languageChoices: [String] {
        var codes = ["auto"] + settings.spokenLanguages
        if !codes.contains(settings.language) { codes.append(settings.language) }
        return codes
    }

    private var languages: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Language", action: "Manage") { AppDelegate.shared.openSettings(.speech) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(languageChoices, id: \.self) { code in
                    MenuChoice(title: code == "auto" ? "Auto" : code.uppercased(),
                               isSelected: settings.language == code, showsCheckmark: false) {
                        settingsManager.settings.language = code
                    }
                    .accessibilityLabel(allSupportedLanguages.first { $0.code == code }?.name ?? code)
                }
            }
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Recent")
                Spacer()
                Button("Show all") { AppDelegate.shared.openSettings(.history) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.top, 2)
            .padding(.bottom, 3)

            ForEach(recentTranscriptions.prefix(3)) { item in
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    copiedID = item.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if copiedID == item.id { copiedID = nil }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.text)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Text(copiedID == item.id ? "Copied" : item.date.shortRelative)
                            .font(.mono(11))
                            .foregroundStyle(copiedID == item.id ? Theme.accent : Theme.textTertiary)
                    }
                }
                .buttonStyle(HoverRowStyle())
                .help("Click to copy")
            }
        }
    }

    // MARK: Footer

    private var monthCost: Decimal {
        ledger.records(since: UsageLedger.startOfMonth).reduce(0) { $0 + $1.costUSD }
    }

    private var spendLine: String {
        guard !ledger.records.isEmpty else { return "No cloud spend yet" }
        let month = "\(monthCost.usdString) this month"
        return ledger.projectedMonthlyCost.map { "\(month) · ≈\($0.usdString)/mo" } ?? month
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                AppDelegate.shared.openSettings(.cloud)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ledger.records.isEmpty ? "No cloud spend yet" : "\(monthCost.usdString) this month")
                    if let projected = ledger.projectedMonthlyCost {
                        Text("≈\(projected.usdString) / month")
                    }
                }
                .font(.mono(11))
                .lineLimit(1)
                .foregroundStyle(Theme.textSecondary)
                .help(spendLine)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            Spacer()
            IconButton(symbol: "gearshape", help: "Settings  ⌘,") { AppDelegate.shared.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            IconButton(symbol: "power", help: "Quit SayStuff  ⌘Q") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Equal-width choices constrain long names instead of letting intrinsic widths stretch the panel.
private struct MenuChoice: View {
    let title: String
    let isSelected: Bool
    var showsCheckmark = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsCheckmark {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(isSelected ? 1 : 0)
                }
            }
            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.accentSoft : (isHovering ? Theme.raised : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.3) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(title)
    }
}

/// Compact output choice. The selected tile takes the accent.
private struct ProfileTile: View {
    let profile: Profile?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: profile?.symbol ?? "text.alignleft")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(profile?.name ?? "Raw")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : (isHovering ? Theme.raised : Theme.surface))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(profile?.name ?? "Raw")
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

/// Local | Cloud in one click. Cloud without a key jumps to where you add one.
struct EngineSwitch: View {
    var engine: TranscriptionEngine? = nil
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var keys = APIKeys.shared
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 0) {
            segment(.local, title: "Local")
            segment(.cloud, title: "Cloud")
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
    }

    private func segment(_ engine: TranscriptionEngine, title: String) -> some View {
        let isSelected = (self.engine ?? settingsManager.settings.engine) == engine
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                settingsManager.settings.engine = engine
            }
            if engine == .cloud, !keys.hasKey(settingsManager.settings.cloudProvider.keyProvider) {
                AppDelegate.shared.openSettings(.cloud)
            }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.raised)
                            .matchedGeometryEffect(id: "engine", in: selection)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
