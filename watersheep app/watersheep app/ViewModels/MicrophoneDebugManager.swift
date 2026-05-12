import AVFoundation
import Combine
import Speech

@MainActor
final class MicrophoneDebugManager: NSObject, ObservableObject, SpeechRecognitionCoordinating {
    private enum ListeningConstants {
        static let silenceTimeoutSeconds: Double = 4.5
        static let finalizationDelaySeconds: Double = 1.25
    }

    enum Mode {
        case idle
        case test
        case wake
        case command
    }

    @Published var microphonePermissionStatus = "Unknown"
    @Published var recordingStatus = "Idle"
    @Published var liveTranscript = "Tap Start Listening to begin."
    @Published var rawRecognizedTranscript = "No speech detected"
    @Published var normalizedTranscript = "No speech detected"
    @Published var wakeWordDetected = false
    @Published var speechRecognitionState = "Idle"
    @Published var lastPartialTranscript = "None"
    @Published var finalTranscript = "None"
    @Published var recognitionEndStatus = "Not finished"
    @Published var speechRecognitionError = "None"
    @Published var wakeModeEnabled = false
    @Published var listeningState = "Idle"
    @Published var extractedCommand = "None"
    @Published var pendingCommand: String?
    @Published var isListening = false
    @Published var isRestartScheduled = false

    var isCurrentlyListening: Bool { isListening }
    var speechRecognitionStatus: String { speechRecognitionState }
    var lastSpeechError: String { speechRecognitionError }

    private let autoRestartWakeMode = true
    private var audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var silenceWatchTask: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?
    private var hasMeaningfulTranscript = false
    private var latestUsefulTranscript = ""
    private var latestUsefulNormalizedTranscript = ""
    private var sessionID = UUID()
    private var mode: Mode = .idle
    private var lastTranscriptUpdate = Date()
    private var wakeArmedAt: Date?

    override init() {
        super.init()
        SpeechManager.shared.recognitionCoordinator = self
    }

    func startMicrophoneTest() {
        mode = .test
        Task {
            await startListening()
        }
    }

    func startSingleCommandListening() {
        mode = .command
        Task {
            await startListening()
        }
    }

    func startAssistantListening() {
        startSingleCommandListening()
    }

    func setWakeModeEnabled(_ isEnabled: Bool) {
        wakeModeEnabled = isEnabled
        listeningState = isEnabled ? "Wake mode armed" : "Wake mode off"

        restartTask?.cancel()
        restartTask = nil

        if isEnabled {
            mode = .wake
            // Start listening immediately so the user doesn't need to also tap
            // the mic button. With wake mode armed we want to be passive-on by
            // default — this is the whole point of "Hey Watersheep".
            if !isListening {
                Task { await self.startListening() }
            }
        } else {
            mode = .idle
            stopRecognition()
        }
    }

    func clearPendingCommand() {
        pendingCommand = nil
    }

    func stopListening() {
        if isListening {
            listeningState = "Stopped by user"
            recognitionEndStatus = "Stopped"
            recordingStatus = "Recording stopped"
        }
        stopRecognition()
    }

    func stopListeningForSpeechOutput() {
        stopRecognition()
    }

    func resumeWakeListeningAfterSpeechOutputIfNeeded() {
        guard wakeModeEnabled else { return }
        guard !isListening else { return }
        listeningState = "Wake restart after speech"
        scheduleWakeRestart()
    }

    func normalizeTranscript(_ text: String) -> String {
        var normalized = text.lowercased()
        let wakeWordVariants = [
            "hey watersheep",
            "hey what sheep",
            "hey sheep",
            "hey water sheep",
            "hey water ship",
            "hey watership",
            "water sheep",
            "water she",
            "what sheep",
            "what's sheep",
            "white sheep",
            "watership",
            "water ship",
            "watersheep",
        ]

        for variant in wakeWordVariants {
            normalized = normalized.replacingOccurrences(of: variant, with: "watersheep")
        }

        return normalized
    }

    func isWakeWordDetected(_ text: String) -> Bool {
        normalizeTranscript(text).contains("watersheep")
    }

    func extractCommandAfterWakeWord(_ text: String) -> String? {
        let normalized = normalizeTranscript(text)
        guard let range = normalized.range(of: "watersheep") else { return nil }

        let command = normalized[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return command.isEmpty ? nil : command
    }

    private func startListening() async {
        guard !isListening else { return }

        stopRecognition()
        resetAudioEngine()
        sessionID = UUID()
        isRestartScheduled = false
        hasMeaningfulTranscript = false
        latestUsefulTranscript = ""
        latestUsefulNormalizedTranscript = ""
        liveTranscript = "Listening..."
        rawRecognizedTranscript = "Listening..."
        normalizedTranscript = "Listening..."
        wakeWordDetected = false
        lastPartialTranscript = "None"
        finalTranscript = "None"
        recognitionEndStatus = "Listening"
        speechRecognitionError = "None"
        extractedCommand = "None"
        lastTranscriptUpdate = Date()
        recordingStatus = "Requesting permissions"
        speechRecognitionState = "Requesting permissions"
        listeningState = mode == .wake ? "Listening for wake word" : "Listening for speech"

        let hasSpeechPermission = await requestSpeechPermission()
        let hasMicrophonePermission = await requestMicrophonePermission()

        guard hasSpeechPermission, hasMicrophonePermission else {
            recordingStatus = "Recording failed"
            speechRecognitionState = "Permission denied"
            recognitionEndStatus = "Permission denied"
            listeningState = "Permission denied"
            liveTranscript = "Permission denied"
            if rawRecognizedTranscript == "Listening..." {
                rawRecognizedTranscript = "No speech detected"
                normalizedTranscript = "No speech detected"
            }
            return
        }

        guard let speechRecognizer, speechRecognizer.isAvailable else {
            recordingStatus = "Recording failed"
            speechRecognitionState = "Recognizer unavailable"
            recognitionEndStatus = "Recognizer unavailable"
            speechRecognitionError = "Speech recognizer unavailable"
            listeningState = "Recognizer unavailable"
            liveTranscript = "Speech recognizer unavailable"
            return
        }

        do {
            try await SpeechManager.shared.prepareForListeningTransition()

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
                throw NSError(
                    domain: "Watersheep.Microphone",
                    code: -10,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone input format is not ready yet."]
                )
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            installInputTap(on: inputNode)

            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            recordingStatus = "Recording started successfully"
            speechRecognitionState = "Listening"
            listeningState = mode == .wake ? "Listening for wake word" : "Listening for speech"

            let currentSessionID = sessionID
            scheduleSilenceTimeout(for: currentSessionID)

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    if let result {
                        self.handleRecognitionResult(result, sessionID: currentSessionID)
                    }

                    if let error {
                        self.handleRecognitionError(error)
                    }
                }
            }
        } catch {
            isListening = false
            recordingStatus = "Recording failed"
            speechRecognitionState = "Recognition failed"
            recognitionEndStatus = "Failed"
            speechRecognitionError = error.localizedDescription
            liveTranscript = "No speech detected"
            rawRecognizedTranscript = "No speech detected"
            normalizedTranscript = "No speech detected"
            listeningState = "Recognition failed"
            print("Speech recognition failed: \(error.localizedDescription)")
            stopRecognition()
        }
    }

    private func finalizeTranscript() {
        silenceWatchTask?.cancel()
        silenceWatchTask = nil

        if !hasMeaningfulTranscript {
            liveTranscript = "No speech detected"
            rawRecognizedTranscript = "No speech detected"
            normalizedTranscript = "No speech detected"
            wakeWordDetected = false
            extractedCommand = "None"
            speechRecognitionState = "No speech detected"
            recognitionEndStatus = "Ended with no speech"
            listeningState = "No speech detected"
        } else {
            liveTranscript = latestUsefulTranscript
            rawRecognizedTranscript = latestUsefulTranscript
            normalizedTranscript = latestUsefulNormalizedTranscript
            wakeWordDetected = isWakeWordDetected(latestUsefulTranscript)
            if speechRecognitionState != "Final transcript received" {
                speechRecognitionState = "Partial transcript received"
            }
            if finalTranscript == "None" {
                finalTranscript = latestUsefulTranscript
            }
            recognitionEndStatus = recognitionEndStatus == "Cancelled" ? "Cancelled" : "Ended normally"

            if mode == .wake {
                if let command = extractCommandAfterWakeWord(latestUsefulTranscript) {
                    extractedCommand = command
                    pendingCommand = command
                    listeningState = "Command captured"
                } else if wakeWordDetected {
                    extractedCommand = "Wake word heard, waiting for command"
                    listeningState = "Wake word detected"
                } else {
                    extractedCommand = "None"
                    listeningState = "Wake word not detected"
                }
            } else if mode == .command {
                let command = extractCommandAfterWakeWord(latestUsefulTranscript) ?? latestUsefulTranscript
                extractedCommand = command
                pendingCommand = command
                listeningState = "Command captured"
            } else {
                extractedCommand = extractCommandAfterWakeWord(latestUsefulTranscript) ?? "None"
                listeningState = "Transcript captured"
            }
        }

        recordingStatus = "Recording finished"
        stopRecognition()

        if wakeModeEnabled {
            scheduleWakeRestart()
        }
    }

    private func stopRecognition() {
        silenceWatchTask?.cancel()
        silenceWatchTask = nil
        restartTask?.cancel()
        restartTask = nil
        isRestartScheduled = false

        teardownAudioEngine()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        isListening = false
        recordingStatus = recordingStatus == "Recording failed" ? recordingStatus : "Idle"
        if speechRecognitionState == "Listening" || speechRecognitionState == "Waiting for final transcript" {
            speechRecognitionState = "Idle"
        }
    }

    private func installInputTap(on inputNode: AVAudioInputNode) {
        // Remove any previous tap before installing a new one so restarting
        // speech recognition doesn't leave the input node in an invalid state.
        inputNode.removeTap(onBus: 0)

        // The input node's output bus is already connected inside the engine
        // graph. Passing a non-nil format here can trigger a format mismatch
        // exception on restart, so we let AVAudioEngine use the bus's existing
        // native format by passing nil.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }
    }

    private func teardownAudioEngine() {
        let inputNode = audioEngine.inputNode

        if audioEngine.isRunning {
            audioEngine.stop()
        }

        inputNode.removeTap(onBus: 0)
        audioEngine.reset()
    }

    private func resetAudioEngine() {
        // Recreate the engine before each new recognition session so no stale
        // graph or tap state survives across restarts. This avoids repeated
        // tap-install crashes after a previous session has already touched the
        // input node.
        audioEngine = AVAudioEngine()
    }

    private func handleRecognitionResult(_ result: SFSpeechRecognitionResult, sessionID: UUID) {
        let transcript = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        hasMeaningfulTranscript = true
        lastTranscriptUpdate = Date()
        latestUsefulTranscript = transcript
        liveTranscript = transcript
        rawRecognizedTranscript = transcript

        let normalized = normalizeTranscript(transcript)
        latestUsefulNormalizedTranscript = normalized
        normalizedTranscript = normalized
        let wasDetected = wakeWordDetected
        wakeWordDetected = isWakeWordDetected(transcript)

        // Real wake-word behaviour: once we hear "watersheep" mid-stream, lock
        // the wake state in and let the silence timeout finalize the command.
        // This means the user doesn't have to wait for the full silence
        // timeout before the wake fires — partial detection is enough.
        if mode == .wake && wakeWordDetected && !wasDetected {
            wakeArmedAt = Date()
        }

        if result.isFinal {
            finalTranscript = transcript
            speechRecognitionState = "Final transcript received"
            recognitionEndStatus = "Ended normally"
            listeningState = "Final transcript received"
            finalizeTranscript()
        } else {
            lastPartialTranscript = transcript
            speechRecognitionState = "Partial transcript received"
            recognitionEndStatus = "Listening"
            listeningState = mode == .wake
                ? (wakeWordDetected ? "Wake word detected" : "Listening for wake word")
                : "Listening for speech"
            scheduleSilenceTimeout(for: sessionID)
        }
    }

    private func handleRecognitionError(_ error: Error) {
        let description = error.localizedDescription.lowercased()

        if description.contains("canceled"), hasMeaningfulTranscript {
            rawRecognizedTranscript = latestUsefulTranscript
            normalizedTranscript = latestUsefulNormalizedTranscript
            if finalTranscript == "None" {
                finalTranscript = latestUsefulTranscript
            }
            speechRecognitionState = "Recognition cancelled after transcript"
            recognitionEndStatus = "Cancelled"
            listeningState = "Recognition cancelled"
            recordingStatus = "Recording finished"
            liveTranscript = latestUsefulTranscript
            stopRecognition()
            if wakeModeEnabled {
                scheduleWakeRestart()
            }
            return
        }

        speechRecognitionError = error.localizedDescription
        recordingStatus = "Recording failed"
        speechRecognitionState = "Recognition failed"
        recognitionEndStatus = "Cancelled"
        listeningState = "Recognition failed"
        if !hasMeaningfulTranscript {
            liveTranscript = "No speech detected"
        }
        // "No speech detected" (kAFAssistantErrorDomain 1110) is normal in
        // wake mode — don't log it as an error.
        let isExpectedSilence = description.contains("no speech detected")
        if !isExpectedSilence {
            print("Speech recognition failed: \(error.localizedDescription)")
        }
        stopRecognition()
        if wakeModeEnabled {
            scheduleWakeRestart()
        }
    }

    private func scheduleSilenceTimeout(for sessionID: UUID) {
        silenceWatchTask?.cancel()
        silenceWatchTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ListeningConstants.silenceTimeoutSeconds))
            await MainActor.run {
                guard let self else { return }
                guard self.sessionID == sessionID else { return }
                guard self.audioEngine.isRunning else { return }

                let silenceDuration = Date().timeIntervalSince(self.lastTranscriptUpdate)
                // Wake-mode + wake heard: short tail (1.4s) so commands fire fast.
                // Otherwise hold the original 3.25s window for full sentences.
                let requiredSilence: TimeInterval =
                    (self.mode == .wake && self.wakeWordDetected) ? 1.4 : 3.25
                guard silenceDuration >= requiredSilence else {
                    self.scheduleSilenceTimeout(for: sessionID)
                    return
                }

                self.recordingStatus = "Processing speech"
                self.speechRecognitionState = "Waiting for final transcript"
                self.listeningState = "Waiting for final transcript"
                self.recognitionRequest?.endAudio()

                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(ListeningConstants.finalizationDelaySeconds))
                    guard let self else { return }
                    guard self.sessionID == sessionID else { return }
                    guard !self.isListening || self.speechRecognitionState == "Waiting for final transcript" else { return }
                    self.finalizeTranscript()
                }
            }
        }
    }

    private func scheduleWakeRestart() {
        guard autoRestartWakeMode else { return }
        guard wakeModeEnabled else { return }
        guard !isListening else { return }
        guard !isRestartScheduled else { return }

        // Don't restart while the assistant is mid-reply — that creates a
        // listen/speak race on the same audio session.
        if SpeechManager.shared.isSpeaking {
            isRestartScheduled = true
            restartTask?.cancel()
            restartTask = Task { [weak self] in
                while self?.shouldDeferRestartWhileSpeaking() == true {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                await MainActor.run {
                    guard let self, self.wakeModeEnabled else { return }
                    self.isRestartScheduled = false
                    self.mode = .wake
                    Task { await self.startListening() }
                }
            }
            return
        }

        // Tightened from 1.75s to 0.5s — anything longer leaves a gap where
        // "Hey Watersheep" can be missed because the recognizer isn't running.
        isRestartScheduled = true
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                guard let self, self.wakeModeEnabled else { return }
                self.isRestartScheduled = false
                self.mode = .wake
                Task { await self.startListening() }
            }
        }
    }

    private func shouldDeferRestartWhileSpeaking() -> Bool {
        SpeechManager.shared.isSpeaking
    }

    private func requestSpeechPermission() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch status {
        case .authorized:
            microphonePermissionStatus = audioPermissionLabel(isSpeechAuthorized: true, isMicrophoneAuthorized: nil)
            return true
        case .denied:
            speechRecognitionError = "Speech recognition permission denied"
        case .restricted:
            speechRecognitionError = "Speech recognition restricted"
        case .notDetermined:
            speechRecognitionError = "Speech recognition not determined"
        @unknown default:
            speechRecognitionError = "Unknown speech recognition permission state"
        }

        microphonePermissionStatus = audioPermissionLabel(isSpeechAuthorized: false, isMicrophoneAuthorized: nil)
        return false
    }

    private func requestMicrophonePermission() async -> Bool {
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        microphonePermissionStatus = audioPermissionLabel(isSpeechAuthorized: nil, isMicrophoneAuthorized: granted)
        if !granted {
            speechRecognitionError = "Microphone permission denied"
        }
        return granted
    }

    private func audioPermissionLabel(isSpeechAuthorized: Bool?, isMicrophoneAuthorized: Bool?) -> String {
        let speechStatus: String
        if let isSpeechAuthorized {
            speechStatus = isSpeechAuthorized ? "Speech OK" : "Speech Denied"
        } else {
            let current = SFSpeechRecognizer.authorizationStatus()
            speechStatus = current == .authorized ? "Speech OK" : "Speech Pending"
        }

        let micStatus: String
        if let isMicrophoneAuthorized {
            micStatus = isMicrophoneAuthorized ? "Mic OK" : "Mic Denied"
        } else {
            micStatus = AVAudioApplication.shared.recordPermission == .granted ? "Mic OK" : "Mic Pending"
        }

        return "\(speechStatus), \(micStatus)"
    }
}
