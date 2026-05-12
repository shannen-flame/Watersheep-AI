import Foundation
import UIKit
@preconcurrency import Vision

struct LocalVisionFallbackService: VisionAnalyzing {
    private let builder = LocalVisionSummaryBuilder()

    func analyze(image: UIImage, prompt: String, localSummary: String?) async throws -> VisionAnalysisResult {
        let preferredSummary = localSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = if let preferredSummary, !preferredSummary.isEmpty {
            preferredSummary
        } else {
            await builder.makeSummary(from: image)
        }

        guard let summary, !summary.isEmpty else {
            throw VisionAnalysisError.emptyResult(
                provider: .localOnly,
                message: "No local Apple Vision summary was available."
            )
        }

        print("[Vision][Local] Using local Apple Vision summary")
        return VisionAnalysisResult(
            provider: .localOnly,
            text: summary,
            fallbackReason: nil,
            rawError: nil,
            rawResponse: nil
        )
    }
}

private actor LocalVisionSummaryBuilder {
    func makeSummary(from image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }

        async let textLines = recognizeText(in: cgImage)
        async let labels = classifyImage(in: cgImage)

        let resolvedText = await textLines
        let resolvedLabels = await labels

        var components: [String] = []

        let topLabels = resolvedLabels
            .prefix(3)
            .map { "\($0.identifier) \(Int($0.confidence * 100))%" }
            .joined(separator: ", ")
        if !topLabels.isEmpty {
            components.append("Objects: \(topLabels)")
        }

        let topText = resolvedText
            .prefix(2)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        if !topText.isEmpty {
            components.append("Text: \(topText)")
        }

        let summary = components.joined(separator: ". ")
        return summary.isEmpty ? nil : summary
    }

    private func recognizeText(in cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let request = VNRecognizeTextRequest { request, _ in
                        let observations = request.results as? [VNRecognizedTextObservation] ?? []
                        continuation.resume(returning: observations.compactMap { $0.topCandidates(1).first?.string })
                    }
                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = false
                    let handler = VNImageRequestHandler(cgImage: cgImage)
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }

    private func classifyImage(in cgImage: CGImage) async -> [VNClassificationObservation] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let request = VNClassifyImageRequest { request, _ in
                        let observations = request.results as? [VNClassificationObservation] ?? []
                        continuation.resume(returning: observations.filter { $0.confidence > 0.2 })
                    }
                    let handler = VNImageRequestHandler(cgImage: cgImage)
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
}
