import SwiftUI
import WatchKit

struct ContentView: View {
    @StateObject private var network = NetworkManager.shared
    @StateObject private var recorder = AudioRecorder()
    @State private var showingSettings = false
    @State private var crownOffset: Double = 0.0
    @State private var lastTriggeredOffset: Double = 0.0
    @State private var lastTriggerTime: Date = .distantPast
    @State private var pulseOpacity: Double = 0.3
    @State private var touchStart: Date = .distantPast
    @State private var didSwipe: Bool = false

    @AppStorage("watchOrientation") private var orientation: String = "landscape"

    private let threshold: Double = 2.4
    private let debounceInterval: TimeInterval = 0.3
    private let swipeDeadline: TimeInterval = 0.3

    var body: some View {
        GeometryReader { geo in
            let swipeThreshold = geo.size.width / 6

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
                    // Top bar — tap for settings
                    Button {
                        showingSettings = true
                    } label: {
                        HStack(spacing: 0) {
                            Text("dispatch")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(Color(white: 0.5))
                            Text(network.isConnected ? "." : "!")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(network.isConnected ? Color(white: 0.5) : .red.opacity(0.8))
                            Spacer()
                            Image(systemName: "gearshape")
                                .font(.system(size: 10))
                                .foregroundColor(Color(white: 0.35))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    // Divider
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)

                    // Recording zone — hold to dictate, swipe to cycle
                    ZStack {
                        VStack(spacing: 6) {
                            if network.isConnected && network.totalWindows > 0 {
                                // Big index number
                                Text("\(network.currentIndex + 1)")
                                    .font(.system(size: 48, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white)

                                // Window name
                                Text(network.currentWindowName)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)

                                // Dot indicators
                                HStack(spacing: 6) {
                                    ForEach(0..<network.totalWindows, id: \.self) { i in
                                        Circle()
                                            .fill(i == network.currentIndex ? Color.white : Color.white.opacity(0.2))
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.top, 4)
                            } else if !network.isConnected {
                                Text("—")
                                    .font(.system(size: 48, weight: .heavy, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.15))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if touchStart == .distantPast {
                                    touchStart = Date()
                                    didSwipe = false
                                }

                                let elapsed = Date().timeIntervalSince(touchStart)
                                let h = value.translation.width
                                let v = value.translation.height

                                // Within swipe deadline: check for horizontal swipe
                                if !didSwipe && !recorder.isRecording && elapsed < swipeDeadline {
                                    if abs(h) > swipeThreshold && abs(h) > abs(v) {
                                        didSwipe = true
                                        let direction: String
                                        if orientation == "landscape" {
                                            direction = h < 0 ? "next" : "prev"
                                        } else {
                                            direction = h < 0 ? "next" : "prev"
                                        }
                                        WKInterfaceDevice.current().play(.click)
                                        network.cycle(direction: direction)
                                    }
                                }

                                // Past deadline + finger hasn't moved far = start recording
                                if !didSwipe && !recorder.isRecording && elapsed >= swipeDeadline {
                                    if abs(h) <= swipeThreshold {
                                        WKInterfaceDevice.current().play(.start)
                                        recorder.startRecording()
                                    } else {
                                        // Moved too far but past deadline — treat as swipe
                                        didSwipe = true
                                        if abs(h) > abs(v) {
                                            let direction = h < 0 ? "next" : "prev"
                                            WKInterfaceDevice.current().play(.click)
                                            network.cycle(direction: direction)
                                        }
                                    }
                                }
                            }
                            .onEnded { _ in
                                touchStart = .distantPast
                                if recorder.isRecording {
                                    if let audioData = recorder.stopRecording() {
                                        WKInterfaceDevice.current().play(.success)
                                        network.dictate(audioData: audioData)
                                    } else {
                                        WKInterfaceDevice.current().play(.failure)
                                    }
                                }
                                didSwipe = false
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
            network.stopDiscovery()
            network.stopPolling()
        }
    }
}
