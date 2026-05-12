import Foundation
import Vision

struct DetectedObject: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Double
}

final class VisionObjectDetectionManager {
    private let recognitionQueue = DispatchQueue(label: "watersheep.vision.object-detection", qos: .userInitiated)

    func detectObjects(
        in pixelBuffer: CVPixelBuffer,
        completion: @escaping (Result<[DetectedObject], Error>) -> Void
    ) {
        recognitionQueue.async {
            let request = VNClassifyImageRequest { request, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                let observations = request.results as? [VNClassificationObservation] ?? []
                let detectedObjects = observations.prefix(5).map { observation in
                    DetectedObject(
                        label: observation.identifier,
                        confidence: Double(observation.confidence)
                    )
                }

                completion(.success(detectedObjects))
            }

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)

            do {
                try handler.perform([request])
            } catch {
                completion(.failure(error))
            }
        }
    }
}
