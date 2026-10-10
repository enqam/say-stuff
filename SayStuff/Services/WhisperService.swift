import Foundation

class WhisperService {
    func transcribe(audioURL: URL, profile: Profile, settings: AppSettings) async throws -> String {
        let settingsManager = SettingsManager.shared
        let whisperPath = settingsManager.whisperBinaryPath
        let modelPath = settingsManager.modelPath
        #if DEBUG
        copyModelInputForDiagnostics(audioURL)
        #endif
        defer {
            cleanupTemporaryRecording(audioURL)
        }

        // Build arguments
        var arguments = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-l", profile.language,
            "-nt",  // No timestamps
            "-np",  // No prints (progress)
        ]

        // Add prompt if specified
        if let prompt = profile.whisperPrompt, !prompt.isEmpty {
            arguments += ["--prompt", prompt]
        }

        // Run whisper-cli
        let output = try await runProcess(path: whisperPath, arguments: arguments)

        // Apply formatting
        return applyFormatting(output, options: profile.formatting)
    }

    private func copyModelInputForDiagnostics(_ audioURL: URL) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let diagnosticsDirectory = appSupport
            .appendingPathComponent("SayStuff", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
        let diagnosticURL = diagnosticsDirectory.appendingPathComponent("latest-model-input.wav")

        do {
            try FileManager.default.createDirectory(at: diagnosticsDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: diagnosticURL.path) {
                try FileManager.default.removeItem(at: diagnosticURL)
            }
            try FileManager.default.copyItem(at: audioURL, to: diagnosticURL)
            print("[WhisperService] Model input audio copied to: \(diagnosticURL.path)")
        } catch {
            print("[WhisperService] Failed to copy model input audio: \(error)")
        }
    }

    private func cleanupTemporaryRecording(_ audioURL: URL) {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let standardizedAudioURL = audioURL.standardizedFileURL

        guard standardizedAudioURL.path.hasPrefix(temporaryDirectory),
              standardizedAudioURL.lastPathComponent.hasPrefix("saystuff_recording_") else {
            return
        }

        do {
            try FileManager.default.removeItem(at: standardizedAudioURL)
        } catch {
            print("[WhisperService] Failed to remove temporary audio: \(error)")
        }
    }

    private func runProcess(path: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                let errorHandle = try? FileHandle(forWritingTo: errorURL)
                defer {
                    try? errorHandle?.close()
                    try? FileManager.default.removeItem(at: errorURL)
                }
                process.standardOutput = outputPipe
                process.standardError = errorHandle ?? FileHandle.nullDevice

                do {
                    try process.run()
                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: outputData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
                        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                        continuation.resume(throwing: WhisperError.processError(errorOutput))
                    } else {
                        continuation.resume(returning: output)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func applyFormatting(_ text: String, options: FormattingOptions) -> String {
        var result = text

        if options.trimWhitespace {
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if options.collapseNewlines {
            // Replace multiple newlines with single space
            let regex = try? NSRegularExpression(pattern: "\\n+", options: [])
            result = regex?.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(location: 0, length: result.utf16.count),
                withTemplate: " "
            ) ?? result
        }

        if options.addTrailingSpace && !result.isEmpty {
            result += " "
        }

        return result
    }
}

enum WhisperError: Error {
    case processError(String)
    case modelNotFound
}
