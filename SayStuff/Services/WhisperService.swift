import Foundation

/// Local transcription via whisper.cpp's `whisper-cli`.
final class WhisperService {
    struct Request {
        let audioURL: URL
        let whisperPath: String
        let modelPath: String
        let language: String
        let vocabulary: String?
    }

    func transcribe(_ request: Request) async throws -> String {
        defer { cleanupTemporaryRecording(request.audioURL) }
        #if DEBUG
        copyModelInputForDiagnostics(request.audioURL)
        #endif

        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: request.whisperPath) else { throw WhisperError.binaryNotFound }
        guard fm.fileExists(atPath: request.modelPath) else { throw WhisperError.modelNotFound }

        var arguments = [
            "-m", request.modelPath,
            "-f", request.audioURL.path,
            "-l", request.language,
            "-t", String(min(ProcessInfo.processInfo.activeProcessorCount, 8)),
            "-nt",   // No timestamps
            "-np",   // No progress output
            "-sns",  // Suppress non-speech tokens
        ]
        if let vocabulary = request.vocabulary, !vocabulary.isEmpty {
            arguments += ["--prompt", vocabulary]
        }

        do {
            return Self.clean(try await runProcess(path: request.whisperPath, arguments: arguments))
        } catch WhisperError.processError(let message) where message.contains("-sns") || message.contains("unknown argument") {
            // Older whisper-cli builds don't know --suppress-nst.
            arguments.removeAll { $0 == "-sns" }
            return Self.clean(try await runProcess(path: request.whisperPath, arguments: arguments))
        }
    }

    /// Joins whisper's per-segment lines and drops non-speech markers like [BLANK_AUDIO].
    static func clean(_ output: String) -> String {
        var text = output.replacingOccurrences(
            of: #"\[[^\]]*\]|\((?:[^)]*\b(?:music|silence|applause|laughs?|blank|inaudible)\b[^)]*)\)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runProcess(path: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                // stdout via pipe, stderr via file: draining one pipe while the other fills can deadlock.
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

    private func cleanupTemporaryRecording(_ audioURL: URL) {
        let temporaryDirectory = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let url = audioURL.standardizedFileURL
        guard url.path.hasPrefix(temporaryDirectory),
              url.lastPathComponent.hasPrefix("saystuff_recording_") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func copyModelInputForDiagnostics(_ audioURL: URL) {
        let directory = AppPaths.support.appendingPathComponent("Diagnostics", isDirectory: true)
        let destination = directory.appendingPathComponent("latest-model-input.wav")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: audioURL, to: destination)
        } catch {
            print("[WhisperService] Failed to copy model input audio: \(error)")
        }
    }
}

enum WhisperError: LocalizedError {
    case binaryNotFound
    case modelNotFound
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "whisper-cli not found"
        case .modelNotFound: return "Speech model not downloaded"
        case .processError: return "Transcription failed"
        }
    }
}
