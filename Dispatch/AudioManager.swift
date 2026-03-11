@preconcurrency import AVFoundation
import Observation
@preconcurrency import Speech

@Observable
@MainActor
final class AudioManager {

    // MARK: - Public State

    var isRecording: Bool = false
    var transcribedText: String = ""
    var partialText: String = ""
    var error: String? = nil

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

    /// Guards against duplicate final sends (recognition task callback vs stopRecording fallback race)
    private var hasFiredFinal: Bool = false

    // MARK: - Permissions

    func requestPermissions() {
        Task.detached {
            let speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            let micGranted = await AVAudioApplication.requestRecordPermission()

            await MainActor.run { [weak self] in
                guard let self else { return }
                switch speechStatus {
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
                if !micGranted {
                    self.error = "Microphone permission denied."
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() {
        // Guard against re-entrant start — tear down any prior session first
        if isRecording {
            stopRecording()
        }
        cleanUp()

        // Clear previous state
        error = nil
        transcribedText = ""
        partialText = ""
        lastSentText = ""
        hasFiredFinal = false

        // Verify speech recognizer is available
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            error = "Speech recognizer is not available."
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
        recognitionTask = speechRecognizer.recognitionTask(with: request) { result, taskError in
            // Extract values before crossing to main actor (avoid sending non-Sendable types)
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let error = taskError

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                if let text {
                    if isFinal {
                        self.transcribedText = text
                        self.partialText = ""
                        if !self.hasFiredFinal {
                            self.hasFiredFinal = true
                            self.onFinalResult?(text)
                        }
                        self.lastSentText = ""
                        self.cleanUp()
                    } else {
                        self.partialText = text
                        self.onPartialResult?(text, self.lastSentText.count)
                        self.lastSentText = text
                    }
                }

                if let error {
                    let nsError = error as NSError
                    let isCancellation = nsError.domain == "kAFAssistantErrorDomain"
                        && nsError.code == 216
                    if !isCancellation && self.transcribedText.isEmpty {
                        self.error =
                            "Recognition failed: \(error.localizedDescription)"
                    }
                    self.cleanUp()
                }
            }
        }

        // Reconfigure audio session so AVAudioEngine doesn't clobber the existing
        // .playAndRecord setup that VolumeButtonManager relies on for outputVolume KVO.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            print("[AudioManager] Audio session config error: \(error)")
        }

        // Set up audio engine tap — guard against simulator/missing audio input
        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            // Validate format — simulator returns 0 channels / 0 sample rate
            guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
                self.error = "No audio input available."
                cleanUp()
                return
            }

            // Install tap via nonisolated helper so the closure doesn't inherit @MainActor
            Self.installAudioTap(on: inputNode, format: recordingFormat, request: request)

            // Start audio engine
            audioEngine.prepare()
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
        if !partialText.isEmpty && transcribedText.isEmpty && !hasFiredFinal {
            transcribedText = partialText
            hasFiredFinal = true
            onFinalResult?(partialText)
            partialText = ""
        }

        lastSentText = ""
    }

    // MARK: - Audio Tap (nonisolated to avoid @MainActor inheritance on realtime audio thread)

    nonisolated private static func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
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
    }
}
