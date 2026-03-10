import SwiftUI

struct ContentView: View {
    @State private var volumeManager = VolumeButtonManager()
    @State private var networkManager = NetworkManager()
    @State private var audioManager = AudioManager()

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
                lastAction: volumeManager.lastAction,
                actionID: volumeManager.actionID,
                isDictating: volumeManager.isDictating
            )
            .allowsHitTesting(false)

            // Hidden volume view for HUD suppression
            HiddenVolumeView(manager: volumeManager)
                .frame(width: 0, height: 0)

            #if targetEnvironment(simulator)
            // Simulator-only touch targets (no volume buttons in sim)
            SimulatorControlsView(volumeManager: volumeManager)
            #endif

            // Bottom bar: branding + connection status
            VStack {
                Spacer()
                Text("dispatch\(networkManager.isConnected ? "." : "!")")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .padding(.bottom, 16)
            }
            .allowsHitTesting(false)
        }
        .statusBarHidden(true)
        .onAppear {
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

        case .sendDoubleEscape:
            networkManager.sendDoubleEscape()
        }
    }

    private func wireAudioCallbacks() {
        audioManager.onPartialResult = { text, previousLength in
            networkManager.streamText(text, isFinal: false, previousLength: previousLength)
        }
        audioManager.onFinalResult = { text in
            networkManager.streamText(text, isFinal: true, previousLength: 0)
        }
    }
}

#Preview {
    ContentView()
        .previewInterfaceOrientation(.landscapeRight)
}
