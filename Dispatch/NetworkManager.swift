import Foundation
import Observation

@Observable
@MainActor
final class NetworkManager {

    // MARK: - Public State

    var isConnected: Bool = false
    var screenSize: CGSize = .zero
    var windowLayouts: [WindowLayout] = []
    var activeIndex: Int = 0
    var totalWindows: Int = 0
    var activeWindowName: String = ""

    // MARK: - Configuration

    private let serverURL = "http://192.168.1.80:9876"
    private var pollTimer: Timer?

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        // Fire immediately, then every 2 seconds
        pollStatus()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollStatus()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Status Polling

    private func pollStatus() {
        guard let url = URL(string: "\(serverURL)/status") else { return }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    isConnected = false
                    return
                }
                parseStatusResponse(data)
                isConnected = true
            } catch {
                isConnected = false
            }
        }
    }

    private func parseStatusResponse(_ data: Data) {
        struct StatusResponse: Decodable {
            let screen: ScreenSize?
            let layout: [WindowLayout]?
            let current_index: Int?
            let total: Int?
            let active_window: String?

            struct ScreenSize: Decodable {
                let width: CGFloat
                let height: CGFloat
            }
        }

        do {
            let status = try JSONDecoder().decode(StatusResponse.self, from: data)

            if let screen = status.screen {
                screenSize = CGSize(width: screen.width, height: screen.height)
            }
            if let layout = status.layout {
                windowLayouts = layout
            }
            if let index = status.current_index {
                activeIndex = index
            }
            if let total = status.total {
                totalWindows = total
            }
            if let name = status.active_window {
                activeWindowName = name
            }
        } catch {
            print("[NetworkManager] Failed to parse status: \(error)")
        }
    }

    // MARK: - Actions

    func cycleNext() {
        // Optimistic update
        if totalWindows > 0 {
            activeIndex = (activeIndex + 1) % totalWindows
        }
        postJSON(endpoint: "/cycle", body: ["direction": "next"])
    }

    func cyclePrevious() {
        // Optimistic update
        if totalWindows > 0 {
            activeIndex = (activeIndex - 1 + totalWindows) % totalWindows
        }
        postJSON(endpoint: "/cycle", body: ["direction": "prev"])
    }

    func sendDoubleEscape() {
        postJSON(endpoint: "/escape", body: [:])
    }

    func streamText(_ text: String, isFinal: Bool, previousLength: Int) {
        let body: [String: Any] = [
            "text": text,
            "is_final": isFinal,
            "previous_length": previousLength,
        ]
        postJSON(endpoint: "/stream-text", body: body)
    }

    func sendEnter() {
        postJSON(endpoint: "/type", body: ["text": "", "enter": true])
    }

    // MARK: - HTTP Helpers

    private func postJSON(endpoint: String, body: [String: Any]) {
        guard let url = URL(string: "\(serverURL)\(endpoint)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            print("[NetworkManager] JSON serialization error: \(error)")
            return
        }

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode != 200
                {
                    print(
                        "[NetworkManager] \(endpoint) returned \(httpResponse.statusCode)"
                    )
                }
            } catch {
                print("[NetworkManager] \(endpoint) failed: \(error)")
            }
        }
    }
}
