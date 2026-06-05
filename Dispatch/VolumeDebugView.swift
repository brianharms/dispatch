import SwiftUI

struct VolumeDebugView: View {
    let volumeManager: VolumeButtonManager

    var body: some View {
        GeometryReader { geo in
            let barHeight: CGFloat = min(geo.size.height - 40, 80)
            let fillHeight = barHeight * CGFloat(volumeManager.debugVolume)
            let midY = barHeight * 0.5
            let logAreaHeight = geo.size.height - barHeight - 80

            VStack(alignment: .leading, spacing: 2) {
                // Mode indicator
                Text("[\(volumeManager.interactionMode.displayName)]")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.6))

                // State + stats text
                Text("\(volumeManager.debugState)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(stateColor)

                Text("vol \(String(format: "%.2f", volumeManager.debugVolume))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(volumeColor)

                Text("kvo:\(volumeManager.debugKVOCount) ign:\(volumeManager.debugIgnoredCount)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))

                Text("rst:\(volumeManager.debugResetCount) \(volumeManager.debugSliderConnected ? "ok" : "NO SLIDER")")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(volumeManager.debugSliderConnected ? .white.opacity(0.4) : .red)

                // Volume bar
                HStack(alignment: .bottom, spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 6, height: barHeight)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(volumeColor)
                            .frame(width: 6, height: max(1, fillHeight))

                        Rectangle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 10, height: 1)
                            .offset(y: -(midY))
                    }
                    .frame(height: barHeight)
                }

                // Log entries
                if logAreaHeight > 20 {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(volumeManager.debugLogEntries.enumerated()), id: \.offset) { idx, entry in
                                    Text(entry)
                                        .font(.system(size: 7, design: .monospaced))
                                        .foregroundColor(logColor(for: entry))
                                        .lineLimit(2)
                                        .id(idx)
                                }
                            }
                        }
                        .frame(height: logAreaHeight)
                        .onChange(of: volumeManager.debugLogEntries.count) {
                            if let last = volumeManager.debugLogEntries.indices.last {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.top, 20)
        }
    }

    private func logColor(for entry: String) -> Color {
        if entry.contains("ACTION") { return .cyan }
        if entry.contains("HOLD") { return .orange }
        if entry.contains("RELEASE") { return .yellow }
        if entry.contains("FAILED") { return .red }
        if entry.contains("RESET") { return .green.opacity(0.6) }
        if entry.contains("SKIP") { return .white.opacity(0.2) }
        return .white.opacity(0.4)
    }

    private var stateColor: Color {
        let state = volumeManager.debugState
        if state.contains("UP") && state.contains("x1") { return .yellow }
        if state.contains("DN") && state.contains("x1") { return .yellow }
        if state.contains("UP") { return .red }
        if state.contains("DN") { return .orange }
        return .white.opacity(0.5)
    }

    private var volumeColor: Color {
        let vol = volumeManager.debugVolume
        if vol > 0.9 || vol < 0.1 { return .red }
        if vol > 0.7 || vol < 0.3 { return .yellow }
        return .green
    }
}
