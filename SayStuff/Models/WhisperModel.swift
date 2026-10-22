import Foundation

enum WhisperModel: String, Codable, CaseIterable {
    case tiny = "tiny"
    case small = "small"
    case medium = "medium"
    case largeTurbo = "large-v3-turbo"
    /// Not Whisper: NVIDIA Parakeet TDT 0.6B v3 via FluidAudio (Neural Engine).
    case parakeet = "parakeet-v3"
    /// Parakeet Ultra: a post-training of v3 with the same languages and speed, lower error rates.
    case parakeetUltra = "parakeet-ultra"

    var isParakeet: Bool { self == .parakeet || self == .parakeetUltra }
    var isWhisper: Bool { !isParakeet }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeTurbo: return "Large v3 Turbo"
        case .parakeet: return "Parakeet v3"
        case .parakeetUltra: return "Parakeet Ultra"
        }
    }

    var description: String {
        switch self {
        case .tiny: return "Fastest, lower accuracy"
        case .small: return "Good balance of speed and accuracy"
        case .medium: return "Better accuracy, slower"
        case .largeTurbo: return "Best quality, optimized for speed"
        case .parakeet: return "Fastest, Neural Engine · 25 European languages"
        case .parakeetUltra: return "Parakeet, more accurate at the same speed"
        }
    }

    var sizeString: String {
        switch self {
        case .tiny: return "~75 MB"
        case .small: return "~488 MB"
        case .medium: return "~1.53 GB"
        case .largeTurbo: return "~1.62 GB"
        case .parakeet: return "~0.5 GB"
        case .parakeetUltra: return "~0.65 GB"
        }
    }

    var shortName: String {
        switch self {
        case .tiny: return "Tiny"
        case .small: return "Small"
        case .medium: return "Medium"
        case .largeTurbo: return "Turbo"
        case .parakeet: return "Parakeet"
        case .parakeetUltra: return "Ultra"
        }
    }

    /// Approximate resident memory while loaded in whisper-server.
    var memoryString: String {
        switch self {
        case .tiny: return "~0.2 GB"
        case .small: return "~0.6 GB"
        case .medium: return "~1.7 GB"
        case .largeTurbo: return "~1.8 GB"
        case .parakeet: return "~0.6 GB"
        case .parakeetUltra: return "~0.7 GB"
        }
    }

    var filename: String {
        "ggml-\(rawValue).bin"
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(filename)")!
    }
}
