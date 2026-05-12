import Combine
import MWDATCore
import SwiftUI
import UserNotifications

struct ConversationTurn: Identifiable, Equatable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    let text: String
    let timestamp: Date

    init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = .now) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
}

struct LocalReminderRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let triggerDate: Date
    let createdAt: Date
    let sourceCommand: String

    init(id: UUID = UUID(), title: String, triggerDate: Date, createdAt: Date = .now, sourceCommand: String) {
        self.id = id
        self.title = title
        self.triggerDate = triggerDate
        self.createdAt = createdAt
        self.sourceCommand = sourceCommand
    }
}

struct ProviderUsageRecord: Identifiable, Equatable {
    let id = UUID()
    let task: String
    let provider: String
    let model: String
    let detail: String
    let timestamp: Date
}

struct DetectedActionableItem: Identifiable, Equatable {
    enum Kind: String {
        case url
        case phoneNumber
        case date
    }

    let id = UUID()
    let kind: Kind
    let value: String
    let displayText: String
}

enum AssistantActionState: Equatable {
    case idle
    case loading
    case succeeded(String)
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

@MainActor
final class GlassesStreamManager: ObservableObject {
    private enum AIVisionConstants {
        // 10 s between frames = max ~6 RPM, leaving headroom for chat calls
        // on the Gemini free tier (15 RPM total).
        static let uploadIntervalSeconds: Double = 10
        static let fallbackCooldownSeconds: Int = 60
    }

    private enum ReminderConstants {
        static let storageKey = "watersheep.localReminders"
        static let defaultInterval: TimeInterval = 3600
    }

    @Published var isPrivacyModeEnabled = false {
        didSet { handlePrivacyModeChange() }
    }
    @Published var isAIVisionEnabled = false
    @Published var currentScene = "AI Vision is off."
    @Published var latestAssistantReply = "No assistant reply yet."
    @Published var detectedActionableItems: [DetectedActionableItem] = []
    @Published private(set) var isStreamingReply = false
    /// Most recent LLM provider name that produced an assistant reply
    /// (`ollama`, `gemini`, `openrouter`, or empty when nothing has answered yet).
    @Published private(set) var lastChatProvider: String = ""
    @Published private(set) var lastChatModel: String = ""
    @Published var isAnalyzingFrame = false
    @Published var isRequestingHelp = false
    @Published var loadedBackendBaseURL = APIConfiguration.fallbackBaseURLString
    @Published var backendHealthStatus = "Backend Not Reachable"
    @Published var lastNetworkError: String?
    @Published var lastBackendEndpointCalled = "None"
    @Published var lastBackendStatusCode = "None"
    @Published var lastBackendRawResponse = "None"
    @Published var lastBackendParsedReply = "None"
    @Published var isAssistantRequestInProgress = false
    @Published var assistantErrorMessage: String?
    @Published var visionIntentDetected = false
    @Published var aiVisionStatusMessage = "Off"
    @Published var decodedMemoryCount = 0
    @Published var visionProviderUsed = VisionProvider.gemini.rawValue
    @Published var visionFallbackReason = "None"
    @Published var visionRawError = "None"
    @Published var quickActionStates: [String: AssistantActionState] = [:]
    @Published var suggestedQuickActions: [String] = []
    @Published var internetSearchSummary = ""
    @Published var internetSearchResults: [InternetSearchResultItem] = []
    @Published var isInternetSearchInProgress = false
    @Published var internetSearchError: String?
    @Published private(set) var providerUsageRecords: [ProviderUsageRecord] = []
    @Published private(set) var isStreamRunning = false
    @Published private(set) var hasActiveDevice = false
    @Published private(set) var showStreamError = false
    @Published private(set) var streamErrorMessage = ""
    @Published private(set) var conversationHistory: [ConversationTurn] = []
    @Published private(set) var reminders: [LocalReminderRecord] = []

    let streamViewModel: StreamSessionViewModel

    private var apiClient: APIClient?
    private var backendClient: BackendClient?
    private let speechManager: SpeechManager
    private var ollamaVisionService: OllamaVisionService?
    private var hybridVisionCoordinator: HybridVisionCoordinator
    private var aiLoopTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var visionPausedUntil: Date?
    private var lastAnalyzedFrameCount = 0
    private var currentSceneUpdatedAt: Date?
    private var lastProactiveMemorySaved: Date?
    private var lastProactiveSceneText: String = ""
    private let reminderCenter = UNUserNotificationCenter.current()

    init(
        wearables: WearablesInterface,
        apiClient: APIClient? = nil,
        backendClient: BackendClient? = nil,
        speechManager: SpeechManager? = nil
    ) {
        self.streamViewModel = StreamSessionViewModel(wearables: wearables)
        self.speechManager = speechManager ?? .shared
        self.apiClient = apiClient
        self.backendClient = backendClient
        let initialOllama = try? OllamaVisionService()
        self.ollamaVisionService = initialOllama
        self.hybridVisionCoordinator = HybridVisionCoordinator(
            geminiService: backendClient.flatMap { GeminiVisionService(backendClient: $0) },
            ollamaService: initialOllama
        )
        self.reminders = Self.loadReminders()
        refreshBackendConfiguration()

        streamViewModel.$streamingStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isStreamRunning = status != .stopped
                if status != .streaming || !self.streamViewModel.hasValidFrame {
                    stopAIVisionLoop()
                    if isAIVisionEnabled {
                        currentScene = self.streamViewModel.statusMessage
                        aiVisionStatusMessage = self.streamViewModel.hasReceivedFirstFrame ? "Waiting for camera" : "No frames received"
                    }
                } else if isAIVisionEnabled {
                    startAIVisionLoop()
                }
            }
            .store(in: &cancellables)

        streamViewModel.$hasActiveDevice
            .receive(on: RunLoop.main)
            .sink { [weak self] hasDevice in
                self?.hasActiveDevice = hasDevice
            }
            .store(in: &cancellables)

        streamViewModel.$showError
            .combineLatest(streamViewModel.$errorMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] showError, errorMessage in
                self?.showStreamError = showError
                self?.streamErrorMessage = errorMessage
            }
            .store(in: &cancellables)
    }

    deinit {
        aiLoopTask?.cancel()
    }

    var reminderStatusText: String {
        let upcoming = reminders.filter { $0.triggerDate > .now }
        if upcoming.isEmpty {
            return "No reminders scheduled"
        }
        if upcoming.count == 1, let first = upcoming.first {
            return "1 reminder: \(first.title)"
        }
        return "\(upcoming.count) reminders scheduled"
    }

    func setAIVisionEnabled(_ isEnabled: Bool) {
        let previousValue = isAIVisionEnabled
        isAIVisionEnabled = isEnabled
        handleAIVisionToggleChange(from: previousValue, to: isEnabled)
    }

    func handleAIVisionToggleChange(from previousValue: Bool, to isEnabled: Bool) {
        print("AI Vision toggle changed: old value = \(previousValue), new value = \(isEnabled)")
        lastNetworkError = nil
        visionPausedUntil = nil

        if isEnabled {
            currentSceneUpdatedAt = nil
            currentScene = streamViewModel.hasValidFrame ? "Analyzing current view..." : streamViewModel.statusMessage
            aiVisionStatusMessage = streamViewModel.hasValidFrame ? "On" : "Waiting for camera frames"
            startAIVisionLoop()
            print("AI Vision analysis loop started")
        } else {
            stopAIVisionLoop()
            currentSceneUpdatedAt = nil
            currentScene = "AI Vision is off."
            aiVisionStatusMessage = "Off"
            print("AI Vision analysis loop stopped")
        }
    }

    func startCamera() async {
        print("camera start requested")
        guard hasActiveDevice else {
            streamErrorMessage = "Glasses are registered but not active yet. Wake the glasses, open the hinges, and wait for the app to show they are ready before starting the camera."
            showStreamError = true
            return
        }
        await streamViewModel.handleStartStreaming()
        if isAIVisionEnabled {
            startAIVisionLoop()
        }
        print("camera started")
    }

    func stopCamera() async {
        stopAIVisionLoop()
        await streamViewModel.stopSession()
    }

    func checkBackendHealth() async {
        let clients = APIConfiguration.candidateBaseURLs.compactMap { url -> (URL, APIClient)? in
            guard let client = try? APIClient(baseURL: url) else {
                return nil
            }
            return (url, client)
        }

        var lastError: Error?
        for (url, client) in clients {
            do {
                let response = try await client.health()
                UserDefaults.standard.set(url.absoluteString, forKey: APIConfiguration.userDefaultsKey)
                apiClient = try? APIClient(baseURL: url)
                backendClient = try? BackendClient(baseURL: url)
                loadedBackendBaseURL = url.absoluteString
                backendHealthStatus = "Backend Connected"
                lastNetworkError = response.message
                appendConversationTurn(role: .system, text: "Backend health check succeeded.")
                return
            } catch {
                lastError = error
            }
        }

        backendHealthStatus = "Backend Not Reachable"
        lastNetworkError = lastError.map { String(describing: $0) }
            ?? APIClientError.invalidBaseURL.localizedDescription
    }

    func checkConfiguredBackendHealth() async {
        guard let apiClient else {
            backendHealthStatus = "Backend Not Reachable"
            lastNetworkError = APIClientError.invalidBaseURL.localizedDescription
            return
        }

        do {
            let response = try await apiClient.health()
            backendHealthStatus = "Backend Connected"
            lastNetworkError = response.message
            appendConversationTurn(role: .system, text: "Backend health check succeeded.")
        } catch {
            backendHealthStatus = "Backend Not Reachable"
            lastNetworkError = String(describing: error)
        }
    }

    func refreshBackendConfiguration() {
        if apiClient == nil {
            apiClient = try? APIClient()
        }
        if backendClient == nil {
            backendClient = try? BackendClient()
        }

        let refreshedAPIClient = try? APIClient()
        let refreshedBackendClient = try? BackendClient()

        apiClient = refreshedAPIClient
        backendClient = refreshedBackendClient
        loadedBackendBaseURL = refreshedAPIClient?.baseURLString
            ?? refreshedBackendClient?.baseURLString
            ?? APIConfiguration.fallbackBaseURLString
        ollamaVisionService = try? OllamaVisionService()
        rebuildVisionCoordinator()
    }

    func dismissStreamError() {
        streamViewModel.dismissError()
        showStreamError = false
        streamErrorMessage = ""
    }

    func requestSceneHelp() async {
        guard let scene = searchSceneContext else {
            updateAssistantReply("I need a fresh scene summary first. Turn on AI Vision, wait for it to update, then try again.")
            return
        }

        isRequestingHelp = true
        isAssistantRequestInProgress = true
        assistantErrorMessage = nil
        defer { isRequestingHelp = false }
        defer { isAssistantRequestInProgress = false }

        do {
            guard let backendClient else {
                throw BackendClientError.invalidBaseURL
            }
            let composedPrompt = "help me with this"
            print("Watersheep: sending scene assist request")
            let debugInfo = try await backendClient.sceneAssist(scene: scene, userMessage: composedPrompt)
            applyBackendDebugInfo(debugInfo)
            recordProviderUsage(task: "Scene assist", provider: debugInfo.provider, model: debugInfo.model, detail: debugInfo.endpoint)
            decodedMemoryCount = 0
            updateAssistantReply(debugInfo.parsedReply ?? "Vision response was empty.")
            lastNetworkError = nil
        } catch {
            applyBackendError(error, fallbackReply: nil)
        }
    }

    func sendAssistantRequest(for transcript: String, source: String = "typed") async {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else { return }

        appendConversationTurn(role: .user, text: trimmedTranscript)

        if let reminderReply = await handleReminderIfNeeded(trimmedTranscript) {
            updateAssistantReply(reminderReply)
            return
        }

        visionIntentDetected = shouldUseSceneAssist(for: trimmedTranscript)

        if shouldUseImageInternetSearch(for: trimmedTranscript) {
            await searchOnlineForCurrentScene(query: trimmedTranscript)
        } else if visionIntentDetected {
            if streamViewModel.hasFreshFrame() {
                await requestImmediateSceneExplanation(prompt: trimmedTranscript)
            } else {
                await sendSceneAssistCommand(trimmedTranscript)
            }
        } else if shouldUseCompatibilityMessage(for: trimmedTranscript) {
            await sendMessage(trimmedTranscript)
        } else {
            await askQuestion(trimmedTranscript, source: source)
        }
    }

    func handleWhatAmILookingAtAction() async {
        if !isAIVisionEnabled {
            setAIVisionEnabled(true)
        }

        if streamViewModel.hasFreshFrame() {
            await requestImmediateSceneExplanation(prompt: "What am I looking at?")
            return
        }

        await performQuickAction(actionID: "what_am_i_looking_at", source: "camera")
    }

    func searchOnlineForCurrentScene(query: String = "search this online") async {
        guard let apiClient else {
            let message = APIClientError.invalidBaseURL.localizedDescription
            internetSearchError = message
            updateAssistantReply(message, speak: false)
            return
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuery = trimmedQuery.isEmpty ? "search this online" : trimmedQuery

        isInternetSearchInProgress = true
        isAssistantRequestInProgress = true
        internetSearchError = nil
        defer {
            isInternetSearchInProgress = false
            isAssistantRequestInProgress = false
        }

        do {
            let result: APIResponseDebug<InternetSearchResponse>
            if let frame = streamViewModel.currentVideoFrame, streamViewModel.hasFreshFrame(), searchSceneContext != nil {
                result = try await apiClient.imageInternetSearch(
                    image: frame,
                    query: resolvedQuery,
                    sceneSummary: searchSceneContext,
                    mode: "image"
                )
            } else if shouldUseImageInternetSearch(for: resolvedQuery) {
                updateAssistantReply("I need a fresh scene summary before I can search what you are looking at. Turn on AI Vision, wait for the scene summary, then try Search Online again.", speak: true)
                return
            } else {
                let searchRequest = InternetSearchRequest(
                    query: resolvedQuery,
                    mode: searchSceneContext == nil ? "web" : "image",
                    sceneContext: searchSceneContext,
                    maxResults: 5
                )
                result = try await apiClient.internetSearch(searchRequest)
            }

            applyBackendDebugInfo(result.debugInfo)
            internetSearchSummary = result.response.summary
            internetSearchResults = result.response.results
            internetSearchError = nil
            lastChatProvider = "internet"
            lastChatModel = result.response.provider
            recordProviderUsage(
                task: "Internet search",
                provider: result.response.provider,
                model: result.response.mode,
                detail: result.debugInfo.endpoint
            )
            updateAssistantReply(formatInternetSearchReply(result.response), speak: true)
        } catch {
            let message = error.localizedDescription
            internetSearchError = message
            lastNetworkError = message
            assistantErrorMessage = message
            updateAssistantReply("I tried to search online, but the search request failed: \(message)", speak: true)
        }
    }

    func handleRecallMemoryAction() async {
        await performQuickAction(actionID: "recall_memory", source: "legacy")
    }

    func handleRememberThisAction() async {
        await performQuickAction(actionID: "remember_this", source: "legacy")
    }

    func handleSummariseMyDayAction() async {
        await performQuickAction(actionID: "summarise_day", source: "legacy")
    }

    func performQuickAction(actionID: String, source: String = "home") async {
        guard let apiClient else {
            let message = APIClientError.invalidBaseURL.localizedDescription
            quickActionStates[actionID] = .failed(message)
            updateAssistantReply(message, speak: false)
            return
        }

        quickActionStates[actionID] = .loading
        isAssistantRequestInProgress = true
        assistantErrorMessage = nil
        defer { isAssistantRequestInProgress = false }

        do {
            let request = QuickActionRequest(
                actionID: actionID,
                sceneContext: hasVisionSceneAvailable ? currentScene : nil,
                source: source
            )
            let result = try await apiClient.quickAction(request)
            applyBackendDebugInfo(result.debugInfo)
            suggestedQuickActions = result.response.suggestedActions
            recordProviderUsage(
                task: "Quick action: \(actionID)",
                provider: result.response.llmProvider ?? "backend",
                model: result.response.llmModel,
                detail: result.debugInfo.endpoint
            )
            quickActionStates[actionID] = .succeeded(result.response.assistantMessage)
            updateAssistantReply(result.response.assistantMessage, speak: result.response.shouldSpeak)
            lastNetworkError = nil
        } catch {
            let message = error.localizedDescription
            quickActionStates[actionID] = .failed(message)
            assistantErrorMessage = message
            lastNetworkError = message
            updateAssistantReply(message.isEmpty ? "That quick action failed." : message, speak: true)
        }
    }

    private func rebuildVisionCoordinator() {
        hybridVisionCoordinator = HybridVisionCoordinator(
            geminiService: backendClient.flatMap { GeminiVisionService(backendClient: $0) },
            ollamaService: ollamaVisionService
        )
    }

    private func sendMessage(_ message: String) async {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let backendClient else {
            let message = BackendClientError.invalidBaseURL.localizedDescription
            lastNetworkError = message
            assistantErrorMessage = message
            updateAssistantReply(message, speak: false)
            return
        }

        isAssistantRequestInProgress = true
        assistantErrorMessage = nil
        defer { isAssistantRequestInProgress = false }

        do {
            print("Watersheep: sending message to backend")
            let debugInfo = try await backendClient.message(message)
            applyBackendDebugInfo(debugInfo)
            recordProviderUsage(task: "Compatibility message", provider: debugInfo.provider, model: debugInfo.model, detail: debugInfo.endpoint)
            decodedMemoryCount = 0
            updateAssistantReply(debugInfo.parsedReply ?? "Backend reply was empty.")
            lastNetworkError = nil
        } catch {
            applyBackendError(error, fallbackReply: nil)
        }
    }

    private func startAIVisionLoop() {
        guard isAIVisionEnabled, streamViewModel.hasValidFrame else { return }
        guard aiLoopTask == nil || aiLoopTask?.isCancelled == true else { return }

        aiLoopTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await analyzeCurrentFrameIfNeeded()
                try? await Task.sleep(for: .seconds(AIVisionConstants.uploadIntervalSeconds))
            }
        }
    }

    private func stopAIVisionLoop() {
        aiLoopTask?.cancel()
        aiLoopTask = nil
        isAnalyzingFrame = false
        lastAnalyzedFrameCount = 0
        if !isAIVisionEnabled {
            aiVisionStatusMessage = "Off"
        }
    }

    private func analyzeCurrentFrameIfNeeded() async {
        guard isAIVisionEnabled, streamViewModel.hasFreshFrame(), !isAnalyzingFrame else {
            if isAIVisionEnabled, streamViewModel.isStreaming {
                aiVisionStatusMessage = streamViewModel.hasReceivedFirstFrame ? "Waiting for camera" : "No frames received"
                currentScene = streamViewModel.statusMessage
            }
            return
        }
        guard streamViewModel.frameCount > lastAnalyzedFrameCount else {
            aiVisionStatusMessage = streamViewModel.frameRate > 0 ? "Waiting for fresh frames" : "Camera stream paused"
            currentScene = streamViewModel.statusMessage
            return
        }
        if let pausedUntil = visionPausedUntil {
            let remainingSeconds = max(Int(ceil(pausedUntil.timeIntervalSinceNow)), 0)
            if remainingSeconds > 0 {
                currentScene = "Vision paused due to API quota. Retrying in \(remainingSeconds)s."
                aiVisionStatusMessage = currentScene
                return
            }
            visionPausedUntil = nil
            aiVisionStatusMessage = "On"
        }
        guard let frame = streamViewModel.currentVideoFrame else { return }

        lastAnalyzedFrameCount = streamViewModel.frameCount

        isAnalyzingFrame = true
        defer { isAnalyzingFrame = false }

        let result = await hybridVisionCoordinator.analyzeScene(
            image: frame,
            localSummary: nil
        )
        handleVisionAnalysisResult(result)
    }

    private func requestImmediateSceneExplanation(prompt: String) async {
        guard let frame = streamViewModel.currentVideoFrame else {
            updateAssistantReply(streamViewModel.isStreaming ? streamViewModel.statusMessage : "No camera frame is available yet. Start the glasses stream first.")
            return
        }

        guard streamViewModel.hasFreshFrame() else {
            let ageText = streamViewModel.currentFrameAge.map { String(format: "%.1fs old", $0) } ?? "unavailable"
            updateAssistantReply("The camera stream is connected, but the latest frame is \(ageText). Restart the camera or wait for a fresh frame, then try again.")
            return
        }

        isAnalyzingFrame = true
        defer { isAnalyzingFrame = false }
        lastAnalyzedFrameCount = streamViewModel.frameCount

        let result = await hybridVisionCoordinator.analyzeScene(
            image: frame,
            prompt: prompt,
            localSummary: nil
        )
        handleVisionAnalysisResult(result)
        updateAssistantReply(result.text)
    }

    private func updateAssistantReply(_ reply: String, speak: Bool = true, alreadyAppended: Bool = false) {
        let trimmedReply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        latestAssistantReply = trimmedReply.isEmpty ? reply : trimmedReply
        if !alreadyAppended {
            appendConversationTurn(role: .assistant, text: latestAssistantReply)
        }
        detectActionableItems(in: latestAssistantReply)

        guard speak else { return }
        guard !latestAssistantReply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            self.speechManager.speak(self.latestAssistantReply)
        }
    }

    private func streamAssistantReply(apiClient: APIClient, request: AssistantRequest) async -> String? {
        isStreamingReply = true
        defer { isStreamingReply = false }

        var accumulated = ""
        var didReceiveAnyChunk = false

        // Insert a placeholder assistant turn we update as tokens arrive.
        let placeholderID = UUID()
        let placeholder = ConversationTurn(id: placeholderID, role: .assistant, text: "")
        conversationHistory.append(placeholder)

        do {
            for try await event in apiClient.streamAssistant(request) {
                switch event {
                case .provider(let name, let model):
                    lastChatProvider = name
                    lastChatModel = model ?? ""
                    recordProviderUsage(task: "Chat stream", provider: name, model: model, detail: "/api/assistant/stream")
                case .fallback(let name):
                    // The streaming attempt failed and a one-shot reply will arrive next.
                    lastChatProvider = name
                    recordProviderUsage(task: "Chat fallback", provider: name, model: nil, detail: "/api/assistant/stream")
                case .token(let chunk):
                    guard !chunk.isEmpty else { continue }
                    accumulated.append(chunk)
                    didReceiveAnyChunk = true
                    if let index = conversationHistory.lastIndex(where: { $0.id == placeholderID }) {
                        conversationHistory[index] = ConversationTurn(id: placeholderID, role: .assistant, text: accumulated)
                    }
                    latestAssistantReply = accumulated
                }
            }
        } catch {
            print("Watersheep: streaming reply failed, falling back: \(error.localizedDescription)")
            if let index = conversationHistory.lastIndex(where: { $0.id == placeholderID }) {
                conversationHistory.remove(at: index)
            }
            return nil
        }

        if !didReceiveAnyChunk {
            if let index = conversationHistory.lastIndex(where: { $0.id == placeholderID }) {
                conversationHistory.remove(at: index)
            }
            return nil
        }

        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handlePrivacyModeChange() {
        if isPrivacyModeEnabled {
            print("Watersheep: privacy mode ON")
            if isAIVisionEnabled {
                setAIVisionEnabled(false)
            }
            if streamViewModel.streamState.isActive {
                Task { await stopCamera() }
            }
            speechManager.stopSpeaking()
            currentSceneUpdatedAt = nil
            currentScene = "Privacy mode is on. Camera, mic, and AI vision are paused."
            aiVisionStatusMessage = "Privacy mode"
        } else {
            print("Watersheep: privacy mode OFF")
            currentSceneUpdatedAt = nil
            currentScene = "AI Vision is off."
            aiVisionStatusMessage = "Off"
        }
    }

    private func detectActionableItems(in text: String) {
        let detector = try? NSDataDetector(types:
            NSTextCheckingResult.CheckingType.link.rawValue
            | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
            | NSTextCheckingResult.CheckingType.date.rawValue
        )
        guard let detector else {
            detectedActionableItems = []
            return
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector.matches(in: text, range: range)
        var seen: Set<String> = []
        var items: [DetectedActionableItem] = []

        for match in matches {
            guard let textRange = Range(match.range, in: text) else { continue }
            let value = String(text[textRange])
            if seen.contains(value) { continue }
            seen.insert(value)

            if let url = match.url {
                items.append(DetectedActionableItem(kind: .url, value: url.absoluteString, displayText: value))
            } else if let phone = match.phoneNumber {
                items.append(DetectedActionableItem(kind: .phoneNumber, value: phone, displayText: value))
            } else if let date = match.date {
                items.append(DetectedActionableItem(kind: .date, value: ISO8601DateFormatter().string(from: date), displayText: value))
            }
        }

        detectedActionableItems = items
    }

    private func persistConversationTurnRemotely(role: String, text: String, source: String) async {
        guard let apiClient else { return }
        do {
            try await apiClient.appendConversationTurn(role: role, text: text, source: source)
        } catch {
            // Persistence is best-effort; we don't want to fail the user-facing flow.
            print("Watersheep: conversation persistence failed: \(error.localizedDescription)")
        }
    }

    func loadPersistedConversationHistory() async {
        guard let apiClient else { return }
        do {
            let turns = try await apiClient.fetchConversationHistory(limit: 40)
            let mapped = turns.compactMap { turn -> ConversationTurn? in
                guard let role = ConversationTurn.Role(rawValue: turn.role) else { return nil }
                return ConversationTurn(role: role, text: turn.text)
            }
            if !mapped.isEmpty {
                conversationHistory = mapped
            }
        } catch {
            print("Watersheep: could not load persisted conversation: \(error.localizedDescription)")
        }
    }

    func clearPersistedConversation() async {
        conversationHistory = []
        guard let apiClient else { return }
        try? await apiClient.clearConversationHistory()
    }

    /// Trigger a backend-side memory save when the scene meaningfully changes.
    /// Wired into `handleVisionAnalysisResult` so glasses become a passive memory log.
    private func maybeSaveProactiveMemory(for sceneText: String) {
        let trimmed = sceneText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return }
        guard !isPrivacyModeEnabled else { return }
        guard UserDefaults.standard.object(forKey: "settings.proactiveMemoryEnabled") as? Bool ?? true else { return }
        guard let backendClient else { return }

        // Don't write a memory while the user is mid-speech (mic active) or
        // the assistant is mid-reply (TTS active). It pollutes the timeline
        // with "you are looking at me" style captures.
        if SpeechManager.shared.isSpeaking { return }
        if SpeechManager.shared.recognitionCoordinator?.isCurrentlyListening == true { return }

        // 3-minute hard debounce + first-30-char similarity check stop the
        // duplicate "person at desk" spam we saw in the previous logs.
        let now = Date()
        if let last = lastProactiveMemorySaved, now.timeIntervalSince(last) < 180 { return }
        if proactiveSceneIsTooSimilar(trimmed, to: lastProactiveSceneText) { return }

        lastProactiveSceneText = trimmed
        lastProactiveMemorySaved = now

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                _ = try await backendClient.saveMemory(summary: trimmed, transcript: nil, sceneContext: trimmed)
            } catch {
                await MainActor.run {
                    // Reset the debounce so a real future scene change can save.
                    self.lastProactiveMemorySaved = nil
                }
            }
        }
    }

    private func proactiveSceneIsTooSimilar(_ candidate: String, to previous: String) -> Bool {
        let normalize: (String) -> String = { input in
            input.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        let a = normalize(candidate)
        let b = normalize(previous)
        if a.isEmpty || b.isEmpty { return false }
        let prefixLength = 30
        let aPrefix = String(a.prefix(prefixLength))
        let bPrefix = String(b.prefix(prefixLength))
        return aPrefix == bPrefix
    }

    private func sendSceneAssistCommand(_ transcript: String) async {
        guard let scene = searchSceneContext else {
            updateAssistantReply("I need a fresh scene summary before I can answer that. Turn on AI Vision and wait for the scene summary to update.")
            assistantErrorMessage = latestAssistantReply
            lastBackendEndpointCalled = "None"
            lastBackendStatusCode = "None"
            lastBackendRawResponse = "None"
            lastBackendParsedReply = "None"
            return
        }
        guard let backendClient else {
            lastNetworkError = BackendClientError.invalidBaseURL.localizedDescription
            return
        }

        do {
            let composedPrompt = transcript
            print("Watersheep: sending scene assist request")
            let debugInfo = try await backendClient.sceneAssist(scene: scene, userMessage: composedPrompt)
            applyBackendDebugInfo(debugInfo)
            recordProviderUsage(task: "Scene assist", provider: debugInfo.provider, model: debugInfo.model, detail: debugInfo.endpoint)
            decodedMemoryCount = 0
            updateAssistantReply(debugInfo.parsedReply ?? "Backend reply was empty.")
            lastNetworkError = nil
        } catch {
            applyBackendError(error, fallbackReply: nil)
        }
    }

    private func askQuestion(_ question: String, source: String) async {
        guard let apiClient else {
            let message = APIClientError.invalidBaseURL.localizedDescription
            lastNetworkError = message
            assistantErrorMessage = message
            updateAssistantReply(message, speak: false)
            return
        }

        isAssistantRequestInProgress = true
        assistantErrorMessage = nil
        defer { isAssistantRequestInProgress = false }

        let request = AssistantRequest(
            message: question,
            sceneContext: makeConversationContext(currentQuestion: question),
            source: source,
            llmProvider: preferredChatProvider(),
            llmModel: nil
        )

        // Try the streaming endpoint first for word-by-word UI. If it fails or
        // returns nothing, fall back to the regular non-streaming /api/assistant.
        let streamedReply = await streamAssistantReply(apiClient: apiClient, request: request)
        if let streamedReply, !streamedReply.isEmpty {
            updateAssistantReply(streamedReply, speak: true, alreadyAppended: true)
            await persistConversationTurnRemotely(role: "user", text: question, source: source)
            await persistConversationTurnRemotely(role: "assistant", text: streamedReply, source: source)
            return
        }

        do {
            print("Watersheep: sending non-streaming assistant request")
            let result = try await apiClient.assistant(request)
            applyBackendDebugInfo(result.debugInfo)
            decodedMemoryCount = result.response.usedMemories.count
            suggestedQuickActions = result.response.suggestedActions
            if let provider = result.response.llmProvider, !provider.isEmpty {
                lastChatProvider = provider
                lastChatModel = result.response.llmModel ?? ""
            }
            recordProviderUsage(
                task: "Assistant",
                provider: result.response.llmProvider,
                model: result.response.llmModel,
                detail: result.debugInfo.endpoint
            )
            updateAssistantReply(result.response.assistantMessage, speak: result.response.shouldSpeak)
            await persistConversationTurnRemotely(role: "user", text: question, source: source)
            await persistConversationTurnRemotely(role: "assistant", text: result.response.assistantMessage, source: source)
            lastNetworkError = nil
            assistantErrorMessage = nil
        } catch {
            applyAPIError(error, endpoint: "/chat")
        }
    }

    /// User's chat-LLM preference from Settings. `nil` means "let the backend choose".
    private func preferredChatProvider() -> String? {
        let raw = UserDefaults.standard.string(forKey: "settings.preferredChatProvider")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let raw, raw != "auto", !raw.isEmpty else { return nil }
        return raw
    }

    private func makeConversationContext(currentQuestion: String) -> String? {
        var sections: [String] = []

        if hasVisionSceneAvailable {
            sections.append("Current scene: \(searchSceneContext ?? currentScene)")
        }

        let recentContext = conversationHistory
            .filter { $0.text != currentQuestion }
            .suffix(6)
            .map { turn in
                let prefix: String
                switch turn.role {
                case .user:
                    prefix = "User"
                case .assistant:
                    prefix = "Assistant"
                case .system:
                    prefix = "System"
                }
                return "\(prefix): \(turn.text)"
            }

        if !recentContext.isEmpty {
            sections.append("Recent conversation:\n\(recentContext.joined(separator: "\n"))")
        }

        let joined = sections.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private func composeSceneAssistPrompt(basePrompt: String) -> String {
        let recentAssistantContext = conversationHistory
            .suffix(4)
            .map { "\($0.role.rawValue.capitalized): \($0.text)" }
            .joined(separator: " | ")

        guard !recentAssistantContext.isEmpty else {
            return basePrompt
        }
        return "\(basePrompt)\n\nConversation context: \(recentAssistantContext)"
    }

    private func shouldUseSceneAssist(for transcript: String) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let sceneAssistPhrases = [
            "help me with this",
            "what am i looking at",
            "wht am i looking at",
            "what am i seeing",
            "wht am i seeing",
            "what do you see",
            "what can you see",
            "what is this",
            "whats this",
            "explain scene",
            "explain the scene",
            "explain what i'm seeing",
            "explain what i am seeing",
            "tell me what you see",
            "describe what i'm looking at",
            "describe what i am looking at",
            "describe what i'm seeing",
            "describe what i am seeing",
            "what's in front of me",
            "whats in front of me",
            "what is in front of me",
            "describe this",
            "read this",
        ]

        return sceneAssistPhrases.contains { normalized.contains($0) }
    }

    private func shouldUseImageInternetSearch(for transcript: String) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let phrases = [
            "search this online",
            "find this product",
            "where can i buy this",
            "where can i get this",
            "look this up",
            "search online",
            "find similar items",
            "find similar",
            "summarise this from the internet",
            "summarize this from the internet",
        ]
        return phrases.contains { normalized.contains($0) }
    }

    private var hasVisionSceneAvailable: Bool {
        searchSceneContext != nil
    }

    private var searchSceneContext: String? {
        let trimmed = currentScene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 12 else { return nil }
        guard let currentSceneUpdatedAt else { return nil }
        guard Date().timeIntervalSince(currentSceneUpdatedAt) <= 60 else { return nil }
        guard streamViewModel.hasFreshFrame(maxAge: 10) else { return nil }
        guard VisionProvider.fromBackend(visionProviderUsed).isSceneDescriptionProvider else { return nil }

        let blockedPrefixes = [
            "AI Vision is off.",
            "Start the camera stream",
            "Camera stream is idle.",
            "Analyzing current view",
            "Vision paused due to API quota.",
            "Vision services are unavailable",
            "I can't confidently tell",
        ]
        if blockedPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return nil
        }
        if trimmed == streamViewModel.statusMessage {
            return nil
        }
        if trimmed.hasPrefix("Vision fallback is active.") {
            return nil
        }
        return trimmed
    }

    private func shouldUseCompatibilityMessage(for transcript: String) -> Bool {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let compatibilityPhrases = [
            "start lock in mode",
            "start lock-in mode",
            "lock in",
            "focus mode",
            "deep work",
            "what should i do next",
            "what next",
            "schedule today",
            "what's my schedule today",
        ]

        return compatibilityPhrases.contains { normalized.contains($0) }
    }

    private func handleVisionAnalysisResult(_ result: VisionAnalysisResult) {
        let hadFreshSceneBeforeResult = searchSceneContext != nil
        visionProviderUsed = result.provider.rawValue
        visionFallbackReason = result.fallbackReason ?? "None"
        visionRawError = result.rawError ?? "None"
        lastNetworkError = result.rawError
        recordProviderUsage(
            task: "Image processing",
            provider: result.provider.displayName,
            model: nil,
            detail: result.fallbackReason ?? "Gemini primary"
        )

        if shouldPauseVisionRetries(for: result) {
            let retrySeconds = AIVisionConstants.fallbackCooldownSeconds
            visionPausedUntil = Date().addingTimeInterval(TimeInterval(retrySeconds))
            aiVisionStatusMessage = "Paused - retry delayed"
            currentSceneUpdatedAt = nil
            currentScene = "Vision fallback is active. Retrying in \(retrySeconds)s."
            lastBackendParsedReply = result.text
            if let rawResponse = result.rawResponse, !rawResponse.isEmpty {
                lastBackendRawResponse = rawResponse
            }
            return
        }

        switch result.provider {
        case .gemini:
            aiVisionStatusMessage = "On - Gemini"
        case .ollama:
            aiVisionStatusMessage = "On - Ollama fallback"
        case .openrouter:
            aiVisionStatusMessage = "On - OpenRouter fallback"
        case .localOnly:
            aiVisionStatusMessage = "On - Local summary fallback"
        case .fallbackMessage:
            aiVisionStatusMessage = "On - Vision fallback message"
        }

        let producedRealScene = result.provider == .gemini || result.provider == .ollama || result.provider == .openrouter
        if producedRealScene {
            currentScene = result.text
            currentSceneUpdatedAt = Date()
        } else if !hadFreshSceneBeforeResult {
            currentScene = result.text
            currentSceneUpdatedAt = nil
        }
        lastBackendParsedReply = result.text
        if let rawResponse = result.rawResponse, !rawResponse.isEmpty {
            lastBackendRawResponse = rawResponse
        }

        // Proactive memory: when the assistant produces a real scene description
        // (i.e. not a fallback message), passively log it so the glasses act
        // like a memory log even when the user does not say "remember this".
        if producedRealScene {
            maybeSaveProactiveMemory(for: result.text)
        }
    }

    private func shouldPauseVisionRetries(for result: VisionAnalysisResult) -> Bool {
        guard result.provider == .localOnly || result.provider == .fallbackMessage else {
            return false
        }

        let signalSource = [result.fallbackReason, result.rawError]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        let retrySignals = [
            "timed out",
            "unreachable",
            "could not connect",
            "host is down",
            "network failure",
        ]

        return retrySignals.contains(where: { signalSource.contains($0) })
    }

    private func applyBackendDebugInfo(_ debugInfo: BackendRequestDebugInfo) {
        lastBackendEndpointCalled = debugInfo.endpoint
        lastBackendStatusCode = String(debugInfo.statusCode)
        lastBackendRawResponse = debugInfo.rawResponseBody.isEmpty ? "None" : debugInfo.rawResponseBody
        lastBackendParsedReply = debugInfo.parsedReply ?? debugInfo.parsedError ?? "None"
        print("Watersheep: backend \(debugInfo.endpoint) -> HTTP \(debugInfo.statusCode)")
    }

    private func applyBackendError(_ error: Error, fallbackReply: String?) {
        lastNetworkError = String(describing: error)
        assistantErrorMessage = String(describing: error)
        decodedMemoryCount = 0

        if case let BackendClientError.requestFailed(endpoint, statusCode, rawBody) = error {
            lastBackendEndpointCalled = endpoint
            lastBackendStatusCode = String(statusCode)
            lastBackendRawResponse = rawBody.isEmpty ? "None" : rawBody
            lastBackendParsedReply = "None"
            updateAssistantReply(rawBody.isEmpty ? (fallbackReply ?? "Unable to get help right now.") : rawBody, speak: true)
            print("Parsed error: \(rawBody)")
            return
        }

        if case let BackendClientError.decodingFailed(endpoint, statusCode, rawBody, underlying) = error {
            lastBackendEndpointCalled = endpoint
            lastBackendStatusCode = String(statusCode)
            lastBackendRawResponse = rawBody.isEmpty ? "None" : rawBody
            lastBackendParsedReply = "None"
            updateAssistantReply(rawBody.isEmpty ? (fallbackReply ?? underlying.localizedDescription) : rawBody, speak: true)
            print("Parsed error: \(underlying.localizedDescription)")
            return
        }

        updateAssistantReply(fallbackReply ?? "Unable to get help right now.", speak: true)
    }

    private func applyAPIError(_ error: Error, endpoint: String) {
        lastNetworkError = String(describing: error)
        assistantErrorMessage = String(describing: error)
        decodedMemoryCount = 0
        lastBackendEndpointCalled = endpoint
        lastBackendParsedReply = "None"

        if case let APIClientError.serverError(statusCode, message) = error {
            lastBackendStatusCode = String(statusCode)
            lastBackendRawResponse = message
            updateAssistantReply(message.isEmpty ? "Unable to get help right now." : message)
            return
        }

        lastBackendStatusCode = "None"
        lastBackendRawResponse = "None"
        updateAssistantReply("Unable to get help right now.")
    }

    private func recordProviderUsage(task: String, provider: String?, model: String?, detail: String) {
        let cleanProvider = nonEmpty(provider) ?? "local/backend"
        let cleanModel = nonEmpty(model) ?? "default"
        let cleanDetail = nonEmpty(detail) ?? "None"

        let record = ProviderUsageRecord(
            task: task,
            provider: cleanProvider,
            model: cleanModel,
            detail: cleanDetail,
            timestamp: .now
        )
        providerUsageRecords.insert(record, at: 0)
        if providerUsageRecords.count > 8 {
            providerUsageRecords.removeLast(providerUsageRecords.count - 8)
        }
    }

    private func formatInternetSearchReply(_ response: InternetSearchResponse) -> String {
        var lines = [response.summary]
        if !response.results.isEmpty {
            lines.append("")
            lines.append("Sources:")
            for result in response.results.prefix(3) {
                lines.append("- \(result.title): \(result.url)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func appendConversationTurn(role: ConversationTurn.Role, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if conversationHistory.last?.role == role, conversationHistory.last?.text == trimmed {
            return
        }
        conversationHistory.append(ConversationTurn(role: role, text: trimmed))
        if conversationHistory.count > 40 {
            conversationHistory.removeFirst(conversationHistory.count - 40)
        }
    }

    private func handleReminderIfNeeded(_ transcript: String) async -> String? {
        let normalized = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let reminderPhrases = ["remind me", "set a reminder", "alarm", "wake me"]
        guard reminderPhrases.contains(where: { normalized.contains($0) }) else {
            return nil
        }

        guard let reminder = parseReminder(from: transcript) else {
            return "I heard a reminder request, but I could not understand when to remind you. Try saying something like 'remind me to stretch in 10 minutes'."
        }

        do {
            try await scheduleReminder(reminder)
            reminders.append(reminder)
            reminders.sort { $0.triggerDate < $1.triggerDate }
            saveReminders()
            return "Okay, I will remind you to \(reminder.title) at \(Self.reminderTimeFormatter.string(from: reminder.triggerDate))."
        } catch {
            return "I understood the reminder, but I could not schedule it: \(error.localizedDescription)"
        }
    }

    private func parseReminder(from transcript: String) -> LocalReminderRecord? {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()

        var title = normalized
        let prefixes = ["remind me to ", "remind me ", "set a reminder to ", "set a reminder for ", "alarm for ", "wake me "]
        for prefix in prefixes {
            if lowercased.hasPrefix(prefix) {
                title = String(normalized.dropFirst(prefix.count))
                break
            }
        }

        let interval: TimeInterval
        if let parsedInterval = parseRelativeInterval(from: lowercased) {
            interval = parsedInterval
            title = stripRelativeTime(from: title)
        } else if lowercased.contains("tomorrow") {
            interval = 24 * 60 * 60
            title = title.replacingOccurrences(of: "tomorrow", with: "", options: .caseInsensitive)
        } else {
            interval = ReminderConstants.defaultInterval
        }

        let cleanTitle = title
            .replacingOccurrences(of: "in ", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,"))

        guard !cleanTitle.isEmpty else { return nil }
        return LocalReminderRecord(
            title: cleanTitle,
            triggerDate: Date().addingTimeInterval(interval),
            sourceCommand: transcript
        )
    }

    private func parseRelativeInterval(from text: String) -> TimeInterval? {
        let patterns: [(String, TimeInterval)] = [
            ("([0-9]+)\\s*(second|seconds)", 1),
            ("([0-9]+)\\s*(minute|minutes|mins|min)", 60),
            ("([0-9]+)\\s*(hour|hours|hr|hrs)", 3600),
            ("([0-9]+)\\s*(day|days)", 86400),
        ]

        for (pattern, multiplier) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let valueRange = Range(match.range(at: 1), in: text),
                  let value = Double(text[valueRange]) else {
                continue
            }
            return value * multiplier
        }
        return nil
    }

    private func stripRelativeTime(from text: String) -> String {
        var value = text
        let patterns = [
            "\\s*in\\s+[0-9]+\\s*(second|seconds|minute|minutes|mins|min|hour|hours|hr|hrs|day|days)",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
        }
        return value
    }

    private func scheduleReminder(_ reminder: LocalReminderRecord) async throws {
        let granted = try await requestNotificationAuthorizationIfNeeded()
        guard granted else {
            throw ReminderError.permissionDenied
        }

        let interval = max(reminder.triggerDate.timeIntervalSinceNow, 1)
        let content = UNMutableNotificationContent()
        content.title = "Watersheep Reminder"
        content.body = reminder.title
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: reminder.id.uuidString, content: content, trigger: trigger)
        try await reminderCenter.add(request)
    }

    private func requestNotificationAuthorizationIfNeeded() async throws -> Bool {
        let settings = await reminderCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return try await reminderCenter.requestAuthorization(options: [.alert, .badge, .sound])
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private static func loadReminders() -> [LocalReminderRecord] {
        guard let data = UserDefaults.standard.data(forKey: ReminderConstants.storageKey),
              let reminders = try? JSONDecoder().decode([LocalReminderRecord].self, from: data) else {
            return []
        }
        return reminders.filter { $0.triggerDate > .now }
    }

    private func saveReminders() {
        let upcoming = reminders.filter { $0.triggerDate > .now }
        if let data = try? JSONEncoder().encode(upcoming) {
            UserDefaults.standard.set(data, forKey: ReminderConstants.storageKey)
        }
    }

    private static let reminderTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private enum ReminderError: LocalizedError {
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Notifications are not allowed for this app."
            }
        }
    }
}
