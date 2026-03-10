import SwiftUI

struct TerminalLayoutView: View {
    let screenSize: CGSize
    let windowLayouts: [WindowLayout]
    let activeIndex: Int
    let isDictating: Bool

    @State private var recordingPulse: CGFloat = 0.05

    var body: some View {
        GeometryReader { geo in
            let availableSize = geo.size
            let padding: CGFloat = 40

            // Compute bounding box from actual window positions
            let bounds = computeBounds()
            let contentSize = CGSize(
                width: max(bounds.width, 1),
                height: max(bounds.height, 1)
            )

            let drawArea = CGSize(
                width: availableSize.width - padding * 2,
                height: availableSize.height - padding * 2
            )

            let scaleX = drawArea.width / contentSize.width
            let scaleY = drawArea.height / contentSize.height
            let scale = min(scaleX, scaleY)

            let scaledWidth = contentSize.width * scale
            let scaledHeight = contentSize.height * scale

            let offsetX = (availableSize.width - scaledWidth) / 2
            let offsetY = (availableSize.height - scaledHeight) / 2

            ZStack(alignment: .topLeading) {
                Color.clear

                // Sort so active window renders last (visually on top in ZStack)
                let sortedWindows = windowLayouts.enumerated().sorted { a, b in
                    if a.offset == activeIndex { return false }
                    if b.offset == activeIndex { return true }
                    return a.offset < b.offset
                }

                ForEach(sortedWindows, id: \.element.id) { index, window in
                    // Translate window position relative to bounding box origin
                    let rectX = (window.x - bounds.minX) * scale + offsetX
                    let rectY = (window.y - bounds.minY) * scale + offsetY
                    let rectW = window.width * scale
                    let rectH = window.height * scale

                    let isActive = index == activeIndex

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(windowFill(isActive: isActive))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(windowStroke(isActive: isActive), lineWidth: isActive ? 2 : 1)
                            )

                        // Traffic light dots
                        HStack(spacing: 4) {
                            Circle().frame(width: 6, height: 6)
                            Circle().frame(width: 6, height: 6)
                            Circle().frame(width: 6, height: 6)
                        }
                        .foregroundColor(isActive && isDictating ? .red : isActive ? .black : .white.opacity(0.3))
                        .padding(.top, 6)
                        .padding(.leading, 8)

                    }
                    .frame(width: rectW, height: rectH)
                    .position(x: rectX + rectW / 2, y: rectY + rectH / 2)
                }
            }
        }
        .onChange(of: isDictating) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    recordingPulse = 0.4
                }
            } else {
                withAnimation(nil) {
                    recordingPulse = 0.05
                }
            }
        }
    }

    /// Compute bounding box enclosing all windows.
    private func computeBounds() -> CGRect {
        guard !windowLayouts.isEmpty else {
            return CGRect(origin: .zero, size: screenSize)
        }

        var minX = CGFloat.infinity
        var minY = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var maxY = -CGFloat.infinity

        for w in windowLayouts {
            minX = min(minX, w.x)
            minY = min(minY, w.y)
            maxX = max(maxX, w.x + w.width)
            maxY = max(maxY, w.y + w.height)
        }

        // Add a small margin around the bounding box
        let margin: CGFloat = 20
        return CGRect(
            x: minX - margin,
            y: minY - margin,
            width: (maxX - minX) + margin * 2,
            height: (maxY - minY) + margin * 2
        )
    }

    private func windowFill(isActive: Bool) -> Color {
        if isActive && isDictating {
            return Color.red.opacity(recordingPulse)
        } else if isActive {
            return .white
        } else {
            return .black
        }
    }

    private func windowStroke(isActive: Bool) -> Color {
        if isActive && isDictating {
            return Color.red
        } else if isActive {
            return .white
        } else {
            return .white.opacity(0.3)
        }
    }
}
