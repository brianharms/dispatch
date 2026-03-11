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

    // Debug logging (visible in app)
    private(set) var debugLogEntries: [String] = []
    private let maxLogEntries = 30

    private func log(_ msg: String) {
        NSLog("[NET] %@", msg)
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))
        debugLogEntries.append("[\(timestamp)] \(msg)")
        if debugLogEntries.count > maxLogEntries {
            debugLogEntries.removeFirst(debugLogEntries.count - maxLogEntries)
        }
    }

    // MARK: - Configuration

    #if targetEnvironment(simulator)
    private var serverURL: String = "http://localhost:9876"
    #else
    private var serverURL: String = "http://192.168.1.78:9876"
    #endif
    private var pollTimer: Timer?
    /// Number of consecutive poll failures. `isConnected` is only set to false
    /// after `disconnectThreshold` consecutive failures, preventing a single
    /// dropped poll from flashing terminals off-screen.
    private var consecutivePollFailures: Int = 0
    private let disconnectThreshold: Int = 3
    /// Number of consecutive polls where layout had fewer windows than current.
    /// Only accept a shrunk layout after this exceeds `shrinkThreshold`,
    /// preventing transient AppleScript hiccups from flashing windows off-screen.
    private var consecutiveShrinkPolls: Int = 0
    private let shrinkThreshold: Int = 2
    /// Number of consecutive polls where window IDs changed.
    /// Only accept new IDs after `idChangeThreshold` consecutive confirmations.
    private var consecutiveIDChangePolls: Int = 0
    private let idChangeThreshold: Int = 2
    private var pendingIDChangeLayout: [WindowLayout]?
    /// When set, polls skip activeIndex updates until the server confirms the expected window.
    /// Cleared when the poll returns a matching active_window_id, on error, or after a 5s timeout.
    private var expectedActiveWindowID: String?
    private var expectedActiveWindowTimer: DispatchWorkItem?

    /// Extract host:port from serverURL for display/editing
    var currentHost: String {
        guard let url = URL(string: serverURL) else { return "" }
        let host = url.host() ?? ""
        let port = url.port ?? 9876
        return port == 9876 ? host : "\(host):\(port)"
    }

    // MARK: - Manual Connection

    func connectManually(ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let host = trimmed.contains(":") ? trimmed : "\(trimmed):9876"
        serverURL = "http://\(host)"
        print("[Manual] Connecting to \(serverURL)")
        stopDiscovery()
        startPolling()
    }

    // MARK: - Bonjour Discovery

    private var browser: NWBrowser?

    func startDiscovery() {
        #if targetEnvironment(simulator)
        // Simulator uses localhost — skip Bonjour, start polling immediately
        startPolling()
        return
        #else
        // If we have a hardcoded server URL, skip Bonjour and start polling
        if !serverURL.isEmpty {
            startPolling()
            return
        }
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
                    consecutivePollFailures += 1
                    if consecutivePollFailures >= disconnectThreshold {
                        isConnected = false
                    }
                    return
                }

                consecutivePollFailures = 0

                if let expected = expectedActiveWindowID {
                    let pollID = peekActiveWindowID(data)
                    if pollID == expected {
                        log("POLL confirmed guard=\(expected)")
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
                consecutivePollFailures += 1
                if consecutivePollFailures >= disconnectThreshold {
                    isConnected = false
                }
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
                self?.log("GUARD TIMEOUT — reverting to server state")
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
                let knownIDs = Set(windowLayouts.map { $0.id })
                let incomingIDs = Set(layout.map { $0.id })
                let idsChanged = !knownIDs.isEmpty && incomingIDs != knownIDs

                if idsChanged {
                    // IDs changed — debounce to filter transient AppleScript glitches
                    // but allow real changes (new/closed windows) through after confirmation
                    if layout == pendingIDChangeLayout {
                        consecutiveIDChangePolls += 1
                    } else {
                        consecutiveIDChangePolls = 1
                        pendingIDChangeLayout = layout
                    }
                    if consecutiveIDChangePolls >= idChangeThreshold {
                        log("LAYOUT IDS confirmed after \(idChangeThreshold) polls")
                        consecutiveIDChangePolls = 0
                        pendingIDChangeLayout = nil
                        consecutiveShrinkPolls = 0
                        windowLayouts = layout
                        totalWindows = layout.count
                    } else {
                        let summary = layout.map { "\($0.id.prefix(8)):\(Int($0.width))x\(Int($0.height))" }.joined(separator: " ")
                        log("LAYOUT IDS holding \(consecutiveIDChangePolls)/\(idChangeThreshold): [\(summary)]")
                    }
                } else if layout.count < windowLayouts.count {
                    // Fewer windows — debounce before accepting
                    consecutiveIDChangePolls = 0
                    pendingIDChangeLayout = nil
                    consecutiveShrinkPolls += 1
                    if consecutiveShrinkPolls < shrinkThreshold {
                        log("LAYOUT SHRINK \(windowLayouts.count)→\(layout.count) poll \(consecutiveShrinkPolls)/\(shrinkThreshold) — holding")
                    } else {
                        log("LAYOUT SHRINK confirmed after \(shrinkThreshold) polls")
                        consecutiveShrinkPolls = 0
                        windowLayouts = layout
                        totalWindows = layout.count
                    }
                } else if layoutSignificantlyChanged(from: windowLayouts, to: layout) {
                    // Real layout change (>5px movement/resize) — accept immediately
                    consecutiveIDChangePolls = 0
                    pendingIDChangeLayout = nil
                    consecutiveShrinkPolls = 0
                    windowLayouts = layout
                    totalWindows = layout.count
                } else {
                    // Minor sub-pixel jitter — keep existing layout, just update count
                    consecutiveIDChangePolls = 0
                    pendingIDChangeLayout = nil
                    consecutiveShrinkPolls = 0
                    totalWindows = layout.count
                }

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

    /// Returns true if layout changed by more than a trivial amount (>5px in any dimension).
    /// Filters out sub-pixel jitter from AppleScript during window transitions.
    private func layoutSignificantlyChanged(from old: [WindowLayout], to new: [WindowLayout]) -> Bool {
        guard old.count == new.count else { return true }
        let threshold: CGFloat = 5
        for (o, n) in zip(old, new) {
            if o.id != n.id { return true }
            if abs(o.x - n.x) > threshold || abs(o.y - n.y) > threshold { return true }
            if abs(o.width - n.width) > threshold || abs(o.height - n.height) > threshold { return true }
        }
        return false
    }

    // MARK: - Actions

    func cycleNext() {
        if !windowLayouts.isEmpty {
            let newIndex = (activeIndex + 1) % windowLayouts.count
            activeIndex = newIndex
            setExpectedGuard(windowLayouts[newIndex].id)
            log("cycleNext → [\(newIndex)] guard=\(windowLayouts[newIndex].id)")
        }
        postJSONWithStatus(endpoint: "/cycle", body: ["direction": "next"])
    }

    func cyclePrevious() {
        if !windowLayouts.isEmpty {
            let newIndex = (activeIndex - 1 + windowLayouts.count) % windowLayouts.count
            activeIndex = newIndex
            setExpectedGuard(windowLayouts[newIndex].id)
            log("cyclePrev → [\(newIndex)] guard=\(windowLayouts[newIndex].id)")
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
                    let bodyStr = String(data: data, encoding: .utf8) ?? "?"
                    log("\(endpoint) OK: \(bodyStr.prefix(120))")
                    parseStatusResponse(data, updateActiveIndex: false)
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    log("\(endpoint) HTTP \(code)")
                    clearExpectedGuard()
                }
            } catch {
                log("\(endpoint) FAILED: \(error.localizedDescription)")
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
