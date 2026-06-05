@preconcurrency import AVFoundation
import MediaPlayer
import UIKit
import Observation
// MARK: - Action Types

enum DispatchAction: Equatable {
    case cycleNext           // Vol Up single press
    case cyclePrevious       // Vol Down single press
    case dictationStarted    // Hold detected → recording
    case dictationEnded      // Hold released → enter
    case sendDoubleEscape    // Double-escape
}

// MARK: - Interaction Modes

enum InteractionMode: String, CaseIterable {
    case primary      // Current: Up=next, Down=prev, Up-hold=dictation, Down-hold=escape
    case simpleFast   // Up=immediate next, Down: double-tap=escape, hold=dictation

    var displayName: String {
        switch self {
        case .primary: return "primary"
        case .simpleFast: return "simple"
        }
    }
}

// MARK: - Volume Button Manager

@Observable
@MainActor
final class VolumeButtonManager {

    // MARK: Published State

    private(set) var lastAction: DispatchAction?
    private(set) var actionID: Int = 0
    private(set) var isDictating: Bool = false
    private(set) var isActive: Bool = false
    var interactionMode: InteractionMode = .simpleFast

    // Immediate visual feedback (fires on first button event, before gap timer)
    private(set) var indicatorAction: DispatchAction?
    private(set) var indicatorActionID: Int = 0

    // Debug
    private(set) var debugVolume: Float = 0.5
    private(set) var debugState: String = "idle"
    private(set) var debugSliderConnected: Bool = false
    private(set) var debugResetCount: Int = 0
    private(set) var debugKVOCount: Int = 0
    private(set) var debugIgnoredCount: Int = 0
    private(set) var debugLogEntries: [String] = []
    private let maxLogEntries = 40

    private func log(_ msg: String) {
        NSLog("[VBM] %@", msg)
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))
        debugLogEntries.append("[\(timestamp)] \(msg)")
        if debugLogEntries.count > maxLogEntries {
            debugLogEntries.removeFirst(debugLogEntries.count - maxLogEntries)
        }
    }

    // MARK: Configuration

    private var effectiveReleaseTimeout: TimeInterval {
        switch interactionMode {
        case .primary: return 0.400
        case .simpleFast: return 0.400
        }
    }

    // simpleUpDebounceMs removed — directional reset filter handles KVO duplicates

    /// Decision timer for vol-down in simple mode.
    /// After this many seconds with no new vol-down KVO, evaluate the count.
    private let simpleDownDecisionTimeout: TimeInterval = 0.500
    /// Release timer during dictation — stop recording this long after last KVO event.
    /// Must be long enough to survive audio engine startup disrupting KVO (~500-800ms).
    private let simpleDictationReleaseTimeout: TimeInterval = 1.0

    // MARK: Internal State

    private enum GestureState: CustomStringConvertible {
        case idle
        case pressing(direction: ButtonDirection, eventCount: Int, startTime: CFAbsoluteTime)

        var description: String {
            switch self {
            case .idle: return "idle"
            case .pressing(let dir, let n, _):
                return "pressing(\(dir == .up ? "UP" : "DN") x\(n))"
            }
        }
    }

    private enum ButtonDirection {
        case up, down
    }

    private var gestureState: GestureState = .idle {
        didSet { debugState = "\(gestureState)" }
    }
    private var releaseTimer: Timer?

    // Volume interception
    private var kvoObservation: NSKeyValueObservation?
    private var lastKnownVolume: Float = 0.5
    private var lastKVOTime: CFAbsoluteTime = 0
    // lastSimpleUpTime removed — no longer debouncing vol-up
    /// Time of the last vol-down event that actually incremented the count.
    /// Used to debounce duplicate KVO events from a single physical press.
    private var lastDownIncrementTime: CFAbsoluteTime = 0
    /// Running count of real down KVO events in current gesture (0 = idle).
    private var simpleDownCount: Int = 0
    /// Timestamp of the first down event in the current gesture.
    private var simpleDownStartTime: CFAbsoluteTime = 0
    /// Non-resetting 500ms decision timer — fires once to evaluate down-event count.
    private var simpleDownDecisionTimer: Timer?

    // Burst cap — limits rapid-fire cycles when volume button is held
    private var cycleBurstCount: Int = 0
    private let cycleBurstMax: Int = 4

    // Haptics
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)

    // Hidden volume view (HUD suppression + slider fallback)
    private var hiddenVolumeView: MPVolumeView?
    private var hiddenVolumeSlider: UISlider?

    // Safety timeout for stuck dictation
    private var dictationSafetyTimer: Timer?

    // Background/foreground observers
    private var backgroundObserver: (any NSObjectProtocol)?
    private var foregroundObserver: (any NSObjectProtocol)?

    // MARK: - Setup / Teardown

    func setup() {
        guard !isActive else { return }
        isActive = true
        // Restore saved mode
        if let saved = UserDefaults.standard.string(forKey: "interactionMode"),
           let mode = InteractionMode(rawValue: saved) {
            interactionMode = mode
        }
        configureAudioSession()
        startKVO()
        registerLifecycleObservers()
        lightHaptic.prepare()
        mediumHaptic.prepare()
        heavyHaptic.prepare()
        log("Mode: \(interactionMode.displayName)")
    }

    func teardown() {
        guard isActive else { return }
        isActive = false
        releaseTimer?.invalidate()
        releaseTimer = nil
        simpleDownDecisionTimer?.invalidate()
        simpleDownDecisionTimer = nil
        dictationSafetyTimer?.invalidate()
        dictationSafetyTimer = nil
        gestureState = .idle
        if isDictating {
            isDictating = false
            fireAction(.dictationEnded)
        }
        kvoObservation?.invalidate()
        kvoObservation = nil
        if let bg = backgroundObserver {
            NotificationCenter.default.removeObserver(bg)
            backgroundObserver = nil
        }
        if let fg = foregroundObserver {
            NotificationCenter.default.removeObserver(fg)
            foregroundObserver = nil
        }
    }

    func setInteractionMode(_ mode: InteractionMode) {
        interactionMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "interactionMode")
        // Reset state machine when switching modes
        releaseTimer?.invalidate()
        releaseTimer = nil
        simpleDownDecisionTimer?.invalidate()
        simpleDownDecisionTimer = nil
        simpleDownCount = 0
        gestureState = .idle
        if isDictating {
            isDictating = false
            fireAction(.dictationEnded)
        }
        log("Mode switched: \(mode.displayName)")
    }

    func setHiddenVolumeView(_ volumeView: MPVolumeView) {
        hiddenVolumeView = volumeView
        debugSliderConnected = true
        findSliderSubview(in: volumeView, attempt: 1)
    }

    private func findSliderSubview(in volumeView: MPVolumeView, attempt: Int) {
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            hiddenVolumeSlider = slider
            log("Slider subview found (attempt \(attempt))")
            resetVolumeNextRunLoop()
        } else if attempt <= 10 {
            // MPVolumeView may populate subviews lazily after layout — retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.findSliderSubview(in: volumeView, attempt: attempt + 1)
            }
        } else {
            log("WARNING: No slider subview after \(attempt) attempts")
            resetVolumeNextRunLoop()
        }
    }

    // MARK: - Audio Session

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker, .mixWithOthers]
            if UserDefaults.standard.bool(forKey: "bluetoothMic") {
                options.insert(.allowBluetooth)
            }
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: options
            )
            try session.setActive(true)
        } catch {
            log("Audio session error: \(error)")
        }
        lastKnownVolume = session.outputVolume
        log("Audio session configured, vol=\(String(format: "%.3f", lastKnownVolume))")
    }

    // MARK: - KVO

    private func startKVO() {
        let session = AVAudioSession.sharedInstance()
        kvoObservation = session.observe(\.outputVolume, options: [.new, .old]) {
            [weak self] _, change in
            guard let self else { return }
            guard let newVolume = change.newValue else { return }
            Task { @MainActor in
                self.handleVolumeChange(newVolume: newVolume)
            }
        }
    }

    func stopKVO() {
        kvoObservation?.invalidate()
        kvoObservation = nil
    }

    func restartKVO() {
        stopKVO()
        startKVO()
    }

    func recoverAfterAudioEngine() {
        configureAudioSession()
        restartKVO()
        resetVolumeNextRunLoop()
    }

    // MARK: - Volume Change Handler

    private func handleVolumeChange(newVolume: Float) {
        debugVolume = newVolume
        debugKVOCount += 1

        let now = CFAbsoluteTimeGetCurrent()
        let gap = lastKVOTime > 0 ? (now - lastKVOTime) * 1000 : 0
        lastKVOTime = now

        let oldVolume = lastKnownVolume
        let delta = newVolume - oldVolume
        lastKnownVolume = newVolume

        let gapStr = gap > 0 ? String(format: "gap=%.0fms", gap) : "gap=—"

        // Ignore negligible changes (noise)
        guard abs(delta) > 0.001 else {
            log("KVO#\(debugKVOCount) SKIP \(gapStr)")
            return
        }

        // Ignore our own volume resets — any event moving TOWARD 0.5 is self-inflicted.
        // We always reset to 0.5 after each real press, so real presses always move
        // away from 0.5 and resets always move back toward it.
        let wasDist = abs(oldVolume - 0.5)
        let nowDist = abs(newVolume - 0.5)
        if nowDist < wasDist {
            debugIgnoredCount += 1
            lastKnownVolume = newVolume
            if isDictating {
                startReleaseTimer()
                log("KVO#\(debugKVOCount) RESET-KEEPALIVE \(gapStr)")
            } else {
                log("KVO#\(debugKVOCount) RESET-BOUNCE \(gapStr)")
            }
            return
        }

        let direction: ButtonDirection = delta > 0 ? .up : .down

        // Track down-event index for gesture analysis
        if direction == .down {
            if simpleDownCount == 0 {
                simpleDownStartTime = now
            }
            simpleDownCount += 1
            let elapsed = (now - simpleDownStartTime) * 1000
            log("KVO#\(debugKVOCount) DN[\(simpleDownCount)] vol=\(String(format: "%.3f", newVolume)) \(gapStr) elapsed=\(String(format: "%.0fms", elapsed)) st=\(debugState)")
        } else {
            log("KVO#\(debugKVOCount) UP vol=\(String(format: "%.3f", newVolume)) \(gapStr) st=\(debugState)")
        }

        // During active dictation, ignore all events except for timer keepalive.
        // Reset bounces and real hold-continuation events both just keep the
        // release timer alive without triggering cycleNext or other actions.
        if isDictating {
            startReleaseTimer()
            log("KVO#\(debugKVOCount) DICTATING-KEEPALIVE \(gapStr)")
            resetVolumeNextRunLoop()
            return
        }

        // Feed into state machine
        handleButtonEvent(direction)

        // Reset volume on the NEXT run loop
        resetVolumeNextRunLoop()
    }

    // MARK: - Volume Reset (next run loop)

    private func resetVolumeNextRunLoop() {
        debugResetCount += 1
        let resetID = debugResetCount


        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let before = AVAudioSession.sharedInstance().outputVolume

            // Use MPVolumeView slider to reset volume.
            // Do NOT use MPMusicPlayerController.setValue — it activates the
            // Now Playing/Music framework and can steal app focus (backgrounding the app).
            if let slider = self.hiddenVolumeSlider {
                slider.value = 0.5
                slider.sendActions(for: .valueChanged)
                slider.sendActions(for: .touchUpInside)
            } else {
                // Slider not yet available — skip reset rather than using
                // MPMusicPlayerController which steals app focus
                self.lastKnownVolume = AVAudioSession.sharedInstance().outputVolume
                self.log("RESET#\(resetID) skipped — no slider yet")
                return
            }

            // Verify after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                let after = AVAudioSession.sharedInstance().outputVolume
                self.debugVolume = after
                let ok = abs(after - 0.5) <= 0.01
                // Only update baseline if reset actually landed near target
                if ok {
                    self.lastKnownVolume = after
                }
                self.log("RESET#\(resetID) before=\(String(format: "%.3f", before)) after=\(String(format: "%.3f", after)) \(ok ? "OK" : "FAILED")")
                if !ok {
                    self.retryReset(attempt: 2)
                }
            }
        }
    }

    /// Retry a failed volume reset up to 3 attempts total.
    private func retryReset(attempt: Int) {
        guard attempt <= 3 else {
            log("RESET retries exhausted — forcing lastKnownVolume=0.5")
            lastKnownVolume = 0.5
            return
        }

        debugResetCount += 1
        let resetID = debugResetCount


        if let slider = hiddenVolumeSlider {
            slider.value = 0.5
            slider.sendActions(for: .valueChanged)
            slider.sendActions(for: .touchUpInside)
        } else {
            // Slider not yet available — skip reset, adjust baseline
            lastKnownVolume = AVAudioSession.sharedInstance().outputVolume
            log("RESET#\(resetID) retry#\(attempt) skipped — no slider yet")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            let after = AVAudioSession.sharedInstance().outputVolume
            self.debugVolume = after
            let ok = abs(after - 0.5) <= 0.01
            if ok {
                self.lastKnownVolume = after
            }
            self.log("RESET#\(resetID) retry#\(attempt) after=\(String(format: "%.3f", after)) \(ok ? "OK" : "RETRY")")
            if !ok {
                self.retryReset(attempt: attempt + 1)
            }
        }
    }

    // MARK: - State Machine (mode dispatch)

    private func handleButtonEvent(_ direction: ButtonDirection) {
        releaseTimer?.invalidate()
        releaseTimer = nil

        switch interactionMode {
        case .primary:
            handlePrimaryMode(direction)
        case .simpleFast:
            handleSimpleFastMode(direction)
        }
    }

    // MARK: - Primary Mode

    private func handlePrimaryMode(_ direction: ButtonDirection) {
        switch gestureState {
        case .idle:
            gestureState = .pressing(direction: direction, eventCount: 1, startTime: CFAbsoluteTimeGetCurrent())
            switch direction {
            case .up: fireIndicator(.cycleNext)
            case .down: fireIndicator(.cyclePrevious)
            }
            startReleaseTimer()

        case .pressing(let currentDir, let count, let startTime):
            if direction == currentDir {
                let newCount = count + 1
                gestureState = .pressing(direction: currentDir, eventCount: newCount, startTime: startTime)

                if newCount == 2 {
                    switch currentDir {
                    case .up:
                        isDictating = true
                        fireAction(.dictationStarted)
                        fireIndicator(.dictationStarted)
                        mediumHaptic.impactOccurred()
                        startDictationSafetyTimer()
                        log("HOLD confirmed: UP (dictation started)")
                    case .down:
                        fireAction(.sendDoubleEscape)
                        fireIndicator(.sendDoubleEscape)
                        heavyHaptic.impactOccurred()
                        log("HOLD confirmed: DOWN (escape sent)")
                    }
                }
                startReleaseTimer()
            } else {
                if count == 1 {
                    commitSinglePress(currentDir)
                } else {
                    endHold(currentDir)
                }
                gestureState = .pressing(direction: direction, eventCount: 1, startTime: CFAbsoluteTimeGetCurrent())
                switch direction {
                case .up: fireIndicator(.cycleNext)
                case .down: fireIndicator(.cyclePrevious)
                }
                startReleaseTimer()
            }
        }
    }

    private func releaseTimerFiredPrimary() {
        switch gestureState {
        case .idle:
            break
        case .pressing(let direction, let count, let startTime):
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            log("RELEASE: dir=\(direction == .up ? "UP" : "DN") events=\(count) duration=\(String(format: "%.0fms", duration * 1000))")

            if count == 1 {
                commitSinglePress(direction)
            } else {
                endHold(direction)
            }
            gestureState = .idle
        }
    }

    // MARK: - Simple & Fast Mode

    private func handleSimpleFastMode(_ direction: ButtonDirection) {
        switch direction {
        case .up:
            // Every physical vol-up fires cycleNext immediately (burst-capped).
            // Cancel any pending down-gesture.
            simpleDownCount = 0
            simpleDownDecisionTimer?.invalidate()
            simpleDownDecisionTimer = nil
            gestureState = .idle
            guard cycleBurstCount < cycleBurstMax else {
                log("SIMPLE: cycleNext SUPPRESSED (burst \(cycleBurstCount)/\(cycleBurstMax))")
                startReleaseTimer()
                return
            }
            cycleBurstCount += 1
            fireAction(.cycleNext)
            fireIndicator(.cycleNext)
            lightHaptic.impactOccurred()
            log("SIMPLE: immediate cycleNext (burst \(cycleBurstCount)/\(cycleBurstMax))")
            startReleaseTimer()

        case .down:
            // simpleDownCount already incremented in handleVolumeChange.
            if simpleDownCount == 1 {
                // First down event — start non-resetting 500ms decision timer.
                gestureState = .pressing(direction: .down, eventCount: 1, startTime: simpleDownStartTime)
                simpleDownDecisionTimer?.invalidate()
                simpleDownDecisionTimer = Timer.scheduledTimer(
                    withTimeInterval: simpleDownDecisionTimeout,
                    repeats: false
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.simpleDownDecisionFired()
                    }
                }
            } else if simpleDownCount >= 3 && !isDictating {
                // 3rd event — start recording immediately, cancel the decision timer.
                simpleDownDecisionTimer?.invalidate()
                simpleDownDecisionTimer = nil
                isDictating = true
                fireAction(.dictationStarted)
                fireIndicator(.dictationStarted)
                mediumHaptic.impactOccurred()
                startDictationSafetyTimer()
                startReleaseTimer()
                log("SIMPLE: hold detected (count=\(simpleDownCount)) → dictation started (immediate)")
            } else {
                // 2nd event — just update state, timer keeps running.
                gestureState = .pressing(direction: .down, eventCount: simpleDownCount, startTime: simpleDownStartTime)
            }
        }
    }

    private func simpleDownDecisionFired() {
        simpleDownDecisionTimer = nil
        let count = simpleDownCount
        let elapsed = (CFAbsoluteTimeGetCurrent() - simpleDownStartTime) * 1000
        log("SIMPLE: decision fired — count=\(count) elapsed=\(String(format: "%.0fms", elapsed))")

        switch count {
        case 1:
            // Single tap → no action (reserved)
            log("SIMPLE: single tap — ignored")
            simpleDownCount = 0
            gestureState = .idle
        case 2:
            // Double tap → double escape
            fireAction(.sendDoubleEscape)
            fireIndicator(.sendDoubleEscape)
            heavyHaptic.impactOccurred()
            log("SIMPLE: double tap → escape")
            simpleDownCount = 0
            gestureState = .idle
        default:
            // 3+ events → start recording
            isDictating = true
            fireAction(.dictationStarted)
            fireIndicator(.dictationStarted)
            mediumHaptic.impactOccurred()
            startDictationSafetyTimer()
            startReleaseTimer()
            log("SIMPLE: hold detected (count=\(count)) → dictation started")
        }
    }

    private func releaseTimerFiredSimpleFast() {
        // Only fires during dictation — 200ms after last KVO event
        if isDictating {
            log("SIMPLE: dictation release — stopping")
            isDictating = false
            dictationSafetyTimer?.invalidate()
            dictationSafetyTimer = nil
            fireAction(.dictationEnded)
            heavyHaptic.impactOccurred()
        }
        // Reset burst cap on release — finger lifted, can cycle again
        if cycleBurstCount > 0 {
            log("SIMPLE: burst reset (\(cycleBurstCount) → 0)")
            cycleBurstCount = 0
        }
        simpleDownCount = 0
        gestureState = .idle
    }

    // MARK: - Release Timer

    private func startReleaseTimer() {
        releaseTimer?.invalidate()
        let timeout: TimeInterval
        if isDictating {
            // SimpleFast: short release (200ms) since decision timer already resolved the gesture.
            // Primary: longer (800ms) to accommodate iOS auto-repeat rate.
            timeout = interactionMode == .simpleFast ? simpleDictationReleaseTimeout : 0.800
        } else {
            timeout = effectiveReleaseTimeout
        }
        releaseTimer = Timer.scheduledTimer(
            withTimeInterval: timeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.releaseTimerFired()
            }
        }
    }

    private func releaseTimerFired() {
        releaseTimer = nil

        switch interactionMode {
        case .primary:
            releaseTimerFiredPrimary()
        case .simpleFast:
            releaseTimerFiredSimpleFast()
        }
    }

    // MARK: - Shared Actions

    private func commitSinglePress(_ direction: ButtonDirection) {
        switch direction {
        case .up: fireAction(.cycleNext)
        case .down: fireAction(.cyclePrevious)
        }
        lightHaptic.impactOccurred()
    }

    private func endHold(_ direction: ButtonDirection) {
        switch direction {
        case .up:
            isDictating = false
            dictationSafetyTimer?.invalidate()
            dictationSafetyTimer = nil
            fireAction(.dictationEnded)
            heavyHaptic.impactOccurred()
        case .down:
            if isDictating {
                // Simple mode: vol-down hold was dictation
                isDictating = false
                dictationSafetyTimer?.invalidate()
                dictationSafetyTimer = nil
                fireAction(.dictationEnded)
                heavyHaptic.impactOccurred()
            }
            // Primary mode: escape already sent on hold confirm
        }
    }

    // MARK: - Indicator Dispatch

    private func fireIndicator(_ action: DispatchAction) {
        indicatorAction = action
        indicatorActionID += 1
    }

    // MARK: - Dictation Safety Timer

    private func startDictationSafetyTimer() {
        dictationSafetyTimer?.invalidate()
        dictationSafetyTimer = Timer.scheduledTimer(
            withTimeInterval: 60.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isDictating else { return }
                self.log("Safety timeout — force-ending dictation")
                self.isDictating = false
                self.dictationSafetyTimer = nil
                self.gestureState = .idle
                self.fireAction(.dictationEnded)
            }
        }
    }

    // MARK: - Action Dispatch

    private func fireAction(_ action: DispatchAction) {
        lastAction = action
        actionID += 1
        log("ACTION: \(String(describing: action)) id=\(actionID)")
    }

    func simulateAction(_ action: DispatchAction) {
        if action == .dictationStarted {
            isDictating = true
        } else if action == .dictationEnded {
            isDictating = false
        }
        fireAction(action)
    }

    // MARK: - App Lifecycle

    private func registerLifecycleObservers() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pauseObservation()
            }
        }
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeObservation()
            }
        }
    }

    private func pauseObservation() {
        kvoObservation?.invalidate()
        kvoObservation = nil
        releaseTimer?.invalidate()
        releaseTimer = nil
        dictationSafetyTimer?.invalidate()
        dictationSafetyTimer = nil
        gestureState = .idle
        if isDictating {
            isDictating = false
            fireAction(.dictationEnded)
        }
    }

    private func resumeObservation() {
        guard isActive else { return }
        configureAudioSession()
        startKVO()
        resetVolumeNextRunLoop()
    }
}
