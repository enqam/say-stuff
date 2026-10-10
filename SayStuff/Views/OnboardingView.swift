import SwiftUI
import AVFoundation
import Combine

/// Three short steps: permissions, engine, shortcut.
struct OnboardingView: View {
    var onFinish: () -> Void

    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @ObservedObject private var keys = APIKeys.shared
    @State private var step: Int
    @State private var hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var hasAccessibility = AXIsProcessTrusted()
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    private var engineReady: Bool {
        _ = downloader.completedCount
        switch settingsManager.settings.engine {
        case .local: return settingsManager.isModelDownloaded(settingsManager.settings.modelSize)
        case .cloud: return keys.hasKey(.fal)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case 0: permissions
                case 1: engine
                default: shortcut
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 46)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Capsule()
                            .fill(index == step ? Theme.accent : Theme.hairlineStrong)
                            .frame(width: index == step ? 18 : 6, height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: step)
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }.buttonStyle(PillButtonStyle())
                }
                Button(step == 2 ? "Start dictating" : "Continue") {
                    if step == 2 { onFinish() } else { step += 1 }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .disabled(step == 1 && !engineReady)
            }
            .padding(20)
        }
        .frame(width: 500, height: 500)
        .onReceive(permissionTimer) { _ in refreshPermissions() }
    }

    // MARK: Steps

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("Talk, and it types.", "SayStuff needs to hear you and to paste where your cursor is.")
            Card {
                PermissionRow(symbol: "mic", title: "Microphone", detail: "Only while the shortcut is active",
                              isGranted: hasMicrophone, action: requestMicrophone)
                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 52)
                PermissionRow(symbol: "keyboard", title: "Accessibility", detail: "To paste into any app",
                              isGranted: hasAccessibility, action: requestAccessibility)
            }
        }
    }

    private var engine: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("How should it listen?", "You can switch any time from the menu bar.")
            ChipPicker(options: [(TranscriptionEngine.local, "On this Mac"), (.cloud, "Cloud · fal.ai")],
                       selection: $settingsManager.settings.engine)
            if settingsManager.settings.engine == .local {
                Card {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        ModelRow(model: model, showsDivider: model != WhisperModel.allCases.last)
                    }
                }
            } else {
                Card { APIKeyRow(provider: .fal).padding(14) }
            }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 22) {
            title("You're set.", "Put your cursor in any text field, press the shortcut and talk.")
            Card {
                CardRow(title: "Shortcut") { ShortcutRecorder() }
                CardRow(title: "Mode", showsDivider: false) {
                    ChipPicker(options: [(HotkeyMode.hold, "Hold to talk"), (.toggle, "Press to toggle")],
                               selection: $settingsManager.settings.hotkeyMode)
                }
            }
            Text("Pick an output profile (Raw, Prompt, Formal) from the \(Image(systemName: "waveform")) menu bar icon.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func title(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Permissions

    private func refreshPermissions() {
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
    }

    private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { refreshPermissions() }
            }
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isGranted ? Theme.success : Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            if isGranted {
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.success)
            } else {
                Button("Allow", action: action).buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(14)
    }
}
