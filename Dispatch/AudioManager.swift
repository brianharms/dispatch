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

    /// Called on each partial recognition result with (currentFullText, previouslySentLength, sequence).
    var onPartialResult: ((String, Int, Int) -> Void)?

    /// Called when recognition finalizes with the complete text.
    var onFinalResult: ((String) -> Void)?

    /// Called with debug log messages to send to the server for diagnostics.
    var onDebugLog: ((String) -> Void)?

    // MARK: - Shared Private State

    private var audioEngine = AVAudioEngine()
    private var lastSentText: String = ""
    private var partialSequence: Int = 0
    private var hasFiredFinal: Bool = false
    private var callbackCount: Int = 0

    /// Which engine is active for the current session
    private var usingSpeechAnalyzer: Bool = false

    // MARK: - SpeechAnalyzer Engine (iOS 26+)

    // Cached across sessions (pre-warmed at app launch)
    private var saCachedFormat: AVAudioFormat?
    private var saCachedConverter: BufferConverter?
    private var saModelReady: Bool = false
    private var saWarmUpTask: Task<Void, Never>?

    // Per-session state
    private var saTranscriber: AnyObject?    // SpeechTranscriber (type-erased for compile on iOS 17)
    private var saAnalyzer: AnyObject?       // SpeechAnalyzer
    private var saInputBuilder: Any?          // AsyncStream<AnalyzerInput>.Continuation (struct, not class)
    private var saResultTask: Task<Void, Never>?
    private var saLockedText: String = ""
    private var saVolatileText: String = ""

    // MARK: - Legacy SFSpeechRecognizer Engine (iOS 17-25)

    /// Thread-safe holder so the audio tap can be swapped to a new recognition request
    /// without removing/reinstalling the tap (enables gapless auto-restart on isFinal).
    private final class LegacyRequestHolder: @unchecked Sendable {
        var request: SFSpeechAudioBufferRecognitionRequest?
    }

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let legacyRequestHolder = LegacyRequestHolder()
    private var legacyAccumulatedTranscript: String = ""
    private var legacyCurrentTranscript: String = ""
    private var legacyLastPartialText: String = ""

    private func debugLog(_ msg: String) {
        onDebugLog?(msg)
    }

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

                // SpeechAnalyzer is fallback-only — no pre-warm needed
            }
        }
    }

    // MARK: - SpeechAnalyzer Pre-Warm

    /// Pre-initializes SpeechAnalyzer resources at app launch so dictation starts instantly.
    /// Caches the audio format, buffer converter, and forces model load.
    private func warmUpSpeechAnalyzer() {
        guard !saModelReady, saCachedFormat == nil else { return }
        if #available(iOS 26, *) {
            saWarmUpTask = Task { @MainActor in
                do {
                    let t0 = CFAbsoluteTimeGetCurrent()
                    debugLog("SA WARM-UP: starting pre-initialization")

                    // Create temporary transcriber to query format and check model
                    let transcriber = SpeechTranscriber(
                        locale: Locale.current,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults],
                        attributeOptions: []
                    )

                    let t1 = CFAbsoluteTimeGetCurrent()
                    debugLog("SA WARM-UP: transcriber created (\(Int((t1 - t0) * 1000))ms)")

                    // Cache audio format
                    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: [transcriber]
                    ) else {
                        debugLog("SA WARM-UP: no compatible audio format")
                        return
                    }
                    saCachedFormat = format
                    saCachedConverter = BufferConverter()

                    let t2 = CFAbsoluteTimeGetCurrent()
                    debugLog("SA WARM-UP: format cached (\(Int((t2 - t1) * 1000))ms)")

                    // Check/download model
                    let locale = Locale.current
                    let installed = await SpeechTranscriber.installedLocales
                    let isInstalled = installed.contains(where: {
                        $0.identifier(.bcp47) == locale.identifier(.bcp47)
                    })

                    let t3 = CFAbsoluteTimeGetCurrent()
                    debugLog("SA WARM-UP: locale check done, installed=\(isInstalled) (\(Int((t3 - t2) * 1000))ms)")

                    if !isInstalled {
                        debugLog("SA WARM-UP: downloading model for \(locale.identifier(.bcp47))...")
                        if let request = try await AssetInventory.assetInstallationRequest(
                            supporting: [transcriber]
                        ) {
                            try await request.downloadAndInstall()
                            debugLog("SA WARM-UP: model downloaded")
                        }
                    }

                    // Force model load by creating and immediately stopping an analyzer
                    let warmAnalyzer = SpeechAnalyzer(modules: [transcriber])
                    let (warmSeq, warmBuilder) = AsyncStream<AnalyzerInput>.makeStream()
                    try await warmAnalyzer.start(inputSequence: warmSeq)
                    warmBuilder.finish()
                    try? await warmAnalyzer.finalizeAndFinishThroughEndOfInput()

                    let t4 = CFAbsoluteTimeGetCurrent()
                    saModelReady = true
                    debugLog("SA WARM-UP: complete, model loaded (\(Int((t4 - t3) * 1000))ms, total \(Int((t4 - t0) * 1000))ms)")

                } catch {
                    debugLog("SA WARM-UP: failed: \(error)")
                }
                saWarmUpTask = nil
            }
        }
    }

    // MARK: - Recording (Public API)

    func startRecording() {
        if isRecording {
            stopRecording()
        }
        cleanUp()

        error = nil
        transcribedText = ""
        partialText = ""
        lastSentText = ""
        hasFiredFinal = false
        partialSequence = 0
        callbackCount = 0

        // Configure audio session
        configureAudioSession()

        // SFSpeechRecognizer is primary — fast first-result (<1s).
        // SpeechAnalyzer (iOS 26+) is fallback only — 4s internal buffering delay.
        usingSpeechAnalyzer = false
        debugLog("=== RECORDING STARTED (SFSpeechRecognizer) ===")
        startWithSFSpeechRecognizer()
    }

    func stopRecording() {
        guard isRecording else { return }

        if usingSpeechAnalyzer {
            if #available(iOS 26, *) {
                stopSpeechAnalyzer()
            }
        } else {
            stopSFSpeechRecognizer()
        }
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]
            if UserDefaults.standard.bool(forKey: "bluetoothMic") {
                options.insert(.allowBluetoothHFP)
            }
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: options
            )
            try session.setActive(true)
        } catch {
            print("[AudioManager] Audio session config error: \(error)")
        }
    }

    // MARK: - Send Helper

    private func sendToServer(_ fullText: String) {
        guard isRecording else { return }
        guard fullText != lastSentText else { return }
        partialSequence += 1
        let seq = partialSequence
        let prevLen = lastSentText.count
        debugLog("SEND seq=\(seq) prevLen=\(prevLen) text=\"\(fullText)\"")
        onPartialResult?(fullText, prevLen, seq)
        lastSentText = fullText
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - SpeechAnalyzer Engine (iOS 26+)
    // ═══════════════════════════════════════════════════════════════════

    @available(iOS 26, *)
    private func startWithSpeechAnalyzer() {
        saLockedText = ""
        saVolatileText = ""

        Task { @MainActor in
            // If warm-up is still running, wait for it
            if let warmUp = saWarmUpTask {
                debugLog("SA: waiting for warm-up to finish...")
                await warmUp.value
            }

            do {
                let t0 = CFAbsoluteTimeGetCurrent()

                // Use cached format/converter if available, otherwise query fresh
                let analyzerFormat: AVAudioFormat
                let converter: BufferConverter
                if let cached = saCachedFormat, let cachedConv = saCachedConverter {
                    analyzerFormat = cached
                    converter = cachedConv
                    debugLog("SA: using cached format + converter")
                } else {
                    let tempTranscriber = SpeechTranscriber(
                        locale: Locale.current,
                        transcriptionOptions: [],
                        reportingOptions: [.volatileResults],
                        attributeOptions: []
                    )
                    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(
                        compatibleWith: [tempTranscriber]
                    ) else {
                        self.debugLog("SpeechAnalyzer: no compatible audio format available")
                        self.usingSpeechAnalyzer = false
                        self.startWithSFSpeechRecognizer()
                        return
                    }
                    analyzerFormat = fmt
                    converter = BufferConverter()
                    saCachedFormat = fmt
                    saCachedConverter = converter
                    debugLog("SA: format queried fresh (no cache)")
                }

                // Create fresh transcriber + analyzer per session
                let transcriber = SpeechTranscriber(
                    locale: Locale.current,
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults],
                    attributeOptions: []
                )
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.saTranscriber = transcriber
                self.saAnalyzer = analyzer

                let t1 = CFAbsoluteTimeGetCurrent()
                debugLog("SA: transcriber+analyzer created (\(Int((t1 - t0) * 1000))ms)")

                // Create async stream for audio input
                let (inputSequence, inputBuilder) = AsyncStream<AnalyzerInput>.makeStream()
                self.saInputBuilder = inputBuilder

                // Start consuming results BEFORE starting the analyzer
                saResultTask = Task { @MainActor [weak self] in
                    do {
                        for try await result in transcriber.results {
                            guard let self, self.isRecording else { break }
                            let text = String(result.text.characters)
                            self.callbackCount += 1
                            let cbNum = self.callbackCount

                            if result.isFinal {
                                self.debugLog("SA cb#\(cbNum) FINAL text=\"\(text)\"")
                                if !text.isEmpty {
                                    self.saLockedText += (self.saLockedText.isEmpty ? "" : " ") + text
                                }
                                self.saVolatileText = ""
                            } else {
                                self.debugLog("SA cb#\(cbNum) volatile text=\"\(text)\"")
                                self.saVolatileText = text
                            }

                            let fullText = self.saLockedText
                                + (self.saVolatileText.isEmpty ? "" : (self.saLockedText.isEmpty ? "" : " ") + self.saVolatileText)
                            self.partialText = fullText
                            self.sendToServer(fullText)
                        }
                    } catch {
                        self?.debugLog("SA result stream error: \(error)")
                    }
                }

                // Start the analyzer
                try await analyzer.start(inputSequence: inputSequence)

                let t2 = CFAbsoluteTimeGetCurrent()
                debugLog("SA: analyzer.start() completed (\(Int((t2 - t1) * 1000))ms)")

                // Set up audio engine tap with format conversion
                let inputNode = audioEngine.inputNode
                let recordingFormat = inputNode.outputFormat(forBus: 0)

                guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
                    self.error = "No audio input available."
                    cleanUp()
                    return
                }

                Self.installSpeechAnalyzerTap(
                    on: inputNode,
                    format: recordingFormat,
                    analyzerFormat: analyzerFormat,
                    converter: converter,
                    inputBuilder: inputBuilder
                )

                audioEngine.prepare()
                try audioEngine.start()
                isRecording = true

                let t3 = CFAbsoluteTimeGetCurrent()
                debugLog("SA: engine started, total setup \(Int((t3 - t0) * 1000))ms")

            } catch {
                self.debugLog("SpeechAnalyzer setup failed: \(error), falling back to SFSpeechRecognizer")
                self.saTranscriber = nil
                self.saAnalyzer = nil
                self.saInputBuilder = nil
                self.error = nil
                self.usingSpeechAnalyzer = false
                self.startWithSFSpeechRecognizer()
            }
        }
    }

    @available(iOS 26, *)
    private func stopSpeechAnalyzer() {
        debugLog("=== STOP RECORDING (SpeechAnalyzer) === locked=\"\(saLockedText)\" volatile=\"\(saVolatileText)\"")

        let finalText = saLockedText
            + (saVolatileText.isEmpty ? "" : (saLockedText.isEmpty ? "" : " ") + saVolatileText)
        debugLog("STOP finalText=\"\(finalText)\"")

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        isRecording = false

        // Signal end of audio and finalize
        if let inputBuilder = saInputBuilder as? AsyncStream<AnalyzerInput>.Continuation {
            inputBuilder.finish()
        }

        Task {
            if let analyzer = saAnalyzer as? SpeechAnalyzer {
                try? await analyzer.finalizeAndFinishThroughEndOfInput()
            }
        }

        // Send final text
        if !finalText.isEmpty {
            if finalText != lastSentText {
                partialSequence += 1
                debugLog("STOP SEND FINAL seq=\(partialSequence) prevLen=\(lastSentText.count) text=\"\(finalText)\"")
                onPartialResult?(finalText, lastSentText.count, partialSequence)
            } else {
                debugLog("STOP finalText == lastSentText, no send needed")
            }
            transcribedText = finalText
            if !hasFiredFinal {
                hasFiredFinal = true
                debugLog("STOP onFinalResult fired")
                onFinalResult?(finalText)
            }
            partialText = ""
        } else {
            debugLog("STOP no text to send")
        }

        saResultTask?.cancel()
        saResultTask = nil
        lastSentText = ""
        debugLog("=== RECORDING ENDED (SpeechAnalyzer) === total callbacks=\(callbackCount)")
    }

    /// Nonisolated tap that converts buffers and feeds them to SpeechAnalyzer
    @available(iOS 26, *)
    nonisolated private static func installSpeechAnalyzerTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        analyzerFormat: AVAudioFormat,
        converter: BufferConverter,
        inputBuilder: AsyncStream<AnalyzerInput>.Continuation
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do {
                let converted = try converter.convertBuffer(buffer, to: analyzerFormat)
                let input = AnalyzerInput(buffer: converted)
                inputBuilder.yield(input)
            } catch {
                // Silently drop buffer on conversion failure — transient errors are expected
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════
    // MARK: - Legacy SFSpeechRecognizer Engine (iOS 17-25)
    // ═══════════════════════════════════════════════════════════════════

    private func startWithSFSpeechRecognizer() {
        legacyAccumulatedTranscript = ""
        legacyCurrentTranscript = ""
        legacyLastPartialText = ""

        guard createLegacyRecognitionTask() else {
            debugLog("SFSpeechRecognizer not available, trying SpeechAnalyzer fallback")
            if #available(iOS 26, *) {
                usingSpeechAnalyzer = true
                debugLog("=== FALLBACK TO SpeechAnalyzer ===")
                startWithSpeechAnalyzer()
            } else {
                error = "Speech recognizer is not available."
                debugLog("ERROR: No speech engine available")
            }
            return
        }

        // Set up audio engine tap — uses holder so we can swap requests on restart
        do {
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            guard recordingFormat.channelCount > 0, recordingFormat.sampleRate > 0 else {
                self.error = "No audio input available."
                cleanUp()
                return
            }

            Self.installLegacyAudioTap(on: inputNode, format: recordingFormat, holder: legacyRequestHolder)

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            debugLog("Legacy audio engine started, isRecording=true")
        } catch {
            self.error = "Audio engine failed to start: \(error.localizedDescription)"
            debugLog("ERROR: Audio engine failed: \(error.localizedDescription)")
            cleanUp()
        }
    }

    /// Creates a new recognition request + task. The audio tap (via holder) automatically
    /// feeds buffers to the new request. Returns false if recognizer is unavailable.
    private func createLegacyRecognitionTask() -> Bool {
        guard let speechRecognizer, speechRecognizer.isAvailable else { return false }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(iOS 17, *) {
            request.requiresOnDeviceRecognition = true
        }
        request.taskHint = .dictation
        request.addsPunctuation = true
        recognitionRequest = request
        legacyRequestHolder.request = request

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, taskError in
            DispatchQueue.main.async {
                self?.handleLegacyCallback(result: result, error: taskError)
            }
        }

        return true
    }

    private func handleLegacyCallback(result: SFSpeechRecognitionResult?, error: Error?) {
        callbackCount += 1
        let cbNum = callbackCount

        if let result {
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            let speechDuration = result.speechRecognitionMetadata?.speechDuration

            debugLog("RECOGNIZER cb#\(cbNum) isFinal=\(isFinal) speechDuration=\(speechDuration.map { String($0) } ?? "nil") text=\"\(text)\"")

            if isFinal {
                // isFinal = recognizer is done (silence timeout ~2-3s, 60s limit, or endAudio).
                // Lock the clean segment text.
                if !text.isEmpty {
                    legacyAccumulatedTranscript += (legacyAccumulatedTranscript.isEmpty ? "" : " ") + text
                    debugLog("SEGMENT LOCK (isFinal): locked \"\(text)\"")
                }
                legacyCurrentTranscript = ""
                legacyLastPartialText = ""
            } else if speechDuration != nil {
                // Utterance boundary — lock the transcript before recognizer resets it
                debugLog("SEGMENT LOCK: speechDuration fired, locking \"\(text)\"")
                legacyAccumulatedTranscript += (legacyAccumulatedTranscript.isEmpty ? "" : " ") + text
                legacyCurrentTranscript = ""
                legacyLastPartialText = ""
            } else {
                // Normal partial — check for drops as belt-and-suspenders
                if !legacyLastPartialText.isEmpty
                    && text.count < legacyLastPartialText.count / 2
                    && !text.isEmpty
                {
                    let commonLen = commonPrefixLength(text, legacyLastPartialText)
                    if commonLen < text.count / 2 {
                        debugLog("DROP DETECTED: \"\(legacyLastPartialText)\" → \"\(text)\", locking previous")
                        legacyAccumulatedTranscript += (legacyAccumulatedTranscript.isEmpty ? "" : " ") + legacyLastPartialText
                    }
                }
                legacyCurrentTranscript = text
                legacyLastPartialText = text
            }

            // Compute full text and send
            let fullText = legacyAccumulatedTranscript
                + (legacyCurrentTranscript.isEmpty ? "" : (legacyAccumulatedTranscript.isEmpty ? "" : " ") + legacyCurrentTranscript)
            partialText = fullText

            if isRecording {
                sendToServer(fullText)
            } else {
                debugLog("RECOGNIZER cb#\(cbNum) SKIPPED (not recording)")
            }

            // Auto-restart after isFinal — keeps listening through pauses.
            // The audio tap stays running via the holder; we just swap in a new request.
            if isFinal && isRecording {
                debugLog("=== AUTO-RESTART RECOGNITION ===")
                recognitionRequest = nil
                recognitionTask = nil
                if createLegacyRecognitionTask() {
                    debugLog("=== RECOGNITION RESTARTED (accumulated: \"\(legacyAccumulatedTranscript)\") ===")
                } else {
                    debugLog("AUTO-RESTART FAILED: recognizer unavailable")
                }
            }
        }

        if let error {
            let nsError = error as NSError
            let isCancellation = nsError.domain == "kAFAssistantErrorDomain"
                && nsError.code == 216
            debugLog("RECOGNIZER ERROR: \(error.localizedDescription) cancel=\(isCancellation)")
            if isRecording {
                // Error during active recording — try to restart
                if !isCancellation {
                    debugLog("ERROR during recording, attempting restart...")
                    recognitionRequest = nil
                    recognitionTask = nil
                    if !createLegacyRecognitionTask() {
                        debugLog("RESTART FAILED after error")
                        self.error = "Recognition failed: \(error.localizedDescription)"
                    }
                }
            } else {
                if !isCancellation && transcribedText.isEmpty {
                    self.error = "Recognition failed: \(error.localizedDescription)"
                }
                cleanUp()
            }
        }
    }

    private func stopSFSpeechRecognizer() {
        let fullText = legacyAccumulatedTranscript
            + (legacyCurrentTranscript.isEmpty ? "" : (legacyAccumulatedTranscript.isEmpty ? "" : " ") + legacyCurrentTranscript)

        debugLog("=== STOP RECORDING (Legacy) === accumulated=\"\(legacyAccumulatedTranscript)\" current=\"\(legacyCurrentTranscript)\" fullText=\"\(fullText)\"")

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        legacyRequestHolder.request = nil
        isRecording = false

        if !fullText.isEmpty {
            if fullText != lastSentText {
                partialSequence += 1
                debugLog("STOP SEND FINAL seq=\(partialSequence) prevLen=\(lastSentText.count) text=\"\(fullText)\"")
                onPartialResult?(fullText, lastSentText.count, partialSequence)
            } else {
                debugLog("STOP finalText == lastSentText, no send needed")
            }
            transcribedText = fullText
            if !hasFiredFinal {
                hasFiredFinal = true
                debugLog("STOP onFinalResult fired")
                onFinalResult?(fullText)
            }
            partialText = ""
        } else {
            debugLog("STOP no text to send")
        }

        lastSentText = ""
        debugLog("=== RECORDING ENDED (Legacy) === total callbacks=\(callbackCount)")
    }

    /// Nonisolated tap — captures the holder (not the request) so we can swap
    /// requests on auto-restart without removing/reinstalling the tap.
    nonisolated private static func installLegacyAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        holder: LegacyRequestHolder
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            holder.request?.append(buffer)
        }
    }

    // MARK: - Helpers

    private func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let limit = min(aChars.count, bChars.count)
        for i in 0..<limit {
            if aChars[i] != bChars[i] { return i }
        }
        return limit
    }

    // MARK: - Cleanup

    private func cleanUp() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)

        // Legacy cleanup
        recognitionRequest = nil
        recognitionTask = nil
        legacyRequestHolder.request = nil

        // SpeechAnalyzer per-session cleanup (preserve cached format + converter)
        saResultTask?.cancel()
        saResultTask = nil
        saTranscriber = nil
        saAnalyzer = nil
        saInputBuilder = nil

        isRecording = false
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - BufferConverter (for SpeechAnalyzer audio format conversion)
// ═══════════════════════════════════════════════════════════════════

/// Converts AVAudioPCMBuffers between formats (e.g., mic format → SpeechAnalyzer format).
/// Thread-safe for use on audio engine's realtime callback thread.
final class BufferConverter: @unchecked Sendable {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }

        guard let converter = converter else {
            throw ConversionError.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))
        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw ConversionError.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        nonisolated(unsafe) var bufferProcessed = false

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            defer { bufferProcessed = true }
            inputStatusPointer.pointee = bufferProcessed ? .noDataNow : .haveData
            return bufferProcessed ? nil : buffer
        }

        guard status != .error else {
            throw ConversionError.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}
