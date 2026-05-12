import Foundation
import UIKit

#if targetEnvironment(simulator)
private let kIsRunningOnSimulator = true
#else
private let kIsRunningOnSimulator = false
#endif

struct APIConfiguration {
    static let infoPlistKey = "BackendBaseURL"
    static let userDefaultsKey = "settings.backendURL"
    static let fallbackBaseURLString = "http://192.168.1.224:8000"
    static let legacyBaseURLStrings = [
        "http://192.168.1.235:8000",
        "http://192.168.1.234:8000",
    ]

    /// Loopback addresses are only valid when the app runs on the same host as
    /// the backend (the iOS simulator). On a physical iPhone they point at the
    /// phone itself, never at the Mac, so we never offer them as a fallback.
    static var fallbackCandidateBaseURLStrings: [String] {
        var candidates = [fallbackBaseURLString]
        candidates.append(contentsOf: legacyBaseURLStrings)
        if kIsRunningOnSimulator {
            candidates.append("http://127.0.0.1:8000")
            candidates.append("http://localhost:8000")
        }
        return candidates
    }

    static var resolvedBaseURLString: String {
        let storedValue = UserDefaults.standard.string(forKey: userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let storedValue, !storedValue.isEmpty {
            return normalizedBaseURLString(for: storedValue)
        }

        let plistValue = (Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let plistValue, !plistValue.isEmpty {
            return normalizedBaseURLString(for: plistValue)
        }

        return fallbackBaseURLString
    }

    static var resolvedBaseURL: URL? {
        URL(string: resolvedBaseURLString)
    }

    static var candidateBaseURLs: [URL] {
        var seen = Set<String>()
        let candidates = [resolvedBaseURLString] + fallbackCandidateBaseURLStrings
        return candidates.compactMap { value in
            let normalized = normalizedBaseURLString(for: value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else {
                return nil
            }
            return URL(string: normalized)
        }
    }

    static func normalizedBaseURLString(for value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if legacyBaseURLStrings.contains(trimmedValue) {
            return fallbackBaseURLString
        }
        if !kIsRunningOnSimulator, isLoopbackURLString(trimmedValue) {
            return fallbackBaseURLString
        }
        return trimmedValue
    }

    private static func isLoopbackURLString(_ value: String) -> Bool {
        guard let components = URLComponents(string: value), let host = components.host else {
            return false
        }
        let normalizedHost = host.lowercased()
        return normalizedHost == "localhost" || normalizedHost == "127.0.0.1" || normalizedHost == "::1"
    }
}

enum APIClientError: LocalizedError {
    case invalidBaseURL
    case encodingFailed
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case decodingFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Backend base URL is invalid."
        case .encodingFailed:
            return "Failed to encode request body."
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .serverError(_, let message):
            return message
        case .decodingFailed(let message):
            return message
        }
    }
}

struct APIClient {
    private static let chatPathCandidates = [
        "api/ask",
        "ask",
        "api/message",
        "message",
        "chat",
        "api/chat",
    ]

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()

    var baseURLString: String {
        baseURL.absoluteString
    }

    init(baseURL: URL? = APIConfiguration.resolvedBaseURL, session: URLSession? = nil) throws {
        guard let baseURL else {
            throw APIClientError.invalidBaseURL
        }

        self.baseURL = baseURL
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 12
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func health() async throws -> HealthResponse {
        do {
            return try await send(.health, as: HealthResponse.self)
        } catch {
            return try await send(.apiHealth, as: HealthResponse.self)
        }
    }

    func ask(_ request: AskRequest) async throws -> APIResponseDebug<AskResponse> {
        let result = try await sendChat(prompt: request.question, sceneContext: request.sceneContext)
        let response = AskResponse(
            question: request.question,
            answer: result.response.message.text,
            reply: result.response.message.text,
            llmProvider: result.response.llmProvider,
            llmModel: result.response.llmModel
        )
        let debugInfo = BackendRequestDebugInfo(
            endpoint: result.debugInfo.endpoint,
            statusCode: result.debugInfo.statusCode,
            rawResponseBody: result.debugInfo.rawResponseBody,
            parsedReply: response.reply,
            parsedError: nil,
            provider: result.response.llmProvider,
            model: result.response.llmModel
        )
        return APIResponseDebug(response: response, debugInfo: debugInfo)
    }

    func assistant(_ request: AssistantRequest) async throws -> APIResponseDebug<AssistantResponse> {
        try await sendJSONWithDebug(path: "api/assistant", body: request, as: AssistantResponse.self)
    }

    /// One event from `/api/assistant/stream`. Either a token chunk or a metadata event.
    enum AssistantStreamEvent {
        case token(String)
        case provider(name: String, model: String?)
        case fallback(name: String)
    }

    /// Stream assistant tokens + metadata via Server-Sent Events. Yields token + provider
    /// events as they arrive, then returns once the server emits `event: done`.
    func streamAssistant(_ request: AssistantRequest) -> AsyncThrowingStream<AssistantStreamEvent, Error> {
        let baseURL = self.baseURL
        let session = self.session

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let requestURL = baseURL.appending(path: "api/assistant/stream")
                    var urlRequest = URLRequest(url: requestURL)
                    urlRequest.httpMethod = "POST"
                    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    urlRequest.httpBody = try JSONEncoder().encode(request)
                    urlRequest.timeoutInterval = 60

                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200 ..< 300).contains(httpResponse.statusCode) else {
                        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.finish(throwing: APIClientError.serverError(
                            statusCode: statusCode,
                            message: "Streaming endpoint failed."
                        ))
                        return
                    }

                    var currentEvent = "message"
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            currentEvent = "message"
                            continue
                        }
                        if line.hasPrefix("event:") {
                            currentEvent = String(line.dropFirst("event:".count))
                                .trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        if line.hasPrefix("data:") {
                            // SSE format: `data: <payload>` — only the single
                            // separator space after `data:` is part of the
                            // protocol, NOT the payload. Stripping all
                            // whitespace here would erase Ollama tokens like
                            // " there" and run every word together.
                            var payload = String(line.dropFirst("data:".count))
                            if payload.hasPrefix(" ") {
                                payload.removeFirst()
                            }
                            switch currentEvent {
                            case "done":
                                continuation.finish()
                                return
                            case "error":
                                continuation.finish(throwing: APIClientError.serverError(
                                    statusCode: 500,
                                    message: payload
                                ))
                                return
                            case "provider":
                                if let data = payload.data(using: .utf8),
                                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let name = parsed["name"] as? String {
                                    let model = parsed["model"] as? String
                                    continuation.yield(.provider(name: name, model: model))
                                }
                            case "fallback":
                                continuation.yield(.fallback(name: payload))
                            default:
                                continuation.yield(.token(payload))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func diagnostics() async throws -> DiagnosticsResponse {
        let requestURL = baseURL.appending(path: "api/diagnostics")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
        return try decoder.decode(DiagnosticsResponse.self, from: data)
    }

    func appendConversationTurn(role: String, text: String, source: String) async throws {
        let payload = ConversationTurnPayload(role: role, text: text, source: source)
        _ = try await sendJSONWithDebug(
            path: "api/conversation",
            body: payload,
            as: ConversationTurnResponse.self
        )
    }

    func fetchConversationHistory(limit: Int = 40) async throws -> [ConversationTurnResponse] {
        let requestURL = baseURL.appending(path: "api/conversation").appending(queryItems: [URLQueryItem(name: "limit", value: String(limit))])
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
        return try decoder.decode(ConversationHistoryResponse.self, from: data).turns
    }

    func clearConversationHistory() async throws {
        let requestURL = baseURL.appending(path: "api/conversation")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
    }

    func quickAction(_ request: QuickActionRequest) async throws -> APIResponseDebug<QuickActionResponse> {
        try await sendJSONWithDebug(path: "api/quick-actions", body: request, as: QuickActionResponse.self)
    }

    func internetSearch(_ request: InternetSearchRequest) async throws -> APIResponseDebug<InternetSearchResponse> {
        try await sendJSONWithDebug(path: "api/internet/search", body: request, as: InternetSearchResponse.self)
    }

    func imageInternetSearch(
        image: UIImage,
        query: String,
        sceneSummary: String?,
        mode: String = "image"
    ) async throws -> APIResponseDebug<InternetSearchResponse> {
        guard let imageData = image.jpegData(compressionQuality: 0.85) else {
            throw APIClientError.encodingFailed
        }

        let path = "api/internet/image-search"
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        request.httpBody = makeImageSearchMultipartBody(
            boundary: boundary,
            imageData: imageData,
            query: query,
            sceneSummary: sceneSummary,
            mode: mode
        )

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validate(response: response, data: data)
        let rawResponseBody = redactedBody(from: data)
        do {
            let decodedResponse = try decoder.decode(InternetSearchResponse.self, from: data)
            let debugInfo = BackendRequestDebugInfo(
                endpoint: "/\(path)",
                statusCode: httpResponse.statusCode,
                rawResponseBody: rawResponseBody,
                parsedReply: decodedResponse.summary,
                parsedError: nil,
                provider: decodedResponse.provider,
                model: decodedResponse.mode
            )
            return APIResponseDebug(response: decodedResponse, debugInfo: debugInfo)
        } catch {
            throw APIClientError.decodingFailed(
                message: "Decoding failed for /\(path) (\(httpResponse.statusCode)): \(error.localizedDescription)"
            )
        }
    }

    func recordEvent(_ request: InteractionEventRequest) async throws {
        _ = try await sendJSONWithDebug(path: "api/events", body: request, as: InteractionEventResponse.self)
    }

    func personalizationProfile() async throws -> PersonalizationProfileResponse {
        let requestURL = baseURL.appending(path: "api/personalization")
        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
        return try decoder.decode(PersonalizationProfileResponse.self, from: data)
    }

    /// Persist a remembered note as a real backend memory.
    func remember(_ request: RememberRequest) async throws -> RememberResponse {
        let payload = MemoryCreatePayload(
            summary: request.memory,
            transcript: request.memory,
            timestamp: Self.iso8601Formatter.string(from: Date())
        )
        let result = try await sendJSONWithDebug(
            path: "api/memories",
            body: payload,
            as: MemoryCreatePayloadResponse.self
        )
        let summary = result.response.summary ?? request.memory
        return RememberResponse(status: "ok", message: "Saved this memory: \(summary)")
    }

    func recall(_ request: RecallRequest) async throws -> RecallResponse {
        let prompt = buildPrompt(
            primaryText: request.query,
            sceneContext: nil,
            instruction: "Use prior conversation history if helpful when answering this recall request."
        )
        let result = try await sendChat(prompt: prompt, sceneContext: nil)
        return RecallResponse(results: nil, reply: result.response.message.text, memories: nil)
    }

    func summariseDay(_ request: SummariseDayRequest) async throws -> SummariseDayResponse {
        let dayInstruction: String
        if let date = request.date?.trimmingCharacters(in: .whitespacesAndNewlines), !date.isEmpty {
            dayInstruction = "Summarise my day for \(date)."
        } else {
            dayInstruction = "Summarise my day."
        }
        let result = try await sendChat(prompt: dayInstruction, sceneContext: nil)
        return SummariseDayResponse(summary: result.response.message.text, reply: result.response.message.text)
    }

    private func send<Response: Decodable>(_ endpoint: APIEndpoint, as type: Response.Type) async throws -> Response {
        let request = try makeRequest(for: endpoint)
        let (data, response) = try await session.data(for: request)
        _ = try validate(response: response, data: data)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw makeDecodingError(error, data: data, endpoint: endpoint)
        }
    }

    private func sendJSONWithDebug<RequestBody: Encodable, Response: Decodable>(
        path: String,
        body: RequestBody,
        as type: Response.Type
    ) async throws -> APIResponseDebug<Response> {
        let requestURL = baseURL.appending(path: path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        if path.hasPrefix("api/internet/") {
            request.timeoutInterval = 45
        }

        let (data, response) = try await session.data(for: request)
        let httpResponse = try validate(response: response, data: data)
        let rawResponseBody = redactedBody(from: data)
        do {
            let decodedResponse = try decoder.decode(Response.self, from: data)
            let debugInfo = BackendRequestDebugInfo(
                endpoint: "/\(path)",
                statusCode: httpResponse.statusCode,
                rawResponseBody: rawResponseBody,
                parsedReply: extractParsedReply(from: decodedResponse),
                parsedError: nil,
                provider: extractProvider(from: decodedResponse),
                model: extractModel(from: decodedResponse)
            )
            return APIResponseDebug(response: decodedResponse, debugInfo: debugInfo)
        } catch {
            throw APIClientError.decodingFailed(
                message: "Decoding failed for /\(path) (\(httpResponse.statusCode)): \(error.localizedDescription)"
            )
        }
    }

    private func sendChat(prompt: String, sceneContext: String?) async throws -> APIResponseDebug<ChatBackendResponse> {
        var lastError: Error?

        for path in Self.chatPathCandidates {
            let requestURL = baseURL.appending(path: path)

            var request = URLRequest(url: requestURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try makeChatPayload(for: path, prompt: prompt, sceneContext: sceneContext)

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw APIClientError.invalidResponse
                }

                let rawResponseBody = redactedBody(from: data)
                guard (200 ..< 300).contains(httpResponse.statusCode) else {
                    let serverError = APIClientError.serverError(statusCode: httpResponse.statusCode, message: rawResponseBody)
                    if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                        lastError = serverError
                        continue
                    }
                    throw serverError
                }

                let decodedResponse = try decodeChatResponse(from: data, path: path, rawResponseBody: rawResponseBody)

                let debugInfo = BackendRequestDebugInfo(
                    endpoint: "/\(path)",
                    statusCode: httpResponse.statusCode,
                    rawResponseBody: rawResponseBody,
                    parsedReply: decodedResponse.message.text,
                    parsedError: nil,
                    provider: decodedResponse.llmProvider,
                    model: decodedResponse.llmModel
                )
                return APIResponseDebug(response: decodedResponse, debugInfo: debugInfo)
            } catch let error as APIClientError {
                if case let .serverError(statusCode, _) = error,
                   statusCode != 404,
                   statusCode != 405 {
                    throw error
                }
                lastError = error
            } catch let error as URLError {
                throw error
            } catch {
                lastError = error
            }
        }

        throw lastError ?? APIClientError.serverError(statusCode: 404, message: "No compatible chat endpoint was found.")
    }

    private func makeChatPayload(for path: String, prompt: String, sceneContext: String?) throws -> Data {
        let encoder = JSONEncoder()

        switch path {
        case "ask", "api/ask":
            return try encoder.encode(AskRequest(question: prompt, sceneContext: sceneContext))
        case "message", "api/message":
            return try encoder.encode(MessageRequest(message: prompt))
        default:
            return try encoder.encode(
                ChatBackendRequest(
                    prompt: prompt,
                    conversationID: nil,
                    sourceMetadata: "watersheep-ios"
                )
            )
        }
    }

    private func decodeChatResponse(from data: Data, path: String, rawResponseBody: String) throws -> ChatBackendResponse {
        if let decoded = try? decoder.decode(ChatBackendResponse.self, from: data) {
            return decoded
        }

        if let decoded = try? decoder.decode(AskResponse.self, from: data) {
            return ChatBackendResponse(
                conversationID: nil,
                message: ChatBackendMessage(text: decoded.reply),
                llmProvider: decoded.llmProvider,
                llmModel: decoded.llmModel
            )
        }

        if let decoded = try? decoder.decode(BackendReplyResponse.self, from: data) {
            return ChatBackendResponse(
                conversationID: nil,
                message: ChatBackendMessage(text: decoded.reply)
            )
        }

        let message = "No compatible reply shape found for /\(path)."
        throw APIClientError.decodingFailed(message: message)
    }

    private func makeRequest(for endpoint: APIEndpoint) throws -> URLRequest {
        let requestURL = baseURL.appending(path: endpoint.path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = endpoint.method

        if endpoint.body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        if case .health = endpoint {
            request.httpBody = nil
        } else if let body = endpoint.body {
            request.httpBody = body
        } else {
            throw APIClientError.encodingFailed
        }

        return request
    }

    private func validate(response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown backend error"
            throw APIClientError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        return httpResponse
    }

    private func extractParsedReply<Response>(from response: Response) -> String? {
        if let askResponse = response as? AskResponse {
            return askResponse.reply
        }
        if let chatResponse = response as? ChatBackendResponse {
            return chatResponse.message.text
        }
        if let assistantResponse = response as? AssistantResponse {
            return assistantResponse.assistantMessage
        }
        if let quickActionResponse = response as? QuickActionResponse {
            return quickActionResponse.assistantMessage
        }
        if let internetSearchResponse = response as? InternetSearchResponse {
            return internetSearchResponse.summary
        }
        if let healthResponse = response as? HealthResponse {
            return healthResponse.message ?? healthResponse.status
        }
        return nil
    }

    private func extractProvider<Response>(from response: Response) -> String? {
        if let askResponse = response as? AskResponse {
            return askResponse.llmProvider
        }
        if let chatResponse = response as? ChatBackendResponse {
            return chatResponse.llmProvider
        }
        if let assistantResponse = response as? AssistantResponse {
            return assistantResponse.llmProvider
        }
        if let quickActionResponse = response as? QuickActionResponse {
            return quickActionResponse.llmProvider
        }
        if let internetSearchResponse = response as? InternetSearchResponse {
            return internetSearchResponse.provider
        }
        return nil
    }

    private func extractModel<Response>(from response: Response) -> String? {
        if let askResponse = response as? AskResponse {
            return askResponse.llmModel
        }
        if let chatResponse = response as? ChatBackendResponse {
            return chatResponse.llmModel
        }
        if let assistantResponse = response as? AssistantResponse {
            return assistantResponse.llmModel
        }
        if let quickActionResponse = response as? QuickActionResponse {
            return quickActionResponse.llmModel
        }
        if let internetSearchResponse = response as? InternetSearchResponse {
            return internetSearchResponse.mode
        }
        return nil
    }

    private func makeImageSearchMultipartBody(
        boundary: String,
        imageData: Data,
        query: String,
        sceneSummary: String?,
        mode: String
    ) -> Data {
        var body = Data()

        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"file\"; filename=\"frame.jpg\"\r\n")
        body.appendUTF8("Content-Type: image/jpeg\r\n\r\n")
        body.append(imageData)
        body.appendUTF8("\r\n")

        appendMultipartField(into: &body, boundary: boundary, name: "query", value: query)
        appendMultipartField(into: &body, boundary: boundary, name: "mode", value: mode)
        if let sceneSummary, !sceneSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            appendMultipartField(into: &body, boundary: boundary, name: "scene_summary", value: sceneSummary)
        }

        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }

    private func appendMultipartField(into body: inout Data, boundary: String, name: String, value: String) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8(value)
        body.appendUTF8("\r\n")
    }

    private func redactedBody(from data: Data) -> String {
        guard let raw = String(data: data, encoding: .utf8) else { return "" }
        if raw.count > 4096 {
            return String(raw.prefix(4093)) + "..."
        }
        return raw
    }

    private func makeDecodingError(_ error: Error, data: Data, endpoint: APIEndpoint) -> APIClientError {
        let message = "Decoding failed for /\(endpoint.path): \(error.localizedDescription)"
        return .decodingFailed(message: message)
    }

    private func buildPrompt(primaryText: String, sceneContext: String?, instruction: String?) -> String {
        var sections: [String] = []

        if let instruction, !instruction.isEmpty {
            sections.append(instruction)
        }

        sections.append(primaryText)

        if let sceneContext, !sceneContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("Context:\n\(sceneContext)")
        }

        return sections.joined(separator: "\n\n")
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct MemoryCreatePayload: Encodable {
    let summary: String
    let transcript: String?
    let timestamp: String
}

private struct MemoryCreatePayloadResponse: Decodable {
    let id: Int?
    let summary: String?
    let timestamp: String?
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(Data(string.utf8))
    }
}
