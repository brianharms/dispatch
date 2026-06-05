import SwiftUI
import WatchKit

struct ContentView: View {
    @StateObject private var network = NetworkManager.shared
    @StateObject private var recorder = AudioRecorder()
    @State private var showingSettings = false
    @State private var settingsDragOffset: CGFloat = 0.0
    @State private var crownOffset: Double = 0.0
    @State private var lastTriggeredOffset: Double = 0.0
    @State private var lastTriggerTime: Date = .distantPast
    @State private var pulseOpacity: Double = 0.3
    @State private var characterScale: CGFloat = 1.0
    @State private var recordingSafetyTimer: Timer?

    // Gesture state
    @State private var touchDownTime: Date = .distantPast
    @State private var didSwipe = false
    @State private var isHoldMode = false
    @State private var maxAbsH: CGFloat = 0
    @State private var holdTimer: Timer?

    @AppStorage("watchOrientation") private var orientation: String = "landscape"

    private let threshold: Double = 2.4
    private let debounceInterval: TimeInterval = 0.3
    private let minRecordingDuration: TimeInterval = 0.4
    private let maxRecordingDuration: TimeInterval = 30.0
    private let holdThreshold: TimeInterval = 0.4   // tap vs hold boundary
    private let holdZone: CGFloat = 12               // max drift for tap/hold (not swipe)

    var body: some View {
        GeometryReader { geo in
            let swipeThreshold = geo.size.width / 5

            ZStack {
                Color.black.ignoresSafeArea()

                // Full-screen red pulse when recording
                if recorder.isRecording {
                    Color.red
                        .opacity(pulseOpacity)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                pulseOpacity = 0.15
                            }
                        }
                        .onDisappear {
                            pulseOpacity = 0.3
                        }
                }

                VStack(spacing: 0) {
                    // Top bar — swipe down for settings
                    HStack(spacing: 0) {
                        Text("dispatch")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(white: 0.5))
                        Text(network.isConnected ? "." : "!")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(network.isConnected ? Color(white: 0.5) : .red.opacity(0.8))
                        Spacer()
                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.3))
                        Spacer().frame(width: 6)
                        // Chevron hint — animates down during drag
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Color(white: settingsDragOffset > 0 ? 0.6 : 0.25))
                            .offset(y: min(settingsDragOffset * 0.15, 3))
                            .animation(.easeOut(duration: 0.15), value: settingsDragOffset)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                if value.translation.height > 0 {
                                    settingsDragOffset = value.translation.height
                                }
                            }
                            .onEnded { value in
                                if value.translation.height > 40 {
                                    WKInterfaceDevice.current().play(.click)
                                    showingSettings = true
                                }
                                settingsDragOffset = 0
                            }
                    )

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)

                    // Main content — tap/hold Claude to record, swipe to cycle
                    VStack(spacing: 0) {
                        Spacer()

                        // Claude character
                        ClaudeCharacter(
                            isRecording: recorder.isRecording,
                            isConnected: network.isConnected
                        )
                        .scaleEffect(characterScale)

                        Spacer().frame(height: 10)

                        // Window info
                        if network.isConnected && network.totalWindows > 0 {
                            Text("\(network.currentIndex + 1)")
                                .font(.system(size: 28, weight: .heavy, design: .monospaced))
                                .foregroundColor(.white)
                                .contentTransition(.numericText())
                                .animation(.spring(response: 0.3), value: network.currentIndex)

                            Text(network.currentWindowName)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.3))
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                ForEach(0..<network.totalWindows, id: \.self) { i in
                                    Circle()
                                        .fill(i == network.currentIndex ? Color.white : Color.white.opacity(0.2))
                                        .frame(width: 5, height: 5)
                                }
                            }
                            .padding(.top, 4)
                        } else if !network.isConnected {
                            Text("—")
                                .font(.system(size: 28, weight: .heavy, design: .monospaced))
                                .foregroundColor(.white.opacity(0.15))
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                // First touch — set up state
                                if touchDownTime == .distantPast {
                                    touchDownTime = Date()
                                    didSwipe = false
                                    isHoldMode = false
                                    maxAbsH = 0

                                    // Schedule hold-to-record timer (only when not already recording)
                                    if !recorder.isRecording {
                                        holdTimer = Timer.scheduledTimer(withTimeInterval: holdThreshold, repeats: false) { _ in
                                            DispatchQueue.main.async {
                                                guard !recorder.isRecording && !didSwipe else { return }
                                                isHoldMode = true
                                                startRecording()
                                            }
                                        }
                                    }
                                }

                                let h = value.translation.width
                                let v = value.translation.height
                                maxAbsH = max(maxAbsH, abs(h))

                                // Swipe detection (only when not recording)
                                if !didSwipe && !recorder.isRecording {
                                    if abs(h) > swipeThreshold && abs(h) > abs(v) {
                                        didSwipe = true
                                        holdTimer?.invalidate()
                                        holdTimer = nil
                                        let direction = h < 0 ? "next" : "prev"
                                        WKInterfaceDevice.current().play(.click)
                                        network.cycle(direction: direction)
                                    }
                                }
                            }
                            .onEnded { _ in
                                holdTimer?.invalidate()
                                holdTimer = nil

                                if recorder.isRecording {
                                    if isHoldMode && recorder.lastRecordingDuration < minRecordingDuration {
                                        // Borderline hold — too short, silently discard
                                        _ = recorder.stopRecording()
                                    } else {
                                        // Normal stop: hold released, or toggle-mode tap to stop
                                        stopAndSend()
                                    }
                                } else if !isHoldMode && !didSwipe && maxAbsH <= holdZone {
                                    // Quick tap with minimal movement — start in toggle mode
                                    startRecording()
                                }

                                touchDownTime = .distantPast
                                didSwipe = false
                                isHoldMode = false
                                maxAbsH = 0
                            }
                    )
                }
            }
        }
        .focusable()
        .digitalCrownRotation(
            $crownOffset,
            from: -10000.0,
            through: 10000.0,
            sensitivity: .low,
            isContinuous: true,
            isHapticFeedbackEnabled: false
        )
        .onChange(of: crownOffset) { oldValue, newValue in
            guard !recorder.isRecording else { return }

            let now = Date()
            guard now.timeIntervalSince(lastTriggerTime) >= debounceInterval else { return }

            let delta = newValue - lastTriggeredOffset
            if delta >= threshold {
                lastTriggeredOffset = newValue
                lastTriggerTime = now
                WKInterfaceDevice.current().play(.click)
                network.cycle(direction: "next")
            } else if delta <= -threshold {
                lastTriggeredOffset = newValue
                lastTriggerTime = now
                WKInterfaceDevice.current().play(.click)
                network.cycle(direction: "prev")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(network: network)
        }
        .onAppear {
            network.startDiscovery()
            network.startPolling()
        }
        .onDisappear {
            stopRecordingIfActive()
            network.stopDiscovery()
            network.stopPolling()
        }
    }

    // MARK: - Recording

    private func startRecording() {
        WKInterfaceDevice.current().play(.start)
        guard recorder.startRecording() else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        // Pop animation
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
            characterScale = 1.12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                characterScale = 1.0
            }
        }
        // Safety timer — auto-stop after max duration
        recordingSafetyTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { _ in
            DispatchQueue.main.async {
                guard recorder.isRecording else { return }
                stopAndSend()
            }
        }
    }

    private func stopAndSend() {
        recordingSafetyTimer?.invalidate()
        recordingSafetyTimer = nil

        let duration = recorder.lastRecordingDuration
        if let audioData = recorder.stopRecording(), duration >= minRecordingDuration {
            WKInterfaceDevice.current().play(.success)
            network.dictate(audioData: audioData)
        } else {
            _ = recorder.stopRecording()
            WKInterfaceDevice.current().play(.failure)
        }
        // Shrink-pop animation
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
            characterScale = 0.92
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                characterScale = 1.0
            }
        }
    }

    private func stopRecordingIfActive() {
        recordingSafetyTimer?.invalidate()
        recordingSafetyTimer = nil
        if recorder.isRecording { _ = recorder.stopRecording() }
    }
}
