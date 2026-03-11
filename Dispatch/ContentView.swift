import SwiftUI

struct ContentView: View {
    @State private var volumeManager = VolumeButtonManager()
    @State private var networkManager = NetworkManager()
    @State private var audioManager = AudioManager()
    @State private var showSettings = false
    @State private var settingsIP = ""
    @State private var showDebug = true
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
            showDebug = UserDefaults.standard.object(forKey: "showDebug") as? Bool ?? true
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
            VStack(alignment: .leading, spacing: 12) {
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
                HStack {
                    Text("mode")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    ForEach(InteractionMode.allCases, id: \.self) { mode in
                        Button(mode.displayName) {
                            volumeManager.setInteractionMode(mode)
                        }
                        .font(.system(size: 11, weight: volumeManager.interactionMode == mode ? .bold : .regular, design: .monospaced))
                        .foregroundColor(volumeManager.interactionMode == mode ? .black : .white.opacity(0.6))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(volumeManager.interactionMode == mode ? Color.white : Color.white.opacity(0.1))
                        )
                    }
                }

                // Debug
                HStack {
                    Text("debug")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                    Button(showDebug ? "on" : "off") {
                        showDebug.toggle()
                        UserDefaults.standard.set(showDebug, forKey: "showDebug")
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(showDebug ? .black : .white.opacity(0.6))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(showDebug ? Color.white : Color.white.opacity(0.1))
                    )
                }

                // IP
                HStack(spacing: 8) {
                    Text("ip")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                    TextField("192.168.1.x", text: $settingsIP)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.decimalPad)
                        .focused($ipFieldFocused)
                        .onSubmit { connectIP() }
                    Button("connect") { connectIP() }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white)
                        .cornerRadius(4)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
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

        case .dictationEnded:
            audioManager.stopRecording()
            networkManager.sendEnter()
            volumeManager.recoverAfterAudioEngine()

        case .sendDoubleEscape:
            networkManager.sendDoubleEscape()
        }
    }

    private func wireAudioCallbacks() {
        audioManager.onPartialResult = { text, previousLength in
            networkManager.streamText(text, isFinal: false, previousLength: previousLength)
        }
        audioManager.onFinalResult = { _ in }
    }
}

#Preview {
    ContentView()
        .previewInterfaceOrientation(.landscapeRight)
}
