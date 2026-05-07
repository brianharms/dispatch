import Foundation
import Network

class NetworkManager: ObservableObject, @unchecked Sendable {
    static let shared = NetworkManager()

    // MARK: - Public State

    @Published var currentWindowName = "—"
    @Published var currentIndex = 0
    @Published var totalWindows = 0
    @Published var isConnected = false

    // MARK: - Configuration

    private var pollTimer: Timer?
    private var consecutivePollFailures = 0
    private let disconnectThreshold = 3

    /// Monotonic sequence number stamped on each cycle command.
    /// Poll responses with `last_cycle_seq` < this are stale and must not update activeIndex.
    private var cycleSequence: Int = 0

    /// Recovery: consecutive polls rejected by stale cycleSequence.
    /// After `rejectedPollRecovery` in a row with no successful cycle, re-sync to server.
    private var consecutiveRejectedPolls = 0
    private let rejectedPollRecovery = 3

    /// Number of consecutive polls where layout shrank.
    /// Only accept after `shrinkThreshold` consecutive confirmations.
    private var consecutiveShrinkPolls = 0
    private let shrinkThreshold = 2

    /// Number of consecutive polls where window IDs changed.
    private var consecutiveIDChangePolls = 0
    private let idChangeThreshold = 2
    private var pendingIDChangeWindowIDs: [String]?

    /// Known window IDs — used for change detection
    private var knownWindowIDs: [String] = []

    // Bonjour discovery
    private var browser: NWBrowser?
    private var discoveredServerURL: String?

    var macHostname: String {
        get { UserDefaults.standard.string(forKey: "macHostname") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "macHostname") }
    }

    private var serverURL: String {
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

    /// Longer timeout for /watch long-poll (server holds 30s)
    private lazy var watchSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 35
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
        discoveredServerURL = nil
        stopPolling()
        startPolling()
    }

    // MARK: - Polling

    func startPolling() {
        stopPolling()
        guard !serverURL.isEmpty else { return }
        fetchInitialStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
        startWatchLoop()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        stopWatchLoop()
    }

    /// Reset the poll countdown so the next poll fires 2s from now.
    /// Only resets the poll timer — does NOT touch the watch loop.
    private func resetPollTimer() {
        guard pollTimer != nil else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.pollStatus()
        }
    }

    // MARK: - Status Polling

    /// One-shot fetch on connect — always runs to populate state + set isConnected.
    private func fetchInitialStatus() {
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)/status") else { return }

        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil,
                      let data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return }
                self.parseStatusResponse(data, updateActiveIndex: true, source: "INIT")
                self.isConnected = true
            }
        }.resume()
    }

    private func pollStatus() {
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)/status") else { return }

        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }

                if error != nil {
                    self.consecutivePollFailures += 1
                    if self.consecutivePollFailures >= self.disconnectThreshold {
                        self.isConnected = false
                    }
                    return
                }

                guard let data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    self.consecutivePollFailures += 1
                    if self.consecutivePollFailures >= self.disconnectThreshold {
                        self.isConnected = false
                    }
                    return
                }

                self.consecutivePollFailures = 0
                self.isConnected = true
                self.parseStatusResponse(data, updateActiveIndex: true, source: "POLL")
            }
        }.resume()
    }

    private func parseStatusResponse(_ data: Data, updateActiveIndex: Bool, source: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Parse window list for ID tracking
        if let layout = json["layout"] as? [[String: Any]] {
            let incomingIDs = layout.compactMap { $0["id"] as? String }
            let incomingCount = layout.count

            if !knownWindowIDs.isEmpty {
                let idsChanged = Set(incomingIDs) != Set(knownWindowIDs)

                if idsChanged {
                    // IDs changed — debounce to filter transient AppleScript glitches
                    if incomingIDs == pendingIDChangeWindowIDs {
                        consecutiveIDChangePolls += 1
                    } else {
                        consecutiveIDChangePolls = 1
                        pendingIDChangeWindowIDs = incomingIDs
                    }
                    if consecutiveIDChangePolls >= idChangeThreshold {
                        consecutiveIDChangePolls = 0
                        pendingIDChangeWindowIDs = nil
                        consecutiveShrinkPolls = 0
                        knownWindowIDs = incomingIDs
                        totalWindows = incomingCount
                    }
                    // Otherwise hold existing state
                } else if incomingCount < knownWindowIDs.count {
                    // Fewer windows — debounce before accepting
                    consecutiveIDChangePolls = 0
                    pendingIDChangeWindowIDs = nil
                    consecutiveShrinkPolls += 1
                    if consecutiveShrinkPolls >= shrinkThreshold {
                        consecutiveShrinkPolls = 0
                        knownWindowIDs = incomingIDs
                        totalWindows = incomingCount
                    }
                } else {
                    // Same IDs or grew — accept immediately
                    consecutiveIDChangePolls = 0
                    pendingIDChangeWindowIDs = nil
                    consecutiveShrinkPolls = 0
                    knownWindowIDs = incomingIDs
                    totalWindows = incomingCount
                }
            } else {
                // First time — accept
                knownWindowIDs = incomingIDs
                totalWindows = incomingCount
            }
        } else if let total = json["total"] as? Int {
            totalWindows = total
        }

        // Active index update with sequence rejection
        // Always use server's current_index directly — watch doesn't need to
        // recompute from window IDs (that causes ordering mismatches).
        if updateActiveIndex {
            let serverSeq = json["last_cycle_seq"] as? Int ?? 0
            let serverIndex = json["current_index"] as? Int ?? json["current"] as? Int ?? currentIndex

            if serverSeq >= cycleSequence {
                currentIndex = serverIndex
                consecutiveRejectedPolls = 0
                resetPollTimer()
            } else {
                consecutiveRejectedPolls += 1
                if consecutiveRejectedPolls >= rejectedPollRecovery {
                    // Recovery: no cycle has succeeded in a while, re-sync to server
                    cycleSequence = serverSeq
                    currentIndex = serverIndex
                    consecutiveRejectedPolls = 0
                    resetPollTimer()
                }
            }
        }

        // Window name
        if let name = json["active_window"] as? String {
            currentWindowName = name
        }
    }

    // MARK: - Focus Watch (Long-Poll)

    private var watchTask: DispatchWorkItem?
    private var watchLoopActive = false

    func startWatchLoop() {
        stopWatchLoop()
        watchLoopActive = true
        doWatchPoll()
    }

    func stopWatchLoop() {
        watchLoopActive = false
        watchTask?.cancel()
        watchTask = nil
    }

    private func doWatchPoll() {
        guard watchLoopActive,
              !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)/watch") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 35

        watchSession.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self, self.watchLoopActive else { return }

                if let error {
                    // Connection error or timeout — brief delay then retry
                    let retry = DispatchWorkItem { [weak self] in
                        self?.doWatchPoll()
                    }
                    self.watchTask = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
                    return
                }

                guard let data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    // Retry immediately on non-200
                    self.doWatchPoll()
                    return
                }

                // Server responded — we're connected
                if !self.isConnected {
                    self.isConnected = true
                }

                // Parse watch response
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let changed = json["changed"] as? Bool, changed {

                    // Update window IDs if layout provided
                    if let layout = json["layout"] as? [[String: Any]] {
                        let ids = layout.compactMap { $0["id"] as? String }
                        if !ids.isEmpty {
                            self.knownWindowIDs = ids
                            self.totalWindows = ids.count
                        }
                    }

                    // Update focus — use server's index directly, respecting cycle guard
                    if let idx = json["current_index"] as? Int {
                        let serverSeq = json["last_cycle_seq"] as? Int ?? 0
                        if serverSeq >= self.cycleSequence {
                            self.currentIndex = idx
                        }
                    }
                    if let name = json["active_window"] as? String {
                        self.currentWindowName = name
                    }
                }

                // Immediately re-poll
                self.doWatchPoll()
            }
        }.resume()
    }

    // MARK: - Actions

    func cycle(direction: String) {
        cycleSequence += 1
        postJSONWithStatus(endpoint: "/cycle", body: ["direction": direction, "seq": cycleSequence])
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

    // MARK: - HTTP Helpers

    /// POST JSON and parse the response as a status update (used by /cycle).
    private func postJSONWithStatus(endpoint: String, body: [String: Any]) {
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)\(endpoint)") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        session.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil,
                      let data,
                      let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return }

                self.isConnected = true
                // Parse cycle response — accept server's activeIndex since we're not doing optimistic updates
                self.parseStatusResponse(data, updateActiveIndex: true, source: "CYCLE-RESP")
            }
        }.resume()
    }
}
