import SwiftUI

struct ContentView: View {
    // Placeholder state — will be driven by NetworkManager later
    @State private var isConnected: Bool = false
    @State private var screenSize = CGSize(width: 2560, height: 1440)
    @State private var windowLayouts = [
        WindowLayout(id: "1", name: "project-a", x: 0, y: 0, width: 1280, height: 720),
        WindowLayout(id: "2", name: "project-b", x: 1280, y: 0, width: 1280, height: 720),
        WindowLayout(id: "3", name: "project-c", x: 0, y: 720, width: 1280, height: 720),
        WindowLayout(id: "4", name: "project-d", x: 1280, y: 720, width: 1280, height: 720),
    ]
    @State private var activeIndex: Int = 1

    // Placeholder state — will be driven by VolumeButtonManager later
    @State private var lastAction: DispatchAction? = nil
    @State private var isDictating: Bool = false

    var body: some View {
        ZStack {
            // Black background
            Color.black.ignoresSafeArea()

            // Terminal window layout visualization (centered)
            TerminalLayoutView(
                screenSize: screenSize,
                windowLayouts: windowLayouts,
                activeIndex: activeIndex,
                isDictating: isDictating
            )

            // Volume button press indicators (top edge overlay)
            ButtonIndicatorView(
                lastAction: lastAction,
                isDictating: isDictating
            )

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
    }
}

#Preview {
    ContentView()
        .previewInterfaceOrientation(.landscapeRight)
}
