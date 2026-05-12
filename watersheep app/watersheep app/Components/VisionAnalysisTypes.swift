import Foundation
import UIKit

enum VisionProvider: String {
    case gemini
    case ollama
    case openrouter
    case localOnly
    case fallbackMessage

    static func fromBackend(_ value: String?) -> VisionProvider {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gemini":
            return .gemini
        case "ollama":
            return .ollama
        case "openrouter":
            return .openrouter
        case "local_summary", "local", "localonly", "local_only":
            return .localOnly
        case "friendly_failure", "fallback", "fallback_message":
            return .fallbackMessage
        default:
            return .fallbackMessage
        }
    }

    var displayName: String {
        switch self {
        case .gemini:
            return "Gemini"
        case .ollama:
            return "Ollama"
        case .openrouter:
            return "OpenRouter"
        case .localOnly:
            return "Local summary"
        case .fallbackMessage:
            return "Fallback message"
        }
    }

    var isSceneDescriptionProvider: Bool {
        switch self {
        case .gemini, .ollama, .openrouter:
            return true
        case .localOnly, .fallbackMessage:
            return false
        }
    }
}

struct VisionAnalysisResult {
    let provider: VisionProvider
    let text: String
    let fallbackReason: String?
    let rawError: String?
    let rawResponse: String?
}

enum VisionAnalysisError: LocalizedError {
    case quotaLimited(provider: VisionProvider, message: String, rawResponse: String?)
    case serviceUnavailable(provider: VisionProvider, message: String, rawResponse: String?)
    case requestFailed(provider: VisionProvider, message: String, rawResponse: String?)
    case emptyResult(provider: VisionProvider, message: String)

    var errorDescription: String? {
        switch self {
        case let .quotaLimited(_, message, _),
             let .serviceUnavailable(_, message, _),
             let .requestFailed(_, message, _),
             let .emptyResult(_, message):
            return message
        }
    }

    var rawResponse: String? {
        switch self {
        case let .quotaLimited(_, _, rawResponse),
             let .serviceUnavailable(_, _, rawResponse),
             let .requestFailed(_, _, rawResponse):
            return rawResponse
        case .emptyResult:
            return nil
        }
    }

    var isFallbackEligible: Bool {
        switch self {
        case .quotaLimited, .serviceUnavailable, .emptyResult:
            return true
        case let .requestFailed(_, message, rawResponse):
            let normalized = [message, rawResponse]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")
            let signals = [
                "501",
                "429",
                "quota exceeded",
                "vision_quota_exceeded",
                "resource exhausted",
                "rate limit",
                "service unavailable",
                "unavailable",
                "cooldown",
                "timed out",
                "unreachable",
            ]
            return signals.contains(where: { normalized.contains($0) })
        }
    }
}

protocol VisionAnalyzing {
    func analyze(image: UIImage, prompt: String, localSummary: String?) async throws -> VisionAnalysisResult
}
