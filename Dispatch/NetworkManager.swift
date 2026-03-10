import Foundation
import Network
import Observation

@Observable
@MainActor
final class NetworkManager {

    // MARK: - Public State

    var isConnected: Bool = false
    var screenSize: CGSize = CGSize(width: 3008, height: 1692)
    var windowLayouts: [WindowLayout] = []
    var activeIndex: Int = 0
    var totalWindows: Int = 0
    var activeWindowName: String = ""

    // MARK: - Configuration

    #if targetEnvironment(simulator)
    private var serverURL: String = "http://localhost:9876"
    #else
    private var serverURL: String = ""
    #endif
    private var pollTimer: Timer?
    /// When set, polls skip activeIndex updates until the server confirms the expected window.
    /// Cleared when the poll returns a matching active_window_id, on error, or after a 5s timeout.
    private var expectedActiveWindowID: String?
    private var expectedActiveWindowTimer: DispatchWorkItem?

    // MARK: - Bonjour Discovery

    private var browser: NWBrowser?

    func startDiscovery() {
        #if targetEnvironment(simulator)
        // Simulator uses localhost — skip Bonjour, start polling immediately
        startPolling()
        return
        #else
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_dispatch._tcp", domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    print("[Bonjour] Browsing for _dispatch._tcp...")
                case .failed(let error):
                    print("[Bonjour] Browse failed: \(error)")
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                for result in results {
                    if case .service(let name, let type, let domain, _) = result.endpoint {
                        print("[Bonjour] Found: \(name) (\(type).\(domain))")
                        self.resolveService(result)
                        return
                    }
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser
        #endif
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    private func resolveService(_ result: NWBrowser.Result) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if let path = connection.currentPath,
                       let endpoint = path.remoteEndpoint,
                       case .hostPort(let host, let port) = endpoint {
                        let hostStr: String
                        switch host {
                        case .ipv4(let addr):
                            hostStr = "\(addr)"
                        case .ipv6(let addr):
                            hostStr = "\(addr)"
                        case .name(let name, _):
                            hostStr = name
                        @unknown default:
                            hostStr = "\(host)"
                        }
                        self.serverURL = "http://\(hostStr):\(port)"
                        print("[Bonjour] Resolved server at \(self.serverURL)")
                        connection.cancel()
                        self.startPolling()
                    }
                case .failed(let error):
                    print("[Bonjour] Resolve failed: \(error)")
                    connection.cancel()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        guard !serverURL.isEmpty else { return }
        pollStatus()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 0.5,
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
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)/status") else { return }

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    isConnected = false
                    return
                }

                if let expected = expectedActiveWindowID {
                    let pollID = peekActiveWindowID(data)
                    if pollID == expected {
                        clearExpectedGuard()
                        parseStatusResponse(data, updateActiveIndex: true)
                    } else {
                        parseStatusResponse(data, updateActiveIndex: false)
                    }
                } else {
                    parseStatusResponse(data, updateActiveIndex: true)
                }
                isConnected = true
            } catch {
                isConnected = false
            }
        }
    }

    private func peekActiveWindowID(_ data: Data) -> String? {
        struct Peek: Decodable { let active_window_id: String? }
        return try? JSONDecoder().decode(Peek.self, from: data).active_window_id
    }

    private func setExpectedGuard(_ windowID: String) {
        expectedActiveWindowTimer?.cancel()
        expectedActiveWindowID = windowID

        let timeout = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.clearExpectedGuard()
            }
        }
        expectedActiveWindowTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func clearExpectedGuard() {
        expectedActiveWindowTimer?.cancel()
        expectedActiveWindowTimer = nil
        expectedActiveWindowID = nil
    }

    private func parseStatusResponse(_ data: Data, updateActiveIndex: Bool = true) {
        struct StatusResponse: Decodable {
            let screen: ScreenSize?
            let layout: [WindowLayout]?
            let active_window_id: String?
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
                totalWindows = layout.count

                if updateActiveIndex,
                   let activeID = status.active_window_id,
                   let matchedIndex = layout.firstIndex(where: { $0.id == activeID }) {
                    activeIndex = matchedIndex
                }
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
        if !windowLayouts.isEmpty {
            let newIndex = (activeIndex + 1) % windowLayouts.count
            activeIndex = newIndex
            setExpectedGuard(windowLayouts[newIndex].id)
        }
        postJSONWithStatus(endpoint: "/cycle", body: ["direction": "next"])
    }

    func cyclePrevious() {
        if !windowLayouts.isEmpty {
            let newIndex = (activeIndex - 1 + windowLayouts.count) % windowLayouts.count
            activeIndex = newIndex
            setExpectedGuard(windowLayouts[newIndex].id)
        }
        postJSONWithStatus(endpoint: "/cycle", body: ["direction": "prev"])
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

    private func postJSONWithStatus(endpoint: String, body: [String: Any]) {
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)\(endpoint)") else { return }

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
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode == 200
                {
                    parseStatusResponse(data, updateActiveIndex: false)
                } else {
                    print("[NetworkManager] \(endpoint) returned non-200")
                    clearExpectedGuard()
                }
            } catch {
                print("[NetworkManager] \(endpoint) failed: \(error)")
                clearExpectedGuard()
            }
        }
    }

    private func postJSON(endpoint: String, body: [String: Any]) {
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)\(endpoint)") else { return }

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
