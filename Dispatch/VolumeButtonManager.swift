import AVFoundation
import MediaPlayer
import UIKit
import Observation

// MARK: - Action Types

enum DispatchAction: String, Sendable {
    case cycleNext          // Vol Up single
    case cyclePrevious      // Vol Down single
    case startDictation     // Vol Up long press (toggle on)
    case stopDictation      // Vol Up long press (toggle off)
    case sendDoubleEscape   // Vol Down long press
    case dualPress          // Both buttons simultaneously
}

// MARK: - Volume Button Manager

@Observable
@MainActor
final class VolumeButtonManager {

    // MARK: Published State

    private(set) var lastAction: DispatchAction?
    private(set) var isDictating: Bool = false
    private(set) var isActive: Bool = false

    // MARK: Configuration

    private let singlePressTimeout: TimeInterval = 0.300
    private let dualPressWindow: TimeInterval = 0.150
    private let longPressWindow: TimeInterval = 0.800
    private let longPressMinRepeats: Int = 3

    // MARK: Internal State

    private enum ButtonDirection {
        case up, down
    }

    private struct PressEvent {
        let direction: ButtonDirection
        let timestamp: TimeInterval
    }

    private var recentPresses: [PressEvent] = []
    private var pendingSinglePressTimer: Timer?
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

        pendingSinglePressTimer?.invalidate()
        pendingSinglePressTimer = nil
        kvoObservation?.invalidate()
        kvoObservation = nil
        recentPresses.removeAll()

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

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
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

    // MARK: - Volume Change Handler

    private func handleVolumeChange(newVolume: Float) {
        // Ignore self-triggered resets
        guard !isResettingVolume else { return }

        let delta = newVolume - lastKnownVolume
        lastKnownVolume = newVolume

        // Ignore negligible changes (noise)
        guard abs(delta) > 0.001 else { return }

        let direction: ButtonDirection = delta > 0 ? .up : .down
        let now = ProcessInfo.processInfo.systemUptime

        // Record press event
        let event = PressEvent(direction: direction, timestamp: now)
        recentPresses.append(event)

        // Reset volume back to midpoint
        resetVolumeToMidpoint()

        // Evaluate gesture state machine
        evaluateGestures(latestDirection: direction, now: now)
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

    // MARK: - Gesture State Machine

    private func evaluateGestures(latestDirection: ButtonDirection, now: TimeInterval) {
        // Cancel any pending single-press timer — we may be accumulating a multi-press gesture
        pendingSinglePressTimer?.invalidate()
        pendingSinglePressTimer = nil

        // Prune old events outside the long press window
        recentPresses.removeAll { now - $0.timestamp > longPressWindow }

        // --- Check for dual press ---
        if checkDualPress(now: now) {
            return
        }

        // --- Check for long press ---
        if checkLongPress(now: now) {
            return
        }

        // --- Defer single press: wait to see if more presses arrive ---
        let capturedDirection = latestDirection
        pendingSinglePressTimer = Timer.scheduledTimer(
            withTimeInterval: singlePressTimeout,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.commitSinglePress(direction: capturedDirection)
            }
        }
    }

    // MARK: - Dual Press Detection

    /// Returns true if a dual press was detected and consumed.
    private func checkDualPress(now: TimeInterval) -> Bool {
        // Need at least 2 recent events
        guard recentPresses.count >= 2 else { return false }

        // Look for an up and a down within the dual press window
        let recent = recentPresses.filter { now - $0.timestamp <= dualPressWindow }
        let hasUp = recent.contains { $0.direction == .up }
        let hasDown = recent.contains { $0.direction == .down }

        if hasUp && hasDown {
            recentPresses.removeAll()
            fireAction(.dualPress)
            heavyHaptic.impactOccurred()
            return true
        }
        return false
    }

    // MARK: - Long Press Detection

    /// Returns true if a long press was detected and consumed.
    private func checkLongPress(now: TimeInterval) -> Bool {
        let windowStart = now - longPressWindow

        let upCount = recentPresses.filter { $0.direction == .up && $0.timestamp >= windowStart }.count
        let downCount = recentPresses.filter { $0.direction == .down && $0.timestamp >= windowStart }.count

        if upCount >= longPressMinRepeats {
            recentPresses.removeAll()
            handleLongPressUp()
            mediumHaptic.impactOccurred()
            return true
        }

        if downCount >= longPressMinRepeats {
            recentPresses.removeAll()
            fireAction(.sendDoubleEscape)
            mediumHaptic.impactOccurred()
            return true
        }

        return false
    }

    // MARK: - Single Press

    private func commitSinglePress(direction: ButtonDirection) {
        // Clear the press history since we're committing
        recentPresses.removeAll()

        switch direction {
        case .up:
            fireAction(.cycleNext)
        case .down:
            fireAction(.cyclePrevious)
        }
        lightHaptic.impactOccurred()
    }

    // MARK: - Long Press Up (Dictation Toggle)

    private func handleLongPressUp() {
        isDictating.toggle()
        fireAction(isDictating ? .startDictation : .stopDictation)
    }

    // MARK: - Action Dispatch

    private func fireAction(_ action: DispatchAction) {
        lastAction = action
        print("[VolumeButtonManager] Action: \(action.rawValue)")
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
        pendingSinglePressTimer?.invalidate()
        pendingSinglePressTimer = nil
        recentPresses.removeAll()
    }

    private func resumeObservation() {
        guard isActive else { return }
        configureAudioSession()
        startKVO()
        resetVolumeToMidpoint()
    }
}
