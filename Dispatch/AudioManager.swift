import AVFoundation
import Observation
import Speech

@Observable
@MainActor
final class AudioManager {

    // MARK: - Public State

    var isRecording: Bool = false
    var transcribedText: String = ""
    var partialText: String = ""
    var error: String? = nil

    // MARK: - Audio Session Coordination

    /// Called before recording starts — the caller should pause volume button observation
    /// (which requires `.playback` category) so we can switch to `.record`.
    var onRecordingSessionWillStart: (() -> Void)?

    /// Called after recording ends — the caller should resume volume button observation
    /// and restore `.playback` category.
    var onRecordingSessionDidEnd: (() -> Void)?

    // MARK: - Streaming Callbacks

    /// Called on each partial recognition result with (currentFullText, previouslySentLength).
    /// The receiver can diff to determine what's new vs. what was revised.
    var onPartialResult: ((String, Int) -> Void)?

    /// Called when recognition finalizes with the complete text.
    var onFinalResult: ((String) -> Void)?

    // MARK: - Private

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    /// Tracks what we last sent to the server so the receiver can compute diffs.
    private var lastSentText: String = ""

    // MARK: - Permissions

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .authorized:
                    break
                case .denied:
                    self.error = "Speech recognition permission denied."
                case .restricted:
                    self.error = "Speech recognition is restricted on this device."
                case .notDetermined:
                    self.error = "Speech recognition permission not determined."
                @unknown default:
                    self.error = "Unknown speech recognition authorization status."
                }
            }
        }

        AVAudioApplication.requestRecordPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !granted {
                    self.error = "Microphone permission denied."
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }

        // Clear previous state
        error = nil
        transcribedText = ""
        partialText = ""
        lastSentText = ""

        // Verify speech recognizer is available
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer is not available."
            return
        }

        // Cancel any in-progress task
        recognitionTask?.cancel()
        recognitionTask = nil

        // Notify caller to pause volume observation before we change audio session
        onRecordingSessionWillStart?()

        // Configure audio session for recording
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            self.error = "Failed to configure audio session: \(error.localizedDescription)"
            onRecordingSessionDidEnd?()
            return
        }

        // Create recognition request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 17, *) {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: request) {
            [weak self] result, taskError in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.transcribedText = text
                        self.partialText = ""
                        // Fire final result callback
                        self.onFinalResult?(text)
                        self.lastSentText = ""
                        self.cleanUp()
                    } else {
                        self.partialText = text
                        // Stream partial result to server
                        self.onPartialResult?(text, self.lastSentText.count)
                        self.lastSentText = text
                    }
                }

                if let taskError {
                    // Don't overwrite a final result with an error from cancellation
                    let nsError = taskError as NSError
                    let isCancellation = nsError.domain == "kAFAssistantErrorDomain"
                        && nsError.code == 216
                    if !isCancellation && self.transcribedText.isEmpty {
                        self.error =
                            "Recognition failed: \(taskError.localizedDescription)"
                    }
                    self.cleanUp()
                }
            }
        }

        // Set up audio engine tap
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) {
            [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Start audio engine
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            self.error = "Audio engine failed to start: \(error.localizedDescription)"
            cleanUp()
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        // Stop the audio engine and end the recognition request.
        // The recognition task will deliver its final result in the callback above.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

        // If we got partial text but recognition hasn't finalized yet,
        // promote partials to transcribed text as a fallback.
        if !partialText.isEmpty && transcribedText.isEmpty {
            transcribedText = partialText
            // Fire final with whatever we have
            onFinalResult?(partialText)
            partialText = ""
        }

        lastSentText = ""
    }

    // MARK: - Cleanup

    private func cleanUp() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false

        // Restore audio session for volume button interception
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            // Non-fatal — volume buttons may not work until next app launch
        }

        onRecordingSessionDidEnd?()
    }
}
