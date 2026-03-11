import Foundation
import Network

class NetworkManager: ObservableObject, @unchecked Sendable {
    static let shared = NetworkManager()

    @Published var currentWindowName = "—"
    @Published var currentIndex = 0
    @Published var totalWindows = 0
    @Published var isConnected = false

    private var pollTimer: Timer?
    private var isFetching = false

    // Debouncing
    private var consecutivePollFailures = 0
    private let disconnectThreshold = 3

    // Expected window guard — prevents poll from reverting optimistic UI
    private var expectedWindowName: String?
    private var expectedGuardTimer: DispatchWorkItem?

    // Bonjour discovery
    private var browser: NWBrowser?
    private var discoveredServerURL: String?

    var macHostname: String {
        get { UserDefaults.standard.string(forKey: "macHostname") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "macHostname") }
    }

    private var serverURL: String {
        // Bonjour-discovered URL takes priority
        if let discovered = discoveredServerURL { return discovered }
        let host = macHostname
        guard !host.isEmpty else { return "" }
        if host.contains(".") && host.first?.isNumber == true {
            return "http://\(host):9876"
        }
        return "http://\(host).local:9876"
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    // MARK: - Bonjour Discovery

    func startDiscovery() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_dispatch._tcp", domain: nil), using: params)

        b.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                if case .service = result.endpoint {
                    self?.resolveService(result)
                    return
                }
            }
        }

        b.start(queue: .main)
        self.browser = b
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    private func resolveService(_ result: NWBrowser.Result) {
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self else { return }
                if case .ready = state,
                   let path = connection.currentPath,
                   let endpoint = path.remoteEndpoint,
                   case .hostPort(let host, let port) = endpoint {
                    let hostStr: String
                    switch host {
                    case .ipv4(let addr): hostStr = "\(addr)"
                    case .ipv6(let addr): hostStr = "\(addr)"
                    case .name(let name, _): hostStr = name
                    @unknown default: hostStr = "\(host)"
                    }
                    self.discoveredServerURL = "http://\(hostStr):\(port)"
                    connection.cancel()
                    // Auto-start polling once discovered
                    if self.pollTimer == nil {
                        self.startPolling()
                    }
                }
            }
        }
        connection.start(queue: .main)
    }

    // MARK: - Manual Connection

    func connectManually(ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        macHostname = trimmed
        discoveredServerURL = nil // clear Bonjour, use manual
        stopPolling()
        startPolling()
    }

    // MARK: - Polling

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }
        fetchStatus()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func fetchStatus() {
        guard !isFetching else { return }
        let url = serverURL
        guard !url.isEmpty, let statusURL = URL(string: "\(url)/status") else { return }
        isFetching = true

        session.dataTask(with: statusURL) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false

                if error != nil {
                    self.consecutivePollFailures += 1
                    if self.consecutivePollFailures >= self.disconnectThreshold {
                        self.isConnected = false
                    }
                    return
                }

                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.consecutivePollFailures += 1
                    if self.consecutivePollFailures >= self.disconnectThreshold {
                        self.isConnected = false
                    }
                    return
                }

                self.consecutivePollFailures = 0
                self.isConnected = true
                self.totalWindows = json["total"] as? Int ?? 0

                // Parse index — dispatch uses "current_index", twist uses "current"
                let serverIndex = json["current_index"] as? Int ?? json["current"] as? Int ?? 0
                // Parse window name — dispatch uses "active_window", twist uses "windows" array
                let serverName: String
                if let name = json["active_window"] as? String {
                    serverName = name
                } else if let windows = json["windows"] as? [String], serverIndex < windows.count {
                    serverName = windows[serverIndex]
                } else {
                    serverName = "No Windows"
                }

                // Guard: don't overwrite optimistic index if we're waiting for confirmation
                if let expected = self.expectedWindowName {
                    if serverName == expected {
                        self.clearExpectedGuard()
                        self.currentIndex = serverIndex
                        self.currentWindowName = serverName
                    }
                    // Otherwise hold the optimistic state
                } else {
                    self.currentIndex = serverIndex
                    self.currentWindowName = serverName
                }
            }
        }.resume()
    }

    // MARK: - Expected Window Guard

    private func setExpectedGuard(_ windowName: String) {
        expectedGuardTimer?.cancel()
        expectedWindowName = windowName

        let timeout = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                self?.clearExpectedGuard()
            }
        }
        expectedGuardTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func clearExpectedGuard() {
        expectedGuardTimer?.cancel()
        expectedGuardTimer = nil
        expectedWindowName = nil
    }

    // MARK: - Actions

    func cycle(direction: String) {
        // Optimistic UI — advance index immediately
        if totalWindows > 0 {
            if direction == "next" {
                currentIndex = (currentIndex + 1) % totalWindows
            } else {
                currentIndex = (currentIndex - 1 + totalWindows) % totalWindows
            }
            currentWindowName = "Window \(currentIndex + 1)"
            setExpectedGuard(currentWindowName)
        }

        let url = serverURL
        guard !url.isEmpty, let cycleURL = URL(string: "\(url)/cycle") else { return }
        var request = URLRequest(url: cycleURL)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["direction": direction])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.clearExpectedGuard()
                    return
                }
                self.isConnected = true
                if let total = json["total"] as? Int { self.totalWindows = total }
                let newIndex = json["current_index"] as? Int ?? json["current"] as? Int ?? self.currentIndex
                let newName = json["active_window"] as? String ?? json["window"] as? String ?? "Window \(newIndex + 1)"
                self.currentIndex = newIndex
                self.currentWindowName = newName
                self.clearExpectedGuard()
            }
        }.resume()
    }

    func dictate(audioData: Data) {
        let url = serverURL
        guard !url.isEmpty, let dictateURL = URL(string: "\(url)/dictate") else { return }
        var request = URLRequest(url: dictateURL)
        request.httpMethod = "POST"
        request.httpBody = audioData
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    func type(text: String) {
        let url = serverURL
        guard !url.isEmpty, let typeURL = URL(string: "\(url)/type") else { return }
        var request = URLRequest(url: typeURL)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text, "enter": true])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        session.dataTask(with: request) { _, _, _ in }.resume()
    }
}
