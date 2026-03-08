import SwiftUI

struct ContentView: View {
    // State bindings — will be driven by managers later
    @State private var isConnected: Bool = false
    @State private var activeWindowName: String = "waiting..."
    @State private var currentIndex: Int = 0
    @State private var totalWindows: Int = 0
    @State private var lastAction: String? = nil
    @State private var isDictating: Bool = false

    // Wireframe pulse trigger
    @State private var isPulsing: Bool = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top: connection status
                HStack {
                    StatusIndicator(isConnected: isConnected)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                Spacer()

                // Center: wireframe polyhedron
                WireframeView(isPulsing: isPulsing, isDictating: isDictating)
                    .frame(width: 260, height: 260)

                Spacer()
                    .frame(height: 40)

                // Active window name
                Text(activeWindowName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Terminal count
                if totalWindows > 0 {
                    Text("\(currentIndex + 1) of \(totalWindows)")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color(white: 0.4))
                        .padding(.top, 4)
                } else {
                    Text("no terminals")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(Color(white: 0.3))
                        .padding(.top, 4)
                }

                Spacer()

                // App name at bottom
                Text("dispatch.")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(Color(white: 0.15))
                    .padding(.bottom, 40)
            }

            // Dictation indicator overlay
            if isDictating {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 8, height: 8)
                            .opacity(isDictating ? 1.0 : 0.0)
                            .animation(
                                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                                value: isDictating
                            )
                        Text("dictating")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(Color(white: 0.6))
                    }
                    .padding(.bottom, 100)
                }
            }

            // Action flash overlay
            if let action = lastAction {
                VStack {
                    Text(action)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(white: 0.1))
                        )
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 60)
            }
        }
        .onChange(of: lastAction) { _, newValue in
            if newValue != nil {
                isPulsing = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    isPulsing = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        lastAction = nil
                    }
                }
            }
        }
        .statusBarHidden(true)
    }
}

#Preview {
    ContentView()
}
