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

class TranscriptionStore: ObservableObject {
    static let shared = TranscriptionStore()

    @Published var transcriptions: [RecentTranscription] = []

    private let fileURL: URL
    private let maxCount = 10

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let sayStuffDir = appSupport.appendingPathComponent("SayStuff")
        try? FileManager.default.createDirectory(at: sayStuffDir, withIntermediateDirectories: true)
        fileURL = sayStuffDir.appendingPathComponent("recent_transcriptions.json")
        load()
    }

    func add(_ text: String) {
        let new = RecentTranscription(text: text)
        transcriptions.insert(new, at: 0)
        if transcriptions.count > maxCount {
            transcriptions = Array(transcriptions.prefix(maxCount))
        }
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            transcriptions = try JSONDecoder().decode([RecentTranscription].self, from: data)
        } catch {
            print("[TranscriptionStore] Failed to load: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(transcriptions)
            try data.write(to: fileURL)
        } catch {
            print("[TranscriptionStore] Failed to save: \(error)")
        }
    }
}
