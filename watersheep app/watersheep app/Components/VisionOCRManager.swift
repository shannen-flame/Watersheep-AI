import Foundation
import Vision

final class VisionOCRManager {
    private let recognitionQueue = DispatchQueue(label: "watersheep.vision.ocr", qos: .userInitiated)

    func recognizeText(
        in pixelBuffer: CVPixelBuffer,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        recognitionQueue.async {
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let strings = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .filter { !$0.isEmpty }

                completion(.success(strings))
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.03

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

            do {
                try handler.perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }
}
