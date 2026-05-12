import AVFoundation
import UIKit

final class CameraManager: NSObject {
    enum CameraManagerError: LocalizedError {
        case cameraUnavailable
        case permissionDenied
        case noFrameAvailable

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable:
                return "The iPhone camera is unavailable."
            case .permissionDenied:
                return "Camera permission denied."
            case .noFrameAvailable:
                return "No valid camera frame is available yet."
            }
        }
    }

    let session = AVCaptureSession()

    var frameHandler: ((CVPixelBuffer) -> Void)?
    var frameProcessingInterval: TimeInterval = 1.0

    private let sessionQueue = DispatchQueue(label: "watersheep.camera.session")
    private let outputQueue = DispatchQueue(label: "watersheep.camera.output")
    private let latestFrameQueue = DispatchQueue(label: "watersheep.camera.latest-frame", attributes: .concurrent)
    private var lastFrameTime = CACurrentMediaTime()
    private var isConfigured = false
    private var latestFrameBuffer: CVPixelBuffer?
    private var hasLoggedFirstFrame = false

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        print("CameraManager start requested")
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            configureAndStart(completion: completion)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.configureAndStart(completion: completion)
                } else {
                    completion(.failure(CameraManagerError.permissionDenied))
                }
            }
        default:
            completion(.failure(CameraManagerError.permissionDenied))
        }
    }

    func stop() {
        print("CameraManager stop requested")
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
        latestFrameQueue.async(flags: .barrier) { [weak self] in
            self?.latestFrameBuffer = nil
            self?.hasLoggedFirstFrame = false
        }
    }

    func getLatestFrame() -> Result<CVPixelBuffer, CameraManagerError> {
        var frame: CVPixelBuffer?
        latestFrameQueue.sync {
            frame = latestFrameBuffer
        }

        if frame != nil {
            print("CameraManager latest frame available: true")
        } else {
            print("CameraManager latest frame available: false")
        }

        guard let frame else {
            return .failure(.noFrameAvailable)
        }

        return .success(frame)
    }

    private func configureAndStart(completion: @escaping (Result<Void, Error>) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                    print("CameraManager session started")
                } else {
                    print("CameraManager session already running")
                }

                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        // Prefer 1080p for OCR / object detection clarity, fall back gracefully
        // if the device or thermal state makes it unavailable.
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
        } else if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        } else {
            session.sessionPreset = .medium
        }
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            session.commitConfiguration()
            throw CameraManagerError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraManagerError.cameraUnavailable
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraManagerError.cameraUnavailable
        }
        session.addOutput(output)
        output.connection(with: .video)?.videoRotationAngle = 90

        session.commitConfiguration()
        isConfigured = true
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let currentTime = CACurrentMediaTime()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        latestFrameQueue.async(flags: .barrier) { [weak self] in
            self?.latestFrameBuffer = pixelBuffer
            if self?.hasLoggedFirstFrame == false {
                self?.hasLoggedFirstFrame = true
                print("CameraManager first frame received")
            }
        }

        guard currentTime - lastFrameTime >= frameProcessingInterval else { return }
        lastFrameTime = currentTime

        frameHandler?(pixelBuffer)
    }
}
