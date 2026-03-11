import SwiftUI

struct ButtonIndicatorView: View {
    let indicatorAction: DispatchAction?
    let indicatorActionID: Int
    let isDictating: Bool

    // Animation states
    @State private var volUpOpacity: CGFloat = 0
    @State private var volDownOpacity: CGFloat = 0
    @State private var volDownText = "<"
    @State private var volDownFontSize: CGFloat = 15
    @State private var volDownOffsetX: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0
    @State private var actionCounter: Int = 0

    // In landscape-left, volume buttons are on the top edge:
    // vol-down is slightly left of vol-up, both on the right side of the screen.
    private let volDownX: CGFloat = 0.67
    private let volUpX: CGFloat = 0.75
    private let buttonY: CGFloat = 12
    private let showGrid = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 5pt alignment grid
                if showGrid {
                    Canvas { context, size in
                        for x in stride(from: CGFloat(0), through: size.width, by: 5) {
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: size.height))
                            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                        }
                        for y in stride(from: CGFloat(0), through: size.height, by: 5) {
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: size.width, y: y))
                            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                        }
                    }
                    .allowsHitTesting(false)
                }

                // Vol Down indicator — "<"
                Text(volDownText)
                    .font(.system(size: volDownFontSize, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .opacity(volDownOpacity)
                    .position(x: geo.size.width * volDownX - 58 + volDownOffsetX, y: buttonY)

                // Vol Up indicator — ">"
                if isDictating {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .scaleEffect(pulseScale)
                        .position(x: geo.size.width * volUpX - 35, y: buttonY)
                } else {
                    Text(">")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .opacity(volUpOpacity)
                        .position(x: geo.size.width * volUpX - 36, y: buttonY)
                }
            }
        }
        .onChange(of: isDictating) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    pulseScale = 1.3
                }
            } else {
                pulseScale = 1.0
            }
        }
        .onChange(of: indicatorActionID) { _, _ in
            guard let action = indicatorAction else { return }
            actionCounter += 1
            handleAction(action)
        }
    }

    /// 500ms total: 250ms fade-in, 250ms fade-out
    private func flashIndicator(
        setOpacity: @escaping (CGFloat) -> Void
    ) {
        let counter = actionCounter

        // Phase 1 (0-250ms): fade in
        withAnimation(.easeOut(duration: 0.25)) {
            setOpacity(1.0)
        }

        // Phase 2 (250-500ms): fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard actionCounter == counter else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                setOpacity(0)
            }
        }
    }

    /// Double flash: fade in, fade to 25%, fade in, fade out
    private func doubleFlashIndicator(
        setOpacity: @escaping (CGFloat) -> Void
    ) {
        let counter = actionCounter

        // Flash 1: fade in
        withAnimation(.easeOut(duration: 0.15)) {
            setOpacity(1.0)
        }

        // Flash 1: fade down to 25%
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard actionCounter == counter else { return }
            withAnimation(.easeIn(duration: 0.15)) {
                setOpacity(0.25)
            }
        }

        // Flash 2: fade back in
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
            guard actionCounter == counter else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                setOpacity(1.0)
            }
        }

        // Flash 2: fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard actionCounter == counter else { return }
            withAnimation(.easeIn(duration: 0.25)) {
                setOpacity(0)
            }
        }
    }

    private func handleAction(_ action: DispatchAction) {
        switch action {
        case .cycleNext:
            flashIndicator(
                setOpacity: { volUpOpacity = $0 }
            )

        case .cyclePrevious:
            volDownText = "<"
            volDownFontSize = 15
            volDownOffsetX = 0
            flashIndicator(
                setOpacity: { volDownOpacity = $0 }
            )

        case .dictationStarted:
            volUpOpacity = 0

        case .dictationEnded:
            volUpOpacity = 0

        case .sendDoubleEscape:
            volDownText = "esc"
            volDownFontSize = 14
            volDownOffsetX = 1
            doubleFlashIndicator(
                setOpacity: { volDownOpacity = $0 }
            )
        }
    }
}
