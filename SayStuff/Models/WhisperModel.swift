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
        case .small: return "~488 MB"
        case .medium: return "~1.53 GB"
        case .largeTurbo: return "~1.62 GB"
        }
    }

    var shortName: String {
        switch self {
        case .tiny: return "Tiny"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeTurbo: return "Turbo"
        }
    }

    /// Approximate resident memory while loaded in whisper-server.
    var memoryString: String {
        switch self {
        case .tiny: return "~0.2 GB"
        case .small: return "~0.6 GB"
        case .medium: return "~1.7 GB"
        case .largeTurbo: return "~1.8 GB"
        }
    }

    var filename: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }
}
