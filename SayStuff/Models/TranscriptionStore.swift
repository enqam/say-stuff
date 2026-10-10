import Foundation

struct RecentTranscription: Codable, Identifiable {
    let id: UUID
    let text: String
    let date: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.date = Date()
    }
}

final class TranscriptionStore: ObservableObject {
    static let shared = TranscriptionStore()

    @Published private(set) var transcriptions: [RecentTranscription] = []

    private let fileURL: URL
    private let maxCount = 50

    init() {
        fileURL = AppPaths.support.appendingPathComponent("recent_transcriptions.json")
        load()
    }

    func add(_ text: String) {
        transcriptions.insert(RecentTranscription(text: text), at: 0)
        if transcriptions.count > maxCount {
            transcriptions.removeLast(transcriptions.count - maxCount)
        }
        save()
    }

    func remove(_ id: RecentTranscription.ID) {
        transcriptions.removeAll { $0.id == id }
        save()
    }

    func clear() {
        transcriptions.removeAll()
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            transcriptions = try JSONDecoder().decode([RecentTranscription].self, from: data)
        } catch {
            print("[TranscriptionStore] Failed to load: \(error)")
        }
    }

    private func save() {
        do {
            try JSONEncoder().encode(transcriptions).write(to: fileURL, options: .atomic)
        } catch {
            print("[TranscriptionStore] Failed to save: \(error)")
        }
    }
}
