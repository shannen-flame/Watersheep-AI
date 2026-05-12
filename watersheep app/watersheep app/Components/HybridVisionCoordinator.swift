import Foundation
import UIKit

/// Coordinates vision analysis between the unified backend endpoint and the
/// on-device Apple Vision fallback. The backend already handles
/// Gemini -> OpenRouter failover, with Ollama only if the backend explicitly
/// enables it, so this coordinator only needs one network service plus a local
/// fallback.
struct HybridVisionCoordinator {
    private let geminiService: GeminiVisionService?
    private let ollamaService: OllamaVisionService?
    private let localVisionService: LocalVisionFallbackService

    init(
        geminiService: GeminiVisionService?,
        ollamaService: OllamaVisionService?,
        localVisionService: LocalVisionFallbackService = LocalVisionFallbackService()
    ) {
        self.geminiService = geminiService
        self.ollamaService = ollamaService
        self.localVisionService = localVisionService
    }

    func analyzeScene(
        image: UIImage,
        prompt: String = "Describe what I am looking at in one short sentence.",
        localSummary: String?
    ) async -> VisionAnalysisResult {
        if let primary = geminiService ?? backendVisionService() {
            do {
                let result = try await primary.analyze(image: image, prompt: prompt, localSummary: localSummary)
                return result
            } catch let error as VisionAnalysisError {
                print("[Vision] Backend request failed: \(error.localizedDescription)")
                if error.isFallbackEligible {
                    return await localFallback(
                        image: image,
                        prompt: prompt,
                        localSummary: localSummary,
                        reason: error.localizedDescription,
                        rawError: error.localizedDescription
                    )
                }
                return VisionAnalysisResult(
                    provider: .gemini,
                    text: "Vision request failed.",
                    fallbackReason: nil,
                    rawError: error.localizedDescription,
                    rawResponse: error.rawResponse
                )
            } catch {
                print("[Vision] Backend request unexpected failure: \(error.localizedDescription)")
                return await localFallback(
                    image: image,
                    prompt: prompt,
                    localSummary: localSummary,
                    reason: "Vision service failed.",
                    rawError: error.localizedDescription
                )
            }
        }

        return await localFallback(
            image: image,
            prompt: prompt,
            localSummary: localSummary,
            reason: "Vision service is not configured.",
            rawError: "Vision service is not configured."
        )
    }

    private func backendVisionService() -> (any VisionAnalyzing)? {
        ollamaService
    }

    private func localFallback(
        image: UIImage,
        prompt: String,
        localSummary: String?,
        reason: String,
        rawError: String?
    ) async -> VisionAnalysisResult {
        do {
            let localResult = try await localVisionService.analyze(image: image, prompt: prompt, localSummary: localSummary)
            return VisionAnalysisResult(
                provider: .localOnly,
                text: localResult.text,
                fallbackReason: reason,
                rawError: rawError,
                rawResponse: nil
            )
        } catch {
            return VisionAnalysisResult(
                provider: .fallbackMessage,
                text: "Vision services are unavailable right now. I will try again once the connection is restored.",
                fallbackReason: reason,
                rawError: rawError ?? error.localizedDescription,
                rawResponse: nil
            )
        }
    }
}
