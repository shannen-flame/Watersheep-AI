import Foundation
import UIKit

enum BackendClientError: LocalizedError {
    case invalidBaseURL
    case invalidImageData
    case invalidResponse
    case requestFailed(endpoint: String, statusCode: Int, rawBody: String)
    case decodingFailed(endpoint: String, statusCode: Int, rawBody: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Backend base URL is invalid."
        case .invalidImageData:
            return "Unable to prepare image data for upload."
        case .invalidResponse:
            return "Backend returned an invalid response."
        case let .requestFailed(endpoint, statusCode, _):
            return "Request to \(endpoint) failed with HTTP \(statusCode)."
        case let .decodingFailed(endpoint, statusCode, _, underlying):
            return "Could not decode \(endpoint) response (HTTP \(statusCode)): \(underlying.localizedDescription)"
        }
    }
}

struct BackendClient {
    static let fallbackBaseURLString = APIConfiguration.fallbackBaseURLString
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

    var baseURLString: String {
        baseURL.absoluteString
    }

    init(baseURL: URL? = APIConfiguration.resolvedBaseURL, session: URLSession = .shared) throws {
        guard let baseURL else {
            throw BackendClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.session = session
        print("Watersheep backend URL: \(baseURL.absoluteString)")
    }

    func fetchGraphHTML() async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/graph/html"))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BackendClientError.invalidResponse
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func healthCheck() async throws {
        do {
            let request = makeRequest(path: "health", method: "GET")
            _ = try await perform(request, endpoint: "/health")
        } catch {
            let request = makeRequest(path: "api/health", method: "GET")
            _ = try await perform(request, endpoint: "/api/health")
        }
    }

    func saveMemory(summary: String, transcript: String?, sceneContext: String?) async throws -> SaveMemoryResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = SaveMemoryRequest(
            summary: summary,
            transcript: transcript,
            location: sceneContext,
            timestamp: formatter.string(from: Date())
        )

        var request = makeRequest(path: "api/memories", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }

        let rawBody = String(data: data, encoding: .utf8) ?? ""
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BackendClientError.requestFailed(
                endpoint: "/api/memories",
                statusCode: httpResponse.statusCode,
                rawBody: rawBody
            )
        }

        do {
            return try JSONDecoder().decode(SaveMemoryResponse.self, from: data)
        } catch {
            throw BackendClientError.decodingFailed(
                endpoint: "/api/memories",
                statusCode: httpResponse.statusCode,
                rawBody: rawBody,
                underlying: error
            )
        }
    }

    func message(_ text: String) async throws -> BackendRequestDebugInfo {
        try await performChat(prompt: text, endpoint: "/chat")
    }

    func sceneAssist(scene: String, userMessage: String) async throws -> BackendRequestDebugInfo {
        do {
            return try await performAssistant(message: userMessage, sceneContext: scene)
        } catch {
            print("Watersheep scene assist /api/assistant failed, falling back to compatibility chat: \(error.localizedDescription)")
        }

        let prompt = """
        Scene:
        \(scene)

        User request:
        \(userMessage)
        """
        return try await performChat(prompt: prompt, endpoint: "/chat")
    }

    private func performAssistant(message: String, sceneContext: String) async throws -> BackendRequestDebugInfo {
        var request = makeRequest(path: "api/assistant", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            AssistantRequest(
                message: message,
                sceneContext: sceneContext,
                source: "scene_assist"
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }

        let rawBody = String(data: data, encoding: .utf8) ?? ""
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BackendClientError.requestFailed(
                endpoint: "/api/assistant",
                statusCode: httpResponse.statusCode,
                rawBody: rawBody
            )
        }

        do {
            let decoded = try JSONDecoder().decode(AssistantResponse.self, from: data)
            return BackendRequestDebugInfo(
                endpoint: "/api/assistant",
                statusCode: httpResponse.statusCode,
                rawResponseBody: redact(rawBody),
                parsedReply: decoded.assistantMessage,
                parsedError: nil,
                provider: decoded.llmProvider,
                model: decoded.llmModel
            )
        } catch {
            throw BackendClientError.decodingFailed(
                endpoint: "/api/assistant",
                statusCode: httpResponse.statusCode,
                rawBody: rawBody,
                underlying: error
            )
        }
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let requestURL = baseURL.appending(path: path)
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        return request
    }

    private func performChat(prompt: String, endpoint: String) async throws -> BackendRequestDebugInfo {
        var lastError: Error?

        for path in Self.chatPathCandidates {
            let attemptedEndpoint = "/\(path)"
            var request = makeRequest(path: path, method: "POST")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try makeChatPayload(for: path, prompt: prompt)

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BackendClientError.invalidResponse
                }

                let rawBody = String(data: data, encoding: .utf8) ?? ""
                print("Watersheep HTTP status (\(attemptedEndpoint)): \(httpResponse.statusCode)")

                guard (200 ..< 300).contains(httpResponse.statusCode) else {
                    let requestError = BackendClientError.requestFailed(
                        endpoint: attemptedEndpoint,
                        statusCode: httpResponse.statusCode,
                        rawBody: rawBody
                    )
                    if httpResponse.statusCode == 404 || httpResponse.statusCode == 405 {
                        lastError = requestError
                        continue
                    }
                    throw requestError
                }

                do {
                    let reply = try decodeReplyMetadata(
                        from: data,
                        endpoint: attemptedEndpoint,
                        statusCode: httpResponse.statusCode,
                        rawBody: rawBody
                    )
                    return BackendRequestDebugInfo(
                        endpoint: attemptedEndpoint,
                        statusCode: httpResponse.statusCode,
                        rawResponseBody: redact(rawBody),
                        parsedReply: reply.text,
                        parsedError: nil,
                        provider: reply.provider,
                        model: reply.model
                    )
                } catch {
                    throw BackendClientError.decodingFailed(
                        endpoint: attemptedEndpoint,
                        statusCode: httpResponse.statusCode,
                        rawBody: rawBody,
                        underlying: error
                    )
                }
            } catch let error as BackendClientError {
                if case let .requestFailed(_, statusCode, _) = error,
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

        throw lastError ?? BackendClientError.requestFailed(
            endpoint: endpoint,
            statusCode: 404,
            rawBody: "No compatible chat endpoint was found."
        )
    }

    private func makeChatPayload(for path: String, prompt: String) throws -> Data {
        let encoder = JSONEncoder()

        switch path {
        case "ask", "api/ask":
            return try encoder.encode(AskRequest(question: prompt))
        case "message", "api/message":
            return try encoder.encode(MessageRequest(message: prompt))
        default:
            return try encoder.encode(
                ChatBackendRequest(
                    prompt: prompt,
                    conversationID: nil,
                    sourceMetadata: "watersheep-ios-legacy"
                )
            )
        }
    }

    private func decodeReplyMetadata(
        from data: Data,
        endpoint: String,
        statusCode: Int,
        rawBody: String
    ) throws -> (text: String, provider: String?, model: String?) {
        let decoder = JSONDecoder()

        if let decoded = try? decoder.decode(ChatBackendResponse.self, from: data) {
            return (decoded.message.text, decoded.llmProvider, decoded.llmModel)
        }

        if let decoded = try? decoder.decode(AskResponse.self, from: data) {
            return (decoded.reply, decoded.llmProvider, decoded.llmModel)
        }

        if let decoded = try? decoder.decode(BackendReplyResponse.self, from: data) {
            return (decoded.reply, nil, nil)
        }

        throw BackendClientError.decodingFailed(
            endpoint: endpoint,
            statusCode: statusCode,
            rawBody: rawBody,
            underlying: NSError(
                domain: "BackendClient",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No compatible reply shape found."]
            )
        )
    }

    private func perform(_ request: URLRequest, endpoint: String) async throws -> BackendRequestDebugInfo {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw BackendClientError.invalidResponse
            }

            let rawBody = String(data: data, encoding: .utf8) ?? ""

            guard (200 ..< 300).contains(httpResponse.statusCode) else {
                throw BackendClientError.requestFailed(
                    endpoint: endpoint,
                    statusCode: httpResponse.statusCode,
                    rawBody: rawBody
                )
            }

            if let reply = try? JSONDecoder().decode(BackendReplyResponse.self, from: data).reply {
                return BackendRequestDebugInfo(
                    endpoint: endpoint,
                    statusCode: httpResponse.statusCode,
                    rawResponseBody: redact(rawBody),
                    parsedReply: reply,
                    parsedError: nil
                )
            }

            return BackendRequestDebugInfo(
                endpoint: endpoint,
                statusCode: httpResponse.statusCode,
                rawResponseBody: redact(rawBody),
                parsedReply: nil,
                parsedError: nil
            )
        } catch {
            throw error
        }
    }

    private func redact(_ rawBody: String) -> String {
        if rawBody.count > 4096 {
            return String(rawBody.prefix(4093)) + "..."
        }
        return rawBody
    }
}

private struct SaveMemoryRequest: Encodable {
    let summary: String
    let transcript: String?
    let location: String?
    let timestamp: String
}

struct SaveMemoryResponse: Decodable {
    let id: Int?
    let summary: String?
    let timestamp: String?
}
