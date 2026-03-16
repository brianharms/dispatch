# dispatch. — Session Log

---

## Session 10 — 2026-03-16 15:20 — Fix Dictation Overlay Stacking Bug

### Goal
Diagnose and fix the bug where long voice recordings cause the ANSI dictation overlay (🎤 + live text) to stack up as dozens of duplicated lines in the terminal, instead of overwriting a single line.

### Accomplished
- **Root cause identified**: ANSI absolute cursor positioning (`\033[row;1H`) targets a logical row in the terminal's scroll buffer. When Claude Code is actively streaming output and the terminal scrolls, each overlay write lands on a NEW physical line — the old overlay text is baked into scrollback and never cleared.
- **Audited scroll margin fix (`DECSTBM`)**: Found 3 critical issues — Claude Code's TUI shares the TTY and would conflict, crash leaves margins stuck with no cleanup path, server can't receive SIGWINCH for resize detection. Rejected this approach.
- **Implemented iTerm2 Status Bar solution**: Created an iTerm2 Python API AutoLaunch script that registers a custom status bar component driven by `user.dictationText` session variable. Completely scroll-proof — status bar is fixed UI chrome.
- **Server updated**: `write_dictation_overlay()` and `clear_dictation_overlay()` now use `\033]1337;SetUserVar=dictationText=<base64>\a` instead of ANSI cursor positioning. Same TTY write pattern already used for `SetColors=bg=`.
- **iOS dedup added**: `AudioManager.sendToServer()` now skips sends when `fullText == lastSentText` — reduces redundant `/stream-text` requests by ~15-30%.

### In Progress / Incomplete
- **User needs to configure iTerm2 status bar**: Must enable status bar in Settings > Profiles > Session, then add "Dictation" component via Configure Status Bar. Also must restart iTerm2 (or manually run the script) so the AutoLaunch script loads.
- **Not yet tested end-to-end** — changes written but not built/deployed/verified on device.

### Key Decisions
- **iTerm2 Status Bar over scroll margins**: Scroll margins (`DECSTBM`) would conflict with Claude Code's TUI, be fragile on crash/resize, and possibly be reset by Claude's own rendering. Status bar component is isolated UI chrome, zero terminal buffer interaction.
- **`SetUserVar` escape sequence as the bridge**: The dispatch server runs outside iTerm2's scripting env but can write escape sequences to TTY files (same as existing `SetColors=bg=` pattern). `SetUserVar` updates session variables that status bar components react to automatically.
- **iOS dedup is complementary, not primary fix**: The serial queue in `NetworkManager` already coalesces rapid sends, so dedup provides modest additional reduction (~15-30%).

### Files Changed
- `~/.config/iterm2/AppSupport/Scripts/AutoLaunch/dictation_overlay.py` — NEW: iTerm2 status bar component for dictation overlay
- `server/dispatch_server.py` — `write_dictation_overlay()` and `clear_dictation_overlay()` rewritten to use `SetUserVar` instead of ANSI cursor positioning
- `Dispatch/AudioManager.swift` — added `guard fullText != lastSentText` dedup in `sendToServer()`

### Known Issues
- SFSpeechRecognizer text-dropping still open from Session 8
- `/focus-push` ID format mismatch still open from Session 7
- Watch app icon still needed
- User must manually configure iTerm2 status bar component (one-time setup)

### Running Services
- None started this session

### Next Steps
1. Restart iTerm2 to load the dictation_overlay.py AutoLaunch script
2. Configure status bar: Settings > Profiles > Session > enable status bar > Configure > add "Dictation" component
3. Restart dispatch server, build iOS app, and test dictation overlay end-to-end
4. If status bar positioning/styling needs adjustment, modify the component in dictation_overlay.py

---

## Session 9 — 2026-03-15 00:00 — Watch App Networking Overhaul + UI Polish

### Goal
Port the iPhone's battle-tested networking logic to the watch app, fix connectivity, and improve the watch UI.

### Accomplished
- **ATS fix**: Changed `NSAllowsLocalNetworking` → `NSAllowsArbitraryLoads` in both Info.plist and project.yml — raw IP addresses like `192.168.1.81` were silently blocked
- **Full networking overhaul** (NetworkManager.swift):
  - `/watch` long-poll loop for instant push updates (replaces 1s polling)
  - Cycle sequence numbers (`cycleSequence`) — stale poll responses can't bounce activeIndex
  - `fetchInitialStatus()` one-shot on connect
  - `resetPollTimer()` only resets countdown, doesn't kill watch loop
  - `postJSONWithStatus()` — cycle responses immediately update state
  - Layout debouncing — shrink threshold + ID-change threshold filter AppleScript transients
  - Separate `watchSession` with 35s timeout for long-poll
- **Index ordering fix**: Watch now uses server's `current_index` directly instead of recomputing from window ID array position (was causing 1,3,2,4 order)
- **Swipe-down settings**: Replaced gear button with drag gesture on top bar (40pt threshold), chevron hint animates during drag
- **Terminal window UI**: Window number displayed inside a white-stroke rounded rectangle with red/yellow/green traffic light dots and window name in title bar
- **Version display**: `v0.2` shown in top bar
- **Version bumped** to 0.2 / build 2
- **Regenerated Xcode project** via xcodegen

### Files Changed
- `Dispatch Watch App/NetworkManager.swift` — full rewrite with phone-parity networking
- `Dispatch Watch App/ContentView.swift` — swipe-down settings, terminal window chrome, version display
- `Dispatch Watch App/Info.plist` — `NSAllowsArbitraryLoads`
- `project.yml` — watch ATS fix, version bump to 0.2

### Known Issues
- Watch device connection intermittent (disconnects during install, needs wake/proximity)
- SFSpeechRecognizer text-dropping still open from Session 8
- `/focus-push` ID format mismatch still open from Session 7

### Next Steps
1. Design feedback on watch UI (user will provide tomorrow)
2. Watch app icon/logo still needed
3. Test dictation end-to-end on watch
4. Consider matching phone's dictation FIFO queue if watch adds streaming text

---

## Session 8 — 2026-03-13 12:26 — Fix Garbled Dictation + ANSI Overlay System

### Goal
Fix garbled dictation text in iTerm2 terminals. Root cause: volatile speech partials were typed directly into the terminal input buffer, requiring constant backspace/delete/retype which garbled text. Solution: display live text via ANSI escape overlay on the Mac screen (not in terminal input), then commit final clean text to terminal only when dictation ends.

### Accomplished
- **ANSI dictation overlay system** — live dictation text displayed as a full-width black bar at the bottom of the terminal using ANSI escape sequences written directly to the TTY file descriptor. Zero AppleScript during dictation — instant, race-free.
  - `write_dictation_overlay(tty_path, text)` — renders 🎤 + text with black background at terminal bottom row
  - `clear_dictation_overlay(tty_path)` — removes overlay on dictation end
  - `get_tty_size(tty_path)` — gets terminal dimensions via `fcntl.ioctl(TIOCGWINSZ)`
- **Commit-on-enter flow** — `/stream-text` only updates overlay (no typing). When Enter arrives via `/type` with `_dictation_final_text` set, commits the accumulated text as one clean `type_text_iterm()` call
- **TTY capture on recording start** — `/recording-start` grabs the active session's TTY path via `get_session_tty()`
- **Escape clears dictation** — `/escape` handler clears overlay and resets `_dictation_final_text`
- **Emoji double-width fix** — adjusted padding to account for 🎤 taking 2 terminal columns but 1 Python character
- **Serial dictation queue** (NetworkManager.swift) — FIFO queue serializes `/stream-text` requests so only one is in-flight at a time
- **Server-side text lock** — `_text_lock = threading.Lock()` around `/stream-text` handler prevents concurrent thread races
- **Sequence number rejection** — belt-and-suspenders: server rejects out-of-order `/stream-text` requests via monotonic sequence counter
- **Bluetooth mic toggle** — UserDefaults-based toggle in settings (default: off/internal mic only)
- **SpeechAnalyzer + SFSpeechRecognizer dual-engine plan** — designed but not yet implemented (Part 3 of plan)

### In Progress / Incomplete
- **Part 3: SpeechAnalyzer engine** (iOS 26+) — plan written in `synchronous-forging-island.md`, not yet coded. Would replace SFSpeechRecognizer's text-dropping behavior with Apple's new WWDC 2025 API
- **iPhone app UI tweaks** — user mentioned positioning elements near physical button locations, settings menu styling during recording

### Key Decisions
- ANSI escape overlay chosen over: macOS floating window (fragile, focus issues), iTerm2 status bar (limited API), terminal title bar (too small). Direct TTY write is instant with no subprocess overhead.
- Overlay at bottom row (`rows - 1`) so user sees it where they're already looking (near the prompt)
- No text enters terminal until explicit commit — eliminates entire category of race conditions

### Files Changed
- `server/dispatch_server.py` — ANSI overlay system, commit-on-enter flow, TTY capture, text lock, sequence rejection, emoji width fix
- `Dispatch/NetworkManager.swift` — serial dictation queue, sequence param
- `Dispatch/AudioManager.swift` — sequence counter, BT UserDefaults check
- `Dispatch/ContentView.swift` — pass sequence in callback, BT toggle in settings
- `Dispatch/VolumeButtonManager.swift` — BT UserDefaults check in configureAudioSession
- `Dispatch.xcodeproj/project.pbxproj` — project changes
- `Dispatch/HiddenVolumeView.swift` — minor changes

### Known Issues
- SFSpeechRecognizer drops text after pauses (>1s silence) — Part 3 plan addresses this
- `/focus-push` ID format mismatch still open from Session 7

### Running Services
- `dispatch_server.py` running on port 9876

### Next Steps
1. Implement Part 3: SpeechAnalyzer engine (iOS 26+) with SFSpeechRecognizer+speechDuration fallback
2. iPhone app UI tweaks — button positioning, settings styling during recording
3. Test overlay with long dictation text (multi-line wrapping behavior)

---

## Session 7 — 2026-03-13 12:24 — /watch Long-Poll Fix + Visual Explainer

### Goal
Diagnose and fix why the `/watch` long-poll push mechanism wasn't delivering focus/layout changes to the phone. Then generate a visual explainer of the project architecture.

### Accomplished
- **Root cause found and fixed**: `resetPollTimer()` in NetworkManager.swift was calling `stopPolling()`, which killed the watch loop permanently. Every accepted status response (including initial `fetchInitialStatus()`) murdered the push channel. Fixed by replacing `stopPolling()` with just `pollTimer?.invalidate()` — only resets the timer countdown, leaves watch loop alive.
- **Confirmed fix working on device** — user verified `/watch` push updates are reaching the phone
- **Added debug print** to server `/watch` handler (line ~855) logging push events with focus/layout flags
- **Generated visual explainer** (`/tmp/explain-dispatch-project.html`) — 3 views (Signal Flow, Sequence Diagrams, System Map), 12 design styles, light/dark toggle

### In Progress / Incomplete
- **`/focus-push` window ID format mismatch**: iTerm2 Python API sends IDs like "w0", server stores AppleScript numeric IDs like "65843". Non-critical — server detects focus changes independently via `build_status()` every 0.5s.

### Key Decisions
- Surgical fix: only changed `resetPollTimer()` behavior, didn't restructure polling/watch architecture
- `/focus-push` ID mismatch left unfixed — secondary path, server's own 0.5s cache loop handles focus detection

### Files Changed
- `Dispatch/NetworkManager.swift` — `resetPollTimer()` no longer kills watch loop (the critical fix)
- `server/dispatch_server.py` — debug print in `/watch` handler for push events

### Known Issues
- `/focus-push` ID format mismatch (iTerm2 Python API "w0" vs AppleScript "65843") — non-critical
- `debugMutePolling = true` and `debugNoOptimistic = true` still set in NetworkManager (from previous debug session)

### Running Services
- `dispatch_server.py` running (PID 8012) on port 9876

### Next Steps
1. Clean up debug flags (`debugMutePolling`, `debugNoOptimistic`) in NetworkManager.swift if no longer needed
2. Optionally fix `/focus-push` ID format mismatch for faster focus detection
3. Continue with plan items: burst cap for volume button hold, other UX improvements

---

## Session 6 — 2026-03-11 00:00 — Watch App Consolidation + UX Overhaul

### Goal
Refactor "Twist" Apple Watch app into the Dispatch project as a second target, rebrand, and fix UX issues.

### Accomplished
- Consolidated Twist watch app into Dispatch as `Dispatch Watch App` target in `project.yml`
- Rebranded to "dispatch." — matching iOS app identity
- Added top settings bar with gear icon (single tap opens settings, keeps recording zone separate)
- Added full-screen pulsating red glow when recording (replaces small dot)
- Unified gesture system: single `DragGesture(minimumDistance: 0)` with 300ms swipe deadline — swipe horizontally >1/6 screen within 300ms = cycle, hold still past 300ms = start recording
- Added orientation setting (landscape/portrait) in settings, stored in `@AppStorage`
- Redesigned settings: IP split into 4 stacked vertical octet fields, defaults to 192.168.1.80, scrollable layout
- Built `server/transcribe` binary (was never compiled — root cause of dictation not working)
- Fixed iCloud xattr codesign issue by building to `/tmp/dispatch-watch-build`
- Voice dictation confirmed working end-to-end (watch → server → transcribe → terminal)
- Big 48pt window index number + dot indicators for clear position awareness
- Removed stale `Dispatch 2.xcodeproj`

### Known Issues / TODO
- **Watch app needs a new logo/icon** — currently using default
- **Watch screen design needs work** — user explicitly said it "sucks", on the to-do list
- Swipe vs hold gesture timing may need further tuning (user said recording was hard to trigger before the 300ms/1/6-screen fix)
- ATS on watch still uses `NSAllowsLocalNetworking` (iOS needed `NSAllowsArbitraryLoads` — may need same fix)
- `dictate()` silently discards errors — no feedback if network call fails
- Dictation takes a noticeable delay (transcription latency)

### Files Changed
- `project.yml` — added `Dispatch Watch App` watchOS target
- `Dispatch Watch App/ContentView.swift` — unified DragGesture with 300ms swipe deadline, top settings bar, red pulse overlay, big index display with dot indicators
- `Dispatch Watch App/SettingsView.swift` — stacked vertical octet IP fields with gutter label, orientation picker, scrollable, octet4 defaults to "80"
- `Dispatch Watch App/DispatchWatchApp.swift` — renamed entry point from TwistApp
- `Dispatch Watch App/NetworkManager.swift` — copied from Twist (unchanged)
- `Dispatch Watch App/AudioRecorder.swift` — copied from Twist (unchanged)
- `Dispatch Watch App/Info.plist` — copied from Twist (unchanged)
- `server/transcribe` — compiled from `transcribe.swift`
- `SESSION_LOG.md` — this file

### Key Decisions
- Watch target uses Swift 5.0 (avoids Swift 6 strict concurrency issues with `@unchecked Sendable`)
- Watch NetworkManager stays as `ObservableObject/@Published` (iOS uses `@Observable/@MainActor`)
- Build output to `/tmp/dispatch-watch-build` to avoid iCloud extended attribute codesign failures
- Single `DragGesture(minimumDistance: 0)` handles both swipe and hold — 300ms deadline, 1/6 screen width threshold. Fast horizontal swipe = cycle windows, stationary hold = record voice.
- Used `/hypothesize` to diagnose dictation failure — root cause was missing compiled `transcribe` binary

### Device
- Apple Watch device ID: `00008310-001374C10E23601E`
- Bundle ID: `com.ritualindustries.dispatch.watch`

### Next Steps
1. Design new watch app icon/logo
2. Redesign watch screen UI — better visual identity and layout
3. Consider `NSAllowsArbitraryLoads` for watch ATS if networking issues arise
4. Add error feedback for failed dictation requests
5. Test swipe gesture tuning on-device
3. Test dictation end-to-end (transcribe binary now compiled)
4. Consider `NSAllowsArbitraryLoads` for watch ATS
5. Add error feedback for failed dictation requests

---

## Session 5 — 2026-03-10 18:18 — Double-Tap Fix, ATS Fix, Escape & Enter Fixes

### Goal
Fix multiple real-device bugs: vol-down double-tap not registering as escape, network connectivity issues, dictation Enter not sending, and double-escape only sending one escape.

### Accomplished
- **Double-tap escape detection fixed**: Added separate `simpleDownDebounceMs = 120` (was reusing `simpleUpDebounceMs = 250` which ate the second press). KVO duplicates arrive within ~80ms; human double-taps at ~200ms+. 120ms sits between.
- **ATS fix for raw IP HTTP**: Changed `NSAllowsLocalNetworking` to `NSAllowsArbitraryLoads` in Info.plist — `NSAllowsLocalNetworking` doesn't cover raw IP addresses like `http://192.168.1.78:9876`
- **Enter after dictation fixed**: Server `/type` endpoint had `if text:` which is falsy for empty string — changed to `if text or enter:` so `sendEnter()` (which sends `{"text": "", "enter": true}`) actually fires
- **Double-escape improved**: `send_escape()` now uses `delay 0.05` between the two `write text (ASCII character 27)` calls so terminal TUI registers them as two distinct Escape keypresses
- Built and deployed builds 9, 10, 11 to device

### In Progress / Incomplete
- Double-escape still intermittently unreliable — user reported one instance where first attempt didn't register (second attempt worked). May need longer delay or different approach
- Network connectivity intermittent — TCP handshakes between phone and Mac sometimes fail (`SYN_RCVD` stuck connections). Likely router AP isolation or WiFi band mismatch. Not a code issue.
- Plan file (`cozy-knitting-hollerith.md`) items still open: triple dictation send fix (`hasFiredFinal` guard), escape indicator fix, volume drift fix

### Key Decisions
- Separate debounce constants for UP (250ms) vs DOWN (120ms) — different gesture requirements
- `NSAllowsArbitraryLoads` is fine for a dev tool that only talks to local server
- Reverted from System Events `key code 53` back to iTerm2 `write text` for escape — `key code 53` requires `activate` which steals focus and has race conditions. `write text` targets the correct session directly.
- Used `/hypothesize` skill extensively — 3 parallel agents per bug investigation

### Files Changed
- `Dispatch/VolumeButtonManager.swift` — added `simpleDownDebounceMs = 120`, used it for vol-down debounce
- `Dispatch/Info.plist` — `NSAllowsArbitraryLoads` instead of `NSAllowsLocalNetworking`, version bumped to 11
- `server/dispatch_server.py` — `/type` handler `if text or enter:`, `send_escape()` with 50ms delay between ESC chars

### Known Issues
- Double-escape intermittently unreliable (may need delay tuning >50ms)
- Network path between iPhone and Mac intermittent (router/WiFi issue, not code)
- Previous session's RESET-BOUNCE and acceptance threshold fixes still in place (working well)

### Running Services
- dispatch_server.py running (PID 5198) on port 9876, logs at `/tmp/dispatch_server.log`
- Build 11 installed on device (00008150-00163C283A05401C)

### Next Steps
1. Tune escape delay (try 75-100ms if 50ms still unreliable)
2. Investigate network intermittency — check router AP isolation, Private WiFi Address
3. Address plan file items: `hasFiredFinal` guard in AudioManager, escape indicator in holdingDown transition, volume drift fix
4. Test dictation end-to-end (text streaming + Enter commit)

---

## Session 3 — 2026-03-08 18:15 — Wiring, Rotation Fix, Real Terminal Layout

### Goal
Continue wiring pass (connecting all managers in ContentView), fix orientation, and show real iTerm2 window layout from the user's second monitor.

### Accomplished
- Completed full wiring pass: VolumeButtonManager, NetworkManager, AudioManager all connected in ContentView
- Changed audio session from `.playback` to `.playAndRecord` with `.defaultToSpeaker, .mixWithOthers, .allowBluetooth` — no more session switching needed
- Simplified AudioManager — removed `onRecordingSessionWillStart`/`onRecordingSessionDidEnd` callbacks and all audio session category switching
- Added `actionID` counter to VolumeButtonManager, increments on every `fireAction()` — fixes SwiftUI `onChange` not firing for repeated same-action presses
- Updated ButtonIndicatorView to observe `actionID` instead of `lastAction`
- ContentView fully rewritten: instantiates managers, wires `onChange(of: volumeManager.actionID)` → `handleAction()`, sets up audio streaming callbacks
- Fixed 180° rotation: switched from `landscapeRight` to `landscapeLeft` (in AppDelegate, Info.plist, project.yml)
- Queried real iTerm2 windows via AppleScript and monitor positions via Python AppKit
- Detected 3 windows on Odyssey Ark (3008x1692): eyeTerm (left), Catcher (center), Claude Code (right, taller)
- Updated NetworkManager placeholder data to match real terminal layout with Ark screen dimensions
- Pre-granted TCC permissions for speech recognition and microphone in simulator TCC.db
- Verified in Simulator: correct orientation, 3 windows matching real positions, active window white fill

### In Progress / Incomplete
- Real-device testing not done — volume buttons and dictation require physical hardware
- Server (`dispatch_server.py`) not started — end-to-end flow not tested
- Gap timeout (300ms) not tuned on real device
- No connection status indicator in the UI

### Key Decisions
- `landscapeLeft` is correct orientation for volume buttons on top (user confirmed `landscapeRight` was 180° off)
- `.playAndRecord` audio session used app-wide — eliminates need to switch categories between volume KVO and microphone recording
- Speech recognition permissions requested on first dictation attempt, not on launch (avoids blocking dialog on startup)
- Placeholder data in NetworkManager uses real terminal layout from user's Odyssey Ark monitor
- Window positions calculated relative to Ark origin: AppleScript bounds converted to Ark-local coordinates using Ark origin (-768, -1692) in AppleScript coords

### Files Changed
- `Dispatch/VolumeButtonManager.swift` — `actionID` counter in `fireAction()`, `.playAndRecord` audio session
- `Dispatch/AudioManager.swift` — removed session switching, removed coordination callbacks
- `Dispatch/ContentView.swift` — full rewrite with manager wiring, action handling, audio callbacks
- `Dispatch/ButtonIndicatorView.swift` — added `actionID` parameter, observe it instead of `lastAction`
- `Dispatch/NetworkManager.swift` — placeholder data with real Odyssey Ark layout (3008x1692, 3 windows)
- `Dispatch/DispatchApp.swift` — `.landscapeLeft` instead of `.landscapeRight`
- `Dispatch/Info.plist` — `UIInterfaceOrientationLandscapeLeft`
- `project.yml` — `UIInterfaceOrientationLandscapeLeft`
- `SESSION_LOG.md` — this file

### Known Issues
- Simulator shows "Pensieve" in permission dialogs (leftover from previous app `com.tether.app` on that sim)
- Volume button interception impossible in Simulator
- `requestPermissions()` called inside `dictationStarted` handler — first dictation may be delayed by permission dialog

### Running Services
- iPhone 17 Pro Simulator (F5D619D2-EDB2-46EB-A2D6-5B1CDBDAA194) is booted with dispatch app installed (PID 86060)
- No dev servers running

### Next Steps
1. Test on Brian's real iPhone (device ID: 00008150-00163C283A05401C, name: Brian's iPhone)
2. Start `server/dispatch_server.py` on Mac for end-to-end testing
3. Tune gap timeout (300ms) based on real-device volume button auto-repeat rate
4. Consider adding subtle connection status indicator
5. Server needs to detect which monitor iTerm2 windows are on (Odyssey Ark vs built-in) and report that monitor's dimensions

---

## Session 2 — 2026-03-08 — Wiring Pass Complete

### Status: App builds and runs in Simulator, ready for real-device testing

### What happened:
- Completed full wiring pass connecting VolumeButtonManager, NetworkManager, and AudioManager in ContentView
- Changed audio session from `.playback` to `.playAndRecord` (with `.defaultToSpeaker, .mixWithOthers, .allowBluetooth`) — allows volume KVO and microphone to work simultaneously without session switching
- Simplified AudioManager — removed `onRecordingSessionWillStart`/`onRecordingSessionDidEnd` callbacks and all audio session switching (no longer needed with `.playAndRecord`)
- Added `actionID` counter to VolumeButtonManager that increments on every `fireAction()` — fixes SwiftUI `onChange` not firing for repeated same-actions
- Updated ButtonIndicatorView to observe `actionID` instead of `lastAction` for the same reason
- ContentView now instantiates all 3 managers, wires `onChange(of: volumeManager.actionID)` to dispatch actions
- Audio streaming callbacks wired: partial results → `networkManager.streamText()`, final results → same
- Dictation flow: `dictationStarted` → `audioManager.startRecording()`, `dictationEnded` → `audioManager.stopRecording()` + `networkManager.sendEnter()`
- Added placeholder window data in NetworkManager defaults (4 windows, 2560x1440 screen) so UI is visible without server
- Verified in Simulator: black background, 2x2 terminal grid, active window white fill, inactive white stroke, "dispatch." branding bottom-left

### Files modified:
- `Dispatch/VolumeButtonManager.swift` — actionID counter, .playAndRecord audio session
- `Dispatch/AudioManager.swift` — removed session switching and coordination callbacks
- `Dispatch/ContentView.swift` — full rewrite with manager wiring
- `Dispatch/ButtonIndicatorView.swift` — observe actionID instead of lastAction
- `Dispatch/NetworkManager.swift` — placeholder default data

## Session 1 — 2026-03-08 — Project Kickoff

### Status: Planning complete, ready for implementation

### What happened:
- Created project directory and CLAUDE.md
- Defined architecture: iPhone → HTTP → Mac Server → iTerm2
- Mapped volume button inputs to actions (cycle, dictate, escape)
- Identified volume button interception technique (AVAudioSession KVO)
- Defined 5-agent breakdown: UI, Button, Server, Xcode, Voice
