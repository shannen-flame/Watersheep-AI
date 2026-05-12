import SwiftUI

struct VoiceAssistantView: View {
    @ObservedObject var streamManager: GlassesStreamManager
    @ObservedObject var microphoneDebugManager: MicrophoneDebugManager
    @ObservedObject private var speechManager = SpeechManager.shared

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    var body: some View {
        ZStack {
            AppBackground()

            VStack(spacing: 0) {
                statusBar
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                conversationFeed
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .padding(.top, 8)
            }
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: microphoneDebugManager.isListening) { _, isListening in
            if isListening {
                startPulse()
            } else {
                stopPulse()
            }
        }
    }

    // MARK: — Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            listeningChip
            if speechManager.isSpeaking {
                StatusChip("Speaking", tone: .warning)
            }
            StatusChip(
                streamManager.backendHealthStatus == "Backend Connected" ? "Online" : "Offline",
                tone: streamManager.backendHealthStatus == "Backend Connected" ? .success : .danger
            )
            Spacer()
            if streamManager.isAssistantRequestInProgress {
                ProgressView()
                    .scaleEffect(0.75)
                    .tint(Color.white.opacity(0.6))
            }
        }
    }

    private var listeningChip: some View {
        HStack(spacing: 6) {
            if microphoneDebugManager.isListening {
                micWaveform
            } else {
                Circle()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
            Text(microphoneDebugManager.isListening ? "Listening" : "Idle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            microphoneDebugManager.isListening
                ? Color.cyan.opacity(0.18)
                : Color.white.opacity(0.08),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(
                    microphoneDebugManager.isListening ? Color.cyan.opacity(0.5) : Color.clear,
                    lineWidth: 1
                )
        )
    }

    private var micWaveform: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.cyan)
                    .frame(width: 2, height: CGFloat([5, 8, 5][i]))
                    .animation(
                        .easeInOut(duration: 0.5)
                            .repeatForever()
                            .delay(Double(i) * 0.15),
                        value: microphoneDebugManager.isListening
                    )
            }
        }
    }

    // MARK: — Conversation Feed

    private var conversationFeed: some View {
        Group {
            if streamManager.conversationHistory.filter({ $0.role != .system }).isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(streamManager.conversationHistory.filter { $0.role != .system }) { turn in
                                ChatBubble(turn: turn)
                                    .id(turn.id)
                            }
                            if streamManager.isAssistantRequestInProgress {
                                thinkingBubble
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                    }
                    .onChange(of: streamManager.conversationHistory.count) { _, _ in
                        if let last = streamManager.conversationHistory.last {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.cyan.opacity(0.12 - Double(i) * 0.03))
                        .frame(width: CGFloat(100 + i * 50), height: CGFloat(100 + i * 50))
                        .scaleEffect(pulseScale)
                        .opacity(pulseOpacity)
                        .animation(
                            .easeInOut(duration: 1.8)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.3),
                            value: pulseScale
                        )
                }

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.3), Color.blue.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 100, height: 100)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.cyan.opacity(0.4), lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(Color.cyan.opacity(0.9))
                    )
            }
            .onAppear {
                pulseScale = 1.08
                pulseOpacity = 0.3
            }

            VStack(spacing: 8) {
                Text("Tap to talk")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Ask me anything — I'm your man")
                    .font(.subheadline)
                    .foregroundStyle(Color.white.opacity(0.55))
            }

            Spacer()
        }
    }

    private var thinkingBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Circle()
                .fill(Color.cyan.opacity(0.2))
                .frame(width: 32, height: 32)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(Color.cyan)
                )

            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .scaleEffect(pulseScale)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.2),
                            value: pulseScale
                        )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08))
            )

            Spacer()
        }
    }

    // MARK: — Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 12) {
            if !microphoneDebugManager.liveTranscript.isEmpty
                && microphoneDebugManager.liveTranscript != "Tap Start Listening to begin."
                && microphoneDebugManager.isListening {
                liveTranscriptBanner
            }

            HStack(spacing: 16) {
                if speechManager.isSpeaking {
                    stopSpeakingButton
                }

                Spacer()

                micButton

                Spacer()

                replayButton
                    .opacity(!speechManager.lastSpokenText.isEmpty ? 1 : 0.35)
                    .disabled(speechManager.lastSpokenText.isEmpty)
            }

            Toggle("Auto-speak replies", isOn: $speechManager.isAutoSpeakEnabled)
                .tint(.cyan)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.65))
        }
    }

    private var liveTranscriptBanner: some View {
        Text(microphoneDebugManager.liveTranscript)
            .font(.footnote)
            .foregroundStyle(Color.cyan.opacity(0.9))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.cyan.opacity(0.25))
            )
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.spring(duration: 0.35), value: microphoneDebugManager.liveTranscript)
    }

    private var micButton: some View {
        Button {
            if microphoneDebugManager.isListening {
                microphoneDebugManager.stopListening()
            } else {
                microphoneDebugManager.startAssistantListening()
            }
        } label: {
            ZStack {
                if microphoneDebugManager.isListening {
                    ForEach(0..<2, id: \.self) { i in
                        Circle()
                            .strokeBorder(Color.cyan.opacity(0.25 - Double(i) * 0.1))
                            .frame(width: CGFloat(76 + i * 24), height: CGFloat(76 + i * 24))
                            .scaleEffect(pulseScale)
                            .animation(
                                .easeInOut(duration: 1.2)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(i) * 0.2),
                                value: pulseScale
                            )
                    }
                }

                Circle()
                    .fill(
                        microphoneDebugManager.isListening
                        ? LinearGradient(
                            colors: [Color.cyan, Color.blue.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [Color.white.opacity(0.15), Color.white.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                microphoneDebugManager.isListening ? Color.cyan.opacity(0.6) : Color.white.opacity(0.15),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(
                        color: microphoneDebugManager.isListening ? Color.cyan.opacity(0.35) : .clear,
                        radius: 16, x: 0, y: 4
                    )

                Image(systemName: microphoneDebugManager.isListening ? "stop.fill" : "mic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: microphoneDebugManager.isListening)
    }

    private var replayButton: some View {
        Button {
            speechManager.replayLastResponse()
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.07), in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    private var stopSpeakingButton: some View {
        Button {
            speechManager.stopSpeaking()
        } label: {
            Image(systemName: "speaker.slash.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.orange.opacity(0.9))
                .frame(width: 48, height: 48)
                .background(Color.orange.opacity(0.1), in: Circle())
                .overlay(Circle().strokeBorder(Color.orange.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }

    // MARK: — Pulse helpers

    private func startPulse() {
        pulseScale = 1.12
        pulseOpacity = 0.2
    }

    private func stopPulse() {
        pulseScale = 1.0
        pulseOpacity = 0.6
    }
}

// MARK: — Chat Bubble

private struct ChatBubble: View {
    let turn: ConversationTurn

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if turn.role == .user {
                Spacer(minLength: 56)
                bubbleContent
            } else {
                avatar
                bubbleContent
                Spacer(minLength: 56)
            }
        }
    }

    private var avatar: some View {
        Circle()
            .fill(Color.cyan.opacity(0.15))
            .frame(width: 32, height: 32)
            .overlay(
                Image(systemName: "waveform")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.cyan)
            )
    }

    private var bubbleContent: some View {
        Text(turn.text)
            .font(.callout)
            .foregroundStyle(turn.role == .user ? Color.white : Color.white.opacity(0.88))
            .multilineTextAlignment(turn.role == .user ? .trailing : .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(bubbleBackground, in: bubbleShape)
    }

    private var bubbleBackground: some ShapeStyle {
        if turn.role == .user {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.cyan.opacity(0.4), Color.blue.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(Color.white.opacity(0.09))
    }

    private var bubbleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
    }
}
