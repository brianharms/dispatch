import SwiftUI

struct ClaudeCharacter: View {
    var isRecording: Bool
    var isConnected: Bool

    @State private var bobOffset: CGFloat = 0
    @State private var isBlinking = false

    var body: some View {
        ZStack {
            // Body
            RoundedRectangle(cornerRadius: 22)
                .stroke(bodyStroke, lineWidth: 1.5)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(bodyFill)
                )
                .frame(width: 76, height: 60)

            VStack(spacing: 6) {
                // Eyes
                HStack(spacing: isRecording ? 22 : 18) {
                    eyeView
                    eyeView
                }

                // Mouth
                mouthView
            }
        }
        .offset(y: bobOffset)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                bobOffset = -3
            }
        }
        .onReceive(Timer.publish(every: 3.5, on: .main, in: .common).autoconnect()) { _ in
            guard !isRecording && isConnected else { return }
            withAnimation(.easeInOut(duration: 0.08)) { isBlinking = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeInOut(duration: 0.08)) { isBlinking = false }
            }
        }
    }

    // MARK: - Sub-views

    private var eyeView: some View {
        Circle()
            .fill(Color.white.opacity(isConnected ? 0.9 : 0.3))
            .frame(width: isRecording ? 10 : 8, height: isRecording ? 10 : 8)
            .scaleEffect(y: isBlinking ? 0.1 : 1.0, anchor: .center)
            .animation(.easeOut(duration: 0.15), value: isRecording)
    }

    @ViewBuilder
    private var mouthView: some View {
        if isRecording {
            // Listening — open mouth
            Ellipse()
                .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                .frame(width: 10, height: 12)
        } else if isConnected {
            // Happy — smile
            SmileCurve()
                .stroke(Color.white.opacity(0.5), lineWidth: 1.5)
                .frame(width: 16, height: 7)
        } else {
            // Disconnected — flat line
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.white.opacity(0.2))
                .frame(width: 12, height: 1.5)
        }
    }

    // MARK: - Colors

    private var bodyStroke: Color {
        if isRecording { return .white.opacity(0.7) }
        return .white.opacity(isConnected ? 0.35 : 0.12)
    }

    private var bodyFill: Color {
        if isRecording { return .white.opacity(0.06) }
        return .white.opacity(isConnected ? 0.02 : 0.01)
    }
}

// MARK: - Smile shape

struct SmileCurve: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: 0),
            control: CGPoint(x: rect.midX, y: rect.height)
        )
        return path
    }
}
