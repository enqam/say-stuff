import Foundation
import Darwin

/// Local transcription with whisper.cpp.
///
/// Prefers `whisper-server` (kept running with the model loaded, so there's no per-dictation
/// model load, and it reports per-language probabilities). Falls back to `whisper-cli`.
final class WhisperService {
    struct Request {
        let audioURL: URL
        let whisperPath: String
        let modelPath: String
        /// One code = forced; several = auto-detect among them; empty = unrestricted auto.
        let candidates: [String]
        let vocabulary: String?
    }

    struct Result {
        let text: String
        /// The detected language wasn't one of the candidates, so it was transcribed again.
        let retriedLanguage: Bool
        /// The model wasn't loaded yet and this dictation waited for it.
        let coldStart: Bool
        let usedServer: Bool
    }

    func transcribe(_ request: Request) async throws -> Result {
        defer { cleanupTemporaryRecording(request.audioURL) }
        #if DEBUG
        copyModelInputForDiagnostics(request.audioURL)
        #endif

        guard FileManager.default.fileExists(atPath: request.modelPath) else { throw WhisperError.modelNotFound }

        if let serverPath = WhisperServer.binaryPath(nextTo: request.whisperPath) {
            let server = WhisperServer.shared
            await server.beginUse()
            let cold = await !server.isReady(model: request.modelPath)
            if let base = try? await server.baseURL(binary: serverPath, model: request.modelPath) {
                do {
                    let (text, retried) = try await transcribeWithServer(base, request)
                    await server.endUse()
                    return Result(text: text, retriedLanguage: retried, coldStart: cold, usedServer: true)
                } catch {
                    await server.endUse()
                    throw error
                }
            }
            await server.endUse()
        }
        let (text, retried) = try await transcribeWithCLI(request)
        return Result(text: text, retriedLanguage: retried, coldStart: true, usedServer: false)
    }

    // MARK: - Server

    private struct ServerResult: Decodable {
        let text: String
        let language: String?
        let language_probabilities: [String: Double]?
    }

    private func transcribeWithServer(_ base: URL, _ request: Request) async throws -> (String, Bool) {
        let audio = try Data(contentsOf: request.audioURL)
        let forced = request.candidates.count == 1 ? request.candidates[0] : nil

        var result = try await infer(base, audio: audio, language: forced ?? "auto", vocabulary: request.vocabulary)
        var retried = false
        if forced == nil, !LanguageMatch.isAllowed(result.language, in: request.candidates) {
            retried = true
            // Detected something the user doesn't speak: take the likeliest of their languages.
            let probabilities = try await infer(base, audio: audio, language: "auto", vocabulary: nil, detectOnly: true)
                .language_probabilities ?? [:]
            let best = request.candidates.max { (probabilities[$0] ?? 0) < (probabilities[$1] ?? 0) } ?? request.candidates[0]
            print("[Whisper] Detected \(result.language ?? "?"), retrying as \(best)")
            result = try await infer(base, audio: audio, language: best, vocabulary: request.vocabulary)
        }
        return (Self.clean(result.text), retried)
    }

    private func infer(_ base: URL, audio: Data, language: String, vocabulary: String?, detectOnly: Bool = false) async throws -> ServerResult {
        var form = MultipartForm()
        form.field("response_format", "verbose_json")
        form.field("language", language)
        form.field("temperature", "0")
        form.field("no_timestamps", "true")
        form.field("suppress_nst", "true")
        form.field("no_language_probabilities", detectOnly ? "false" : "true")
        if detectOnly { form.field("detect_language", "true") }
        if let vocabulary, !vocabulary.isEmpty { form.field("prompt", vocabulary) }
        form.file("file", filename: "audio.wav", contentType: "audio/wav", data: audio)

        var request = URLRequest(url: base.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.upload(for: request, from: form.finished)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WhisperError.processError(String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ServerResult.self, from: data)
    }

    // MARK: - CLI fallback

    private func transcribeWithCLI(_ request: Request) async throws -> (String, Bool) {
        guard FileManager.default.isExecutableFile(atPath: request.whisperPath) else { throw WhisperError.binaryNotFound }
        let forced = request.candidates.count == 1 ? request.candidates[0] : nil

        var output = try await runCLI(request, language: forced ?? "auto")
        var retried = false
        if forced == nil, !LanguageMatch.isAllowed(output.detected, in: request.candidates) {
            retried = true
            // whisper-cli only reports its top guess, so there are no probabilities to rank by.
            // Misdetections are almost always a short non-English phrase, so prefer that.
            let retry = request.candidates.first { $0 != "en" } ?? request.candidates[0]
            print("[Whisper] Detected \(output.detected ?? "?"), retrying as \(retry)")
            output = try await runCLI(request, language: retry)
        }
        return (Self.clean(output.text), retried)
    }

    private func runCLI(_ request: Request, language: String) async throws -> (text: String, detected: String?) {
        var arguments = [
            "-m", request.modelPath,
            "-f", request.audioURL.path,
            "-l", language,
            "-t", String(min(ProcessInfo.processInfo.activeProcessorCount, 8)),
            "-nt",   // No timestamps
            "-np",   // No progress output
            "-sns",  // Suppress non-speech tokens
        ]
        if let vocabulary = request.vocabulary, !vocabulary.isEmpty {
            arguments += ["--prompt", vocabulary]
        }

        let result: (stdout: String, stderr: String)
        do {
            result = try await runProcess(path: request.whisperPath, arguments: arguments)
        } catch WhisperError.processError(let message) where message.contains("-sns") || message.contains("unknown argument") {
            // Older whisper-cli builds don't know --suppress-nst.
            arguments.removeAll { $0 == "-sns" }
            result = try await runProcess(path: request.whisperPath, arguments: arguments)
        }
        // stderr has "whisper_full_with_state: auto-detected language: ru (p = 0.97)"
        let detected = result.stderr
            .range(of: #"auto-detected language: (\w+)"#, options: .regularExpression)
            .map { String(result.stderr[$0].split(separator: " ").last ?? "") }
        return (result.stdout, detected)
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

    private func runProcess(path: String, arguments: [String]) async throws -> (stdout: String, stderr: String) {
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
                    let errorOutput = String(data: (try? Data(contentsOf: errorURL)) ?? Data(), encoding: .utf8) ?? ""

                    if process.terminationStatus != 0 {
                        continuation.resume(throwing: WhisperError.processError(errorOutput))
                    } else {
                        continuation.resume(returning: (output, errorOutput))
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

/// Runs `whisper-server` on localhost with the selected model loaded, so dictations skip the
/// ~1.3 s model load. It's started when recording begins (the load overlaps with speaking) and
/// stopped after `idleTimeout` without use, so the model's memory (≈1.8 GB for Large v3 Turbo)
/// isn't held while you're not dictating.
actor WhisperServer {
    static let shared = WhisperServer()

    private var process: Process?
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?
    /// Seconds; 0 keeps the model loaded indefinitely.
    private var idleTimeout: TimeInterval = 300

    func setIdleTimeout(_ seconds: TimeInterval) {
        idleTimeout = seconds
        scheduleIdleStop()
    }

    func beginUse() {
        inFlight += 1
        idleTask?.cancel()
    }

    func endUse() {
        inFlight = max(0, inFlight - 1)
        scheduleIdleStop()
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard idleTimeout > 0, process != nil else { return }
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard inFlight == 0, process != nil else { return }
        print("[WhisperServer] Idle — unloading model")
        stop()
    }
    private var model: String?
    private var port: Int = 0
    private var starting: Task<URL, Error>?

    static func binaryPath(nextTo cliPath: String) -> String? {
        let path = URL(fileURLWithPath: cliPath).deletingLastPathComponent().appendingPathComponent("whisper-server").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Starts (or restarts for a new model) the server and returns its URL once the model is loaded.
    func baseURL(binary: String, model: String) async throws -> URL {
        if let process, process.isRunning, self.model == model, starting == nil {
            return URL(string: "http://127.0.0.1:\(port)/")!
        }
        if let starting, self.model == model { return try await starting.value }

        stop()
        self.model = model
        port = Self.freePort()
        let port = self.port

        // A small sh watchdog owns the server: it stops it when we terminate it, and within a
        // second of SayStuff exiting for any reason (quit, crash, kill), so no server is orphaned.
        let watchdog = """
        "$@" & server=$!
        trap 'kill $server 2>/dev/null; exit 0' TERM INT HUP
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && kill -0 $server 2>/dev/null; do sleep 1; done
        kill $server 2>/dev/null
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdog, "sh", binary,
            "-m", model,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-t", String(min(ProcessInfo.processInfo.activeProcessorCount, 8)),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
        print("[WhisperServer] Starting on port \(port) with \(URL(fileURLWithPath: model).lastPathComponent)")

        let task = Task<URL, Error> {
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            // The server only starts listening once the model is loaded.
            for _ in 0..<300 {
                guard process.isRunning else { throw WhisperError.processError("whisper-server exited") }
                var probe = URLRequest(url: url)
                probe.timeoutInterval = 1
                if (try? await URLSession.shared.data(for: probe)) != nil { return url }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw WhisperError.processError("whisper-server didn't start")
        }
        starting = task
        defer { starting = nil }
        do {
            return try await task.value
        } catch {
            stop()
            throw error
        }
    }

    /// Starts loading the model now (called when recording begins).
    func prewarm(cliPath: String, model: String) async {
        guard let binary = Self.binaryPath(nextTo: cliPath), FileManager.default.fileExists(atPath: model) else { return }
        _ = try? await baseURL(binary: binary, model: model)
        scheduleIdleStop()
    }

    /// Stops the server if it has a different model loaded than `model`.
    func stopUnless(model: String) {
        if self.model != model { stop() }
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        process?.terminate()
        process = nil
        model = nil
    }

    /// Whether `model` is loaded and ready, i.e. the next request won't wait for a load.
    func isReady(model: String) -> Bool {
        process?.isRunning == true && self.model == model && starting == nil
    }

    private static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length) == 0 && getsockname(socket, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : Int.random(in: 49_152...65_000)
    }
}

/// Minimal multipart/form-data builder.
struct MultipartForm {
    let boundary = "saystuff-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
    }

    mutating func file(_ name: String, filename: String, contentType: String, data: Data) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }

    /// Closes the form; call once after the last part.
    var finished: Data {
        body + "--\(boundary)--\r\n".data(using: .utf8)!
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
