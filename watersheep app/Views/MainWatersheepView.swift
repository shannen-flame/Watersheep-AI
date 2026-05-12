import Combine
import MWDATCore
import SwiftUI

private struct CameraDebugContent: View {
    let streamManager: GlassesStreamManager
    let microphoneDebugManager: MicrophoneDebugManager
    @ObservedObject var debugViewModel: DebugViewModel
    let connectionStatus: String
    let backendStatus: String
    let aiVisionStatus: String
    let lastNetworkError: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailRow(title: "Connection", value: connectionStatus)
            DetailRow(title: "Backend", value: backendStatus)
            DetailRow(title: "Network Error", value: lastNetworkError)
            DetailRow(title: "AI Vision", value: aiVisionStatus)
            DetailRow(title: "Vision Provider", value: streamManager.visionProviderUsed)
            DetailRow(title: "Vision Fallback", value: streamManager.visionFallbackReason)
            DetailRow(title: "Vision Raw Error", value: streamManager.visionRawError)
            DetailRow(title: "Scene Text", value: streamManager.currentScene)
            DetailRow(title: "Assistant Status", value: streamManager.isAssistantRequestInProgress ? "Loading" : "Idle")
            DetailRow(title: "Assistant Error", value: streamManager.assistantErrorMessage ?? "None")
            DetailRow(title: "Internet Search", value: streamManager.isInternetSearchInProgress ? "Searching" : "Idle")
            DetailRow(title: "Internet Error", value: streamManager.internetSearchError ?? "None")
            DetailRow(title: "Wake Mode", value: microphoneDebugManager.wakeModeEnabled ? "Armed" : "Off")
            DetailRow(title: "Listening State", value: microphoneDebugManager.listeningState)
            DetailRow(title: "iPhone OCR Debug Camera", value: debugViewModel.cameraStatus)
            DetailRow(title: "iPhone OCR Debug", value: debugViewModel.ocrStatus)
            DetailRow(title: "Recognized Text", value: debugViewModel.latestRecognizedText)
            DetailRow(title: "Objects", value: debugViewModel.latestDetectedObjectsText)
            DetailRow(title: "Scene Summary", value: debugViewModel.latestSceneSummary)
            DetailRow(title: "Vision Status", value: debugViewModel.ollamaVisionStatus)
            DetailRow(title: "Vision Trigger", value: debugViewModel.ollamaTriggerStatus)
            DetailRow(title: "Vision Provider Used", value: debugViewModel.lastVisionProvider)
            DetailRow(title: "Vision Error", value: debugViewModel.lastOllamaVisionError)
            DetailRow(title: "Last Assistant Reply", value: streamManager.latestAssistantReply)

            Button(debugViewModel.cameraStatus == "Running" ? "Stop iPhone OCR Debug" : "Start iPhone OCR Debug") {
                if debugViewModel.cameraStatus == "Running" {
                    debugViewModel.stopOCR()
                } else {
                    debugViewModel.startOCR()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

}

struct MainWatersheepView: View {
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @ObservedObject var streamManager: GlassesStreamManager
    @ObservedObject var microphoneDebugManager: MicrophoneDebugManager
    @AppStorage("settings.debugModeEnabled") private var debugModeEnabled = false
    @StateObject private var debugViewModel = DebugViewModel()
    @State private var userMessage = ""
    @State private var isSendingTextMessage = false
    @State private var isDebugPanelExpanded = false
    @State private var hasLoadedDeferredContent = false

    init(
        wearablesViewModel: WearablesViewModel,
        streamManager: GlassesStreamManager,
        microphoneDebugManager: MicrophoneDebugManager
    ) {
        self.wearablesViewModel = wearablesViewModel
        self.streamManager = streamManager
        self.microphoneDebugManager = microphoneDebugManager
    }

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    previewCard
                    controlsCard
                    if hasLoadedDeferredContent {
                        sceneCard
                        assistantCard
                        internetSearchCard
                        providerUsageCard
                        chatCard

                        if debugModeEnabled {
                            DebugPanel(title: "Camera Debug", isExpanded: $isDebugPanelExpanded) {
                                CameraDebugContent(
                                    streamManager: streamManager,
                                    microphoneDebugManager: microphoneDebugManager,
                                    debugViewModel: debugViewModel,
                                    connectionStatus: connectionStatus,
                                    backendStatus: streamManager.backendHealthStatus,
                                    aiVisionStatus: aiVisionStatus,
                                    lastNetworkError: lastNetworkError
                                )
                            }
                        }
                    } else {
                        loadingCard
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Camera")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Error", isPresented: streamErrorBinding) {
            Button("OK") {
                streamManager.dismissStreamError()
            }
        } message: {
            Text(streamManager.streamErrorMessage)
        }
        .onAppear {
            Task { @MainActor in
                if !hasLoadedDeferredContent {
                    await Task.yield()
                    hasLoadedDeferredContent = true
                }
            }
        }
        .onDisappear {
            debugViewModel.onOllamaVisionResult = nil
            debugViewModel.stopOCR()
        }
        .onChange(of: debugModeEnabled) { _, isEnabled in
            if !isEnabled {
                debugViewModel.stopOCR()
            }
        }
    }

    private var header: some View {
        GlassCard(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    SectionHeader("Camera", subtitle: "Live wearable vision with assistant-ready scene understanding.")
                    Spacer()
                    StatusChip(streamManager.streamViewModel.streamState.title, tone: streamStatusTone)
                }

                HStack(spacing: 10) {
                    StatusChip(wearablesViewModel.registrationState == .registered ? "Glasses Connected" : "Glasses Disconnected", tone: wearablesViewModel.registrationState == .registered ? .success : .danger)
                    StatusChip(streamManager.backendHealthStatus == "Backend Connected" ? "Backend Online" : "Backend Offline", tone: streamManager.backendHealthStatus == "Backend Connected" ? .success : .warning)
                    StatusChip(streamManager.isAIVisionEnabled ? "AI Vision On" : "AI Vision Off", tone: streamManager.isAIVisionEnabled ? .success : .neutral)
                }
            }
        }
    }

    private var previewCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Live Preview", subtitle: streamManager.streamViewModel.statusMessage)
                StreamView(viewModel: streamManager.streamViewModel, wearablesVM: wearablesViewModel)
            }
        }
    }

    private var controlsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Controls", subtitle: "Keep this surface minimal during live use.")

                Toggle("AI Vision", isOn: aiVisionBinding)
                    .tint(.cyan)

                if wearablesViewModel.registrationState != .registered {
                    FloatingActionButton(
                        title: wearablesViewModel.registrationState == .registering ? "Connecting Glasses..." : "Connect Glasses",
                        systemImage: "dot.radiowaves.left.and.right",
                        isEnabled: wearablesViewModel.registrationState != .registering
                    ) {
                        print("Connect glasses button tapped from Camera screen")
                        wearablesViewModel.connectGlasses()
                    }
                }

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        FloatingActionButton(
                            title: streamManager.isStreamRunning ? "Stop Camera" : "Start Camera",
                            systemImage: streamManager.isStreamRunning ? "stop.fill" : "camera.fill",
                            isEnabled: canControlCamera || streamManager.isStreamRunning
                        ) {
                            Task {
                                if streamManager.isStreamRunning {
                                    await streamManager.stopCamera()
                                } else {
                                    await streamManager.startCamera()
                                }
                            }
                        }

                        FloatingActionButton(
                            title: "Explain Scene",
                            systemImage: "sparkles",
                            isEnabled: streamManager.isAIVisionEnabled && streamManager.streamViewModel.hasValidFrame && streamManager.streamViewModel.frameRate > 0
                        ) {
                            Task {
                                await streamManager.handleWhatAmILookingAtAction()
                            }
                        }
                    }

                    FloatingActionButton(
                        title: streamManager.isInternetSearchInProgress ? "Searching Online..." : "Search Online",
                        systemImage: "safari.fill",
                        isEnabled: !streamManager.isInternetSearchInProgress && (streamManager.streamViewModel.hasValidFrame || !streamManager.currentScene.isEmpty)
                    ) {
                        Task {
                            await streamManager.searchOnlineForCurrentScene()
                        }
                    }
                }
            }
        }
    }

    private var sceneCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Scene Summary", subtitle: "Compact visual understanding from the assistant pipeline.")
                DetailRow(title: "AI Vision Status", value: aiVisionStatus)
                DetailRow(title: "Stream State", value: streamManager.streamViewModel.streamState.title)
                DetailRow(title: "Stream Message", value: streamManager.streamViewModel.statusMessage)
                DetailRow(title: "Stream Codec", value: streamManager.streamViewModel.activeCodec)
                DetailRow(title: "Frame Callbacks", value: "\(streamManager.streamViewModel.rawFrameCallbackCount)")
                DetailRow(title: "Frames Received", value: "\(streamManager.streamViewModel.frameCount)")
                DetailRow(title: "Decode Failures", value: "\(streamManager.streamViewModel.decodeFailureCount)")
                DetailRow(title: "Frame Rate", value: "\(String(format: "%.1f", streamManager.streamViewModel.frameRate)) fps")
                DetailRow(title: "Scene", value: streamManager.currentScene)
                DetailRow(title: "Hybrid Summary", value: streamManager.currentScene)
                DetailRow(title: "Reminders", value: streamManager.reminderStatusText)
            }
        }
    }

    private var assistantCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Assistant", subtitle: streamManager.isAssistantRequestInProgress ? "Watersheep is thinking..." : "Latest assistant output.")
                Text(streamManager.latestAssistantReply)
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.86))

                HStack(spacing: 8) {
                    StatusChip(
                        chatProviderLabel,
                        tone: streamManager.lastChatProvider.isEmpty ? .neutral : .success
                    )
                    StatusChip(
                        visionProviderLabel,
                        tone: streamManager.visionProviderUsed == "gemini" ? .success : .warning
                    )
                }

                if streamManager.isAssistantRequestInProgress {
                    ProgressView("Working...")
                        .tint(.white)
                }
            }
        }
    }

    private var chatProviderLabel: String {
        let provider = streamManager.lastChatProvider.isEmpty ? "—" : streamManager.lastChatProvider.capitalized
        if streamManager.lastChatModel.isEmpty {
            return "Chat: \(provider)"
        }
        return "Chat: \(provider) (\(streamManager.lastChatModel))"
    }

    private var visionProviderLabel: String {
        let provider = VisionProvider.fromBackend(streamManager.visionProviderUsed)
        return "Vision: \(provider.displayName)"
    }

    private var providerUsageCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Provider Usage", subtitle: "Recent tasks and which AI/backend handled them.")

                if streamManager.providerUsageRecords.isEmpty {
                    DetailRow(title: "No provider activity yet", value: "Run AI Vision or ask the assistant.")
                } else {
                    ForEach(streamManager.providerUsageRecords.prefix(5)) { record in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(record.task)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Spacer()
                                Text(record.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Color.white.opacity(0.48))
                            }
                            Text(providerUsageDetail(record))
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private var internetSearchCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Online Research", subtitle: streamManager.isInternetSearchInProgress ? "Checking sources..." : "Sources and summary.")

                if streamManager.isInternetSearchInProgress {
                    ProgressView("Searching online...")
                        .tint(.white)
                }

                if let error = streamManager.internetSearchError, !error.isEmpty {
                    DetailRow(title: "Error", value: error)
                } else if streamManager.internetSearchSummary.isEmpty && streamManager.internetSearchResults.isEmpty {
                    DetailRow(title: "No search yet", value: "Ready")
                } else {
                    if !streamManager.internetSearchSummary.isEmpty {
                        Text(streamManager.internetSearchSummary)
                            .font(.body)
                            .foregroundStyle(Color.white.opacity(0.86))
                    }

                    ForEach(streamManager.internetSearchResults.prefix(5)) { result in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(result.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                                Spacer()
                                StatusChip("\(Int(result.confidence * 100))%", tone: result.confidence >= 0.7 ? .success : .warning)
                            }

                            if !result.summary.isEmpty {
                                Text(result.summary)
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.68))
                                    .lineLimit(3)
                            }

                            HStack {
                                Text(result.source)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.55))
                                Spacer()
                                if let url = URL(string: result.url) {
                                    Link(destination: url) {
                                        Label("Open", systemImage: "safari")
                                            .font(.caption.weight(.semibold))
                                    }
                                    .foregroundStyle(.cyan)
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }

    private func providerUsageDetail(_ record: ProviderUsageRecord) -> String {
        if record.model == "default" {
            return "\(record.provider) • \(record.detail)"
        }
        return "\(record.provider) (\(record.model)) • \(record.detail)"
    }

    private var chatCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Text Chat", subtitle: "Fallback assistant input that keeps camera and voice separate.")

                if !streamManager.conversationHistory.isEmpty {
                    ForEach(streamManager.conversationHistory.suffix(6)) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.role.rawValue.capitalized)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.5))
                            Text(message.text)
                                .foregroundStyle(Color.white.opacity(0.88))
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

                HStack(spacing: 12) {
                    TextField("Ask Watersheep...", text: $userMessage)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .foregroundStyle(.white)
                        .disabled(isSendingTextMessage)
                        .onSubmit(sendTypedMessage)

                    Button {
                        sendTypedMessage()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSendingTextMessage || userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var aiVisionBinding: Binding<Bool> {
        Binding(
            get: { streamManager.isAIVisionEnabled },
            set: { newValue in
                let previousValue = streamManager.isAIVisionEnabled
                streamManager.isAIVisionEnabled = newValue
                streamManager.handleAIVisionToggleChange(from: previousValue, to: newValue)
            }
        )
    }

    private var streamErrorBinding: Binding<Bool> {
        Binding(
            get: { streamManager.showStreamError },
            set: { newValue in
                if !newValue {
                    streamManager.dismissStreamError()
                }
            }
        )
    }

    private var canControlCamera: Bool {
        switch streamManager.streamViewModel.streamState {
        case .connecting, .stopping:
            return false
        case .idle, .streaming, .failed:
            return wearablesViewModel.registrationState == .registered && streamManager.hasActiveDevice
        }
    }

    private var connectionStatus: String {
        if wearablesViewModel.registrationState != .registered {
            return "Not connected. Use Connect Glasses to register with Meta AI."
        }
        if streamManager.isStreamRunning {
            return streamManager.streamViewModel.statusMessage
        }
        if streamManager.hasActiveDevice {
            return "Connected. Glasses are ready to stream."
        }
        return "Connected. Waiting for glasses to become active."
    }

    private var streamStatusTone: StatusChip.Tone {
        switch streamManager.streamViewModel.streamState {
        case .streaming:
            return streamManager.streamViewModel.hasReceivedFirstFrame ? .success : .warning
        case .connecting, .stopping:
            return .warning
        case .failed:
            return .danger
        case .idle:
            return .neutral
        }
    }

    private var aiVisionStatus: String {
        if !streamManager.isAIVisionEnabled {
            return "Off"
        }
        if streamManager.aiVisionStatusMessage != "On" {
            return streamManager.aiVisionStatusMessage
        }
        if streamManager.isAnalyzingFrame {
            return "On and analyzing"
        }
        return "On"
    }

    private var lastNetworkError: String {
        streamManager.lastNetworkError?.isEmpty == false ? streamManager.lastNetworkError! : "None"
    }

    private var loadingCard: some View {
        GlassCard {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preparing camera workspace")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Loading the assistant, scene summary, and debug surfaces after the preview is visible.")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.68))
                }
            }
        }
    }

    private func sendTypedMessage() {
        let message = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSendingTextMessage else { return }

        isSendingTextMessage = true
        userMessage = ""
        print("User message sent: \(message)")

        Task {
            await streamManager.sendAssistantRequest(for: message)
            await MainActor.run {
                print("Assistant reply: \(streamManager.latestAssistantReply)")
                isSendingTextMessage = false
            }
        }
    }
}
