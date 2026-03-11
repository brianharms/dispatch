import SwiftUI

struct SettingsView: View {
    @ObservedObject var network: NetworkManager
    @State private var octet1: String = "192"
    @State private var octet2: String = "168"
    @State private var octet3: String = "1"
    @State private var octet4: String = "80"
    @AppStorage("watchOrientation") private var orientation: String = "landscape"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("settings")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button("done") { dismiss() }
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                }

                // IP address — stacked octet fields with label in gutter
                HStack(alignment: .top, spacing: 6) {
                    Text("ip")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                        .frame(width: 16)
                        .padding(.top, 8)

                    VStack(spacing: 4) {
                        OctetField(value: $octet1, label: "1")
                        OctetField(value: $octet2, label: "2")
                        OctetField(value: $octet3, label: "3")
                        OctetField(value: $octet4, label: "4", highlight: true)
                    }
                }

                Button {
                    let ip = "\(octet1).\(octet2).\(octet3).\(octet4)"
                    network.connectManually(ip: ip)
                    dismiss()
                } label: {
                    Text("connect")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                // Orientation picker
                HStack(spacing: 8) {
                    Text("orient")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Button {
                        orientation = orientation == "landscape" ? "portrait" : "landscape"
                    } label: {
                        Text(orientation)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12))
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            parseHostname(network.macHostname)
        }
    }

    private func parseHostname(_ host: String) {
        let parts = host.split(separator: ".").map(String.init)
        if parts.count == 4 {
            octet1 = parts[0]
            octet2 = parts[1]
            octet3 = parts[2]
            octet4 = parts[3]
        } else if !host.isEmpty {
            octet4 = host
        }
    }
}

struct OctetField: View {
    @Binding var value: String
    var label: String = ""
    var highlight: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.2))
                .frame(width: 10)
            TextField("0", text: $value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(highlight ? .white : .white.opacity(0.6))
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(Color.white.opacity(highlight ? 0.15 : 0.07))
                .cornerRadius(4)
                #if os(watchOS)
                .textContentType(.oneTimeCode)
                #endif
        }
    }
}
