import SwiftUI
import Carbon.HIToolbox

// MARK: - Theme

/// System type, adaptive colors and one warm accent. Liquid Glass is reserved for the
/// floating chrome (menu panel, tab bar, recording pill); content sits on plain fills.
enum Theme {
    static let surface = Color.primary.opacity(0.045)
    static let raised = Color.primary.opacity(0.08)
    static let hairline = Color.primary.opacity(0.07)
    static let hairlineStrong = Color.primary.opacity(0.12)

    static let text = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: .tertiaryLabelColor)

    static let accent = Color(red: 1, green: 0.40, blue: 0.29)
    static let accentSoft = accent.opacity(0.16)
    static let success = Color(nsColor: .systemGreen)
    static let warning = Color(nsColor: .systemOrange)

    static let nsAccent = NSColor(red: 1, green: 0.40, blue: 0.29, alpha: 1)
}

extension Font {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    /// Tabular figures for times, money and key caps.
    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

extension View {
    /// Liquid Glass on macOS 26+, a vibrant material before that. One glass layer per surface;
    /// nothing inside it is glass, which keeps compositing cheap.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if UISnapshotMode.isActive {
            // Glass is composited by the window server and can't be captured offscreen.
            self.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            self.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

/// Section label.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Cards & rows

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
    }
}

struct CardRow<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    var showsDivider = true
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if showsDivider {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 14)
            }
        }
    }
}

// MARK: - Chips

struct Chip: View {
    let title: String
    let isSelected: Bool
    var mono = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(mono ? .mono(11, weight: .semibold) : .system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : (isHovering ? Theme.text : Theme.textSecondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(isSelected ? Theme.accentSoft : (isHovering ? Theme.raised : Theme.raised.opacity(0.6))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// One-click choice between a few values. Replaces dropdowns everywhere.
struct ChipPicker<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var mono = false

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { value, title in
                Chip(title: title, isSelected: selection == value, mono: mono) { selection = value }
            }
        }
    }
}

/// Wrapping layout for chip grids.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

// MARK: - Switch

/// Drawn switch: consistent accent color and no NSSwitch per row.
struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { isOn.toggle() }
        } label: {
            Capsule()
                .fill(isOn ? Theme.accent : Theme.raised)
                .frame(width: 34, height: 20)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(isOn ? Color.white : Theme.textSecondary)
                        .padding(3)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(prominent ? Theme.accent : Theme.raised))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.hairlineStrong))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Full-width row with a hover highlight, for lists in the menu panel.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : (isHovering ? 0.06 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? Theme.text : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(isHovering ? Theme.raised : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

// MARK: - Fields

struct ThemedField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.textTertiary))
            } else {
                TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.textTertiary))
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? .mono(12, weight: .regular) : .system(size: 13))
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Paste-in API key with live verification state.
struct APIKeyRow: View {
    let provider: APIKeys.Provider
    @ObservedObject private var keys = APIKeys.shared
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if keys.hasKey(provider) {
                    Text(keys.maskedKey(provider))
                        .font(.mono(12, weight: .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised))
                    status
                    Button("Remove") { keys.setKey(nil, for: provider) }
                        .buttonStyle(PillButtonStyle())
                } else {
                    ThemedField(placeholder: "Paste your \(provider.displayName) key", text: $draft, mono: true, secure: true)
                        .onSubmit(save)
                    Button("Save", action: save)
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if !keys.hasKey(provider) {
                Link(destination: provider.signupURL) {
                    Text("Get a key at \(provider.signupURL.host ?? "") ↗")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .onAppear(perform: verifyIfNeeded)
    }

    @ViewBuilder
    private var status: some View {
        switch keys.status[provider] ?? .unknown {
        case .valid:
            Label("Verified", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.success)
        case .invalid:
            Label("Rejected", systemImage: "xmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
        case .checking:
            ProgressView().controlSize(.small)
        case .unknown:
            EmptyView()
        }
    }

    private func verifyIfNeeded() {
        if keys.hasKey(provider), (keys.status[provider] ?? .unknown) == .unknown {
            keys.verify(provider)
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keys.setKey(key, for: provider)
        draft = ""
    }
}

// MARK: - Key caps & shortcut recorder

struct KeyCaps: View {
    let combo: KeyCombo
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(combo.parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.mono(size, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, part.count > 1 ? 6 : 0)
                    .frame(minWidth: size + 10, minHeight: size + 9)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.raised))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Theme.hairlineStrong)
                    )
            }
        }
        .accessibilityLabel(combo.displayString)
    }
}

struct ShortcutRecorder: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        Button(action: { isRecording ? stop() : start() }) {
            if isRecording {
                Text(rejected ? "Add ⌘ ⌥ ⌃ or ⇧" : "Type shortcut…")
                    .font(.mono(11, weight: .semibold))
                    .foregroundStyle(rejected ? Theme.warning : Theme.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 22)
                    .background(Capsule().fill(Theme.accentSoft))
            } else {
                KeyCaps(combo: settingsManager.settings.hotkey)
            }
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Press Esc to cancel" : "Click to change")
        .onDisappear(perform: stop)
    }

    private func start() {
        isRecording = true
        rejected = false
        DictationController.shared.setHotkeysSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = KeyCombo.modifierNames(from: event.modifierFlags)
            if event.keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
                stop()
                return nil
            }
            // A bare letter would hijack normal typing everywhere.
            guard !modifiers.isEmpty || KeyCombo.isFunctionKey(event.keyCode) else {
                rejected = true
                NSSound.beep()
                return nil
            }
            settingsManager.settings.hotkeyModifiers = modifiers
            settingsManager.settings.hotkeyKeyCode = event.keyCode
            settingsManager.settings.hotkeyKey = event.charactersIgnoringModifiers?.lowercased() ?? ""
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        DictationController.shared.setHotkeysSuspended(false)
    }
}

// MARK: - Model row

struct ModelRow: View {
    let model: WhisperModel
    var showsDivider = true
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var isHovering = false

    private var isSelected: Bool { settingsManager.settings.modelSize == model }
    private var isDownloaded: Bool {
        _ = downloader.completedCount  // re-evaluate when a download lands
        return settingsManager.isModelDownloaded(model)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(isSelected && isDownloaded ? Theme.accent : Theme.hairlineStrong, lineWidth: 1.5)
                    if isSelected && isDownloaded {
                        Circle().fill(Theme.accent).padding(4)
                    }
                }
                .frame(width: 16, height: 16)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.displayName)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isDownloaded ? Theme.text : Theme.textSecondary)
                        if model == .small {
                            Text("Recommended")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.accentSoft))
                        }
                    }
                    Text(downloader.errors[model] ?? "\(model.description) · \(model.sizeString)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(downloader.errors[model] == nil ? Theme.textTertiary : Theme.accent)
                }

                Spacer()

                if let progress = downloader.progress[model] {
                    Text("\(Int(progress * 100))%")
                        .font(.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                    ProgressView(value: progress)
                        .tint(Theme.accent)
                        .frame(width: 70)
                    IconButton(symbol: "xmark", help: "Cancel") { downloader.cancel(model) }
                } else if !isDownloaded {
                    Button("Download") { downloader.download(model) }
                        .buttonStyle(PillButtonStyle())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(isHovering && isDownloaded && !isSelected ? 0.03 : 0))
            .contentShape(Rectangle())
            .onTapGesture { if isDownloaded { settingsManager.settings.modelSize = model } }
            .onHover { isHovering = $0 }

            if showsDivider {
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 42)
            }
        }
    }
}

// MARK: - Profile preview

/// What the fixed sample sentence turns into under a profile.
struct ProfilePreview: View {
    let profile: Profile?
    var liveOutput: String? = nil
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            Text("“\(ProfileSample.spoken)”")
                .font(.system(size: compact ? 10.5 : 11.5).italic())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(compact ? 1 : 2)

            Text(liveOutput ?? ProfileSample.output(for: profile) ?? "Run a preview to see this profile's output.")
                .font(.system(size: compact ? 11.5 : 13))
                .foregroundStyle(Theme.text)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(compact ? 11 : 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
    }
}

extension Date {
    var shortRelative: String {
        let seconds = Int(-timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}

extension Decimal {
    var usdString: String {
        let value = NSDecimalNumber(decimal: self).doubleValue
        if value == 0 { return "$0.00" }
        return value < 0.01 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }
}
