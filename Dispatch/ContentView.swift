import SwiftUI

struct ContentView: View {
    @State private var volumeManager = VolumeButtonManager()
    @State private var networkManager = NetworkManager()
    @State private var audioManager = AudioManager()
    @State private var showSettings = false
    @State private var settingsIP = ""
    @State private var showDebug = false
    @State private var bluetoothMic = false
    @FocusState private var ipFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TerminalLayoutView(
                screenSize: networkManager.screenSize,
                windowLayouts: networkManager.windowLayouts,
                activeIndex: networkManager.activeIndex,
                isDictating: volumeManager.isDictating
            )

            ButtonIndicatorView(
                indicatorAction: volumeManager.indicatorAction,
                indicatorActionID: volumeManager.indicatorActionID,
                isDictating: volumeManager.isDictating
            )
            .allowsHitTesting(false)

            // Hidden volume view for HUD suppression
            HiddenVolumeView(manager: volumeManager)
                .frame(width: 0, height: 0)

            #if targetEnvironment(simulator)
            SimulatorControlsView(volumeManager: volumeManager)
            #endif

            if showDebug {
                // Volume debug overlay — left edge
                VolumeDebugView(volumeManager: volumeManager)
                    .allowsHitTesting(false)

                // Network debug overlay — right edge
                NetworkDebugView(networkManager: networkManager)
                    .allowsHitTesting(false)
            }

            if networkManager.debugBounceLog {
                BounceDebugView(networkManager: networkManager)
                    .allowsHitTesting(false)
            }

            // Bottom bar: branding + connection status
            VStack {
                Spacer()
                HStack {
                    Text("dispatch\(networkManager.isConnected ? "." : "!")")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                        .onTapGesture(count: 2) {
                            settingsIP = networkManager.currentHost
                            showSettings.toggle()
                            if showSettings { ipFieldFocused = true }
                        }
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.bottom, 16)
            }

            // Settings pane
            if showSettings {
                settingsOverlay
            }
        }
        .statusBarHidden(true)
        .onAppear {
            showDebug = UserDefaults.standard.object(forKey: "showDebug") as? Bool ?? false
            bluetoothMic = UserDefaults.standard.bool(forKey: "bluetoothMic")
            volumeManager.setup()
            networkManager.startDiscovery()
            audioManager.requestPermissions()
            wireAudioCallbacks()
        }
        .onDisappear {
            volumeManager.teardown()
            networkManager.stopDiscovery()
            networkManager.stopPolling()
            audioManager.stopRecording()
        }
        .onChange(of: volumeManager.actionID) { _, _ in
            handleAction()
        }
    }

    // MARK: - Settings Overlay

    private var settingsOverlay: some View {
        VStack {
            Spacer()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    // Header
                    HStack {
                        Text("settings")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                        Spacer()
                        Button("done") { showSettings = false }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    // Mode
                    HStack(spacing: 6) {
                        settingsLabel("mode")
                        ForEach(InteractionMode.allCases, id: \.self) { mode in
                            Button(mode.displayName) {
                                volumeManager.setInteractionMode(mode)
                            }
                            .font(.system(size: 11, weight: volumeManager.interactionMode == mode ? .bold : .regular, design: .monospaced))
                            .foregroundColor(volumeManager.interactionMode == mode ? .black : .white.opacity(0.6))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(volumeManager.interactionMode == mode ? Color.white : Color.white.opacity(0.1))
                            )
                        }
                    }

                    // Toggle row: debug + bounce log
                    HStack(spacing: 6) {
                        settingsLabel("debug")
                        settingsToggle(showDebug ? "on" : "off", isOn: showDebug) {
                            showDebug.toggle()
                            UserDefaults.standard.set(showDebug, forKey: "showDebug")
                        }

                        settingsLabel("bounce")
                            .padding(.leading, 8)
                        settingsToggle(
                            networkManager.debugBounceLog ? "on" : "off",
                            isOn: networkManager.debugBounceLog,
                            onColor: .green
                        ) {
                            networkManager.debugBounceLog.toggle()
                            if !networkManager.debugBounceLog {
                                networkManager.clearBounceLog()
                            }
                        }
                    }

                    // Toggle row: polling + optimistic
                    HStack(spacing: 6) {
                        settingsLabel("polling")
                        settingsToggle(
                            networkManager.debugMutePolling ? "muted" : "live",
                            isOn: !networkManager.debugMutePolling,
                            offColor: .red
                        ) {
                            networkManager.debugMutePolling.toggle()
                        }

                        settingsLabel("optimistic")
                            .padding(.leading, 8)
                        settingsToggle(
                            networkManager.debugNoOptimistic ? "off" : "on",
                            isOn: !networkManager.debugNoOptimistic,
                            offColor: .red
                        ) {
                            networkManager.debugNoOptimistic.toggle()
                        }
                    }

                    // Toggle row: bluetooth mic
                    HStack(spacing: 6) {
                        settingsLabel("bt mic")
                        settingsToggle(
                            bluetoothMic ? "on" : "off",
                            isOn: bluetoothMic
                        ) {
                            bluetoothMic.toggle()
                            UserDefaults.standard.set(bluetoothMic, forKey: "bluetoothMic")
                        }
                    }

                    // IP
                    HStack(spacing: 6) {
                        settingsLabel("ip")
                        TextField("192.168.1.x", text: $settingsIP)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.decimalPad)
                            .focused($ipFieldFocused)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .onSubmit { connectIP() }
                        Button("connect") { connectIP() }
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.white)
                            .cornerRadius(4)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: 340, maxHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.bottom, 6)
        }
    }

    // MARK: - Settings Helpers

    private func settingsLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.white.opacity(0.4))
    }

    private func settingsToggle(
        _ label: String,
        isOn: Bool,
        onColor: Color = .white,
        offColor: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let activeColor = isOn ? onColor : (offColor ?? .white)
        let bgColor = isOn
            ? onColor.opacity(onColor == .white ? 1.0 : 0.2)
            : (offColor != nil ? offColor!.opacity(0.2) : Color.white.opacity(0.1))
        let fgColor = isOn
            ? (onColor == .white ? Color.black : onColor)
            : (offColor ?? .white.opacity(0.6))

        return Button(label, action: action)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(fgColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(bgColor)
            )
    }

    // MARK: - Actions

    private func connectIP() {
        networkManager.connectManually(ip: settingsIP)
        showSettings = false
    }

    private func handleAction() {
        guard let action = volumeManager.lastAction else { return }

        switch action {
        case .cycleNext:
            networkManager.cycleNext()

        case .cyclePrevious:
            networkManager.cyclePrevious()

        case .dictationStarted:
            audioManager.startRecording()
            networkManager.notifyRecordingStart()

        case .dictationEnded:
            audioManager.stopRecording()
            let hasText = !audioManager.transcribedText.isEmpty || !audioManager.partialText.isEmpty
            if hasText {
                networkManager.sendEnterAfterDictation()
            } else {
                networkManager.notifyRecordingStop()
            }
            volumeManager.recoverAfterAudioEngine()

        case .sendDoubleEscape:
            networkManager.sendDoubleEscape()
        }
    }

    private func wireAudioCallbacks() {
        audioManager.onPartialResult = { text, previousLength, sequence in
            networkManager.streamText(text, isFinal: false, previousLength: previousLength, sequence: sequence)
        }
        audioManager.onFinalResult = { _ in }
        audioManager.onDebugLog = { message in
            networkManager.sendDebugLog(message)
        }
    }
}

#Preview {
    ContentView()
        .previewInterfaceOrientation(.landscapeRight)
}
