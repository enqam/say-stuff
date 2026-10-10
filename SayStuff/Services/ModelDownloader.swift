import Foundation

/// Downloads whisper models. One shared instance so onboarding and Settings show the same progress.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    @Published private(set) var progress: [WhisperModel: Double] = [:]
    @Published private(set) var errors: [WhisperModel: String] = [:]
    /// Bumped when a download lands so views re-check what's on disk.
    @Published private(set) var completedCount = 0

    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var tasks: [Int: (task: URLSessionDownloadTask, model: WhisperModel)] = [:]
    private var parakeetTask: Task<Void, Never>?

    func isDownloading(_ model: WhisperModel) -> Bool {
        progress[model] != nil
    }

    func download(_ model: WhisperModel) {
        guard !isDownloading(model) else { return }
        guard !SettingsManager.shared.isModelDownloaded(model) else {
            completedCount += 1
            return
        }
        errors[model] = nil
        progress[model] = 0
        guard model.isWhisper else {
            downloadParakeet()
            return
        }
        let task = session.downloadTask(with: model.downloadURL)
        tasks[task.taskIdentifier] = (task, model)
        task.resume()
    }

    /// Parakeet comes from FluidAudio's model hub (several CoreML files), not a single URL.
    private func downloadParakeet() {
        parakeetTask = Task { @MainActor in
            let downloader = ModelDownloader.shared
            do {
                try await ParakeetService.download { fraction in
                    DispatchQueue.main.async {
                        if downloader.progress[.parakeet] != nil { downloader.progress[.parakeet] = fraction }
                    }
                }
                downloader.progress[.parakeet] = nil
                let settings = SettingsManager.shared
                if !settings.isModelDownloaded(settings.settings.modelSize) { settings.settings.modelSize = .parakeet }
                downloader.completedCount += 1
            } catch {
                downloader.progress[.parakeet] = nil
                if !Task.isCancelled { downloader.errors[.parakeet] = error.localizedDescription }
            }
        }
    }

    func cancel(_ model: WhisperModel) {
        if model == .parakeet {
            parakeetTask?.cancel()
            progress[.parakeet] = nil
            return
        }
        guard let entry = tasks.first(where: { $0.value.model == model }) else { return }
        entry.value.task.cancel()
        tasks[entry.key] = nil
        progress[model] = nil
    }

    // MARK: URLSessionDownloadDelegate (main queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let model = tasks[downloadTask.taskIdentifier]?.model, totalBytesExpectedToWrite > 0 else { return }
        progress[model] = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model = tasks[downloadTask.taskIdentifier]?.model else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            errors[model] = "The download server returned an error. Try again."
            return
        }

        let settings = SettingsManager.shared
        let destination = settings.expandedModelDirectory.appendingPathComponent(model.filename)
        do {
            try FileManager.default.createDirectory(at: settings.expandedModelDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            // First model on a fresh install, or the selected one is missing: switch to the new one.
            if !settings.isModelDownloaded(settings.settings.modelSize) {
                settings.settings.modelSize = model
            }
            completedCount += 1
        } catch {
            errors[model] = "Couldn't save the model: \(error.localizedDescription)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let model = tasks.removeValue(forKey: task.taskIdentifier)?.model else { return }
        progress[model] = nil
        if let error, (error as NSError).code != NSURLErrorCancelled {
            errors[model] = error.localizedDescription
        }
    }
}
