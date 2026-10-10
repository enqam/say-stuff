import SwiftUI
import Carbon.HIToolbox

// MARK: - Key caps

struct KeyCaps: View {
    let combo: KeyCombo
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(combo.parts.enumerated()), id: \.offset) { _, part in
                Text(part)
                    .font(.system(size: size, weight: .medium, design: .rounded))
                    .padding(.horizontal, part.count > 1 ? 5 : 0)
                    .frame(minWidth: size + 9, minHeight: size + 7)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.07))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(combo.displayString)
    }
}

// MARK: - Shortcut recorder

struct ShortcutRecorder: View {
    @ObservedObject private var settingsManager = SettingsManager.shared
    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        Button(action: toggle) {
            Group {
                if isRecording {
                    Text(rejected ? "Add ⌘, ⌥, ⌃ or ⇧" : "Type shortcut…")
                        .font(.system(size: 12))
                        .foregroundStyle(rejected ? .orange : .secondary)
                        .frame(minWidth: 110)
                } else {
                    KeyCaps(combo: settingsManager.settings.hotkey)
                }
            }
            .padding(.vertical, 1)
        }
        .help(isRecording ? "Press Esc to cancel" : "Click to change the shortcut")
        .onDisappear(perform: stop)
    }

    private func toggle() {
        isRecording ? stop() : start()
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
    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var downloader = ModelDownloader.shared

    private var isSelected: Bool { settingsManager.settings.modelSize == model }
    private var isDownloaded: Bool {
        _ = downloader.completedCount  // re-evaluate when a download lands
        return settingsManager.isModelDownloaded(model)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected && isDownloaded ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundStyle(isSelected && isDownloaded ? Color.accentColor : Color.secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                    if model == .small {
                        Badge("Recommended")
                    }
                }
                Text("\(model.description) · \(model.sizeString)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = downloader.errors[model] {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            if let progress = downloader.progress[model] {
                ProgressView(value: progress)
                    .frame(width: 80)
                Button {
                    downloader.cancel(model)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel download")
            } else if !isDownloaded {
                Button("Download") { downloader.download(model) }
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isDownloaded { settingsManager.settings.modelSize = model }
        }
        .opacity(isDownloaded || downloader.isDownloading(model) ? 1 : 0.75)
    }
}

// MARK: - Profile preview

/// Shows what the fixed sample sentence turns into under a profile.
struct ProfilePreview: View {
    let profile: Profile?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Text("“\(ProfileSample.spoken)”")
                .font(.system(size: compact ? 10.5 : 11.5))
                .italic()
                .foregroundStyle(.tertiary)
                .lineLimit(compact ? 1 : 2)

            if let output = ProfileSample.output(for: profile) {
                Text(output)
                    .font(.system(size: compact ? 11.5 : 12.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(profile?.instructions ?? "")
                    .font(.system(size: compact ? 11.5 : 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 4 : 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

// MARK: - Small pieces

struct Badge: View {
    let text: String
    var tint: Color = .accentColor

    init(_ text: String, tint: Color = .accentColor) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}

/// Marks controls whose backend lands in the next step.
struct ComingNextNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "hammer")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Menu-like row used in the popover: full-width hit area with a hover highlight.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : (isHovering ? 0.07 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }
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
