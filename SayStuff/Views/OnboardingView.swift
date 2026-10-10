import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @StateObject private var downloader = ModelDownloader()
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var currentStep = SettingsManager.shared.isModelDownloaded(SettingsManager.shared.settings.modelSize) ? 3 : 0
    @State private var selectedModel: WhisperModel = .small

    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch currentStep {
            case 0:
                WelcomeStep(onNext: { currentStep = 1 })
            case 1:
                ModelPickerStep(
                    selectedModel: $selectedModel,
                    onNext: {
                        settingsManager.settings.modelSize = selectedModel
                        currentStep = 2
                    }
                )
            case 2:
                DownloadStep(
                    model: selectedModel,
                    downloader: downloader,
                    onComplete: { currentStep = 3 }
                )
            case 3:
                PermissionsStep(onNext: { currentStep = 4 })
            case 4:
                CompleteStep(onFinish: onComplete)
            default:
                EmptyView()
            }
        }
        .frame(width: 500, height: 400)
        .padding()
    }
}

struct WelcomeStep: View {
    var onNext: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.accentColor)

            Text("SayStuff")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Record speech and paste it as text")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "keyboard", text: "Press the shortcut to start and stop recording")
                FeatureRow(icon: "waveform", text: "Speech recognition runs on your Mac")
                FeatureRow(icon: "doc.on.clipboard", text: "Text is pasted into the active text field")
            }

            Spacer()

            Button("Continue") {
                onNext()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 30)
                .foregroundColor(.accentColor)
            Text(text)
        }
    }
}

struct ModelPickerStep: View {
    @Binding var selectedModel: WhisperModel
    var onNext: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Choose a Model")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Larger models are more accurate but slower")
                .foregroundColor(.secondary)

            Spacer()

            VStack(spacing: 12) {
                ForEach(WhisperModel.allCases, id: \.self) { model in
                    ModelOptionRow(
                        model: model,
                        isSelected: selectedModel == model,
                        onSelect: { selectedModel = model }
                    )
                }
            }

            Spacer()

            Button("Download & Continue") {
                onNext()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}

struct ModelOptionRow: View {
    let model: WhisperModel
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                VStack(alignment: .leading) {
                    HStack {
                        Text(model.displayName)
                            .fontWeight(.medium)
                        if model == .small {
                            Text("Recommended")
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    }
                    Text(model.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(model.sizeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct DownloadStep: View {
    let model: WhisperModel
    @ObservedObject var downloader: ModelDownloader
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Downloading Model")
                .font(.largeTitle)
                .fontWeight(.bold)

            Spacer()

            if downloader.isDownloading {
                VStack(spacing: 12) {
                    ProgressView(value: downloader.progress)
                        .progressViewStyle(.linear)

                    Text("\(Int(downloader.progress * 100))%")
                        .font(.headline)

                    Text(downloader.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 40)
            } else if downloader.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)

                Text("Model ready")
                    .font(.headline)
            } else if let error = downloader.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.red)

                Text("Download Failed")
                    .font(.headline)

                Text(error)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Retry") {
                    downloader.download(model: model)
                }
            }

            Spacer()

            if downloader.isComplete {
                Button("Continue") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .onAppear {
            downloader.download(model: model)
        }
    }
}

struct PermissionsStep: View {
    var onNext: () -> Void
    @State private var hasAccessibility = false
    @State private var hasMicrophone = false
    private let permissionTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Allow microphone access and text insertion")
                .foregroundColor(.secondary)

            Spacer()

            VStack(spacing: 16) {
                PermissionRow(
                    icon: "keyboard",
                    title: "Accessibility",
                    description: "Required for auto‑paste into other apps",
                    isGranted: hasAccessibility,
                    onRequest: requestAccessibility
                )

                PermissionRow(
                    icon: "mic",
                    title: "Microphone",
                    description: "Required for voice recording",
                    isGranted: hasMicrophone,
                    onRequest: requestMicrophone
                )
            }

            Spacer()

            Button("Continue") {
                onNext()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!hasAccessibility || !hasMicrophone)
        }
        .onAppear { checkAccessibility() }
        .onReceive(permissionTimer) { _ in checkAccessibility() }
    }

    private func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
        hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { checkAccessibility() }
            }
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)

        // Check again after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            checkAccessibility()
        }
    }
}

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let onRequest: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 40)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(8)
    }
}

struct CompleteStep: View {
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundColor(.green)

            Text("Ready")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Press ⌃⌥⇧⌘A to start; press again to finish")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Shortcuts")
                    .fontWeight(.medium)

                Text("• Click the menu bar icon to change profiles")
                Text("• With Raycast Hyper Key: press Caps Lock + A")
                Text("• Quit the old Hammerspoon dictation to avoid shortcut conflicts")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Spacer()

            Button("Done") {
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
