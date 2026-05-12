import Foundation

struct ChatBackendRequest: Codable {
    let prompt: String
    let conversationID: UUID?
    let sourceMetadata: String?

    init(prompt: String, conversationID: UUID? = nil, sourceMetadata: String? = nil) {
        self.prompt = prompt
        self.conversationID = conversationID
        self.sourceMetadata = sourceMetadata
    }
}

struct ChatBackendMessage: Decodable {
    let text: String

    private enum CodingKeys: String, CodingKey {
        case text
        case content
        case message
        case reply
        case response
        case detail
        case assistantMessage = "assistant_message"
    }

    init(text: String) {
        self.text = text
    }

    init(from decoder: Decoder) throws {
        if let singleValue = try? decoder.singleValueContainer(),
           let text = try? singleValue.decode(String.self)
        {
            self.text = text
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let text = try container.decodeIfPresent(String.self, forKey: .text) {
            self.text = text
            return
        }

        if let text = try container.decodeIfPresent(String.self, forKey: .content) {
            self.text = text
            return
        }

        if let text = try container.decodeIfPresent(String.self, forKey: .message) {
            self.text = text
            return
        }

        if let text = try container.decodeIfPresent(String.self, forKey: .reply) {
            self.text = text
            return
        }

        if let text = try container.decodeIfPresent(String.self, forKey: .response) {
            self.text = text
            return
        }

        if let text = try container.decodeIfPresent(String.self, forKey: .detail) {
            self.text = text
            return
        }

        if let text = try container.decodeIfPresent(String.self, forKey: .assistantMessage) {
            self.text = text
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .text,
            in: container,
            debugDescription: "Missing chat message text"
        )
    }
}

struct ChatBackendResponse: Decodable {
    let conversationID: UUID?
    let message: ChatBackendMessage
    let llmProvider: String?
    let llmModel: String?

    private enum CodingKeys: String, CodingKey {
        case conversationID
        case conversationId = "conversation_id"
        case id
        case message
        case reply
        case response
        case detail
        case assistantMessage = "assistant_message"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
    }

    init(conversationID: UUID?, message: ChatBackendMessage, llmProvider: String? = nil, llmModel: String? = nil) {
        self.conversationID = conversationID
        self.message = message
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        conversationID =
            try container.decodeIfPresent(UUID.self, forKey: .conversationID)
            ?? container.decodeIfPresent(UUID.self, forKey: .conversationId)
            ?? container.decodeIfPresent(UUID.self, forKey: .id)
        llmProvider = try container.decodeIfPresent(String.self, forKey: .llmProvider)
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel)

        if let message = try container.decodeIfPresent(ChatBackendMessage.self, forKey: .message) {
            self.message = message
            return
        }

        if let reply = try container.decodeIfPresent(String.self, forKey: .reply)
            ?? container.decodeIfPresent(String.self, forKey: .response)
            ?? container.decodeIfPresent(String.self, forKey: .detail)
            ?? container.decodeIfPresent(String.self, forKey: .assistantMessage)
        {
            self.message = ChatBackendMessage(text: reply)
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .message,
            in: container,
            debugDescription: "Missing chat response message"
        )
    }
}

struct Memory: Codable, Identifiable {
    let id: UUID
    let memory: String
    let timestamp: String?
    let type: String?

    init(id: UUID = UUID(), memory: String, timestamp: String? = nil, type: String? = nil) {
        self.id = id
        self.memory = memory
        self.timestamp = timestamp
        self.type = type
    }

    private enum CodingKeys: String, CodingKey {
        case memory
        case timestamp
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        memory = try container.decode(String.self, forKey: .memory)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        type = try container.decodeIfPresent(String.self, forKey: .type)
    }
}

struct HealthResponse: Decodable {
    let status: String?
    let message: String?
    let service: String?
    let version: String?
    let activeAIProvider: String?
    let environment: String?
}

struct AskRequest: Codable {
    let question: String
    let sceneContext: String?
    let memoryLimit: Int

    private enum CodingKeys: String, CodingKey {
        case question
        case sceneContext = "scene_context"
        case memoryLimit = "memory_limit"
    }

    init(question: String, sceneContext: String? = nil, memoryLimit: Int = 3) {
        self.question = question
        self.sceneContext = sceneContext
        self.memoryLimit = memoryLimit
    }
}

struct AssistantRequest: Codable {
    let message: String
    let sceneContext: String?
    let source: String
    let llmProvider: String?
    let llmModel: String?

    init(
        message: String,
        sceneContext: String? = nil,
        source: String,
        llmProvider: String? = nil,
        llmModel: String? = nil
    ) {
        self.message = message
        self.sceneContext = sceneContext
        self.source = source
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }

    private enum CodingKeys: String, CodingKey {
        case message
        case sceneContext = "scene_context"
        case source
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
    }
}

struct AssistantResponse: Decodable {
    let assistantMessage: String
    let intent: String
    let shouldSpeak: Bool
    let usedMemories: [Memory]
    let actionResult: [String: String]?
    let suggestedActions: [String]
    let llmProvider: String?
    let llmModel: String?

    private enum CodingKeys: String, CodingKey {
        case assistantMessage = "assistant_message"
        case intent
        case shouldSpeak = "should_speak"
        case usedMemories = "used_memories"
        case actionResult = "action_result"
        case suggestedActions = "suggested_actions"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
    }
}

struct InternetSearchRequest: Codable {
    let query: String
    let mode: String
    let sceneContext: String?
    let imageBase64: String?
    let provider: String?
    let maxResults: Int

    init(
        query: String,
        mode: String = "web",
        sceneContext: String? = nil,
        imageBase64: String? = nil,
        provider: String? = nil,
        maxResults: Int = 5
    ) {
        self.query = query
        self.mode = mode
        self.sceneContext = sceneContext
        self.imageBase64 = imageBase64
        self.provider = provider
        self.maxResults = maxResults
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case mode
        case sceneContext = "scene_context"
        case imageBase64 = "image_base64"
        case provider
        case maxResults = "max_results"
    }
}

struct InternetSearchResultItem: Decodable, Identifiable, Equatable {
    let id = UUID()
    let title: String
    let summary: String
    let url: String
    let source: String
    let confidence: Double

    private enum CodingKeys: String, CodingKey {
        case title
        case summary
        case url
        case source
        case confidence
    }
}

struct InternetSearchResponse: Decodable {
    let query: String
    let mode: String
    let summary: String
    let results: [InternetSearchResultItem]
    let provider: String
    let confidence: Double
    let exactMatch: Bool
    let imageKeywords: String?

    private enum CodingKeys: String, CodingKey {
        case query
        case mode
        case summary
        case results
        case provider
        case confidence
        case exactMatch = "exact_match"
        case imageKeywords = "image_keywords"
    }
}

struct QuickActionRequest: Codable {
    let actionID: String
    let sceneContext: String?
    let source: String

    private enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case sceneContext = "scene_context"
        case source
    }
}

struct QuickActionResponse: Decodable {
    let actionID: String
    let status: String
    let assistantMessage: String
    let shouldSpeak: Bool
    let suggestedActions: [String]
    let llmProvider: String?
    let llmModel: String?

    private enum CodingKeys: String, CodingKey {
        case actionID = "action_id"
        case status
        case assistantMessage = "assistant_message"
        case shouldSpeak = "should_speak"
        case suggestedActions = "suggested_actions"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
    }
}

struct InteractionEventRequest: Codable {
    let eventType: String
    let source: String
    let payload: [String: String]

    private enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case source
        case payload
    }
}

struct InteractionEventResponse: Decodable {
    let id: Int
    let eventType: String
    let source: String
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case source
        case createdAt = "created_at"
    }
}

struct PersonalizationProfileResponse: Decodable {
    let suggestedActions: [String]
    let preferredResponseStyle: String
    let eventCount: Int

    private enum CodingKeys: String, CodingKey {
        case suggestedActions = "suggested_actions"
        case preferredResponseStyle = "preferred_response_style"
        case eventCount = "event_count"
    }
}

struct MessageRequest: Codable {
    let message: String
}

struct RememberRequest: Codable {
    let memory: String
}

struct RecallRequest: Codable {
    let query: String
}

struct SummariseDayRequest: Codable {
    let date: String?

    init(date: String? = nil) {
        self.date = date
    }
}

struct AskResponse: Decodable {
    let question: String?
    let answer: String?
    let reply: String
    let usedMemories: [Memory]?
    let llmProvider: String?
    let llmModel: String?

    init(
        question: String? = nil,
        answer: String? = nil,
        reply: String,
        usedMemories: [Memory]? = nil,
        llmProvider: String? = nil,
        llmModel: String? = nil
    ) {
        self.question = question
        self.answer = answer
        self.reply = reply
        self.usedMemories = usedMemories
        self.llmProvider = llmProvider
        self.llmModel = llmModel
    }

    private enum CodingKeys: String, CodingKey {
        case question
        case answer
        case reply
        case response
        case message
        case assistantMessage = "assistant_message"
        case usedMemories = "used_memories"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        question = try container.decodeIfPresent(String.self, forKey: .question)
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
        usedMemories = try AskResponse.decodeUsedMemories(from: container)
        llmProvider = try container.decodeIfPresent(String.self, forKey: .llmProvider)
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel)

        if let reply = try container.decodeIfPresent(String.self, forKey: .reply) {
            self.reply = reply
        } else if let answer = try container.decodeIfPresent(String.self, forKey: .answer) {
            self.reply = answer
        } else if let assistantMessage = try container.decodeIfPresent(String.self, forKey: .assistantMessage) {
            self.reply = assistantMessage
        } else if let response = try container.decodeIfPresent(String.self, forKey: .response) {
            self.reply = response
        } else if let message = try container.decodeIfPresent(String.self, forKey: .message) {
            self.reply = message
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .reply,
                in: container,
                debugDescription: "Missing reply field"
            )
        }
    }

    private static func decodeUsedMemories(from container: KeyedDecodingContainer<CodingKeys>) throws -> [Memory]? {
        guard container.contains(.usedMemories) else { return nil }
        if try container.decodeNil(forKey: .usedMemories) {
            return nil
        }
        if let memoryString = try? container.decode(String.self, forKey: .usedMemories) {
            return [Memory(memory: memoryString, timestamp: nil, type: nil)]
        }
        if let memories = try? container.decode([Memory].self, forKey: .usedMemories) {
            return memories
        }
        if let memory = try? container.decode(Memory.self, forKey: .usedMemories) {
            return [memory]
        }
        return nil
    }
}

struct RememberResponse: Decodable {
    let status: String?
    let message: String?

    init(status: String? = nil, message: String? = nil) {
        self.status = status
        self.message = message
    }
}

struct RecallResponse: Decodable {
    let results: [String]?
    let reply: String?
    let memories: [String]?

    init(results: [String]? = nil, reply: String? = nil, memories: [String]? = nil) {
        self.results = results
        self.reply = reply
        self.memories = memories
    }
}

struct SummariseDayResponse: Decodable {
    let summary: String?
    let reply: String?

    init(summary: String? = nil, reply: String? = nil) {
        self.summary = summary
        self.reply = reply
    }
}

struct ConversationTurnPayload: Encodable {
    let role: String
    let text: String
    let source: String
}

struct ConversationTurnResponse: Decodable, Identifiable {
    let id: Int
    let role: String
    let text: String
    let source: String
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case source
        case createdAt = "created_at"
    }
}

struct ConversationHistoryResponse: Decodable {
    let count: Int
    let turns: [ConversationTurnResponse]
}

struct DiagnosticsProviderHealth: Decodable {
    let available: Bool
    let detail: String
    let latencyMs: Int?
    let models: [String]?
    let expectedModel: String?
    let expectedModelAvailable: Bool?

    private enum CodingKeys: String, CodingKey {
        case available
        case detail
        case latencyMs = "latency_ms"
        case models
        case expectedModel = "expected_model"
        case expectedModelAvailable = "expected_model_available"
    }
}

struct DiagnosticsResponse: Decodable {
    let status: String
    let appName: String
    let environment: String
    let ollama: DiagnosticsProviderHealth
    let gemini: DiagnosticsProviderHealth
    let openrouter: DiagnosticsProviderHealth?
    let database: DiagnosticsProviderHealth
    let corsOrigins: [String]
    let debugEndpointsEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case status
        case appName = "app_name"
        case environment
        case ollama
        case gemini
        case openrouter
        case database
        case corsOrigins = "cors_origins"
        case debugEndpointsEnabled = "debug_endpoints_enabled"
    }
}

struct BackendReplyResponse: Decodable {
    let reply: String

    private enum CodingKeys: String, CodingKey {
        case reply
        case response
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let reply = try container.decodeIfPresent(String.self, forKey: .reply) {
            self.reply = reply
        } else if let response = try container.decodeIfPresent(String.self, forKey: .response) {
            self.reply = response
        } else if let message = try container.decodeIfPresent(String.self, forKey: .message) {
            self.reply = message
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .reply,
                in: container,
                debugDescription: "Missing reply field"
            )
        }
    }
}

struct BackendRequestDebugInfo {
    let endpoint: String
    let statusCode: Int
    let rawResponseBody: String
    let parsedReply: String?
    let parsedError: String?
    let provider: String?
    let model: String?

    init(
        endpoint: String,
        statusCode: Int,
        rawResponseBody: String,
        parsedReply: String?,
        parsedError: String?,
        provider: String? = nil,
        model: String? = nil
    ) {
        self.endpoint = endpoint
        self.statusCode = statusCode
        self.rawResponseBody = rawResponseBody
        self.parsedReply = parsedReply
        self.parsedError = parsedError
        self.provider = provider
        self.model = model
    }
}

struct APIResponseDebug<Response> {
    let response: Response
    let debugInfo: BackendRequestDebugInfo
}
