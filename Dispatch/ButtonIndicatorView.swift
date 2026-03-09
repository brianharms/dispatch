import SwiftUI

struct ButtonIndicatorView: View {
    let lastAction: DispatchAction?
    let actionID: Int
    let isDictating: Bool

    // Animation states
    @State private var showVolUpFlash = false
    @State private var showVolDownFlash = false
    @State private var volUpText = "+"
    @State private var volDownText = "-"
    @State private var pulseScale: CGFloat = 1.0
    @State private var lastProcessedAction: DispatchAction?
    @State private var actionCounter: Int = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Vol Up indicator (left side of top edge in landscape-right)
                if isDictating {
                    // Persistent red recording dot with pulse
                    Circle()
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                        .scaleEffect(pulseScale)
                        .position(x: geo.size.width * 0.3, y: 20)
                        .onAppear {
                            withAnimation(
                                .easeInOut(duration: 0.8)
                                .repeatForever(autoreverses: true)
                            ) {
                                pulseScale = 1.3
                            }
                        }
                        .onDisappear {
                            pulseScale = 1.0
                        }
                } else if showVolUpFlash {
                    Text(volUpText)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .position(x: geo.size.width * 0.3, y: 20)
                        .transition(.opacity)
                }

                // Vol Down indicator (right side of top edge)
                if showVolDownFlash {
                    Text(volDownText)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .position(x: geo.size.width * 0.7, y: 20)
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: actionID) { _, _ in
            guard let action = lastAction else { return }
            actionCounter += 1
            handleAction(action)
        }
    }

    private func handleAction(_ action: DispatchAction) {
        let currentCounter = actionCounter

        switch action {
        case .cycleNext:
            volUpText = "+"
            withAnimation(.easeIn(duration: 0.05)) {
                showVolUpFlash = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard actionCounter == currentCounter else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    showVolUpFlash = false
                }
            }

        case .cyclePrevious:
            volDownText = "\u{2212}" // minus sign
            withAnimation(.easeIn(duration: 0.05)) {
                showVolDownFlash = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard actionCounter == currentCounter else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    showVolDownFlash = false
                }
            }

        case .dictationStarted:
            showVolUpFlash = false

        case .dictationEnded:
            showVolUpFlash = false

        case .sendDoubleEscape:
            volDownText = "esc"
            withAnimation(.easeIn(duration: 0.05)) {
                showVolDownFlash = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard actionCounter == currentCounter else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    showVolDownFlash = false
                }
            }
        }
    }
}
