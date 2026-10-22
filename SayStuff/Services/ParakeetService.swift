import Foundation
import AVFoundation
import FluidAudio
import os

private let log = Logger(subsystem: "com.saystuff.app", category: "parakeet")

/// Local transcription with NVIDIA Parakeet TDT 0.6B (v3 or its Ultra post-training) on the
/// Neural Engine via FluidAudio. 25 European languages (incl. English, Russian, Ukrainian),
/// language detected as part of decoding, no separate detection pass. Prepared in the
/// background before dictation. One model is loaded at a time.
actor ParakeetService {
    static let shared = ParakeetService()

    private var manager: AsrManager?
    private var loadedVersion: AsrModelVersion?
    private var decoderLayers = 2
    private var loading: (version: AsrModelVersion, task: Task<Void, Error>)?
    private var inFlight = 0
    private var recordings = 0
    private var loadGeneration = 0
    private var idleTask: Task<Void, Never>?
    /// Seconds; 0 keeps the model loaded indefinitely.
    private var idleTimeout: TimeInterval = 0

    struct Result {
        let text: String
        let coldStart: Bool
    }

    nonisolated static func version(for model: WhisperModel) -> AsrModelVersion {
        model == .parakeetUltra ? .ultra : .v3
    }

    nonisolated static func isDownloaded(_ model: WhisperModel) -> Bool {
        let version = version(for: model)
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version)
    }

    nonisolated static func download(_ model: WhisperModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(version: version(for: model)) { progress($0.fractionCompleted) }
    }

    func setIdleTimeout(_ seconds: TimeInterval) {
        idleTimeout = seconds
        scheduleUnload()
    }

    /// Loads and exercises inference, including the long-audio path, before first use.
    func prewarm(_ model: WhisperModel) async {
        guard Self.isDownloaded(model) else { return }
        idleTask?.cancel()
        do { try await load(Self.version(for: model)) }
        catch { log.error("Parakeet preparation failed: \(error.localizedDescription, privacy: .public)") }
        scheduleUnload()
    }

    /// The idle deadline must not expire while the user is still speaking.
    func beginRecording(_ model: WhisperModel) async {
        recordings += 1
        await prewarm(model)
    }

    func endRecording() {
        recordings = max(0, recordings - 1)
        scheduleUnload()
    }

    /// Transcribes `samples` (16 kHz mono) when given, which skips reading the file back.
    func transcribe(_ url: URL, samples: [Float]?, model: WhisperModel, forcedLanguage: String?,
                    trace: LatencyTrace? = nil) async throws -> Result {
        trace?.mark("parakeet.requested")
        inFlight += 1
        idleTask?.cancel()
        defer {
            inFlight -= 1
            scheduleUnload()
            Self.returnFreedMemory()
        }
        let version = Self.version(for: model)
        let cold = manager == nil || loadedVersion != version
        try await load(version)
        trace?.mark("parakeet.ready")
        guard let manager else { throw WhisperError.modelNotFound }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        // The hint keeps output in the forced language's script (e.g. no Latin-letter Russian).
        let hint = forcedLanguage.flatMap(Language.init(rawValue:))
        let result: ASRResult
        if let samples, !samples.isEmpty {
            result = try await manager.transcribe(samples, decoderState: &state, language: hint)
        } else {
            result = try await manager.transcribe(url, decoderState: &state, language: hint)
        }
        trace?.mark("parakeet.inferenceFinished")
        return Result(text: result.text, coldStart: cold)
    }

    func unload(reason: String = "model selection changed") {
        idleTask?.cancel()
        idleTask = nil
        guard inFlight == 0, recordings == 0 else { return }
        dropModel(reason: reason)
    }

    private func dropModel(reason: String) {
        loadGeneration += 1
        loading?.task.cancel()
        loading = nil
        guard manager != nil else { return }
        manager = nil
        loadedVersion = nil
        log.notice("Unloaded Parakeet: \(reason, privacy: .public)")
    }

    private func load(_ version: AsrModelVersion) async throws {
        if manager != nil, loadedVersion == version { return }
        if let loading, loading.version == version { return try await loading.task.value }
        // Another variant is loaded or loading: only one stays in memory.
        if manager != nil || loading != nil { dropModel(reason: "switching variant") }
        loadGeneration += 1
        let generation = loadGeneration
        let task = Task {
            let start = ProcessInfo.processInfo.systemUptime
            log.notice("Preparing Parakeet \(String(describing: version), privacy: .public) generation \(generation)")
            let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: version), version: version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            try Task.checkCancellation()
            let loadedAt = ProcessInfo.processInfo.systemUptime
            log.notice("Loaded Parakeet models in \(loadedAt - start, format: .fixed(precision: 2))s; warming inference")
            // Loading MLModel objects does not execute predictions. Exercise both paths
            // with generated silence so deferred ANE work happens before user dictation.
            // Results and decoder state are discarded; no microphone or history is used.
            // Enough windows to exercise all four long-audio workers.
            for seconds in [0.5, 64.0] {
                var state = TdtDecoderState.make(decoderLayers: models.version.decoderLayers)
                _ = try await manager.transcribe(
                    [Float](repeating: 0, count: Int(seconds * 16_000)), decoderState: &state)
                try Task.checkCancellation()
            }
            guard generation == self.loadGeneration else { throw CancellationError() }
            self.finishLoading(manager, version: version, layers: models.version.decoderLayers)
            Self.returnFreedMemory()
            log.notice("Parakeet inference ready; warmup \(ProcessInfo.processInfo.systemUptime - loadedAt, format: .fixed(precision: 2))s")
        }
        loading = (version, task)
        defer { if generation == loadGeneration { loading = nil } }
        try await task.value
    }

    private func finishLoading(_ manager: AsrManager, version: AsrModelVersion, layers: Int) {
        self.manager = manager
        loadedVersion = version
        decoderLayers = layers
    }

    /// Inference allocates and frees tens of MB of CPU buffers; malloc keeps those pages
    /// counted against the app until told to give them back. Waits so it never delays a paste.
    private nonisolated static func returnFreedMemory() {
        Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let released = malloc_zone_pressure_relief(nil, 0)
            log.notice("Returned \(released / 1_048_576) MB of freed memory")
        }
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        guard idleTimeout > 0, manager != nil, inFlight == 0, recordings == 0 else { return }
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unload(reason: "idle timeout")
        }
    }
}
