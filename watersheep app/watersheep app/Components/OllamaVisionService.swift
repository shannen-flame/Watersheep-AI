import Foundation
import UIKit

struct OllamaVisionConfiguration {
    static let infoPlistKey = "OllamaVisionBaseURL"
    static let userDefaultsKey = "settings.ollamaVisionURL"
    static let fallbackBaseURLString = APIConfiguration.fallbackBaseURLString
    static let generatePath = "api/vision/analyze"
    static let healthPath = "health"
    static let defaultModel = "gemma3"
    static let defaultPrompt = "Describe what I am looking at in one short sentence."

    static var resolvedBaseURLString: String {
        let storedValue = UserDefaults.standard.string(forKey: userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let storedValue, !storedValue.isEmpty {
            return normalizeBaseURLString(storedValue)
        }

        let plistValue = (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let plistValue, !plistValue.isEmpty {
            return normalizeBaseURLString(plistValue)
        }

        return APIConfiguration.resolvedBaseURLString
    }

    private static func normalizeBaseURLString(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return APIConfiguration.resolvedBaseURLString
        }

        if components.port == 11434 {
            UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            return APIConfiguration.resolvedBaseURLString
        }

        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url?.absoluteString ?? APIConfiguration.resolvedBaseURLString
    }
}

enum OllamaVisionServiceError: LocalizedError {
    case invalidBaseURL
    case imageEncodingFailed
    case invalidResponse
    case serverError(statusCode: Int, body: String)
    case emptyResponse
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Vision service base URL is invalid."
        case .imageEncodingFailed:
            return "Failed to prepare the image for upload."
        case .invalidResponse:
            return "Received an invalid response from the vision service."
        case .serverError(let statusCode, _):
            return "Vision request failed with HTTP \(statusCode)."
        case .emptyResponse:
            return "Vision service returned an empty response."
        case .decodingFailed:
            return "Could not decode the vision service response."
        }
    }
}

struct OllamaVisionDebugInfo {
    let endpoint: String
    let statusCode: Int
    let parsedResponse: String?
}

struct OllamaVisionResult {
    let text: String
    let providerHint: String
    let fallbackReason: String?
    let debugInfo: OllamaVisionDebugInfo
}

struct OllamaVisionFailure {
    let message: String
    let isQuotaOrServiceIssue: Bool
    let debugInfo: OllamaVisionDebugInfo
}

enum OllamaVisionRequestResult {
    case success(OllamaVisionResult)
    case failure(OllamaVisionFailure)
}

struct OllamaVisionHealthResult {
    let isReachable: Bool
    let message: String
    let statusCode: Int
}

private struct OllamaVisionGenerateResponse: Decodable {
    let assistantMessage: String?
    let visionSummary: String?
    let fallbackReason: String?
    let localSummary: String?
    let visionProvider: String?
    let response: String?
    let message: OllamaVisionMessage?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case assistantMessage = "assistant_message"
        case visionSummary = "vision_summary"
        case fallbackReason = "fallback_reason"
        case localSummary = "local_summary"
        case visionProvider = "vision_provider"
        case response
        case message
        case error
    }

    struct OllamaVisionMessage: Decodable {
        let content: String?
    }

    var resolvedText: String? {
        assistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? visionSummary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? response?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? message?.content?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

struct OllamaVisionService {
    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(baseURLString: String = OllamaVisionConfiguration.resolvedBaseURLString, session: URLSession? = nil) throws {
        guard let baseURL = URL(string: baseURLString) else {
            throw OllamaVisionServiceError.invalidBaseURL
        }

        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            // Ollama on the Mac can take 14-18s to return a vision caption when
            // it's the fallback path after a Gemini quota miss. 12s is too tight.
            configuration.timeoutIntervalForRequest = 25
            configuration.timeoutIntervalForResource = 35
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func describeImage(
        _ image: UIImage,
        sceneSummary: String? = nil,
        prompt: String? = nil,
        model: String? = nil
    ) async -> OllamaVisionRequestResult {
        // 0.85 is the sweet spot for vision models — visually
        // lossless on text and small details, ~30% smaller than 1.0.
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            return .failure(
                OllamaVisionFailure(
                    message: OllamaVisionServiceError.imageEncodingFailed.localizedDescription,
                    isQuotaOrServiceIssue: false,
                    debugInfo: makeDebugInfo(statusCode: 0, parsedResponse: nil)
                )
            )
        }

        let resolvedPrompt = makePrompt(prompt: prompt, sceneSummary: sceneSummary)
        let resolvedModel = model ?? OllamaVisionConfiguration.defaultModel
        let boundary = "Boundary-\(UUID().uuidString)"
        let requestURL = baseURL.appending(path: OllamaVisionConfiguration.generatePath)

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            imageData: imageData,
            prompt: resolvedPrompt,
            sceneSummary: sceneSummary,
            model: resolvedModel
        )

        print("Vision request -> \(requestURL.absoluteString)")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let message = makeNetworkFailureMessage(from: error)
            print("Vision request failed before response: \(message)")
            return .failure(
                OllamaVisionFailure(
                    message: message,
                    isQuotaOrServiceIssue: isQuotaSignal(in: message),
                    debugInfo: makeDebugInfo(statusCode: 0, parsedResponse: nil)
                )
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .failure(
                OllamaVisionFailure(
                    message: OllamaVisionServiceError.invalidResponse.localizedDescription,
                    isQuotaOrServiceIssue: false,
                    debugInfo: makeDebugInfo(statusCode: 0, parsedResponse: nil)
                )
            )
        }

        print("Vision response status: \(httpResponse.statusCode)")

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = "Vision request failed with HTTP \(httpResponse.statusCode)."
            return .failure(
                OllamaVisionFailure(
                    message: message,
                    isQuotaOrServiceIssue: httpResponse.statusCode == 429 || httpResponse.statusCode == 503,
                    debugInfo: makeDebugInfo(statusCode: httpResponse.statusCode, parsedResponse: nil)
                )
            )
        }

        let decodedResponse: OllamaVisionGenerateResponse
        do {
            decodedResponse = try decoder.decode(OllamaVisionGenerateResponse.self, from: data)
        } catch {
            return .failure(
                OllamaVisionFailure(
                    message: OllamaVisionServiceError.decodingFailed(error.localizedDescription).localizedDescription,
                    isQuotaOrServiceIssue: false,
                    debugInfo: makeDebugInfo(statusCode: httpResponse.statusCode, parsedResponse: nil)
                )
            )
        }

        if let errorMessage = decodedResponse.error?.trimmingCharacters(in: .whitespacesAndNewlines), !errorMessage.isEmpty {
            return .failure(
                OllamaVisionFailure(
                    message: "Vision service reported an error.",
                    isQuotaOrServiceIssue: isQuotaSignal(in: errorMessage),
                    debugInfo: makeDebugInfo(statusCode: httpResponse.statusCode, parsedResponse: nil)
                )
            )
        }

        guard let resolvedText = decodedResponse.resolvedText else {
            return .failure(
                OllamaVisionFailure(
                    message: OllamaVisionServiceError.emptyResponse.localizedDescription,
                    isQuotaOrServiceIssue: false,
                    debugInfo: makeDebugInfo(statusCode: httpResponse.statusCode, parsedResponse: nil)
                )
            )
        }

        return .success(
            OllamaVisionResult(
                text: resolvedText,
                providerHint: decodedResponse.visionProvider ?? "gemini",
                fallbackReason: decodedResponse.fallbackReason,
                debugInfo: makeDebugInfo(
                    statusCode: httpResponse.statusCode,
                    parsedResponse: redactedPreview(of: resolvedText)
                )
            )
        )
    }

    func healthCheck() async -> OllamaVisionHealthResult {
        let requestURL = baseURL.appending(path: OllamaVisionConfiguration.healthPath)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return OllamaVisionHealthResult(
                    isReachable: false,
                    message: OllamaVisionServiceError.invalidResponse.localizedDescription,
                    statusCode: 0
                )
            }

            return OllamaVisionHealthResult(
                isReachable: (200 ..< 300).contains(httpResponse.statusCode),
                message: (200 ..< 300).contains(httpResponse.statusCode)
                    ? "Vision backend is reachable."
                    : "Vision backend health check failed with HTTP \(httpResponse.statusCode).",
                statusCode: httpResponse.statusCode
            )
        } catch {
            return OllamaVisionHealthResult(
                isReachable: false,
                message: makeNetworkFailureMessage(from: error),
                statusCode: 0
            )
        }
    }

    private func makePrompt(prompt: String?, sceneSummary: String?) -> String {
        let basePrompt = (prompt ?? OllamaVisionConfiguration.defaultPrompt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sceneSummary, !sceneSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return basePrompt
        }

        return """
        \(basePrompt)

        Scene summary:
        \(sceneSummary)
        """
    }

    private func makeMultipartBody(
        boundary: String,
        imageData: Data,
        prompt: String,
        sceneSummary: String?,
        model: String
    ) -> Data {
        var body = Data()

        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"frame.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        body.append("\r\n")

        appendField(into: &body, boundary: boundary, name: "prompt", value: prompt)
        if let sceneSummary, !sceneSummary.isEmpty {
            appendField(into: &body, boundary: boundary, name: "scene_summary", value: sceneSummary)
        }
        appendField(into: &body, boundary: boundary, name: "model", value: model)

        body.append("--\(boundary)--\r\n")
        return body
    }

    private func appendField(into body: inout Data, boundary: String, name: String, value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append(value)
        body.append("\r\n")
    }

    private func makeDebugInfo(statusCode: Int, parsedResponse: String?) -> OllamaVisionDebugInfo {
        OllamaVisionDebugInfo(
            endpoint: "/\(OllamaVisionConfiguration.generatePath)",
            statusCode: statusCode,
            parsedResponse: parsedResponse
        )
    }

    private func redactedPreview(of value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 240 {
            return trimmed
        }
        return String(trimmed.prefix(237)) + "..."
    }

    private func isQuotaSignal(in message: String) -> Bool {
        let lower = message.lowercased()
        let signals = [
            "429",
            "quota",
            "rate limit",
            "rate-limit",
            "service unavailable",
            "unavailable",
            "cooldown",
        ]
        return signals.contains(where: { lower.contains($0) })
    }

    private func makeNetworkFailureMessage(from error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return "Vision request timed out. Verify the backend is reachable from this phone."
            case NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorNotConnectedToInternet:
                return "Vision backend is unreachable."
            default:
                return "Vision request failed: \(nsError.localizedDescription)"
            }
        }
        return "Vision request failed: \(error.localizedDescription)"
    }
}

extension OllamaVisionService: VisionAnalyzing {
    func analyze(image: UIImage, prompt: String, localSummary: String?) async throws -> VisionAnalysisResult {
        let result = await describeImage(image, sceneSummary: localSummary, prompt: prompt)
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
                    provider: .ollama,
                    message: failure.message,
                    rawResponse: nil
                )
            }
            throw VisionAnalysisError.requestFailed(
                provider: .ollama,
                message: failure.message,
                rawResponse: nil
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
