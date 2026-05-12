import AVFoundation
import Combine
import CoreImage
import Foundation
import UIKit

@MainActor
final class DebugViewModel: ObservableObject {
    private enum HybridVisionConstants {
        static let objectDetectionInterval: TimeInterval = 1.5
        static let ollamaVisionInterval: TimeInterval = 2
        static let sceneChangeTriggerInterval: TimeInterval = 8
        static let ollamaRetryCooldownInterval: TimeInterval = 120
        static let ollamaHealthCheckInterval: TimeInterval = 120
    }

    @Published private(set) var latestRecognizedText = "No OCR text yet."
    @Published private(set) var recognizedTextLines: [String] = []
    @Published private(set) var detectedObjects: [DetectedObject] = []
    @Published private(set) var latestDetectedObjectsText = "No objects detected yet."
    @Published private(set) var latestSceneSummary = "No scene summary yet."
    @Published private(set) var latestOllamaVisionText = "No vision result yet."
    @Published private(set) var ocrStatus = "Idle"
    @Published private(set) var objectDetectionStatus = "Idle"
    @Published private(set) var ollamaVisionStatus = "Idle"
    @Published private(set) var ollamaTriggerStatus = "Idle"
    @Published private(set) var cameraStatus = "Stopped"
    @Published private(set) var lastOCRError = "None"
    @Published private(set) var lastObjectDetectionError = "None"
    @Published private(set) var lastOllamaVisionError = "None"
    @Published private(set) var lastVisionProvider = "None"

    private let cameraManager: CameraManager
    private let visionOCRManager: VisionOCRManager
    private let visionObjectDetectionManager: VisionObjectDetectionManager
    private let ollamaVisionService: OllamaVisionService?
    private let speechManager: SpeechManager
    private let ciContext = CIContext()
    private var isProcessingFrame = false
    private var isProcessingObjectDetection = false
    private var isProcessingOllamaVision = false
    private var isStartingCamera = false
    private var ollamaTask: Task<Void, Never>?
    private var lastObjectDetectionTime = CACurrentMediaTime()
    private var lastOllamaVisionTime = CACurrentMediaTime()
    private var lastSceneChangeTriggerTime = CACurrentMediaTime()
    private var lastOllamaSummary = ""
    private var ollamaRetryBlockedUntil: CFTimeInterval = 0
    private var lastOllamaHealthCheckTime: CFTimeInterval = 0
    private var lastOllamaHealthWasReachable = false
    var onOllamaVisionResult: ((String) -> Void)?

    init(
        cameraManager: CameraManager,
        visionOCRManager: VisionOCRManager,
        visionObjectDetectionManager: VisionObjectDetectionManager,
        ollamaVisionService: OllamaVisionService?,
        speechManager: SpeechManager
    ) {
        self.cameraManager = cameraManager
        self.visionOCRManager = visionOCRManager
        self.visionObjectDetectionManager = visionObjectDetectionManager
        self.ollamaVisionService = ollamaVisionService
        self.speechManager = speechManager
        self.cameraManager.frameHandler = { [weak self] pixelBuffer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processOCRFrame(pixelBuffer)
                self.processObjectDetectionFrame(pixelBuffer)
                self.processOllamaVisionFrame(pixelBuffer)
            }
        }
    }

    convenience init() {
        self.init(
            cameraManager: CameraManager(),
            visionOCRManager: VisionOCRManager(),
            visionObjectDetectionManager: VisionObjectDetectionManager(),
            ollamaVisionService: try? OllamaVisionService(),
            speechManager: .shared
        )
    }

    func startOCR() {
        if isStartingCamera || cameraStatus == "Running" {
            print("Hybrid vision pipeline already active")
            return
        }

        print("Hybrid vision pipeline start requested")
        isStartingCamera = true
        cameraStatus = "Starting"
        ocrStatus = "Starting"
        cameraManager.start { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isStartingCamera = false
                switch result {
                case .success:
                    print("Hybrid vision pipeline started")
                    self.cameraStatus = "Running"
                    self.ocrStatus = "Scanning"
                    self.objectDetectionStatus = "Scanning"
                    self.ollamaVisionStatus = "Checking"
                    self.ollamaTriggerStatus = "Checking vision health"
                    self.ollamaRetryBlockedUntil = 0
                    self.lastOCRError = "None"
                    self.lastObjectDetectionError = "None"
                    self.lastOllamaVisionError = "None"
                    self.checkOllamaHealthIfNeeded(force: true)
                case .failure(let error):
                    print("Hybrid vision pipeline failed to start: \(error.localizedDescription)")
                    self.cameraStatus = "Failed"
                    self.ocrStatus = "Unavailable"
                    self.objectDetectionStatus = "Unavailable"
                    self.ollamaVisionStatus = "Unavailable"
                    self.ollamaTriggerStatus = "Unavailable"
                    self.lastOCRError = error.localizedDescription
                    self.lastObjectDetectionError = error.localizedDescription
                    self.lastOllamaVisionError = error.localizedDescription
                }
            }
        }
    }

    func stopOCR() {
        guard isStartingCamera || cameraStatus != "Stopped" else { return }
        print("Hybrid vision pipeline stop requested")
        isStartingCamera = false
        cameraManager.stop()
        ollamaTask?.cancel()
        ollamaTask = nil
        isProcessingOllamaVision = false
        cameraStatus = "Stopped"
        ocrStatus = "Idle"
        objectDetectionStatus = "Idle"
        ollamaVisionStatus = "Idle"
        ollamaTriggerStatus = "Idle"
        ollamaRetryBlockedUntil = 0
    }

    func explainCurrentScene() {
        print("Explain Current Scene button tapped")

        guard !isProcessingOllamaVision else {
            ollamaVisionStatus = "Busy"
            ollamaTriggerStatus = "Manual request ignored while analysis is running"
            return
        }

        switch cameraManager.getLatestFrame() {
        case .success(let pixelBuffer):
            guard let image = makeUIImage(from: pixelBuffer) else {
                ollamaVisionStatus = "Failed"
                ollamaTriggerStatus = "Manual request failed"
                latestOllamaVisionText = "The latest camera frame could not be prepared."
                lastOllamaVisionError = "Failed to convert the latest camera frame into an image."
                return
            }
            startManualOllamaVisionRequest(with: image)
        case .failure(let error):
            ollamaVisionStatus = "Failed"
            ollamaTriggerStatus = "Manual request failed"
            latestOllamaVisionText = "Start the camera to capture a frame first."
            lastOllamaVisionError = error.localizedDescription
        }
    }

    func explainCurrentScene(using image: UIImage) {
        print("Explain Current Scene button tapped")
        guard !isProcessingOllamaVision else {
            ollamaVisionStatus = "Busy"
            ollamaTriggerStatus = "Manual request ignored while analysis is running"
            return
        }
        startManualOllamaVisionRequest(with: image)
    }

    private func processOCRFrame(_ pixelBuffer: CVPixelBuffer) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        visionOCRManager.recognizeText(in: pixelBuffer) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessingFrame = false

                switch result {
                case .success(let strings):
                    self.recognizedTextLines = Array(strings.prefix(5))
                    self.latestRecognizedText = self.recognizedTextLines.isEmpty
                        ? "No text detected."
                        : self.recognizedTextLines.joined(separator: "\n")
                    self.refreshSceneSummary()
                    self.ocrStatus = "Updated"
                    self.lastOCRError = "None"
                case .failure(let error):
                    self.ocrStatus = "Failed"
                    self.lastOCRError = error.localizedDescription
                }
            }
        }
    }

    private func processObjectDetectionFrame(_ pixelBuffer: CVPixelBuffer) {
        let currentTime = CACurrentMediaTime()
        guard currentTime - lastObjectDetectionTime >= HybridVisionConstants.objectDetectionInterval else { return }
        guard !isProcessingObjectDetection else { return }
        isProcessingObjectDetection = true
        lastObjectDetectionTime = currentTime

        visionObjectDetectionManager.detectObjects(in: pixelBuffer) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isProcessingObjectDetection = false

                switch result {
                case .success(let objects):
                    self.detectedObjects = objects
                    self.latestDetectedObjectsText = objects.isEmpty
                        ? "No objects detected."
                        : objects.map { "\($0.label) (\(Int($0.confidence * 100))%)" }.joined(separator: ", ")
                    self.refreshSceneSummary()
                    self.objectDetectionStatus = "Updated"
                    self.lastObjectDetectionError = "None"
                case .failure(let error):
                    self.objectDetectionStatus = "Failed"
                    self.lastObjectDetectionError = error.localizedDescription
                }
            }
        }
    }

    private func processOllamaVisionFrame(_ pixelBuffer: CVPixelBuffer) {
        let currentTime = CACurrentMediaTime()
        guard let image = makeUIImage(from: pixelBuffer) else {
            ollamaVisionStatus = "Failed"
            lastOllamaVisionError = "Failed to convert camera frame to UIImage."
            return
        }

        if currentTime < ollamaRetryBlockedUntil {
            let remainingSeconds = max(Int(ceil(ollamaRetryBlockedUntil - currentTime)), 1)
            ollamaVisionStatus = "Cooling down"
            ollamaTriggerStatus = "Retrying in \(remainingSeconds)s"
            return
        }

        guard currentTime - lastOllamaVisionTime >= HybridVisionConstants.ollamaVisionInterval else { return }
        checkOllamaHealthIfNeeded(force: false)
        guard lastOllamaHealthWasReachable else {
            ollamaVisionStatus = "Unavailable"
            ollamaTriggerStatus = "Preview running; vision health check pending"
            return
        }
        let normalizedSummary = normalizedSummary(latestSceneSummary)
        guard !normalizedSummary.isEmpty else { return }
        guard normalizedSummary != lastOllamaSummary else { return }
        guard currentTime - lastSceneChangeTriggerTime >= HybridVisionConstants.sceneChangeTriggerInterval else { return }

        startAutomaticOllamaVisionRequest(with: image)
    }

    private func makeUIImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func refreshSceneSummary() {
        latestSceneSummary = makeSceneSummary()
    }

    private func makeSceneSummary() -> String {
        let textSnippet = recognizedTextLines
            .prefix(2)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")

        let objectSnippet = detectedObjects
            .prefix(3)
            .map { "\($0.label) \(Int($0.confidence * 100))%" }
            .joined(separator: ", ")

        var components: [String] = []
        if !objectSnippet.isEmpty {
            components.append("Objects: \(objectSnippet)")
        }
        if !textSnippet.isEmpty {
            components.append("Text: \(textSnippet)")
        }

        return components.isEmpty ? "No scene summary yet." : components.joined(separator: ". ")
    }

    private func normalizedSummary(_ summary: String) -> String {
        let normalized = summary
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized == "no scene summary yet." ? "" : normalized
    }

    private func startAutomaticOllamaVisionRequest(with image: UIImage) {
        guard !isProcessingOllamaVision else { return }
        startOllamaVisionRequest(
            with: image,
            reason: "Scene changed",
            updateSceneChangeMarkers: true
        )
    }

    private func startManualOllamaVisionRequest(with image: UIImage) {
        guard !isProcessingOllamaVision else { return }
        checkOllamaHealthIfNeeded(force: true)
        startOllamaVisionRequest(
            with: image,
            reason: "Manual request",
            updateSceneChangeMarkers: false
        )
    }

    private func startOllamaVisionRequest(
        with image: UIImage,
        reason: String,
        updateSceneChangeMarkers: Bool
    ) {
        guard let ollamaVisionService else {
            ollamaVisionStatus = "Unavailable"
            ollamaTriggerStatus = "\(reason) unavailable"
            lastOllamaVisionError = OllamaVisionServiceError.invalidBaseURL.localizedDescription
            print("Vision request failed: service unavailable")
            return
        }

        if CACurrentMediaTime() < ollamaRetryBlockedUntil {
            let remainingSeconds = max(Int(ceil(ollamaRetryBlockedUntil - CACurrentMediaTime())), 1)
            ollamaVisionStatus = "Cooling down"
            ollamaTriggerStatus = "\(reason) delayed \(remainingSeconds)s"
            print("Vision request blocked by cooldown: \(reason)")
            return
        }

        guard !isProcessingOllamaVision else {
            ollamaVisionStatus = "Busy"
            ollamaTriggerStatus = "\(reason) ignored while analysis is running"
            return
        }

        let sceneSummary = latestSceneSummary
        isProcessingOllamaVision = true
        lastOllamaVisionTime = CACurrentMediaTime()
        if updateSceneChangeMarkers {
            lastSceneChangeTriggerTime = CACurrentMediaTime()
        }
        ollamaVisionStatus = "Sending"
        ollamaTriggerStatus = reason
        lastOllamaVisionError = "None"

        print("Vision request started: \(reason)")

        ollamaTask = Task(priority: .utility) { [weak self] in
            let result = await ollamaVisionService.describeImage(image, sceneSummary: sceneSummary)
            await MainActor.run {
                guard let self else { return }
                switch result {
                case .success(let success):
                    self.isProcessingOllamaVision = false
                    self.ollamaRetryBlockedUntil = 0
                    self.ollamaVisionStatus = "Updated"
                    self.ollamaTriggerStatus = "\(reason) completed"
                    self.latestOllamaVisionText = success.text
                    self.lastVisionProvider = success.providerHint.capitalized
                    self.lastOllamaVisionError = "None"
                    if updateSceneChangeMarkers {
                        self.lastOllamaSummary = self.normalizedSummary(sceneSummary)
                    }
                    self.onOllamaVisionResult?(success.text)
                    print("Vision request completed: \(reason)")
                case .failure(let failure):
                    self.isProcessingOllamaVision = false
                    let shouldCooldown = failure.isQuotaOrServiceIssue || self.shouldApplyOllamaCooldown(for: failure.message)
                    if shouldCooldown {
                        self.ollamaRetryBlockedUntil = CACurrentMediaTime() + HybridVisionConstants.ollamaRetryCooldownInterval
                        self.lastOllamaHealthWasReachable = false
                        self.ollamaVisionStatus = "Cooling down"
                        self.ollamaTriggerStatus = "\(reason) retry delayed"
                    } else {
                        self.ollamaVisionStatus = "Failed"
                        self.ollamaTriggerStatus = "\(reason) failed"
                    }
                    self.latestOllamaVisionText = "No vision result yet."
                    self.lastOllamaVisionError = failure.message
                    print("Vision request failed: \(reason)")
                }
            }
        }
    }

    private func shouldApplyOllamaCooldown(for message: String) -> Bool {
        let normalized = message.lowercased()
        let retrySignals = [
            "timed out",
            "unreachable",
            "could not connect",
            "host is down",
            "network connection was lost",
        ]
        return retrySignals.contains(where: { normalized.contains($0) })
    }

    private func checkOllamaHealthIfNeeded(force: Bool) {
        guard let ollamaVisionService else {
            ollamaVisionStatus = "Unavailable"
            ollamaTriggerStatus = "Vision base URL is not configured"
            lastOllamaHealthWasReachable = false
            return
        }

        let now = CACurrentMediaTime()
        if !force && now < ollamaRetryBlockedUntil {
            return
        }
        guard force || now - lastOllamaHealthCheckTime >= HybridVisionConstants.ollamaHealthCheckInterval else {
            return
        }

        lastOllamaHealthCheckTime = now
        Task(priority: .utility) { [weak self] in
            let result = await ollamaVisionService.healthCheck()
            await MainActor.run {
                guard let self else { return }
                self.lastOllamaHealthWasReachable = result.isReachable
                if result.isReachable {
                    self.ollamaRetryBlockedUntil = 0
                    if self.ollamaVisionStatus == "Checking" || self.ollamaVisionStatus == "Unavailable" || self.ollamaVisionStatus == "Cooling down" {
                        self.ollamaVisionStatus = "Ready"
                    }
                    self.ollamaTriggerStatus = "Watching for scene changes"
                    self.lastOllamaVisionError = "None"
                } else {
                    self.ollamaRetryBlockedUntil = CACurrentMediaTime() + HybridVisionConstants.ollamaRetryCooldownInterval
                    self.ollamaVisionStatus = "Unavailable"
                    self.ollamaTriggerStatus = "Preview running; vision retry delayed"
                    self.lastOllamaVisionError = result.message
                }
            }
        }
    }
}
