import SwiftUI

struct NetworkDebugView: View {
    let networkManager: NetworkManager

    var body: some View {
        GeometryReader { geo in
            let logAreaHeight = geo.size.height - 40

            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(networkManager.isConnected ? "connected" : "disconnected")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(networkManager.isConnected ? .green : .red)

                    Text("win:\(networkManager.totalWindows) idx:\(networkManager.activeIndex)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))

                    if logAreaHeight > 20 {
                        ScrollViewReader { proxy in
                            ScrollView(.vertical, showsIndicators: false) {
                                LazyVStack(alignment: .trailing, spacing: 1) {
                                    ForEach(Array(networkManager.debugLogEntries.enumerated()), id: \.offset) { idx, entry in
                                        Text(entry)
                                            .font(.system(size: 7, design: .monospaced))
                                            .foregroundColor(logColor(for: entry))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.trailing)
                                            .id(idx)
                                    }
                                }
                            }
                            .frame(height: logAreaHeight)
                            .onChange(of: networkManager.debugLogEntries.count) {
                                if let last = networkManager.debugLogEntries.indices.last {
                                    proxy.scrollTo(last, anchor: .bottom)
                                }
                            }
                        }
                    }
                }
                .frame(width: 200)
                .padding(.trailing, 6)
                .padding(.top, 20)
            }
        }
    }

    private func logColor(for entry: String) -> Color {
        if entry.contains("FAILED") { return .red }
        if entry.contains("TIMEOUT") { return .red }
        if entry.contains("HTTP") && !entry.contains("OK") { return .orange }
        if entry.contains("confirmed") { return .green }
        if entry.contains("cycle") { return .cyan }
        return .white.opacity(0.4)
    }
}
