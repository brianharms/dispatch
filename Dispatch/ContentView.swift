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

            // Hidden volume view for HUD suppression
            HiddenVolumeView(manager: volumeManager)
                .frame(width: 0, height: 0)

            // "dispatch." branding — bottom-left
            VStack {
                Spacer()
                HStack {
                    Text("dispatch.")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 0.4, green: 0.4, blue: 0.4))
                        .padding(.leading, 20)
                        .padding(.bottom, 16)
                    Spacer()
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            volumeManager.setup()
            networkManager.startPolling()
            wireAudioCallbacks()
        }
        .onDisappear {
            volumeManager.teardown()
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
            audioManager.requestPermissions()
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
