import Foundation

class WhisperService {
    func transcribe(audioURL: URL, profile: Profile, settings: AppSettings) async throws -> String {
        let settingsManager = SettingsManager.shared
        let whisperPath = settingsManager.whisperBinaryPath
        let modelPath = settingsManager.modelPath

        // Build arguments
        var arguments = [
            "-m", modelPath,
            "-f", audioURL.path,
            "-nt",  // No timestamps
            "-np",  // No prints (progress)
        ]

        // Add language
        if profile.language != "auto" {
            arguments += ["-l", profile.language]
        }

        // Add prompt if specified
        if let prompt = profile.whisperPrompt, !prompt.isEmpty {
            arguments += ["-pp", prompt]
        }

        // Run whisper-cli
        let output = try await runProcess(path: whisperPath, arguments: arguments)

        // Apply formatting
        return applyFormatting(output, options: profile.formatting)
    }

    private func runProcess(path: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
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
