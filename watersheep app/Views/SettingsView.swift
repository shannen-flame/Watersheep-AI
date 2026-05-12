import MWDATCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var streamManager: GlassesStreamManager
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @ObservedObject var microphoneDebugManager: MicrophoneDebugManager
    @StateObject private var reminderManager = ReminderManager.shared
    @StateObject private var speechManager = SpeechManager.shared
    @AppStorage(APIConfiguration.userDefaultsKey) private var backendURL = APIConfiguration.resolvedBaseURLString
    @AppStorage(OllamaVisionConfiguration.userDefaultsKey) private var ollamaVisionURL = OllamaVisionConfiguration.resolvedBaseURLString
    @AppStorage("settings.saveMemoriesAutomatically") private var saveMemoriesAutomatically = true
    @AppStorage("settings.wakeWordPlaceholderEnabled") private var wakeWordPlaceholderEnabled = false
    @AppStorage("settings.debugModeEnabled") private var debugModeEnabled = false
    @AppStorage("settings.preferredChatProvider") private var preferredChatProvider: String = "auto"
    @State private var connectionAlert: ConnectionAlert?
    @State private var isTestingConnection = false
    @State private var isTestingOllama = false
    @State private var diagnostics: DiagnosticsResponse?
    @State private var diagnosticsError: String?
    @State private var isLoadingDiagnostics = false

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    diagnosticsCard
                    backendCard
                    ollamaCard
                    assistantCard
                    permissionCard
                    runtimeCard
                }
                .padding(20)
            }
        }
        .task {
            await refreshDiagnostics()
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $connectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var heroCard: some View {
        GlassCard(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Settings", subtitle: "Configure backend, voice, vision, and development behavior.")

                HStack(spacing: 10) {
                    StatusChip(streamManager.backendHealthStatus == "Backend Connected" ? "Backend Online" : "Backend Offline", tone: backendTone)
                    StatusChip(speechManager.isAutoSpeakEnabled ? "Auto Speak On" : "Auto Speak Off", tone: speechManager.isAutoSpeakEnabled ? .success : .neutral)
                    StatusChip(debugModeEnabled ? "Debug On" : "Debug Off", tone: debugModeEnabled ? .warning : .neutral)
                }
            }
        }
    }

    private var backendCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Backend", subtitle: "Point the app at your Watersheep backend.")

                VStack(alignment: .leading, spacing: 8) {
                    Text("BACKEND URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.5))

                    TextField("http://192.168.1.224:8000", text: $backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onSubmit {
                            persistBackendURL()
                        }
                }

                DetailRow(title: "Current Status", value: streamManager.backendHealthStatus)
                DetailRow(title: "Resolved URL", value: backendURL)

                FloatingActionButton(
                    title: isTestingConnection ? "Testing Connection..." : "Test Connection",
                    systemImage: "dot.radiowaves.left.and.right",
                    isEnabled: !isTestingConnection
                ) {
                    Task {
                        await testConnection()
                    }
                }
            }
        }
    }

    private var assistantCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Assistant", subtitle: "Voice playback, wake behavior, and debug controls.")

                VStack(alignment: .leading, spacing: 8) {
                    Text("CHAT LLM")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.5))

                    Picker("Chat LLM", selection: $preferredChatProvider) {
                        Text("Auto (backend chooses)").tag("auto")
                        Text("Ollama (local)").tag("ollama")
                        Text("Gemini").tag("gemini")
                        Text("OpenRouter").tag("openrouter")
                    }
                    .pickerStyle(.menu)
                    .tint(.cyan)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    Text("Vision always tries Gemini first, then falls back to OpenRouter (and Ollama if you enable it on the backend).")
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.55))
                }

                settingsToggle("Auto Speak Responses", isOn: $speechManager.isAutoSpeakEnabled)
                settingsToggle("Save Memories Automatically", isOn: $saveMemoriesAutomatically)
                settingsToggle("Wake Word Placeholder", isOn: $wakeWordPlaceholderEnabled)
                settingsToggle("Debug Mode", isOn: $debugModeEnabled)
                settingsToggle("Force iPhone Mic", isOn: $speechManager.forceIPhoneMic)

                DetailRow(
                    title: "Last Chat Provider",
                    value: chatProviderSummary
                )
                DetailRow(
                    title: "Last Spoken Reply",
                    value: speechManager.lastSpokenText.isEmpty ? "None" : speechManager.lastSpokenText
                )
                DetailRow(title: "Speech Error", value: speechManager.speechError)
            }
        }
    }

    private var chatProviderSummary: String {
        let provider = streamManager.lastChatProvider.isEmpty ? "—" : streamManager.lastChatProvider.capitalized
        if streamManager.lastChatModel.isEmpty {
            return provider
        }
        return "\(provider) (\(streamManager.lastChatModel))"
    }

    private var ollamaCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader("Vision Backend", subtitle: "Local model analysis is proxied through the backend so the phone does not need direct Ollama access.")

                VStack(alignment: .leading, spacing: 8) {
                    Text("VISION BACKEND URL")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.5))

                    TextField("http://192.168.1.224:8000", text: $ollamaVisionURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onSubmit {
                        persistOllamaURL()
                    }
                }

                DetailRow(title: "Resolved URL", value: ollamaVisionURL)

                FloatingActionButton(
                    title: isTestingOllama ? "Testing Vision..." : "Test Vision",
                    systemImage: "cpu",
                    isEnabled: !isTestingOllama
                ) {
                    Task {
                        await testOllama()
                    }
                }
            }
        }
    }

    private var permissionCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Permissions & Devices", subtitle: "Check input and wearable readiness at a glance.")
                DetailRow(title: "Microphone", value: microphoneDebugManager.microphonePermissionStatus)
                DetailRow(title: "Speech Recognition", value: microphoneDebugManager.speechRecognitionState)
                DetailRow(title: "Notifications", value: reminderManager.authorizationStatus)
                DetailRow(title: "Bluetooth Power", value: wearablesViewModel.bluetoothStateSummary)
                DetailRow(title: "Bluetooth Access", value: wearablesViewModel.bluetoothPermissionSummary)
                DetailRow(title: "Glasses Registration", value: registrationStatus)
                DetailRow(title: "Glasses Devices", value: wearablesViewModel.deviceSummary)
                DetailRow(title: "Glasses Session", value: wearablesViewModel.sessionSummary)
                DetailRow(title: "Listening State", value: microphoneDebugManager.listeningState)
            }
        }
    }

    private var runtimeCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Runtime", subtitle: "Live app state for streaming, vision, and backend connectivity.")
                DetailRow(title: "Streaming", value: streamManager.isStreamRunning ? "Active" : "Idle")
                DetailRow(title: "Stream State", value: streamManager.streamViewModel.streamState.title)
                DetailRow(title: "Active Device", value: streamManager.hasActiveDevice ? "Yes" : "No")
                DetailRow(title: "Stream Codec", value: streamManager.streamViewModel.activeCodec)
                DetailRow(title: "Frame Counters", value: "\(streamManager.streamViewModel.frameCount) frames / \(streamManager.streamViewModel.rawFrameCallbackCount) callbacks / \(streamManager.streamViewModel.decodeFailureCount) decode fails")
                DetailRow(title: "AI Vision", value: streamManager.isAIVisionEnabled ? "Enabled" : "Disabled")
                DetailRow(title: "Last Image Provider", value: VisionProvider.fromBackend(streamManager.visionProviderUsed).displayName)
                DetailRow(title: "Last Chat Provider", value: chatProviderRuntimeValue)
                DetailRow(title: "Image Routing", value: "Gemini first; Ollama, OpenRouter, then local only after Gemini fails.")
                DetailRow(title: "Wake Mode", value: microphoneDebugManager.wakeModeEnabled ? "On" : "Off")
                DetailRow(title: "Reminders", value: "\(reminderManager.upcomingReminders.count) scheduled")
                DetailRow(title: "Stream Error", value: streamManager.streamErrorMessage.isEmpty ? "None" : streamManager.streamErrorMessage)
                DetailRow(title: "Network Error", value: streamManager.lastNetworkError ?? "None")
            }
        }
    }

    private var registrationStatus: String {
        switch wearablesViewModel.registrationState {
        case .registering:
            return "Connecting"
        case .registered:
            return "Connected"
        default:
            return "Unknown"
        }
    }

    private var chatProviderRuntimeValue: String {
        let provider = streamManager.lastChatProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.isEmpty {
            return "None yet"
        }
        let model = streamManager.lastChatModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? provider : "\(provider) (\(model))"
    }

    private var backendTone: StatusChip.Tone {
        streamManager.backendHealthStatus == "Backend Connected" ? .success : .warning
    }

    private func settingsToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .foregroundStyle(.white)
        }
        .tint(.cyan)
    }

    private func persistBackendURL() {
        let trimmed = APIConfiguration.normalizedBaseURLString(
            for: backendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        backendURL = trimmed.isEmpty ? APIConfiguration.fallbackBaseURLString : trimmed
        streamManager.refreshBackendConfiguration()
    }

    private func persistOllamaURL() {
        let trimmed = APIConfiguration.normalizedBaseURLString(
            for: ollamaVisionURL.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        if let components = URLComponents(string: trimmed), components.port == 11434 {
            ollamaVisionURL = APIConfiguration.resolvedBaseURLString
            UserDefaults.standard.removeObject(forKey: OllamaVisionConfiguration.userDefaultsKey)
            return
        }
        ollamaVisionURL = trimmed.isEmpty ? OllamaVisionConfiguration.resolvedBaseURLString : trimmed
        streamManager.refreshBackendConfiguration()
    }

    private var diagnosticsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    SectionHeader(
                        "Diagnostics",
                        subtitle: "Live backend, AI, and database health."
                    )
                    Spacer()
                    Button {
                        Task { await refreshDiagnostics() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoadingDiagnostics)
                }

                if isLoadingDiagnostics {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Checking…")
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                } else if let diagnostics {
                    diagnosticsRow(
                        title: "Ollama",
                        provider: diagnostics.ollama,
                        extra: diagnostics.ollama.expectedModelAvailable == true
                            ? "Has \(diagnostics.ollama.expectedModel ?? "model")"
                            : (diagnostics.ollama.expectedModel.map { "Missing \($0)" } ?? nil)
                    )
                    diagnosticsRow(title: "Gemini", provider: diagnostics.gemini, extra: nil)
                    if let openrouter = diagnostics.openrouter {
                        diagnosticsRow(title: "OpenRouter", provider: openrouter, extra: nil)
                    }
                    diagnosticsRow(title: "Database", provider: diagnostics.database, extra: nil)
                    DetailRow(
                        title: "Environment",
                        value: "\(diagnostics.environment) • debug \(diagnostics.debugEndpointsEnabled ? "on" : "off")"
                    )
                } else if let diagnosticsError {
                    Text(diagnosticsError)
                        .font(.subheadline)
                        .foregroundStyle(Color.orange.opacity(0.9))
                }
            }
        }
    }

    private func diagnosticsRow(title: String, provider: DiagnosticsProviderHealth, extra: String?) -> some View {
        let tone: StatusChip.Tone = provider.available ? .success : .warning
        var detailLines: [String] = [provider.detail]
        if let latency = provider.latencyMs {
            detailLines.append("\(latency) ms")
        }
        if let extra, !extra.isEmpty {
            detailLines.append(extra)
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                StatusChip(title, tone: tone)
                Spacer()
                Text(provider.available ? "OK" : "Unavailable")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(provider.available ? .green : .orange)
            }
            Text(detailLines.joined(separator: " • "))
                .font(.subheadline)
                .foregroundStyle(Color.white.opacity(0.78))
                .textSelection(.enabled)
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func refreshDiagnostics() async {
        isLoadingDiagnostics = true
        defer { isLoadingDiagnostics = false }

        do {
            let client = try APIClient()
            diagnostics = try await client.diagnostics()
            diagnosticsError = nil
        } catch {
            diagnostics = nil
            diagnosticsError = "Could not load diagnostics: \(error.localizedDescription)"
        }
    }

    private func testConnection() async {
        persistBackendURL()
        isTestingConnection = true
        defer { isTestingConnection = false }

        await streamManager.checkBackendHealth()
        backendURL = streamManager.loadedBackendBaseURL
        if streamManager.backendHealthStatus == "Backend Connected" {
            connectionAlert = ConnectionAlert(
                title: "Connection Successful",
                message: "Watersheep connected to \(backendURL)."
            )
        } else {
            connectionAlert = ConnectionAlert(
                title: "Connection Failed",
                message: streamManager.lastNetworkError ?? "No local backend URL responded."
            )
        }
    }

    private func testOllama() async {
        persistOllamaURL()
        isTestingOllama = true
        defer { isTestingOllama = false }

        do {
            let service = try OllamaVisionService(baseURLString: ollamaVisionURL)
            let result = await service.healthCheck()
            connectionAlert = ConnectionAlert(
                title: result.isReachable ? "Vision Reachable" : "Vision Unavailable",
                message: result.message
            )
        } catch {
            connectionAlert = ConnectionAlert(
                title: "Vision Failed",
                message: error.localizedDescription
            )
        }
    }
}

private struct ConnectionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

#Preview {
    NavigationStack {
        SettingsView(
            streamManager: GlassesStreamManager(wearables: Wearables.shared),
            wearablesViewModel: WearablesViewModel(wearables: Wearables.shared),
            microphoneDebugManager: MicrophoneDebugManager()
        )
    }
}
