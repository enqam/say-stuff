import SwiftUI
import Carbon.HIToolbox

enum MenuTab: String, CaseIterable {
    case main = "Main"
    case history = "History"
}

// MARK: - Design System

struct DS {
    // Colors - true black with maximum contrast
    static let bg = Color.black                     // True black
    static let bgElevated = Color(white: 0.05)      // Barely lifted
    static let bgHover = Color(white: 0.10)         // Hover state
    static let border = Color(white: 0.12)
    static let borderSubtle = Color(white: 0.08)

    // Text - maximum contrast
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.75)
    static let textMuted = Color(white: 0.50)

    // Accents - pure vivid red like the recording pill
    static let accent = Color(red: 1.0, green: 0.1, blue: 0.1)   // Pure vivid red
    static let accentSoft = Color(red: 1.0, green: 0.2, blue: 0.2)
    static let success = Color(red: 0.1, green: 1.0, blue: 0.3)
    static let warning = Color(red: 1.0, green: 0.6, blue: 0.0)
}

struct MenuBarView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var profileManager: ProfileManager

    @State private var activeTab: MenuTab = .main
    @State private var showSettings: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HeaderView(appDelegate: appDelegate, activeTab: $activeTab, showSettings: $showSettings)

            // Content
            Group {
                if showSettings {
                    SettingsTabContent(profileManager: profileManager)
                } else {
                    switch activeTab {
                    case .main:
                        MainTabContent(
                            appDelegate: appDelegate,
                            profileManager: profileManager
                        )
                    case .history:
                        HistoryTabContent()
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // Footer
            FooterView(appDelegate: appDelegate)
        }
        .frame(width: 340, height: 480)
        .background(
            ZStack {
                DS.bg

                // Subtle red glow from top
                RadialGradient(
                    colors: [DS.accent.opacity(0.08), Color.clear],
                    center: .top,
                    startRadius: 0,
                    endRadius: 300
                )

                // Inner vignette for depth
                RadialGradient(
                    colors: [Color.clear, Color.black.opacity(0.3)],
                    center: .center,
                    startRadius: 100,
                    endRadius: 250
                )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(DS.accent.opacity(0.4), lineWidth: 1.5)
        )
        .shadow(color: DS.accent.opacity(0.15), radius: 20, x: 0, y: 0)
    }
}

// MARK: - Header

struct HeaderView: View {
    @ObservedObject var appDelegate: AppDelegate
    @Binding var activeTab: MenuTab
    @Binding var showSettings: Bool
    @State private var showMicPicker = false
    @State private var isCopied = false
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var transcriptionStore = TranscriptionStore.shared

    var body: some View {
        VStack(spacing: 14) {
            // Top row: mic button, centered logo, copy + settings buttons
            HStack {
                // Mic input button (left) — Button+popover to fix icon visibility
                Button(action: { showMicPicker.toggle() }) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(showMicPicker ? DS.accent : DS.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(showMicPicker ? DS.accent.opacity(0.2) : DS.bgHover)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 32)
                .popover(isPresented: $showMicPicker, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Button(action: {
                            settingsManager.settings.selectedAudioDeviceUID = nil
                            showMicPicker = false
                        }) {
                            HStack {
                                Text("System Default")
                                    .font(.system(size: 13, design: .rounded))
                                Spacer()
                                if settingsManager.settings.selectedAudioDeviceUID == nil {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(DS.accent)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Rectangle()
                            .fill(DS.border)
                            .frame(height: 1)
                            .padding(.horizontal, 8)

                        ForEach(audioDeviceManager.inputDevices) { device in
                            Button(action: {
                                settingsManager.settings.selectedAudioDeviceUID = device.uid
                                showMicPicker = false
                            }) {
                                HStack {
                                    Text(device.name)
                                        .font(.system(size: 13, design: .rounded))
                                    Spacer()
                                    if settingsManager.settings.selectedAudioDeviceUID == device.uid {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(DS.accent)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(minWidth: 200)
                    .background(DS.bgElevated)
                }

                Spacer()

                // Centered logo (conditional)
                if settingsManager.settings.showLogoInMenu {
                    HStack(spacing: 8) {
                        // Squircle logo with waveform
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.black)
                                .frame(width: 44, height: 44)
                                .shadow(color: DS.accent.opacity(0.3), radius: 8, x: 0, y: 0)

                            RoundedRectangle(cornerRadius: 10)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(white: 0.12), Color(white: 0.04)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 44, height: 44)

                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.15), Color.clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    ),
                                    lineWidth: 1
                                )
                                .frame(width: 44, height: 44)

                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(DS.accent.opacity(0.5), lineWidth: 1.5)
                                .frame(width: 44, height: 44)

                            Image(systemName: "waveform")
                                .font(.system(size: 26, weight: .bold))
                                .foregroundColor(DS.accent)
                        }

                        Text("SayStuff")
                            .font(.custom("Didot", size: 22).weight(.bold))
                            .foregroundColor(DS.accent)
                    }
                }

                Spacer()

                // Copy last transcription button
                Button(action: copyLastTranscription) {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isCopied ? DS.success : (transcriptionStore.transcriptions.isEmpty ? DS.textMuted : DS.textSecondary))
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isCopied ? DS.success.opacity(0.2) : DS.bgHover)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 32)
                .disabled(transcriptionStore.transcriptions.isEmpty)

                // Settings button (right)
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(showSettings ? DS.accent : DS.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(showSettings ? DS.accent.opacity(0.2) : DS.bgHover)
                        )
                }
                .buttonStyle(.plain)
                .frame(width: 32)
            }

            // Tab bar - only Main and History now
            if !showSettings {
                HStack(spacing: 6) {
                    ForEach(MenuTab.allCases, id: \.self) { tab in
                        TabIconButton(
                            icon: iconFor(tab),
                            isSelected: activeTab == tab
                        ) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                activeTab = tab
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(DS.bgElevated)
    }

    private func iconFor(_ tab: MenuTab) -> String {
        switch tab {
        case .main: return "house.fill"
        case .history: return "clock.fill"
        }
    }

    private func copyLastTranscription() {
        guard let text = transcriptionStore.transcriptions.first?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isCopied = false
        }
    }
}

struct TabIconButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(isSelected ? DS.accent : DS.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? DS.accent.opacity(0.15) : (isHovering ? DS.bgHover : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? DS.accent.opacity(0.5) : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Main Tab

struct MainTabContent: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var profileManager: ProfileManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                LanguageSelectorView(appDelegate: appDelegate)
                ProfileSelectorView(appDelegate: appDelegate, profileManager: profileManager)
                UsageGuideView()
            }
            .padding(16)
        }
    }
}

// MARK: - Language Selector

struct LanguageSelectorView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject private var settingsManager = SettingsManager.shared

    private var visibleLanguages: [SupportedLanguage] {
        allSupportedLanguages.filter { settingsManager.settings.menuLanguages.contains($0.code) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LANGUAGE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(DS.textMuted)
                .tracking(1)

            HStack(spacing: 8) {
                ForEach(visibleLanguages) { lang in
                    LanguageButton(
                        code: lang.shortLabel,
                        isSelected: appDelegate.selectedLanguage == lang.code,
                        action: { appDelegate.selectLanguage(lang.code) }
                    )
                }
            }
        }
        .onChange(of: settingsManager.settings.menuLanguages) { newLanguages in
            if !newLanguages.contains(appDelegate.selectedLanguage),
               let first = newLanguages.first {
                appDelegate.selectLanguage(first)
            }
        }
    }
}

struct LanguageButton: View {
    let code: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(code)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(isSelected ? DS.textPrimary : DS.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isSelected ? DS.accent.opacity(0.25) : (isHovering ? DS.bgHover : DS.bgElevated))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? DS.accent : DS.borderSubtle, lineWidth: isSelected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Profile Selector

struct ProfileSelectorView: View {
    @ObservedObject var appDelegate: AppDelegate
    @ObservedObject var profileManager: ProfileManager
    @State private var editingProfile: Profile?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROFILE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(DS.textMuted)
                .tracking(1)

            VStack(spacing: 4) {
                ForEach(profileManager.profiles) { profile in
                    ProfileRow(
                        profile: binding(for: profile),
                        isSelected: appDelegate.activeProfile?.id == profile.id,
                        isEditing: editingProfile?.id == profile.id,
                        onSelect: { appDelegate.selectProfile(profile) },
                        onEdit: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                editingProfile = editingProfile?.id == profile.id ? nil : profile
                            }
                        },
                        onSave: { profileManager.save() }
                    )
                }
            }
        }
    }

    private func binding(for profile: Profile) -> Binding<Profile> {
        guard let index = profileManager.profiles.firstIndex(where: { $0.id == profile.id }) else {
            return .constant(profile)
        }
        return $profileManager.profiles[index]
    }
}

struct ProfileRow: View {
    @Binding var profile: Profile
    let isSelected: Bool
    let isEditing: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onSave: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Radio indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? DS.accent : DS.border, lineWidth: 2)
                        .frame(width: 20, height: 20)

                    if isSelected {
                        Circle()
                            .fill(DS.accent)
                            .frame(width: 10, height: 10)
                    }
                }

                Text(profile.name)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .regular, design: .rounded))
                    .foregroundColor(isSelected ? DS.textPrimary : DS.textSecondary)

                Spacer()

                // Edit button - always in layout, just invisible when not hovering
                Button(action: onEdit) {
                    Image(systemName: isEditing ? "checkmark" : "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isEditing ? DS.success : DS.textMuted)
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(isEditing ? DS.success.opacity(0.2) : DS.bgHover)
                        )
                }
                .buttonStyle(.plain)
                .opacity(isHovering || isEditing ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                onSelect()
            }

            // Inline edit panel
            if isEditing {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle()
                        .fill(DS.borderSubtle)
                        .frame(height: 1)
                        .padding(.horizontal, 14)

                    // Name field
                    HStack {
                        Text("Name")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(DS.textMuted)
                            .frame(width: 60, alignment: .leading)

                        TextField("Profile name", text: $profile.name)
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(DS.textPrimary)
                            .textFieldStyle(.plain)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6).fill(DS.bgElevated))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border, lineWidth: 1))
                            .onChange(of: profile.name) { _ in onSave() }
                    }
                    .padding(.horizontal, 14)

                    // Language picker - custom inline buttons
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Language")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(DS.textMuted)

                        HStack(spacing: 6) {
                            ForEach(["auto", "en", "ru", "es", "fr", "de"], id: \.self) { lang in
                                Button(action: {
                                    profile.language = lang
                                    onSave()
                                }) {
                                    Text(lang.uppercased())
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(profile.language == lang ? DS.textPrimary : DS.textSecondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(profile.language == lang ? DS.accent.opacity(0.25) : DS.bgElevated)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .strokeBorder(profile.language == lang ? DS.accent : DS.borderSubtle, lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 14)

                    // Prompt field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Whisper Prompt")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(DS.textMuted)

                        TextField("Words you'll say...", text: Binding(
                            get: { profile.whisperPrompt ?? "" },
                            set: { profile.whisperPrompt = $0.isEmpty ? nil : $0 }
                        ))
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(DS.textPrimary)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DS.bgElevated))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.border, lineWidth: 1))
                        .onChange(of: profile.whisperPrompt) { _ in onSave() }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? DS.accent.opacity(0.1) : (isHovering ? DS.bgHover : DS.bgElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isEditing ? DS.accent.opacity(0.4) : (isSelected ? DS.accent.opacity(0.3) : DS.borderSubtle), lineWidth: isEditing ? 1.5 : 1)
        )
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isEditing)
    }
}

// MARK: - Usage Guide

struct UsageGuideView: View {
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                withAnimation(.easeOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            }) {
                HStack(spacing: 10) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 14))
                        .foregroundColor(DS.textMuted)

                    Text("Quick Guide")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(DS.textSecondary)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(DS.textMuted)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DS.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(DS.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .focusable(false)

            if isExpanded {
                VStack(alignment: .leading, spacing: 20) {
                    GuideSection(title: "HOW TO USE") {
                        GuideBullet("Hold ⌥⌘V to record, release to transcribe")
                        GuideBullet("Text auto-pastes at your cursor")
                        GuideBullet("Pick a language or use AUTO")
                    }

                    GuideSection(title: "PROFILES") {
                        GuideBullet("Create profiles for different contexts")
                        GuideBullet("Each has its own language & prompt")
                    }

                    GuideSection(title: "WHISPER PROMPT") {
                        Text("Conditions recognition during transcription. Helps Whisper:")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(DS.textSecondary)

                        GuideBullet("Spell words you say correctly")
                        GuideBullet("Apply punctuation from your pauses")
                        GuideBullet("Cannot add/change words—only how it hears them")

                        VStack(alignment: .leading, spacing: 8) {
                            GuideExample("Tech terms:", "Kubernetes, kubectl, PostgreSQL, nginx")
                            GuideExample("Names:", "Anthropic, Claude, OpenAI, LLaMA")
                            GuideExample("Casual:", "hey so basically i was thinking")
                            GuideExample("Formal:", "Dear Sir, I am writing to inquire.")
                        }
                        .padding(.top, 4)

                        Text("Limit: 224 tokens")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(DS.textMuted)
                            .padding(.top, 4)
                    }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(DS.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(DS.borderSubtle, lineWidth: 1)
                )
                .padding(.top, 4)
            }
        }
    }
}

struct GuideSection: View {
    let title: String
    let content: () -> AnyView

    init(title: String, @ViewBuilder content: @escaping () -> some View) {
        self.title = title
        self.content = { AnyView(content()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(DS.accent)
                .tracking(0.5)

            content()
        }
    }
}

struct GuideBullet: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(DS.accent)
                .frame(width: 5, height: 5)
                .padding(.top, 6)

            Text(text)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct GuideExample: View {
    let label: String
    let example: String

    init(_ label: String, _ example: String) {
        self.label = label
        self.example = example
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(DS.textMuted)

            Text(example)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(DS.accent)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DS.accent.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DS.accent.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

// MARK: - History Tab

struct HistoryTabContent: View {
    @ObservedObject var store = TranscriptionStore.shared

    var body: some View {
        Group {
            if store.transcriptions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(DS.textMuted)

                    Text("No transcriptions yet")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(DS.textSecondary)

                    Text("Hold ⌥⌘V to record")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(DS.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.transcriptions) { item in
                            TranscriptionCard(item: item)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct TranscriptionCard: View {
    let item: RecentTranscription
    @State private var isHovering = false
    @State private var isCopied = false

    private func formatRelativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)

        if seconds < 60 {
            return "\(seconds)s ago"
        } else if seconds < 3600 {
            let minutes = seconds / 60
            return "\(minutes)m ago"
        } else if seconds < 86400 {
            let hours = seconds / 3600
            return "\(hours)h ago"
        } else {
            let days = seconds / 86400
            return "\(days)d ago"
        }
    }

    var body: some View {
        Button(action: copyToClipboard) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.text)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(DS.textPrimary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text(formatRelativeTime(item.date))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.textMuted)

                    Spacer()

                    if isHovering || isCopied {
                        HStack(spacing: 4) {
                            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .semibold))
                            Text(isCopied ? "Copied" : "Copy")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(isCopied ? DS.success : DS.textSecondary)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovering ? DS.bgHover : DS.bgElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(DS.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        isCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isCopied = false
        }
    }
}

// MARK: - Settings Tab

enum SettingsSection: String, CaseIterable {
    case general = "General"
    case profiles = "Profiles"
    case hotkey = "Hotkey"
    case model = "Model"
}

struct SettingsTabContent: View {
    @ObservedObject var profileManager: ProfileManager
    @State private var activeSection: SettingsSection = .general

    var body: some View {
        VStack(spacing: 0) {
            // Section picker
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        SettingsPill(
                            title: section.rawValue,
                            isSelected: activeSection == section
                        ) {
                            withAnimation(.easeOut(duration: 0.12)) {
                                activeSection = section
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }

            Rectangle()
                .fill(DS.borderSubtle)
                .frame(height: 1)

            ScrollView {
                Group {
                    switch activeSection {
                    case .general:
                        GeneralSettingsContent()
                    case .profiles:
                        ProfilesSettingsContent(profileManager: profileManager)
                    case .hotkey:
                        HotkeySettingsContent()
                    case .model:
                        ModelSettingsContent()
                    }
                }
                .padding(16)
            }
        }
    }
}

struct SettingsPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? DS.textPrimary : DS.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(isSelected ? DS.accent.opacity(0.2) : (isHovering ? DS.bgHover : Color.clear))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? DS.accent.opacity(0.4) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
    }
}

// MARK: - General Settings

struct GeneralSettingsContent: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MICROPHONE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.textMuted)
                    .tracking(1)

                Menu {
                    Button("System Default") {
                        settingsManager.settings.selectedAudioDeviceUID = nil
                    }
                    Divider()
                    ForEach(audioDeviceManager.inputDevices) { device in
                        Button(device.name) {
                            settingsManager.settings.selectedAudioDeviceUID = device.uid
                        }
                    }
                } label: {
                    HStack {
                        Text(currentDeviceName)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundColor(DS.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(DS.textMuted)
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(DS.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(DS.borderSubtle, lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
            }

            VStack(spacing: 8) {
                SettingsToggleRow(
                    title: "Play sounds",
                    isOn: $settingsManager.settings.playSounds
                )
                SettingsToggleRow(
                    title: "Show menu bar icon",
                    isOn: $settingsManager.settings.showMenuBarIcon
                )
                SettingsToggleRow(
                    title: "Show logo in menu",
                    isOn: $settingsManager.settings.showLogoInMenu
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("QUICK-SWITCH LANGUAGES")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.textMuted)
                    .tracking(1)

                VStack(spacing: 4) {
                    ForEach(allSupportedLanguages) { lang in
                        LanguageToggleRow(
                            language: lang,
                            isOn: Binding(
                                get: { settingsManager.settings.menuLanguages.contains(lang.code) },
                                set: { enabled in
                                    if enabled {
                                        if !settingsManager.settings.menuLanguages.contains(lang.code) {
                                            settingsManager.settings.menuLanguages.append(lang.code)
                                        }
                                    } else {
                                        // Prevent removing the last language
                                        guard settingsManager.settings.menuLanguages.count > 1 else { return }
                                        settingsManager.settings.menuLanguages.removeAll { $0 == lang.code }
                                    }
                                }
                            ),
                            isLastEnabled: settingsManager.settings.menuLanguages == [lang.code]
                        )
                    }
                }
            }
        }
    }

    private var currentDeviceName: String {
        if let uid = settingsManager.settings.selectedAudioDeviceUID,
           let device = audioDeviceManager.inputDevices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System Default"
    }
}

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(DS.textPrimary)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DS.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DS.borderSubtle, lineWidth: 1)
        )
    }
}

struct LanguageToggleRow: View {
    let language: SupportedLanguage
    @Binding var isOn: Bool
    let isLastEnabled: Bool

    var body: some View {
        HStack {
            Text(language.name)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(DS.textPrimary)

            Text(language.shortLabel)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(DS.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DS.bgHover)
                )

            Spacer()

            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
                .disabled(isLastEnabled)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DS.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(DS.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Profiles Settings

struct ProfilesSettingsContent: View {
    @ObservedObject var profileManager: ProfileManager
    @State private var editingProfileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(profileManager.profiles) { profile in
                ProfileSettingsCard(
                    profile: binding(for: profile),
                    isEditing: editingProfileId == profile.id,
                    onToggleEdit: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            editingProfileId = editingProfileId == profile.id ? nil : profile.id
                        }
                    },
                    onDelete: profileManager.profiles.count > 1 ? {
                        withAnimation {
                            profileManager.profiles.removeAll { $0.id == profile.id }
                            profileManager.save()
                        }
                    } : nil,
                    onSave: { profileManager.save() }
                )
            }

            Button(action: addProfile) {
                HStack {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                    Text("Add Profile")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundColor(DS.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(DS.accent.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [6]))
                )
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }

    private func binding(for profile: Profile) -> Binding<Profile> {
        guard let index = profileManager.profiles.firstIndex(where: { $0.id == profile.id }) else {
            return .constant(profile)
        }
        return $profileManager.profiles[index]
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
        editingProfileId = newProfile.id
        profileManager.save()
    }
}

struct ProfileSettingsCard: View {
    @Binding var profile: Profile
    let isEditing: Bool
    let onToggleEdit: () -> Void
    let onDelete: (() -> Void)?
    let onSave: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if isEditing {
                    TextField("Name", text: $profile.name)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .textFieldStyle(.plain)
                        .foregroundColor(DS.textPrimary)
                        .onChange(of: profile.name) { _ in onSave() }
                } else {
                    Text(profile.name)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(DS.textPrimary)
                }

                Spacer()

                HStack(spacing: 8) {
                    if let onDelete = onDelete, isEditing {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(DS.accent)
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: isEditing ? "checkmark" : "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isEditing ? DS.success : DS.textMuted)
                }
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture { onToggleEdit() }

            if isEditing {
                VStack(alignment: .leading, spacing: 12) {
                    Rectangle()
                        .fill(DS.borderSubtle)
                        .frame(height: 1)

                    HStack {
                        Text("Language")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(DS.textSecondary)
                        Spacer()
                        Picker("", selection: $profile.language) {
                            Text("Auto").tag("auto")
                            Text("EN").tag("en")
                            Text("RU").tag("ru")
                            Text("ES").tag("es")
                            Text("FR").tag("fr")
                            Text("DE").tag("de")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 90)
                        .onChange(of: profile.language) { _ in onSave() }
                    }
                    .padding(.horizontal, 14)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Whisper Prompt")
                            .font(.system(size: 13, design: .rounded))
                            .foregroundColor(DS.textSecondary)

                        TextField("Words you'll say...", text: Binding(
                            get: { profile.whisperPrompt ?? "" },
                            set: { profile.whisperPrompt = $0.isEmpty ? nil : $0 }
                        ))
                        .font(.system(size: 13, design: .rounded))
                        .textFieldStyle(.plain)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(DS.bg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(DS.borderSubtle, lineWidth: 1)
                        )
                        .onChange(of: profile.whisperPrompt) { _ in onSave() }
                    }
                    .padding(.horizontal, 14)

                    VStack(spacing: 6) {
                        MiniToggle(title: "Trim whitespace", isOn: $profile.formatting.trimWhitespace, onSave: onSave)
                        MiniToggle(title: "Collapse newlines", isOn: $profile.formatting.collapseNewlines, onSave: onSave)
                        MiniToggle(title: "Add trailing space", isOn: $profile.formatting.addTrailingSpace, onSave: onSave)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isEditing ? DS.bgElevated : (isHovering ? DS.bgHover : DS.bgElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isEditing ? DS.accent.opacity(0.3) : DS.borderSubtle, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }
}

struct MiniToggle: View {
    let title: String
    @Binding var isOn: Bool
    let onSave: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(DS.textSecondary)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.7)
                .onChange(of: isOn) { _ in onSave() }
        }
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsContent: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var isRecording = false
    @State private var eventMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HOTKEY")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(DS.textMuted)
                .tracking(1)

            HStack {
                Text("Current:")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(DS.textSecondary)

                Text(hotkeyDisplayString)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(DS.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DS.bgElevated)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(DS.accent.opacity(0.3), lineWidth: 1)
                    )

                Spacer()
            }

            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 15))
                    Text(isRecording ? "Press any key..." : "Change Hotkey")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .foregroundColor(isRecording ? DS.warning : DS.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isRecording ? DS.warning.opacity(0.15) : DS.accent.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isRecording ? DS.warning.opacity(0.4) : DS.accent.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .focusable(false)

            // Mode selector
            Text("MODE")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(DS.textMuted)
                .tracking(1)
                .padding(.top, 8)

            HStack(spacing: 8) {
                ForEach(HotkeyMode.allCases, id: \.self) { mode in
                    ModeButton(
                        title: mode == .hold ? "Hold" : "Toggle",
                        isSelected: settingsManager.settings.hotkeyMode == mode,
                        action: { settingsManager.settings.hotkeyMode = mode }
                    )
                }
            }

            if settingsManager.settings.hotkeyMode == .toggle {
                HStack {
                    Text("Auto-stop:")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(DS.textSecondary)

                    Slider(value: $settingsManager.settings.toggleTimeout, in: 60...600, step: 30)
                        .tint(DS.accent)

                    Text("\(Int(settingsManager.settings.toggleTimeout / 60))m")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(DS.textMuted)
                        .frame(width: 30, alignment: .trailing)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.bgElevated)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(DS.borderSubtle, lineWidth: 1)
                )
            }

            Text(helpText)
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(DS.textMuted)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var helpText: String {
        switch settingsManager.settings.hotkeyMode {
        case .hold:
            return "Hold to record, release to transcribe and paste."
        case .toggle:
            return "Press once to start, press again to stop and transcribe."
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
        let legacyKey = settingsManager.settings.hotkeyKey.uppercased()
        return legacyKey.isEmpty ? "?" : legacyKey
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            self.captureHotkey(event: event)
            return nil
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

struct ModeButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? DS.textPrimary : DS.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? DS.accent.opacity(0.2) : (isHovering ? DS.bgHover : DS.bgElevated))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? DS.accent.opacity(0.4) : DS.borderSubtle, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Model Settings

struct ModelSettingsContent: View {
    @ObservedObject private var settingsManager = SettingsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("MODEL SIZE")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.textMuted)
                    .tracking(1)

                VStack(spacing: 4) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        ModelRow(
                            model: model,
                            isSelected: settingsManager.settings.modelSize == model,
                            isDownloaded: settingsManager.isModelDownloaded(model),
                            isDownloading: settingsManager.downloadingModels.contains(model),
                            downloadProgress: settingsManager.downloadProgress[model] ?? 0,
                            onSelect: {
                                if settingsManager.isModelDownloaded(model) {
                                    settingsManager.settings.modelSize = model
                                }
                            },
                            onDownload: {
                                settingsManager.downloadModel(model)
                            }
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("PATHS")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(DS.textMuted)
                    .tracking(1)

                PathField(label: "whisper-cli", path: $settingsManager.settings.whisperPath)
                PathField(label: "Models", path: $settingsManager.settings.modelDirectory)
            }
        }
    }
}

struct ModelRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let isDownloaded: Bool
    let isDownloading: Bool
    let downloadProgress: Double
    let onSelect: () -> Void
    let onDownload: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            // Radio button
            ZStack {
                Circle()
                    .strokeBorder(isSelected ? DS.accent : (isDownloaded ? DS.border : DS.border.opacity(0.5)), lineWidth: 2)
                    .frame(width: 18, height: 18)

                if isSelected {
                    Circle()
                        .fill(DS.accent)
                        .frame(width: 8, height: 8)
                }
            }
            .opacity(isDownloaded ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular, design: .rounded))
                    .foregroundColor(isDownloaded ? DS.textPrimary : DS.textMuted)

                if isDownloading {
                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(DS.border)
                                .frame(height: 4)

                            RoundedRectangle(cornerRadius: 2)
                                .fill(DS.accent)
                                .frame(width: geo.size.width * downloadProgress, height: 4)
                        }
                    }
                    .frame(height: 4)
                }
            }

            Spacer()

            if isDownloading {
                Text("\(Int(downloadProgress * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.accent)
            } else if isDownloaded {
                // Checkmark for downloaded
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(DS.success)
            } else {
                // Download button
                Button(action: onDownload) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12))
                        Text(model.sizeDescription)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                    }
                    .foregroundColor(DS.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DS.accent.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? DS.accent.opacity(0.1) : (isHovering ? DS.bgHover : DS.bgElevated))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? DS.accent.opacity(0.3) : DS.borderSubtle, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isDownloaded {
                onSelect()
            }
        }
        .opacity(isDownloaded || isDownloading ? 1 : 0.8)
        .onHover { isHovering = $0 }
    }
}

struct PathField: View {
    let label: String
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(DS.textSecondary)

            TextField("", text: $path)
                .font(.system(size: 12, design: .monospaced))
                .textFieldStyle(.plain)
                .foregroundColor(DS.textPrimary)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DS.bg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(DS.borderSubtle, lineWidth: 1)
                )
        }
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var appDelegate: AppDelegate

    var body: some View {
        HStack {
            Button(action: { appDelegate.checkForUpdates() }) {
                Text("Check for Updates")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(DS.textMuted)
            }
            .buttonStyle(.plain)
            .focusable(false)

            Spacer()

            Button(action: { appDelegate.quit() }) {
                HStack(spacing: 4) {
                    Image(systemName: "power")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Quit")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundColor(DS.accent.opacity(0.8))
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DS.bgElevated)
    }
}

// MARK: - Status Indicators

struct RecordingDot: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DS.accent.opacity(0.3))
                .frame(width: 20, height: 20)
                .scaleEffect(isPulsing ? 1.5 : 1.0)
                .opacity(isPulsing ? 0 : 0.8)

            Circle()
                .fill(DS.accent)
                .frame(width: 10, height: 10)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

struct TranscribingSpinner: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.6)
            .stroke(DS.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 16, height: 16)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - WhisperModel Extension

extension WhisperModel {
    var sizeDescription: String {
        switch self {
        case .tiny: return "~75MB"
        case .small: return "~466MB"
        case .medium: return "~1.5GB"
        case .largeTurbo: return "~1.5GB"
        }
    }
}

// MARK: - Legacy (keeping for compatibility)

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(DS.textMuted)
            .textCase(.uppercase)
            .tracking(1)
    }
}

#Preview {
    MenuBarView(
        appDelegate: AppDelegate(),
        profileManager: ProfileManager.shared
    )
}
