@preconcurrency import AVFoundation
import MediaPlayer
import UIKit
import Observation

// MARK: - Action Types

enum DispatchAction: Equatable {
    case cycleNext           // Vol Up single press
    case cyclePrevious       // Vol Down single press
    case dictationStarted    // Vol Up hold detected (2+ rapid events)
    case dictationEnded      // Vol Up released (300ms gap after holding)
    case sendDoubleEscape    // Vol Down long press released
}

// MARK: - Volume Button Manager

@Observable
@MainActor
final class VolumeButtonManager {

    // MARK: Published State

    private(set) var lastAction: DispatchAction?
    private(set) var actionID: Int = 0  // increments on every action, even repeated ones
    private(set) var isDictating: Bool = false
    private(set) var isActive: Bool = false

    // MARK: Configuration

    private let gapTimeout: TimeInterval = 0.300  // 2 missed auto-repeat cycles

    // MARK: Internal State Machine

    private enum GestureState {
        case idle
        case pendingUp       // got one vol-up, waiting to see if more come
        case holdingUp       // 2+ vol-up events in rapid succession — dictating
        case pendingDown     // got one vol-down, waiting to see if more come
        case holdingDown     // 2+ vol-down events in rapid succession
    }

    private var gestureState: GestureState = .idle
    private var gapTimer: Timer?

    // Volume interception
    private var isResettingVolume: Bool = false
    private var kvoObservation: NSKeyValueObservation?
    private var lastKnownVolume: Float = 0.5

    // Haptics
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)

    // Hidden volume view reference (held to keep MPVolumeView alive)
    private var hiddenVolumeSlider: UISlider?

    // Background/foreground observers
    private var backgroundObserver: (any NSObjectProtocol)?
    private var foregroundObserver: (any NSObjectProtocol)?

    // MARK: - Setup / Teardown

    func setup() {
        guard !isActive else { return }
        isActive = true

        configureAudioSession()
        startKVO()
        registerLifecycleObservers()

        // Pre-warm haptic generators
        lightHaptic.prepare()
        mediumHaptic.prepare()
        heavyHaptic.prepare()
    }

    func teardown() {
        guard isActive else { return }
        isActive = false

        gapTimer?.invalidate()
        gapTimer = nil
        gestureState = .idle
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

    /// Call this from your UIViewRepresentable to hand over the hidden slider.
    func setHiddenVolumeSlider(_ slider: UISlider?) {
        hiddenVolumeSlider = slider
        // Initialise volume to midpoint so both directions work immediately
        if let slider {
            isResettingVolume = true
            slider.value = 0.5
            slider.sendActions(for: .valueChanged)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.isResettingVolume = false
                self?.lastKnownVolume = 0.5
            }
        }
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
            print("[VolumeButtonManager] Audio session error: \(error)")
        }
        lastKnownVolume = session.outputVolume
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
        startKVO()
    }

    // MARK: - Volume Change Handler

    private func handleVolumeChange(newVolume: Float) {
        // Ignore self-triggered resets
        guard !isResettingVolume else { return }

        let delta = newVolume - lastKnownVolume
        lastKnownVolume = newVolume

        // Ignore negligible changes (noise)
        guard abs(delta) > 0.001 else { return }

        let direction: ButtonDirection = delta > 0 ? .up : .down

        // Reset volume back to midpoint
        resetVolumeToMidpoint()

        // Feed into the state machine
        handleButtonEvent(direction)
    }

    private enum ButtonDirection {
        case up, down
    }

    // MARK: - Volume Reset

    private func resetVolumeToMidpoint() {
        guard let slider = hiddenVolumeSlider else { return }
        isResettingVolume = true
        slider.value = 0.5
        slider.sendActions(for: .valueChanged)
        // Allow a brief window for the KVO to fire and be ignored
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isResettingVolume = false
            self?.lastKnownVolume = 0.5
        }
    }

    // MARK: - State Machine

    private func handleButtonEvent(_ direction: ButtonDirection) {
        // Cancel existing gap timer — we got a new event
        gapTimer?.invalidate()
        gapTimer = nil

        switch gestureState {

        // ── IDLE ──
        case .idle:
            switch direction {
            case .up:
                gestureState = .pendingUp
                startGapTimer()
            case .down:
                gestureState = .pendingDown
                startGapTimer()
            }

        // ── PENDING UP (got 1 vol-up, waiting to see if it's a hold) ──
        case .pendingUp:
            if direction == .up {
                // Second vol-up within gap window → it's a hold — start dictation
                gestureState = .holdingUp
                isDictating = true
                fireAction(.dictationStarted)
                mediumHaptic.impactOccurred()
                startGapTimer()  // watch for release
            } else {
                // Got a down event while pending up — treat the up as single, then start pending down
                commitSinglePress(.up)
                gestureState = .pendingDown
                startGapTimer()
            }

        // ── HOLDING UP (dictating — vol-up events keep coming) ──
        case .holdingUp:
            if direction == .up {
                // Still holding — restart gap timer
                startGapTimer()
            } else {
                // Got a down while holding up — that's unusual, ignore the down event
                // and keep watching for the up release
                startGapTimer()
            }

        // ── PENDING DOWN (got 1 vol-down, waiting to see if it's a hold) ──
        case .pendingDown:
            if direction == .down {
                // Second vol-down within gap window → it's a hold — fire escape NOW
                gestureState = .holdingDown
                fireAction(.sendDoubleEscape)
                heavyHaptic.impactOccurred()
                startGapTimer()  // watch for release to return to idle
            } else {
                // Got an up event while pending down — treat down as single, start pending up
                commitSinglePress(.down)
                gestureState = .pendingUp
                startGapTimer()
            }

        // ── HOLDING DOWN (vol-down events keep coming) ──
        case .holdingDown:
            if direction == .down {
                // Still holding — restart gap timer
                startGapTimer()
            } else {
                // Got an up while holding down — ignore, keep watching for release
                startGapTimer()
            }
        }
    }

    // MARK: - Gap Timer

    /// Starts a 300ms gap timer. When it fires, it means the button was released.
    private func startGapTimer() {
        gapTimer?.invalidate()
        gapTimer = Timer.scheduledTimer(
            withTimeInterval: gapTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.gapTimerFired()
            }
        }
    }

    private func gapTimerFired() {
        let previousState = gestureState
        gapTimer = nil

        switch previousState {
        case .idle:
            break  // nothing to do

        case .pendingUp:
            // Only one vol-up event, then silence → single press
            commitSinglePress(.up)
            gestureState = .idle

        case .holdingUp:
            // Was dictating, button released → stop dictation + send Enter
            isDictating = false
            fireAction(.dictationEnded)
            heavyHaptic.impactOccurred()
            gestureState = .idle

        case .pendingDown:
            // Only one vol-down event, then silence → single press
            commitSinglePress(.down)
            gestureState = .idle

        case .holdingDown:
            // Vol-down long press released — escape already fired on hold start
            gestureState = .idle
        }
    }

    // MARK: - Single Press

    private func commitSinglePress(_ direction: ButtonDirection) {
        switch direction {
        case .up:
            fireAction(.cycleNext)
        case .down:
            fireAction(.cyclePrevious)
        }
        lightHaptic.impactOccurred()
    }

    // MARK: - Action Dispatch

    private func fireAction(_ action: DispatchAction) {
        lastAction = action
        actionID += 1
        print("[VolumeButtonManager] Action: \(action) (id: \(actionID))")
    }

    /// Called by simulator touch controls to bypass the volume KVO state machine.
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
        gapTimer?.invalidate()
        gapTimer = nil
        gestureState = .idle
    }

    private func resumeObservation() {
        guard isActive else { return }
        configureAudioSession()
        startKVO()
        resetVolumeToMidpoint()
    }
}
