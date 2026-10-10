import SwiftUI
import AVFoundation
import Combine

/// Three short steps: permissions, speech model, shortcut.
struct OnboardingView: View {
    var onFinish: () -> Void

    @ObservedObject private var settingsManager = SettingsManager.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var step: Int
    @State private var hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var hasAccessibility = AXIsProcessTrusted()
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(initialStep: Int = 0, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: initialStep)
    }

    private var modelReady: Bool {
        _ = downloader.completedCount
        return settingsManager.isModelDownloaded(settingsManager.settings.modelSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: permissions
                case 1: model
                default: shortcut
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 32)
            .padding(.top, 44)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Back") { step -= 1 }
                }
                Button(step == 2 ? "Done" : "Continue") {
                    if step == 2 { onFinish() } else { step += 1 }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(step == 1 && !modelReady)
            }
            .padding(20)
        }
        .frame(width: 480, height: 460)
        .onReceive(permissionTimer) { _ in refreshPermissions() }
    }

    // MARK: Steps

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Talk, and it types.", "SayStuff needs two permissions to listen and to paste into other apps.")

            VStack(spacing: 10) {
                PermissionRow(
                    symbol: "mic",
                    title: "Microphone",
                    detail: "To hear you while the shortcut is active.",
                    isGranted: hasMicrophone,
                    action: requestMicrophone
                )
                PermissionRow(
                    symbol: "keyboard",
                    title: "Accessibility",
                    detail: "To paste the text where your cursor is.",
                    isGranted: hasAccessibility,
                    action: requestAccessibility
                )
            }
        }
    }

    private var model: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("Pick a speech model", "Runs entirely on your Mac. You can switch or add a cloud engine later.")
            VStack(spacing: 12) {
                ForEach(WhisperModel.allCases, id: \.self) { ModelRow(model: $0) }
            }
        }
    }

    private var shortcut: some View {
        VStack(alignment: .leading, spacing: 18) {
            title("You're set", "Put your cursor in any text field, use the shortcut and start talking.")
            VStack(spacing: 12) {
                LabeledContent("Shortcut") { ShortcutRecorder() }
                Picker("Mode", selection: $settingsManager.settings.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

            Text("SayStuff lives in the menu bar (\(Image(systemName: "waveform"))). Click it to switch output profiles or see recent text.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func title(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
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
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 28)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                    .accessibilityLabel("Allowed")
            } else {
                Button("Allow", action: action)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}
