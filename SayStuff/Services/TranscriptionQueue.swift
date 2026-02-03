import Foundation

/// Represents a transcription that's waiting to be pasted
struct PendingTranscription {
    let id: UUID
    let task: Task<String, Error>
}

/// Manages queued transcriptions and paste delivery
class TranscriptionQueue {
    private var pending: [PendingTranscription] = []
    private let pasteService: PasteService

    /// Called when a transcription completes successfully
    var onTranscriptionComplete: ((String) -> Void)?

    /// Called when a transcription fails
    var onTranscriptionFailed: ((Error) -> Void)?

    init(pasteService: PasteService) {
        self.pasteService = pasteService
    }

    /// Add a new transcription to the queue
    @discardableResult
    func enqueue(task: Task<String, Error>) -> UUID {
        let id = UUID()
        let pending = PendingTranscription(
            id: id,
            task: task
        )
        self.pending.append(pending)

        // Start monitoring this task
        Task {
            await processTranscription(pending)
        }

        return id
    }

    /// Process a transcription when it completes
    private func processTranscription(_ item: PendingTranscription) async {
        do {
            let transcription = try await item.task.value

            await MainActor.run {
                // Paste the transcription
                pasteService.pasteText(transcription)

                // Notify completion
                onTranscriptionComplete?(transcription)

                // Remove from queue
                pending.removeAll { $0.id == item.id }
            }
        } catch {
            print("[TranscriptionQueue] Transcription failed: \(error)")
            await MainActor.run {
                onTranscriptionFailed?(error)
                pending.removeAll { $0.id == item.id }
            }
        }
    }

    /// Cancel all pending transcriptions
    func cancelAll() {
        for item in pending {
            item.task.cancel()
        }
        pending.removeAll()
    }

    /// Check if there are any pending transcriptions
    var hasPending: Bool {
        !pending.isEmpty
    }
}
