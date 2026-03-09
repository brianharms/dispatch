# dispatch. — Session Log

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
