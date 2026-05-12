import AVFoundation
import Combine

@MainActor
protocol SpeechRecognitionCoordinating: AnyObject {
    func stopListeningForSpeechOutput()
    func resumeWakeListeningAfterSpeechOutputIfNeeded()
    var isCurrentlyListening: Bool { get }
}

@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechManager()

    @Published var isAutoSpeakEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutoSpeakEnabled, forKey: Self.autoSpeakDefaultsKey)
            if !isAutoSpeakEnabled {
                stopSpeaking()
            }
        }
    }
    @Published var forceIPhoneMic: Bool {
        didSet {
            UserDefaults.standard.set(forceIPhoneMic, forKey: Self.forceIPhoneMicDefaultsKey)
        }
    }
    @Published private(set) var lastSpokenText = ""
    @Published private(set) var isSpeaking = false
    @Published private(set) var speechError = "None"

    private static let autoSpeakDefaultsKey = "settings.autoSpeakResponses"
    private static let forceIPhoneMicDefaultsKey = "settings.forceIPhoneMic"

    private let synthesizer = AVSpeechSynthesizer()
    private var speechTask: Task<Void, Never>?
    private var currentUtterance: AVSpeechUtterance?
    weak var recognitionCoordinator: (any SpeechRecognitionCoordinating)?

    override init() {
        if UserDefaults.standard.object(forKey: Self.autoSpeakDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.autoSpeakDefaultsKey)
        }

        self.isAutoSpeakEnabled = UserDefaults.standard.bool(forKey: Self.autoSpeakDefaultsKey)
        self.forceIPhoneMic = UserDefaults.standard.bool(forKey: Self.forceIPhoneMicDefaultsKey)
        super.init()
        synthesizer.delegate = self
    }

    func prepareForListeningTransition() async throws {
        stopSpeaking()
        try deactivateAudioSessionIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        try configureAudioSessionForListening()
    }

    func prepareForSpeakingTransition() async throws {
        recognitionCoordinator?.stopListeningForSpeechOutput()
        try deactivateAudioSessionIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        try configureAudioSessionForSpeaking()
    }

    func configureAudioSessionForListening() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetoothHFP]
        )

        if forceIPhoneMic {
            let builtInMic = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic })
            try audioSession.setPreferredInput(builtInMic)
        } else {
            try audioSession.setPreferredInput(nil)
        }

        try audioSession.setActive(true)
    }

    func configureAudioSessionForSpeaking() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .spokenAudio,
            options: [.allowBluetoothHFP, .allowBluetoothA2DP, .defaultToSpeaker, .duckOthers]
        )
        try audioSession.setPreferredInput(nil)
        try audioSession.setActive(true)
    }

    func stopSpeaking() {
        speechTask?.cancel()
        speechTask = nil
        stopSynthesizerOnly()
    }

    private func stopSynthesizerOnly() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        currentUtterance = nil
        isSpeaking = false
    }

    func speak(_ text: String, storeAsLastSpoken: Bool = true, forcePlayback: Bool = false) {
        guard !text.isEmpty else { return }
        guard isAutoSpeakEnabled || forcePlayback else {
            if storeAsLastSpoken {
                lastSpokenText = text
            }
            return
        }

        if storeAsLastSpoken {
            lastSpokenText = text
        }

        speechTask?.cancel()
        speechTask = Task { @MainActor in
            // The Bluetooth HFP route to the Meta glasses can briefly report a
            // 0 Hz sample rate after a wake/listen transition, which makes
            // AVAudioSession.setActive throw OSStatus 561017449 ('!siz'). When
            // that happens we wait and retry once — by then HFP has finished
            // negotiating and the route is back at 16 kHz.
            let activated = await activateSpeakingSessionWithRetry()
            guard activated else { return }
            guard !Task.isCancelled else { return }
            stopSynthesizerOnly()

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.5
            utterance.pitchMultiplier = 1.0

            speechError = "None"
            currentUtterance = utterance
            isSpeaking = true
            synthesizer.speak(utterance)
        }
    }

    private func activateSpeakingSessionWithRetry() async -> Bool {
        let retryDelaysMs: [Int] = [0, 350, 800]
        var lastError: Error?

        for (attempt, delay) in retryDelaysMs.enumerated() {
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(delay))
            }
            if Task.isCancelled { return false }

            do {
                try await prepareForSpeakingTransition()
                if attempt > 0 {
                    print("speaking session activated on retry \(attempt)")
                }
                return true
            } catch {
                lastError = error
                if !isRetryableSessionError(error) {
                    break
                }
            }
        }

        if let lastError {
            speechError = lastError.localizedDescription
            isSpeaking = false
            print("speaking session activation gave up: \(lastError.localizedDescription)")
        }
        return false
    }

    private func isRetryableSessionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        // 561017449 = 'siz!' — session can't activate, often transient when
        // Bluetooth HFP is mid-negotiation. Anything in the OSStatus domain
        // around session activation gets one retry.
        if nsError.code == 561017449 { return true }
        if nsError.domain == NSOSStatusErrorDomain { return true }
        return false
    }

    func replayLastResponse() {
        guard !lastSpokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        speak(lastSpokenText, storeAsLastSpoken: false, forcePlayback: true)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentUtterance = nil
            self.speechTask = nil
            self.recognitionCoordinator?.resumeWakeListeningAfterSpeechOutputIfNeeded()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.currentUtterance = nil
            self.speechTask = nil
            self.recognitionCoordinator?.resumeWakeListeningAfterSpeechOutputIfNeeded()
        }
    }

    private func deactivateAudioSessionIfNeeded() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
