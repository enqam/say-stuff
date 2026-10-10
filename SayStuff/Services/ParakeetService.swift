import Foundation
import AVFoundation
import FluidAudio
import os

private let log = Logger(subsystem: "com.saystuff.app", category: "parakeet")

/// Local transcription with NVIDIA Parakeet TDT 0.6B v3 on the Neural Engine (via FluidAudio).
/// 25 European languages (incl. English, Russian, Ukrainian), language detected as part of
/// decoding, no separate detection pass. Loaded on demand and unloaded when idle, like whisper-server.
actor ParakeetService {
    static let shared = ParakeetService()

    private var manager: AsrManager?
    private var decoderLayers = 2
    private var loading: Task<Void, Error>?
    private var inFlight = 0
    private var idleTask: Task<Void, Never>?
    /// Seconds; 0 keeps the model loaded indefinitely.
    private var idleTimeout: TimeInterval = 300

    struct Result {
        let text: String
        let coldStart: Bool
    }

    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
    }

    nonisolated static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await AsrModels.download(version: .v3) { progress($0.fractionCompleted) }
    }

    func setIdleTimeout(_ seconds: TimeInterval) {
        idleTimeout = seconds
        scheduleUnload()
    }

    /// Starts loading now (called when recording begins), so it's usually ready at stop.
    func prewarm() async {
        guard Self.isDownloaded else { return }
        try? await load()
        scheduleUnload()
    }

    func transcribe(_ url: URL, forcedLanguage: String?) async throws -> Result {
        inFlight += 1
        idleTask?.cancel()
        defer {
            inFlight -= 1
            scheduleUnload()
        }
        let cold = manager == nil
        try await load()
        guard let manager else { throw WhisperError.modelNotFound }

        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        // The hint keeps output in the forced language's script (e.g. no Latin-letter Russian).
        let hint = forcedLanguage.flatMap(Language.init(rawValue:))
        let result = try await manager.transcribe(url, decoderState: &state, language: hint)
        return Result(text: result.text, coldStart: cold)
    }

    func unload() {
        idleTask?.cancel()
        idleTask = nil
        guard manager != nil, inFlight == 0 else { return }
        manager = nil
        log.notice("Unloaded Parakeet")
    }

    private func load() async throws {
        if manager != nil { return }
        if let loading { return try await loading.value }
        let task = Task {
            let start = Date()
            let models = try await AsrModels.load(from: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.finishLoading(manager, layers: models.version.decoderLayers)
            log.notice("Loaded Parakeet in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func finishLoading(_ manager: AsrManager, layers: Int) {
        self.manager = manager
        decoderLayers = layers
    }

    private func scheduleUnload() {
        idleTask?.cancel()
        guard idleTimeout > 0, manager != nil else { return }
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }
}
