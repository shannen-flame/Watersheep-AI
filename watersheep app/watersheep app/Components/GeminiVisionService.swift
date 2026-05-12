import Foundation
import UIKit

/// Thin wrapper that uses the unified `/api/vision/analyze` endpoint.
///
/// The backend already runs Gemini-first with safer provider fallback, so the
/// iOS app no longer needs to call the legacy `/analyze-frame` route. This type
/// stays as `VisionAnalyzing` so the existing `HybridVisionCoordinator` keeps
/// working.
struct GeminiVisionService: VisionAnalyzing {
    private let visionService: OllamaVisionService

    init?(backendClient: BackendClient) {
        guard let service = try? OllamaVisionService() else {
            return nil
        }
        self.visionService = service
    }

    init(visionService: OllamaVisionService) {
        self.visionService = visionService
    }

    func analyze(image: UIImage, prompt: String, localSummary: String?) async throws -> VisionAnalysisResult {
        let result = await visionService.describeImage(
            image,
            sceneSummary: localSummary,
            prompt: prompt
        )

        switch result {
        case .success(let success):
            let provider = VisionProvider.fromBackend(success.providerHint)
            return VisionAnalysisResult(
                provider: provider,
                text: success.text,
                fallbackReason: success.fallbackReason,
                rawError: nil,
                rawResponse: nil
            )
        case .failure(let failure):
            if failure.isQuotaOrServiceIssue {
                throw VisionAnalysisError.quotaLimited(
                    provider: .gemini,
                    message: failure.message,
                    rawResponse: nil
                )
            }
            throw VisionAnalysisError.requestFailed(
                provider: .gemini,
                message: failure.message,
                rawResponse: nil
            )
        }
    }
}
