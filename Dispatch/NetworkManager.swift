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

    /// When true, polling is paused — no data comes back from the server.
    /// Commands (cycle, dictation, etc.) still send outbound.
    var debugMutePolling: Bool = true

    /// When true, cycle commands do NOT optimistically update activeIndex.
    /// The phone waits for the server to confirm the change via poll/response.
    var debugNoOptimistic: Bool = true

    /// When true, logs every activeIndex mutation with source, seq, and timestamps.
    var debugBounceLog: Bool = false

    // Debug logging (visible in app)
    private(set) var debugLogEntries: [String] = []
    private let maxLogEntries = 30

    // Bounce-specific debug log (visible in app when debugBounceLog is on)
    private(set) var bounceLogEntries: [String] = []
    private let maxBounceLogEntries = 50

    private func log(_ msg: String) {
        NSLog("[NET] %@", msg)
        let timestamp = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))
        debugLogEntries.append("[\(timestamp)] \(msg)")
        if debugLogEntries.count > maxLogEntries {
            debugLogEntries.removeFirst(debugLogEntries.count - maxLogEntries)
        }
    }

    private func bounceLog(_ source: String, _ msg: String) {
        guard debugBounceLog else { return }
        let t = String(format: "%.3f", CFAbsoluteTimeGetCurrent().truncatingRemainder(dividingBy: 1000))
        let entry = "[\(t)] [\(source)] \(msg)"
        NSLog("[BOUNCE] %@", entry)
        bounceLogEntries.append(entry)
        if bounceLogEntries.count > maxBounceLogEntries {
            bounceLogEntries.removeFirst(bounceLogEntries.count - maxBounceLogEntries)
        }
    }

    func clearBounceLog() {
        bounceLogEntries.removeAll()
    }

    // MARK: - Configuration

    #if targetEnvironment(simulator)
    private var serverURL: String = "http://localhost:9876"
    #else
    // Default empty — set by user in Settings on first launch.
    // The picker that appears asks for the Mac server's IP (LAN or Tailscale).
    private var serverURL: String = ""
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

    /// Monotonic sequence number stamped on each cycle command.
    /// Poll responses with `last_cycle_seq` < this are stale and must not update activeIndex.
    private var cycleSequence: Int = 0

    // MARK: - Dictation FIFO Queue
    // Serializes /stream-text requests so only one is in-flight at a time.
    // Other endpoints (cycle, escape, etc.) remain fire-and-forget.
    private var dictationQueue: [() async -> Void] = []
    private var dictationInFlight: Bool = false

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
        fetchInitialStatus()
        pollStatus()
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollStatus()
            }
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
        pollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pollStatus()
            }
        }
    }

    // MARK: - Status Polling

    /// One-shot fetch on connect — bypasses debugMutePolling to populate layout + set isConnected.
    private func fetchInitialStatus() {
        guard !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)/status") else { return }
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else { return }
                parseStatusResponse(data, updateActiveIndex: true, source: "INIT")
                isConnected = true
            } catch {}
        }
    }

    private func pollStatus() {
        guard !debugMutePolling,
              !serverURL.isEmpty,
              let url = URL(string: "\(serverURL)/status") else { return }

        bounceLog("POLL", "firing (activeIndex=\(activeIndex) seq=\(cycleSequence))")

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
                parseStatusResponse(data, updateActiveIndex: true, source: "POLL")
                isConnected = true
            } catch {
                consecutivePollFailures += 1
                if consecutivePollFailures >= disconnectThreshold {
                    isConnected = false
                }
            }
        }
    }

    private func parseStatusResponse(_ data: Data, updateActiveIndex: Bool = true, source: String = "?") {
        struct StatusResponse: Decodable {
            let screen: ScreenSize?
            let layout: [WindowLayout]?
            let active_window_id: String?
            let total: Int?
            let active_window: String?
            let last_cycle_seq: Int?

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

            }

            // Active index update — outside the layout block so /cycle responses
            // (which have no layout) can still update activeIndex.
            if updateActiveIndex,
               let activeID = status.active_window_id,
               let matchedIndex = windowLayouts.firstIndex(where: { $0.id == activeID }) {
                let serverSeq = status.last_cycle_seq ?? 0
                if debugNoOptimistic {
                    // No optimistic index to protect — accept server's word
                    let oldIndex = activeIndex
                    activeIndex = matchedIndex
                    resetPollTimer()
                    bounceLog(source, "ACCEPT idx \(oldIndex)→\(matchedIndex) srvSeq=\(serverSeq) phoneSeq=\(cycleSequence) id=\(activeID.prefix(8))")
                } else {
                    // Server only confirms seq after AppleScript activation completes.
                    // Polls before that carry a stale seq and get rejected here,
                    // protecting the phone's optimistic activeIndex from bounce-back.
                    if serverSeq >= cycleSequence {
                        let oldIndex = activeIndex
                        activeIndex = matchedIndex
                        resetPollTimer()
                        bounceLog(source, "ACCEPT idx \(oldIndex)→\(matchedIndex) srvSeq=\(serverSeq) phoneSeq=\(cycleSequence)")
                    } else {
                        bounceLog(source, "REJECT idx=\(activeIndex) matched=\(matchedIndex) srvSeq=\(serverSeq) < phoneSeq=\(cycleSequence)")
                    }
                }
            } else if updateActiveIndex {
                let activeID = status.active_window_id ?? "nil"
                bounceLog(source, "NO-MATCH id=\(activeID.prefix(8)) layouts=\(windowLayouts.count)")
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

    // MARK: - Focus Watch (Long-Poll)

    private var watchTask: Task<Void, Never>?

    /// Start a persistent long-poll loop that listens for Mac-side focus changes.
    func startWatchLoop() {
        stopWatchLoop()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.serverURL.isEmpty,
                      let url = URL(string: "\(self.serverURL)/watch") else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }

                do {
                    // 35s timeout — slightly longer than server's 30s hold
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 35

                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else { continue }

                    // Server responded — we're connected
                    if !self.isConnected {
                        self.isConnected = true
                    }

                    struct WatchResponse: Decodable {
                        let changed: Bool
                        let current_index: Int?
                        let active_window_id: String?
                        let active_window: String?
                        let layout: [WindowLayout]?
                        let screen: ScreenSize?
                    }
                    struct ScreenSize: Decodable {
                        let width: CGFloat
                        let height: CGFloat
                    }

                    let watch = try JSONDecoder().decode(WatchResponse.self, from: data)
                    if watch.changed {
                        // Update layout if provided (move/resize)
                        if let layout = watch.layout, !layout.isEmpty {
                            self.windowLayouts = layout
                        }
                        if let screen = watch.screen {
                            self.screenSize = CGSize(width: screen.width, height: screen.height)
                        }
                        // Update focus
                        if let activeID = watch.active_window_id,
                           let matchedIndex = self.windowLayouts.firstIndex(where: { $0.id == activeID }) {
                            self.activeIndex = matchedIndex
                            if let name = watch.active_window {
                                self.activeWindowName = name
                            }
                        }
                        self.bounceLog("WATCH", "state push idx→\(self.activeIndex)")
                    }
                } catch {
                    // Connection error or timeout — brief delay then retry
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    func stopWatchLoop() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: - Actions

    func cycleNext() {
        cycleSequence += 1
        if !debugNoOptimistic && !windowLayouts.isEmpty {
            let oldIndex = activeIndex
            let newIndex = (activeIndex + 1) % windowLayouts.count
            activeIndex = newIndex
            log("cycleNext → [\(newIndex)] seq=\(cycleSequence)")
            bounceLog("OPTIMISTIC", "cycleNext \(oldIndex)→\(newIndex) seq=\(cycleSequence)")
        } else {
            log("cycleNext (no-opt) seq=\(cycleSequence)")
            bounceLog("CMD", "cycleNext sent seq=\(cycleSequence) activeIndex=\(activeIndex)")
        }
        postJSONWithStatus(endpoint: "/cycle", body: ["direction": "next", "seq": cycleSequence])
    }

    func cyclePrevious() {
        cycleSequence += 1
        if !debugNoOptimistic && !windowLayouts.isEmpty {
            let oldIndex = activeIndex
            let newIndex = (activeIndex - 1 + windowLayouts.count) % windowLayouts.count
            activeIndex = newIndex
            log("cyclePrev → [\(newIndex)] seq=\(cycleSequence)")
            bounceLog("OPTIMISTIC", "cyclePrev \(oldIndex)→\(newIndex) seq=\(cycleSequence)")
        } else {
            log("cyclePrev (no-opt) seq=\(cycleSequence)")
            bounceLog("CMD", "cyclePrev sent seq=\(cycleSequence) activeIndex=\(activeIndex)")
        }
        postJSONWithStatus(endpoint: "/cycle", body: ["direction": "prev", "seq": cycleSequence])
    }

    func sendDoubleEscape() {
        postJSON(endpoint: "/escape", body: [:])
    }

    func streamText(_ text: String, isFinal: Bool, previousLength: Int, sequence: Int) {
        let body: [String: Any] = [
            "text": text,
            "is_final": isFinal,
            "previous_length": previousLength,
            "seq": sequence,
        ]
        // Drop any pending (not in-flight) items — only latest text matters
        dictationQueue.removeAll()
        // Enqueue and drain — only one /stream-text in-flight at a time
        dictationQueue.append { [weak self] in
            guard let self,
                  !self.serverURL.isEmpty,
                  let url = URL(string: "\(self.serverURL)/stream-text") else { return }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch { return }

            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   httpResponse.statusCode != 200 {
                    print("[NetworkManager] /stream-text returned \(httpResponse.statusCode)")
                }
            } catch {
                print("[NetworkManager] /stream-text failed: \(error)")
            }
        }
        drainDictationQueue()
    }

    private func drainDictationQueue() {
        guard !dictationInFlight, !dictationQueue.isEmpty else { return }
        dictationInFlight = true
        let work = dictationQueue.removeFirst()
        Task {
            await work()
            dictationInFlight = false
            drainDictationQueue()
        }
    }

    func sendEnter() {
        postJSON(endpoint: "/type", body: ["text": "", "enter": true])
    }

    /// Send Enter AFTER all pending dictation requests complete, then notify recording stop.
    /// Prevents the race where Enter arrives at the server before the last stream-text.
    func sendEnterAfterDictation() {
        // Enqueue Enter
        dictationQueue.append { [weak self] in
            guard let self,
                  !self.serverURL.isEmpty,
                  let url = URL(string: "\(self.serverURL)/type") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = ["text": "", "enter": true]
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch { return }
            do {
                let (_, _) = try await URLSession.shared.data(for: request)
            } catch {
                print("[NetworkManager] /type (enter after dictation) failed: \(error)")
            }
        }
        // Enqueue recording-stop after Enter
        dictationQueue.append { [weak self] in
            guard let self,
                  !self.serverURL.isEmpty,
                  let url = URL(string: "\(self.serverURL)/recording-stop") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [:] as [String: Any])
            do {
                let (_, _) = try await URLSession.shared.data(for: request)
            } catch {
                print("[NetworkManager] /recording-stop (after dictation) failed: \(error)")
            }
        }
        drainDictationQueue()
    }

    func notifyRecordingStart() {
        postJSON(endpoint: "/recording-start", body: [:])
    }

    func sendDebugLog(_ message: String) {
        postJSON(endpoint: "/debug-log", body: ["message": message])
    }

    func notifyRecordingStop() {
        // Clear stale dictation queue items from the ended session
        dictationQueue.removeAll()
        postJSON(endpoint: "/recording-stop", body: [:])
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
                    bounceLog("CYCLE-RESP", "received \(bodyStr.prefix(200))")
                    // In optimistic mode, don't update activeIndex from cycle response —
                    // the optimistic update already set it. In no-optimistic mode,
                    // accept the server's activeIndex from the cycle response.
                    parseStatusResponse(data, updateActiveIndex: debugNoOptimistic, source: "CYCLE-RESP")
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    log("\(endpoint) HTTP \(code)")
                }
            } catch {
                log("\(endpoint) FAILED: \(error.localizedDescription)")
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
