import MWDATCore
import SwiftUI

struct HomeScreenView: View {
    @ObservedObject var viewModel: WearablesViewModel
    @ObservedObject var streamManager: GlassesStreamManager
    @ObservedObject var microphoneDebugManager: MicrophoneDebugManager
    @ObservedObject var memoryTimelineViewModel: MemoryTimelineViewModel
    @ObservedObject var reminderManager: ReminderManager

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heroCard
                    statusCard
                    quickActionsCard
                    navigationCard
                }
                .padding(20)
            }
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var heroCard: some View {
        GlassCard(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Watersheep")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Context-aware second brain for wearable AI assistance.")
                        .font(.headline)
                        .foregroundStyle(Color.white.opacity(0.74))
                }

                Toggle(isOn: privacyModeBinding) {
                    HStack(spacing: 8) {
                        Image(systemName: streamManager.isPrivacyModeEnabled ? "lock.shield.fill" : "lock.shield")
                        Text(streamManager.isPrivacyModeEnabled ? "Privacy Mode On" : "Privacy Mode Off")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                }
                .tint(.red)

                HStack(spacing: 10) {
                    StatusChip(connectionChipTitle, tone: connectionChipTone)
                    StatusChip(streamManager.backendHealthStatus == "Backend Connected" ? "Backend Online" : "Backend Offline", tone: backendChipTone)
                    StatusChip(streamManager.isAIVisionEnabled ? "AI Vision On" : "AI Vision Off", tone: streamManager.isAIVisionEnabled ? .success : .neutral)
                }

                HStack(spacing: 12) {
                    FloatingActionButton(
                        title: microphoneDebugManager.isListening ? "Listening..." : "Talk to Watersheep",
                        systemImage: microphoneDebugManager.isListening ? "waveform.circle.fill" : "mic.fill",
                        isEnabled: !microphoneDebugManager.isListening
                    ) {
                        microphoneDebugManager.startSingleCommandListening()
                    }

                    Button {
                        Task {
                            if streamManager.isStreamRunning {
                                await streamManager.stopCamera()
                            } else {
                                await streamManager.startCamera()
                            }
                        }
                    } label: {
                        Image(systemName: streamManager.isStreamRunning ? "stop.fill" : "camera.fill")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.registrationState != .registered)
                }

                if viewModel.registrationState != .registered {
                    FloatingActionButton(
                        title: viewModel.registrationState == .registering ? "Connecting Glasses..." : "Connect Glasses",
                        systemImage: "dot.radiowaves.left.and.right",
                        isEnabled: viewModel.registrationState != .registering
                    ) {
                        print("Connect glasses button tapped")
                        viewModel.connectGlasses()
                    }
                }
            }
        }
    }

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("System Status", subtitle: "Live wearable, backend, and assistant readiness.")
                DetailRow(title: "Connection", value: connectionStatus)
                DetailRow(title: "Backend", value: streamManager.backendHealthStatus)
                DetailRow(title: "AI Vision", value: aiVisionStatus)
                DetailRow(title: "Latest Scene", value: streamManager.currentScene)
                DetailRow(title: "Reminders", value: streamManager.reminderStatusText)
            }
        }
    }

    private var quickActionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Quick Actions", subtitle: "Common prompts for scene help and memory.")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(HomeQuickAction.allCases) { action in
                        Button {
                            performQuickAction(action)
                        } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: action.icon)
                                        .font(.title3.weight(.semibold))
                                    Spacer()
                                    if actionState(for: action).isLoading {
                                        ProgressView()
                                            .tint(.white)
                                    }
                                }
                                Text(action.rawValue)
                                    .font(.headline)
                                    .multilineTextAlignment(.leading)
                                Text(actionStatusText(for: action))
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.62))
                            }
                            .foregroundStyle(.white)
                            .padding(16)
                            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(actionState(for: action).isLoading)
                    }
                }
            }
        }
    }

    private var navigationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader("Explore", subtitle: "Jump into the core Watersheep workflows.")

                NavigationLink {
                    MemoryTimelineView(
                        viewModel: memoryTimelineViewModel,
                        reminderManager: reminderManager
                    )
                } label: {
                    navigationRow(title: "Memory", subtitle: "Search captured memories and assistant history", icon: "clock.arrow.circlepath")
                }

                NavigationLink {
                    SettingsView(
                        streamManager: streamManager,
                        wearablesViewModel: viewModel,
                        microphoneDebugManager: microphoneDebugManager
                    )
                } label: {
                    navigationRow(title: "Settings", subtitle: "Backend, voice, permissions, and debug", icon: "gearshape")
                }

                NavigationLink {
                    CameraDebugInfoView(
                        streamManager: streamManager,
                        wearablesViewModel: viewModel,
                        microphoneDebugManager: microphoneDebugManager
                    )
                } label: {
                    navigationRow(title: "Debug", subtitle: "Camera diagnostics and hybrid vision tooling", icon: "ladybug")
                }
            }
        }
    }

    private func navigationRow(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.68))
            }

            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.vertical, 4)
    }

    private var privacyModeBinding: Binding<Bool> {
        Binding(
            get: { streamManager.isPrivacyModeEnabled },
            set: { streamManager.isPrivacyModeEnabled = $0 }
        )
    }

    private var connectionStatus: String {
        switch viewModel.registrationState {
        case .registering:
            return "Connecting to Meta glasses."
        case .registered:
            return streamManager.isStreamRunning ? "Connected and streaming." : "Connected and ready."
        default:
            return "Waiting for connection."
        }
    }

    private var aiVisionStatus: String {
        if !streamManager.isAIVisionEnabled {
            return "Off"
        }
        return streamManager.isAnalyzingFrame ? "Analyzing live scene." : streamManager.aiVisionStatusMessage
    }

    private var connectionChipTitle: String {
        switch viewModel.registrationState {
        case .registering:
            return "Connecting"
        case .registered:
            return "Glasses Ready"
        default:
            return "Disconnected"
        }
    }

    private var connectionChipTone: StatusChip.Tone {
        switch viewModel.registrationState {
        case .registering:
            return .warning
        case .registered:
            return .success
        default:
            return .danger
        }
    }

    private var backendChipTone: StatusChip.Tone {
        streamManager.backendHealthStatus == "Backend Connected" ? .success : .warning
    }

    private func performQuickAction(_ action: HomeQuickAction) {
        Task {
            await streamManager.performQuickAction(actionID: action.actionID, source: "home")
        }
    }

    private func actionState(for action: HomeQuickAction) -> AssistantActionState {
        streamManager.quickActionStates[action.actionID] ?? .idle
    }

    private func actionStatusText(for action: HomeQuickAction) -> String {
        switch actionState(for: action) {
        case .idle:
            return action.subtitle
        case .loading:
            return "Working..."
        case .succeeded:
            return "Done"
        case .failed(let message):
            return message.isEmpty ? "Failed" : message
        }
    }
}

private struct CameraDebugInfoView: View {
    @ObservedObject var streamManager: GlassesStreamManager
    @ObservedObject var wearablesViewModel: WearablesViewModel
    @ObservedObject var microphoneDebugManager: MicrophoneDebugManager

    var body: some View {
        ZStack {
            AppBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GlassCard(padding: 22) {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader("Debug Access", subtitle: "Use the Camera tab for live preview and hybrid vision diagnostics.")
                            StatusChip(streamManager.isStreamRunning ? "Camera Active" : "Camera Idle", tone: streamManager.isStreamRunning ? .success : .warning)
                            StatusChip(streamManager.isAIVisionEnabled ? "AI Vision On" : "AI Vision Off", tone: streamManager.isAIVisionEnabled ? .success : .neutral)
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader("Current State", subtitle: "Lightweight diagnostics without constructing the full camera workspace.")
                            DetailRow(title: "Backend", value: streamManager.backendHealthStatus)
                            DetailRow(title: "Connection", value: wearablesViewModel.registrationState == .registered ? "Registered" : "Not registered")
                            DetailRow(title: "Devices", value: wearablesViewModel.deviceSummary)
                            DetailRow(title: "Device Session", value: wearablesViewModel.sessionSummary)
                            DetailRow(title: "Active Device", value: streamManager.hasActiveDevice ? "Yes" : "No")
                            DetailRow(title: "Stream", value: streamManager.streamViewModel.streamState.title)
                            DetailRow(title: "Codec", value: streamManager.streamViewModel.activeCodec)
                            DetailRow(title: "Frames", value: "\(streamManager.streamViewModel.frameCount) frames / \(streamManager.streamViewModel.rawFrameCallbackCount) callbacks / \(streamManager.streamViewModel.decodeFailureCount) decode fails")
                            DetailRow(title: "Stream Error", value: streamManager.streamErrorMessage.isEmpty ? "None" : streamManager.streamErrorMessage)
                            DetailRow(title: "Listening", value: microphoneDebugManager.listeningState)
                            DetailRow(title: "Latest Scene", value: streamManager.currentScene)
                            DetailRow(title: "Reminders", value: streamManager.reminderStatusText)
                        }
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum HomeQuickAction: String, CaseIterable, Identifiable {
    case whatAmILookingAt = "What am I looking at?"
    case rememberThis = "Remember this"
    case recallMemory = "Recall memory"
    case summariseMyDay = "Summarise my day"

    var id: String { rawValue }

    var actionID: String {
        switch self {
        case .whatAmILookingAt: return "what_am_i_looking_at"
        case .rememberThis: return "remember_this"
        case .recallMemory: return "recall_memory"
        case .summariseMyDay: return "summarise_day"
        }
    }

    var subtitle: String {
        switch self {
        case .whatAmILookingAt: return "Analyze the current scene"
        case .rememberThis: return "Save useful active context"
        case .recallMemory: return "Search recent memories"
        case .summariseMyDay: return "Summarize today"
        }
    }

    var icon: String {
        switch self {
        case .whatAmILookingAt: return "eye"
        case .rememberThis: return "bookmark"
        case .recallMemory: return "clock.arrow.circlepath"
        case .summariseMyDay: return "text.alignleft"
        }
    }
}

#Preview {
    NavigationStack {
        HomeScreenView(
            viewModel: WearablesViewModel(wearables: Wearables.shared),
            streamManager: GlassesStreamManager(wearables: Wearables.shared),
            microphoneDebugManager: MicrophoneDebugManager(),
            memoryTimelineViewModel: MemoryTimelineViewModel(),
            reminderManager: ReminderManager.shared
        )
    }
    .preferredColorScheme(.dark)
}
