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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 15)
                .padding(.bottom, 14)

            if !hasAccessibility {
                accessibilityBanner
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }

            profiles
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            hairline
            languages
                .padding(.horizontal, 16)
                .padding(.vertical, 11)

            if !history.transcriptions.isEmpty {
                hairline
                recent
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }

            hairline
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: 340)
        .background(Theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairlineStrong))
        .preferredColorScheme(.dark)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HeightKey.self, perform: onHeightChange)
        .onAppear { hasAccessibility = AXIsProcessTrusted() }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SayStuff")
                    .font(.display(21))
                    .foregroundStyle(Theme.text)
                status
            }
            Spacer()
            EngineSwitch()
        }
    }

    @ViewBuilder
    private var status: some View {
        switch dictation.phase {
        case .idle:
            HStack(spacing: 6) {
                KeyCaps(combo: settings.hotkey, size: 9)
                Text(settings.hotkeyMode == .hold ? "hold to talk" : "to talk")
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                Label {
                    Text("LISTENING \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                } icon: {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                }
                .font(.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
        case .processing:
            Text("TRANSCRIBING…")
                .font(.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var accessibilityBanner: some View {
        Button {
            AppDelegate.shared.showOnboarding()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Theme.warning)
                Text("Allow Accessibility so SayStuff can paste")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("FIX")
                    .font(.mono(10, weight: .bold))
                    .foregroundStyle(Theme.warning)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(0.1)))
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
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(profileChoices, id: \.?.id) { profile in
                    ProfileTile(
                        profile: profile,
                        isSelected: settings.activeProfileID == profile?.id
                    ) {
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
                .frame(height: 126, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            if previewProfile != nil, !keys.hasKey(.groq) {
                Button {
                    AppDelegate.shared.openSettings(.profiles)
                } label: {
                    Text("Profiles need a Groq key — add one ↗")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.warning)
                }
                .buttonStyle(.plain)
                .padding(.leading, 2)
            }
        }
    }

    // MARK: Language

    private var languageChoices: [String] {
        var codes = ["auto"] + settings.recentLanguages
        if !codes.contains(settings.language) { codes.append(settings.language) }
        return codes
    }

    private var languages: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(.trailing, 2)
            ForEach(languageChoices, id: \.self) { code in
                Chip(title: code == "auto" ? "AUTO" : code.uppercased(), isSelected: settings.language == code, mono: true) {
                    settingsManager.settings.selectLanguage(code)
                }
            }
            Spacer()
            IconButton(symbol: "plus", help: "More languages") {
                AppDelegate.shared.openSettings(.transcription)
            }
        }
    }

    // MARK: Recent

    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Eyebrow("Recent")
                Spacer()
                Button {
                    AppDelegate.shared.openSettings(.history)
                } label: {
                    Text("ALL")
                        .font(.mono(10, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

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
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Text(copiedID == item.id ? "COPIED" : item.date.shortRelative)
                            .font(.mono(10, weight: .medium))
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
        HStack(spacing: 2) {
            if ledger.records.isEmpty {
                Text(settings.engine == .local ? "On-device · free" : "Cloud")
                    .font(.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.leading, 6)
            } else {
                Button {
                    AppDelegate.shared.openSettings(.transcription)
                } label: {
                    Text("\(monthCost.usdString) this month")
                        .font(.mono(10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
            }
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

/// Square-ish tile: icon over name. Selected tiles glow in the accent.
private struct ProfileTile: View {
    let profile: Profile?
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : (isHovering ? Theme.raised : Theme.surface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.55) : Theme.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// LOCAL | CLOUD in one click. Cloud without a key jumps to where you add one.
struct EngineSwitch: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var keys = APIKeys.shared

    var body: some View {
        HStack(spacing: 0) {
            segment(.local, title: "LOCAL")
            segment(.cloud, title: "CLOUD")
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.3)))
        .overlay(Capsule().strokeBorder(Theme.hairline))
    }

    private func segment(_ engine: TranscriptionEngine, title: String) -> some View {
        let isSelected = settingsManager.settings.engine == engine
        return Button {
            settingsManager.settings.engine = engine
            if engine == .cloud, !keys.hasKey(.fal) {
                AppDelegate.shared.openSettings(.transcription)
            }
        } label: {
            Text(title)
                .font(.mono(10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(isSelected ? Theme.text : Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? Theme.raised : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}
