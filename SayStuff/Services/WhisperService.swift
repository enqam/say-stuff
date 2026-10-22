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

    fileprivate struct ServerResult: Decodable {
        let text: String
        let language: String?
        let language_probabilities: [String: Double]?
    }

    private func transcribeWithServer(_ base: URL, _ request: Request) async throws -> (String, Bool) {
        let audio = try Data(contentsOf: request.audioURL)
        let result = try await Self.transcribe(base, audio: audio, candidates: request.candidates, prompt: request.vocabulary)
        return (result.text, result.retried)
    }

    /// One request (two more if the detected language isn't one the user speaks).
    static func transcribe(_ base: URL, audio: Data, candidates: [String], prompt: String?)
        async throws -> (text: String, language: String?, retried: Bool) {
        let forced = candidates.count == 1 ? candidates[0] : nil

        var result = try await infer(base, audio: audio, language: forced ?? "auto", vocabulary: prompt)
        var language = forced ?? result.language
        var retried = false
        if forced == nil, !LanguageMatch.isAllowed(result.language, in: candidates) {
            retried = true
            // Detected something the user doesn't speak: take the likeliest of their languages.
            let probabilities = try await infer(base, audio: audio, language: "auto", vocabulary: nil, detectOnly: true)
                .language_probabilities ?? [:]
            let best = candidates.max { (probabilities[$0] ?? 0) < (probabilities[$1] ?? 0) } ?? candidates[0]
            print("[Whisper] Detected \(result.language ?? "?"), retrying as \(best)")
            result = try await infer(base, audio: audio, language: best, vocabulary: prompt)
            language = best
        }
        return (clean(result.text), language, retried)
    }

    /// 16-bit PCM WAV, the format whisper-server reads without converting.
    static func wav(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }  // Apple silicon is little-endian, like WAV
        return data
    }

    private static func infer(_ base: URL, audio: Data, language: String, vocabulary: String?, detectOnly: Bool = false) async throws -> ServerResult {
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

/// Transcribes a dictation in chunks while it's still being spoken, so only the last chunk is
/// left when the user stops. Chunks run one at a time, in order, on the same whisper-server;
/// each gets the text before it as its prompt, so sentences carry over the cut.
final class WhisperStream: @unchecked Sendable {
    private let binary: String
    private let model: String
    private let candidates: [String]
    private let vocabulary: String?

    // Guarded by `lock`.
    private let lock = NSLock()
    private var chain: Task<Void, Never>?
    private var texts: [String] = []
    /// Fixed by the first chunk, so a dictation doesn't switch language halfway.
    private var language: String?
    private var failure: Error?
    private var retriedLanguage = false

    init?(whisperPath: String, model: String, candidates: [String], vocabulary: String?) {
        guard let binary = WhisperServer.binaryPath(nextTo: whisperPath),
              FileManager.default.fileExists(atPath: model) else { return nil }
        self.binary = binary
        self.model = model
        self.candidates = candidates
        self.vocabulary = vocabulary
    }

    /// Queues a chunk (16 kHz mono). Callable from any thread; chunks keep their arrival order.
    func append(_ samples: [Float]) {
        lock.withLock {
            let previous = chain
            chain = Task.detached(priority: .userInitiated) { [self] in
                await previous?.value
                await transcribe(samples)
            }
        }
    }

    /// Transcribes the final chunk (nil if nothing was said after the last one) and returns
    /// the whole dictation. Throws if any chunk failed, so the caller can redo the full file.
    func finish(tail: [Float]?) async throws -> (text: String, retriedLanguage: Bool) {
        if let tail, !tail.isEmpty { append(tail) }
        let last = lock.withLock { chain }
        await last?.value
        return try lock.withLock {
            if let failure { throw failure }
            return (Self.join(texts), retriedLanguage)
        }
    }

    /// Joins chunk texts. A pause mid-sentence makes whisper end a chunk with "…" and start
    /// the next with a capital ("Also, the... The voiceover"); undo both.
    static func join(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            var next = part
            if !result.isEmpty {
                result = result.replacingOccurrences(of: #"\s*(\.\.\.|…)$"#, with: "", options: .regularExpression)
                if !(result.last.map { ".!?".contains($0) } ?? true),
                   let word = next.split(separator: " ").first,
                   continuationWords.contains(word.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
                    next = next.prefix(1).lowercased() + next.dropFirst()
                }
                result += " "
            }
            result += next
        }
        return result
    }

    /// Common words that start a chunk mid-sentence; names and "I" keep their capital.
    private static let continuationWords: Set<String> = [
        "the", "a", "an", "and", "but", "or", "so", "because", "which", "that", "this", "these", "those",
        "it", "it's", "its", "we", "you", "they", "he", "she", "to", "of", "in", "on", "at", "for", "with",
        "from", "by", "like", "also", "then", "just", "if", "when", "what", "how", "why", "where", "there",
        "is", "are", "was", "were", "be", "been", "have", "has", "had", "do", "does", "did", "can", "could",
        "would", "should", "will", "not", "maybe", "probably", "actually", "basically", "my", "your", "our",
        "their", "some", "any", "all", "more", "as", "than", "about", "into", "up", "out", "now", "even",
        "и", "а", "но", "что", "это", "как", "в", "на", "с", "по", "не", "я", "мы", "ты", "он", "она", "они",
    ]

    private static let leadIn = ["en": "Okay, here it is. ", "ru": "Хорошо, вот текст. "]

    /// Skips chunks that haven't started yet.
    func cancel() {
        lock.withLock { if failure == nil { failure = CancellationError() } }
    }

    private func transcribe(_ samples: [Float]) async {
        let (stopped, language, previous) = lock.withLock {
            (failure != nil, language, Self.join(texts))
        }
        guard !stopped else { return }
        let server = WhisperServer.shared
        await server.beginUse()
        do {
            let base = try await server.baseURL(binary: binary, model: model)
            // Whisper reads the prompt as the text before this audio. A punctuated lead-in keeps
            // it punctuating: context that ends mid-sentence otherwise turns punctuation off.
            let context = previous.isEmpty ? nil : (Self.leadIn[language ?? ""] ?? "") + previous.suffix(250)
            let prompt = [vocabulary.map { $0 + "." }, context].compactMap { $0 }.joined(separator: " ")
            let result = try await WhisperService.transcribe(
                base, audio: WhisperService.wav(samples), candidates: language.map { [$0] } ?? candidates,
                prompt: prompt.isEmpty ? nil : prompt)
            lock.withLock {
                if !result.text.isEmpty { texts.append(result.text) }
                if self.language == nil { self.language = result.language }
                if result.retried { retriedLanguage = true }
            }
        } catch {
            lock.withLock { if failure == nil { failure = error } }
        }
        await server.endUse()
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
