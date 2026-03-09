import SwiftUI

struct TerminalLayoutView: View {
    let screenSize: CGSize
    let windowLayouts: [WindowLayout]
    let activeIndex: Int
    let isDictating: Bool

    var body: some View {
        GeometryReader { geo in
            let availableSize = geo.size
            let padding: CGFloat = 40
            let drawArea = CGSize(
                width: availableSize.width - padding * 2,
                height: availableSize.height - padding * 2
            )

            // Scale factor: fit monitor resolution into available draw area
            let scaleX = drawArea.width / screenSize.width
            let scaleY = drawArea.height / screenSize.height
            let scale = min(scaleX, scaleY)

            let scaledMonitorWidth = screenSize.width * scale
            let scaledMonitorHeight = screenSize.height * scale

            // Center offset
            let offsetX = (availableSize.width - scaledMonitorWidth) / 2
            let offsetY = (availableSize.height - scaledMonitorHeight) / 2

            ZStack(alignment: .topLeading) {
                // Transparent background to fill the geometry reader
                Color.clear

                ForEach(Array(windowLayouts.enumerated()), id: \.element.id) { index, window in
                    let rectX = window.x * scale + offsetX
                    let rectY = window.y * scale + offsetY
                    let rectW = window.width * scale
                    let rectH = window.height * scale

                    let isActive = index == activeIndex

                    Rectangle()
                        .fill(windowFill(isActive: isActive, isDictating: isDictating))
                        .frame(width: rectW, height: rectH)
                        .overlay(
                            Rectangle()
                                .stroke(windowStroke(isActive: isActive, isDictating: isDictating), lineWidth: 1)
                        )
                        .position(x: rectX + rectW / 2, y: rectY + rectH / 2)
                }
            }
        }
    }

    private func windowFill(isActive: Bool, isDictating: Bool) -> Color {
        if isActive && isDictating {
            return Color(red: 1.0, green: 0.0, blue: 0.0)
        } else if isActive {
            return .white
        } else {
            return .clear
        }
    }

    private func windowStroke(isActive: Bool, isDictating: Bool) -> Color {
        if isActive && isDictating {
            return Color(red: 1.0, green: 0.0, blue: 0.0)
        } else if isActive {
            return .white
        } else {
            return .white
        }
    }
}
