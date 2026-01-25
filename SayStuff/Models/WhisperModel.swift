import Foundation

enum WhisperModel: String, Codable, CaseIterable {
    case tiny = "tiny"
    case small = "small"
    case medium = "medium"
    case largeTurbo = "large-v3-turbo"

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeTurbo: return "Large v3 Turbo"
        }
    }

    var description: String {
        switch self {
        case .tiny: return "Fastest, lower accuracy"
        case .small: return "Good balance of speed and accuracy"
        case .medium: return "Better accuracy, slower"
        case .largeTurbo: return "Best quality, optimized for speed"
        }
    }

    var sizeString: String {
        switch self {
        case .tiny: return "~75 MB"
        case .small: return "~150 MB"
        case .medium: return "~500 MB"
        case .largeTurbo: return "~400 MB"
        }
    }

    var filename: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }
}
