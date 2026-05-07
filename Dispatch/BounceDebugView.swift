import SwiftUI

struct BounceDebugView: View {
    let networkManager: NetworkManager

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(networkManager.bounceLogEntries.enumerated()), id: \.offset) { idx, entry in
                                Text(entry)
                                    .font(.system(size: 7, design: .monospaced))
                                    .foregroundColor(bounceColor(for: entry))
                                    .lineLimit(2)
                                    .id(idx)
                            }
                        }
                    }
                    .frame(height: min(geo.size.height * 0.4, 160))
                    .onChange(of: networkManager.bounceLogEntries.count) {
                        if let last = networkManager.bounceLogEntries.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
        }
    }

    private func bounceColor(for entry: String) -> Color {
        if entry.contains("REJECT") { return .red }
        if entry.contains("OPTIMISTIC") { return .cyan }
        if entry.contains("CYCLE-RESP") { return .green }
        if entry.contains("POLL") && entry.contains("ACCEPT") { return .yellow }
        if entry.contains("POLL") { return .white.opacity(0.3) }
        if entry.contains("CMD") { return .cyan.opacity(0.7) }
        if entry.contains("NO-MATCH") { return .orange }
        return .white.opacity(0.4)
    }
}
