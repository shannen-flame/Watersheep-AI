import MWDATCore
import SwiftUI

private enum AppTab: Hashable {
    case home
    case camera
    case assistant
    case memory
    case settings
}

struct MainAppView: View {
    let wearables: WearablesInterface
    @ObservedObject private var viewModel: WearablesViewModel
    @StateObject private var streamManager: GlassesStreamManager
    @StateObject private var microphoneDebugManager = MicrophoneDebugManager()
    @StateObject private var memoryTimelineViewModel = MemoryTimelineViewModel()
    @StateObject private var reminderManager = ReminderManager.shared
    @State private var selectedTab: AppTab = .home
    @State private var hasPerformedInitialHealthCheck = false

    init(wearables: WearablesInterface, viewModel: WearablesViewModel) {
        self.wearables = wearables
        self.viewModel = viewModel
        _streamManager = StateObject(wrappedValue: GlassesStreamManager(wearables: wearables))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeScreenView(
                    viewModel: viewModel,
                    streamManager: streamManager,
                    microphoneDebugManager: microphoneDebugManager,
                    memoryTimelineViewModel: memoryTimelineViewModel,
                    reminderManager: reminderManager
                )
            }
            .tag(AppTab.home)
            .tabItem {
                Label("Home", systemImage: "house")
            }

            NavigationStack {
                MainWatersheepView(
                    wearablesViewModel: viewModel,
                    streamManager: streamManager,
                    microphoneDebugManager: microphoneDebugManager
                )
            }
            .tag(AppTab.camera)
            .tabItem {
                Label("Camera", systemImage: "camera")
            }

            NavigationStack {
                VoiceAssistantView(
                    streamManager: streamManager,
                    microphoneDebugManager: microphoneDebugManager
                )
            }
            .tag(AppTab.assistant)
            .tabItem {
                Label("Assistant", systemImage: "waveform.circle")
            }

            NavigationStack {
                MemoryTimelineView(
                    viewModel: memoryTimelineViewModel,
                    reminderManager: reminderManager
                )
            }
            .tag(AppTab.memory)
            .tabItem {
                Label("Memory", systemImage: "clock.arrow.circlepath")
            }

            NavigationStack {
                SettingsView(
                    streamManager: streamManager,
                    wearablesViewModel: viewModel,
                    microphoneDebugManager: microphoneDebugManager
                )
            }
            .tag(AppTab.settings)
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
        }
        .task {
            guard !hasPerformedInitialHealthCheck else { return }
            hasPerformedInitialHealthCheck = true
            await streamManager.checkBackendHealth()
            await streamManager.loadPersistedConversationHistory()
            memoryTimelineViewModel.recordSystemEvent("Backend health check completed for the current app session.")
        }
        .task(id: microphoneDebugManager.pendingCommand) {
            guard let command = microphoneDebugManager.pendingCommand else { return }
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else {
                microphoneDebugManager.clearPendingCommand()
                return
            }
            microphoneDebugManager.stopListening()
            memoryTimelineViewModel.recordCommand(trimmedCommand)
            await streamManager.sendAssistantRequest(for: trimmedCommand, source: "voice")
            microphoneDebugManager.clearPendingCommand()
        }
        .onChange(of: streamManager.currentScene) { _, scene in
            memoryTimelineViewModel.recordScene(scene)
        }
        .onChange(of: streamManager.latestAssistantReply) { _, reply in
            memoryTimelineViewModel.recordAssistantReply(reply)
        }
        .onChange(of: viewModel.registrationState) { _, _ in
            memoryTimelineViewModel.recordConnectionState(connectionSummary)
        }
        .onChange(of: selectedTab) { _, _ in }
    }

    private var connectionSummary: String {
        switch viewModel.registrationState {
        case .registering:
            return "Registration in progress."
        case .registered:
            return "Glasses connected and ready."
        default:
            return "Unknown registration state."
        }
    }
}
