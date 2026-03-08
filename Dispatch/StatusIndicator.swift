import SwiftUI

struct StatusIndicator: View {
    var isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Color.green : Color.red.opacity(0.7))
                .frame(width: 7, height: 7)
                .shadow(
                    color: isConnected ? .green.opacity(0.5) : .red.opacity(0.3),
                    radius: 4
                )

            Text(isConnected ? "connected" : "disconnected")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(Color(white: 0.45))
        }
    }
}
