import SwiftUI

/// The menu bar panel. Everything here is one click: profile, engine, language, copy a recent result.
struct MenuBarView: View {
    var onHeightChange: (CGFloat) -> Void = { _ in }

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

    private var settings: AppSettings { settingsManager.settings }
    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if !hasAccessibility {
                accessibilityBanner
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            profiles
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            separator
            languages
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            if !history.transcriptions.isEmpty {
                separator
                recent
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
            }

            separator
            footer
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
        }
        .frame(width: Self.width)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HeightKey.self, perform: onHeightChange)
        .onAppear { hasAccessibility = AXIsProcessTrusted() }
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
            EngineSwitch()
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
                    Text("Listening · \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .foregroundStyle(Theme.accent)
                }
            case .processing:
                Text("Transcribing…")
            }
        }
        .font(.mono(11.5))
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
        [nil] + profileStore.profiles.map { Optional($0) }
    }

    private var previewProfile: Profile? {
        if let hovered = hoveredProfileID { return profileStore.profile(id: hovered) }
        return profileStore.profile(id: settings.activeProfileID)
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 6) {
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

            ProfilePreview(profile: previewProfile, compact: true)
                .frame(height: 124, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

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

    // MARK: Language

    private var languageChoices: [String] {
        var codes = ["auto"] + settings.spokenLanguages
        if !codes.contains(settings.language) { codes.append(settings.language) }
        return codes
    }

    private var languages: some View {
        HStack(spacing: 5) {
            Image(systemName: "globe")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .padding(.trailing, 3)
            ForEach(languageChoices, id: \.self) { code in
                Chip(title: code == "auto" ? "Auto" : code.uppercased(), isSelected: settings.language == code) {
                    settingsManager.settings.language = code
                }
            }
            Spacer()
            IconButton(symbol: "ellipsis", help: "All languages") {
                AppDelegate.shared.openSettings(.speech)
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

            ForEach(history.transcriptions.prefix(3)) { item in
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
                            .lineLimit(2)
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

    private var footer: some View {
        HStack(spacing: 0) {
            Button {
                AppDelegate.shared.openSettings(.cloud)
            } label: {
                Text(ledger.records.isEmpty ? "No cloud spend yet" : "\(monthCost.usdString) this month")
                    .font(.mono(11.5))
                    .foregroundStyle(Theme.textTertiary)
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
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Icon over name. The selected tile takes the accent.
private struct ProfileTile: View {
    let profile: Profile?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: profile?.symbol ?? "text.alignleft")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
                Text(profile?.name ?? "Raw")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : (isHovering ? Theme.raised : Theme.surface))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovering)
    }
}

/// Local | Cloud in one click. Cloud without a key jumps to where you add one.
struct EngineSwitch: View {
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
        let isSelected = settingsManager.settings.engine == engine
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
