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

    /// Debounce window for vol-up actions in simple mode.
    /// A single physical press can generate 1-3 KVO events; only the first fires cycleNext.
    private let simpleUpDebounceMs: Double = 250

    /// Debounce window for vol-down in simple mode (shorter to allow double-tap detection).
    /// Duplicate KVO events from a single press arrive within ~50-80ms.
    /// Human double-taps arrive at ~200-350ms. 120ms sits safely between.
    private let simpleDownDebounceMs: Double = 120

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
    private var suppressEventsUntil: CFAbsoluteTime = 0
    private var lastResetRequestTime: CFAbsoluteTime = 0
    private var lastSimpleUpTime: CFAbsoluteTime = 0
    /// Time of the last vol-down event that actually incremented the count.
    /// Used to debounce duplicate KVO events from a single physical press.
    private var lastDownIncrementTime: CFAbsoluteTime = 0

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
        if let slider = volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider {
            hiddenVolumeSlider = slider
            log("Slider subview found")
        } else {
            log("WARNING: No slider subview — MPMusicPlayerController only")
        }
        resetVolumeNextRunLoop()
    }

    // MARK: - Audio Session

    func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth]
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

        // Suppress events briefly after hold ends (audio session reconfiguration noise)
        if now < suppressEventsUntil {
            log("KVO#\(debugKVOCount) SUPPRESSED \(gapStr)")
            return
        }

        // Ignore negligible changes (noise)
        guard abs(delta) > 0.001 else {
            log("KVO#\(debugKVOCount) SKIP \(gapStr)")
            return
        }

        // Ignore our own volume resets landing — volume moving TOWARD 0.5
        // Only within 200ms of a reset request; stale offsets from failed resets
        // must not eat real button presses
        let wasDist = abs(oldVolume - 0.5)
        let nowDist = abs(newVolume - 0.5)
        let resetAge = (now - lastResetRequestTime) * 1000
        if nowDist < wasDist && resetAge < 200 {
            debugIgnoredCount += 1
            lastKnownVolume = newVolume  // Keep baseline in sync even when filtering
            log("KVO#\(debugKVOCount) RESET-BOUNCE \(gapStr) (d=\(String(format: "%+.3f", delta)) rst=\(String(format: "%.0f", resetAge))ms)")
            return
        }

        let direction: ButtonDirection = delta > 0 ? .up : .down

        // In simple mode, suppress vol-down ghost events caused by vol-up resets.
        // After a vol-up fires, the reset to 0.5 arrives as a vol-down KVO within ~100ms.
        if interactionMode == .simpleFast && direction == .down {
            let sinceLastUp = (now - lastSimpleUpTime) * 1000
            if sinceLastUp < 250 {
                debugIgnoredCount += 1
                log("KVO#\(debugKVOCount) GHOST-DN \(gapStr) sinceUp=\(String(format: "%.0f", sinceLastUp))ms")
                resetVolumeNextRunLoop()
                return
            }
        }

        log("KVO#\(debugKVOCount) \(direction == .up ? "UP" : "DN") vol=\(String(format: "%.3f", newVolume)) \(gapStr) st=\(debugState)")

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
        lastResetRequestTime = CFAbsoluteTimeGetCurrent()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            let before = AVAudioSession.sharedInstance().outputVolume

            // Strategy 1: MPMusicPlayerController (primary)
            let player = MPMusicPlayerController.applicationMusicPlayer
            (player as NSObject).setValue(Float(0.5), forKey: "volume")

            // Strategy 2: Slider fallback
            if let slider = self.hiddenVolumeSlider {
                slider.value = 0.5
                slider.sendActions(for: .valueChanged)
                slider.sendActions(for: .touchUpInside)
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
        lastResetRequestTime = CFAbsoluteTimeGetCurrent()

        let player = MPMusicPlayerController.applicationMusicPlayer
        (player as NSObject).setValue(Float(0.5), forKey: "volume")

        if let slider = hiddenVolumeSlider {
            slider.value = 0.5
            slider.sendActions(for: .valueChanged)
            slider.sendActions(for: .touchUpInside)
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
            // Debounce: a single physical press can fire 1-3 KVO events.
            // Only the first one triggers cycleNext; extras are suppressed.
            let now = CFAbsoluteTimeGetCurrent()
            let sinceLastUp = (now - lastSimpleUpTime) * 1000
            if sinceLastUp < simpleUpDebounceMs {
                log("SIMPLE: UP debounce \(String(format: "%.0f", sinceLastUp))ms — skipped")
                return
            }
            lastSimpleUpTime = now
            fireAction(.cycleNext)
            fireIndicator(.cycleNext)
            lightHaptic.impactOccurred()
            log("SIMPLE: immediate cycleNext")

        case .down:
            switch gestureState {
            case .idle:
                // First vol-down event — no indicator yet, wait for gesture resolution
                lastDownIncrementTime = CFAbsoluteTimeGetCurrent()
                gestureState = .pressing(direction: .down, eventCount: 1, startTime: lastDownIncrementTime)
                startReleaseTimer()

            case .pressing(let currentDir, let count, let startTime):
                guard currentDir == .down else {
                    // Was tracking something else — shouldn't happen in simple mode
                    // since vol-up doesn't set state, but handle gracefully
                    lastDownIncrementTime = CFAbsoluteTimeGetCurrent()
                    gestureState = .pressing(direction: .down, eventCount: 1, startTime: lastDownIncrementTime)
                    fireIndicator(.cyclePrevious)
                    startReleaseTimer()
                    return
                }

                // Debounce: a single physical press can fire 2-3 KVO events.
                // Only increment count if enough time has passed since last increment.
                let now = CFAbsoluteTimeGetCurrent()
                let sinceLastIncrement = (now - lastDownIncrementTime) * 1000
                if sinceLastIncrement < simpleDownDebounceMs {
                    log("SIMPLE: DN debounce \(String(format: "%.0f", sinceLastIncrement))ms — skipped")
                    startReleaseTimer()
                    return
                }

                lastDownIncrementTime = now
                let newCount = count + 1
                gestureState = .pressing(direction: .down, eventCount: newCount, startTime: startTime)

                if newCount == 2 {
                    // 2nd event — don't fire escape yet; defer to release timer.
                    // If a 3rd event arrives, it becomes dictation instead.
                    log("SIMPLE: count=2, deferring escape to release timer")
                    startReleaseTimer()
                } else if newCount == 3 {
                    // Third event → transition to dictation hold
                    isDictating = true
                    fireAction(.dictationStarted)
                    fireIndicator(.dictationStarted)
                    mediumHaptic.impactOccurred()
                    startDictationSafetyTimer()
                    log("SIMPLE: hold → dictation started")
                    startReleaseTimer()
                } else {
                    // 4+ events — continuation of hold, just reset timer
                    startReleaseTimer()
                }
            }
        }
    }

    private func releaseTimerFiredSimpleFast() {
        switch gestureState {
        case .idle:
            break
        case .pressing(let direction, let count, let startTime):
            let duration = CFAbsoluteTimeGetCurrent() - startTime
            log("RELEASE(simple): dir=\(direction == .up ? "UP" : "DN") events=\(count) duration=\(String(format: "%.0fms", duration * 1000))")

            guard direction == .down else {
                // Vol-up shouldn't be in state machine in simple mode
                gestureState = .idle
                return
            }

            switch count {
            case 1:
                // Single vol-down tap → do nothing in simple mode
                break
            case 2:
                // Double-tap confirmed — fire escape now that no 3rd event arrived
                fireAction(.sendDoubleEscape)
                fireIndicator(.sendDoubleEscape)
                heavyHaptic.impactOccurred()
                log("SIMPLE: release timer → escape (count stayed at 2)")
            default:
                // Hold ended → end dictation
                endHold(.down)
            }
            gestureState = .idle
        }
    }

    // MARK: - Release Timer

    private func startReleaseTimer() {
        releaseTimer?.invalidate()
        releaseTimer = Timer.scheduledTimer(
            withTimeInterval: effectiveReleaseTimeout,
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
        suppressEventsUntil = CFAbsoluteTimeGetCurrent() + 0.6

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
