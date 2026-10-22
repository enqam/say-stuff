// Standalone integration smoke test, linked with ParakeetService.swift and FluidAudio.
// Uses generated silence only: no microphone, transcript history, or paste events.
import Foundation
import AVFoundation

// Dependencies outside the service under test.
enum WhisperError: Error { case modelNotFound }
struct LatencyTrace: Sendable { func mark(_ stage: String) {} }

@main struct ParakeetLifecycleSmoke {
    static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-lifecycle-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        memset(buffer.floatChannelData![0], 0, 8_000 * MemoryLayout<Float>.size)
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        let service = ParakeetService()
        // Concurrent startup preparation shares a single load and completes inference warmup.
        async let first: Void = service.prewarm()
        async let second: Void = service.prewarm()
        _ = await (first, second)
        let warm = try await service.transcribe(url, forcedLanguage: nil)
        precondition(!warm.coldStart, "Startup prewarm did not make inference ready")

        // A short configured deadline cannot unload the model while recording.
        await service.setIdleTimeout(0.1)
        await service.beginRecording()
        try await Task.sleep(nanoseconds: 300_000_000)
        let duringRecording = try await service.transcribe(url, forcedLanguage: nil)
        precondition(!duringRecording.coldStart, "Idle timeout unloaded an active recording")
        await service.endRecording()
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterIdle = try await service.transcribe(url, forcedLanguage: nil)
        precondition(afterIdle.coldStart, "Idle timeout did not resume after recording ended")

        // Always keeps the model, including when a previously scheduled timer is cancelled.
        await service.setIdleTimeout(0)
        try await Task.sleep(nanoseconds: 300_000_000)
        let retained = try await service.transcribe(url, forcedLanguage: nil)
        precondition(!retained.coldStart, "Always did not cancel the idle timer")
        await service.unload(reason: "smoke test complete")
        print("PASS: concurrent prewarm, inference readiness, recording lease, idle expiry, Always retention")
    }
}
