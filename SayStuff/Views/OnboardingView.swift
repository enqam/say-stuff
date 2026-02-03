import SwiftUI

struct OnboardingView: View {
    @StateObject private var downloader = ModelDownloader()
    @ObservedObject var settingsManager = SettingsManager.shared
    @State private var currentStep = 0
    @State private var selectedModel: WhisperModel = .largeTurbo

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

            Text("Welcome to SayStuff")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Push-to-talk voice transcription for your Mac")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                FeatureRow(icon: "keyboard", text: "Hold a hotkey to record your voice")
                FeatureRow(icon: "waveform", text: "Transcription powered by whisper.cpp")
                FeatureRow(icon: "doc.on.clipboard", text: "Text automatically pasted where you need it")
            }

            Spacer()

            Button("Get Started") {
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
                        if model == .largeTurbo {
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

                Text("Download Complete!")
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

    var body: some View {
        VStack(spacing: 20) {
            Text("Permissions")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("SayStuff needs some permissions to work")
                .foregroundColor(.secondary)

            Spacer()

            VStack(spacing: 16) {
                PermissionRow(
                    icon: "keyboard",
                    title: "Accessibility",
                    description: "Required for global hotkeys",
                    isGranted: hasAccessibility,
                    onRequest: requestAccessibility
                )

                PermissionRow(
                    icon: "mic",
                    title: "Microphone",
                    description: "Required for voice recording",
                    isGranted: true, // Usually auto-granted on first use
                    onRequest: {}
                )
            }

            Spacer()

            Button("Continue") {
                onNext()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .onAppear {
            checkAccessibility()
        }
    }

    private func checkAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
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

            Text("You're All Set!")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Hold Option+Command+V to start recording")
                .font(.title3)
                .foregroundColor(.secondary)

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                Text("Quick Tips:")
                    .fontWeight(.medium)

                Text("• Click the menu bar icon to change profiles")
                Text("• Each profile can have its own language and prompt")
                Text("• Use prompts to improve accuracy for specific topics")
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)

            Spacer()

            Button("Start Using SayStuff") {
                onFinish()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
