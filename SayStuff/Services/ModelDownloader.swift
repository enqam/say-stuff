import Foundation

class ModelDownloader: ObservableObject {
    @Published var isDownloading = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var isComplete = false
    @Published var error: String?

    private var downloadTask: URLSessionDownloadTask?

    func download(model: WhisperModel) {
        isDownloading = true
        isComplete = false
        error = nil
        progress = 0
        statusMessage = "Connecting..."

        let modelDir = URL(fileURLWithPath: SettingsManager.shared.settings.modelDirectory)
        let destination = modelDir.appendingPathComponent(model.filename)

        // Check if already downloaded
        if FileManager.default.fileExists(atPath: destination.path) {
            isDownloading = false
            isComplete = true
            statusMessage = "Model already downloaded"
            return
        }

        let session = URLSession(configuration: .default, delegate: DownloadDelegate(downloader: self, destination: destination), delegateQueue: .main)

        downloadTask = session.downloadTask(with: model.downloadURL)
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        isDownloading = false
        statusMessage = "Cancelled"
    }

    fileprivate func handleProgress(_ totalBytesWritten: Int64, _ totalBytesExpectedToWrite: Int64) {
        progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let mbWritten = Double(totalBytesWritten) / 1_000_000
        let mbTotal = Double(totalBytesExpectedToWrite) / 1_000_000
        statusMessage = String(format: "Downloading %.1f / %.1f MB", mbWritten, mbTotal)
    }

    fileprivate func handleCompletion(location: URL?, destination: URL, error: Error?) {
        isDownloading = false

        if let error = error {
            self.error = error.localizedDescription
            return
        }

        guard let location = location else {
            self.error = "Download failed: no file"
            return
        }

        do {
            // Remove existing file if present
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            isComplete = true
            statusMessage = "Download complete"
        } catch {
            self.error = "Failed to save model: \(error.localizedDescription)"
        }
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var downloader: ModelDownloader?
    let destination: URL

    init(downloader: ModelDownloader, destination: URL) {
        self.downloader = downloader
        self.destination = destination
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        downloader?.handleProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        downloader?.handleCompletion(location: location, destination: destination, error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloader?.handleCompletion(location: nil, destination: destination, error: error)
        }
    }
}
