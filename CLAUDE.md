# dispatch.

> A walkie-talkie for vibecoding with Claude.
> Part of **vibeKit** by ritual.industries.

## What This Is

An iPhone app that lets you control multiple terminal windows using only the volume buttons and your voice. You kick your feet up, hold your phone, and project-manage multiple Claude Code sessions with two buttons and dictation.

## Architecture

```
iPhone (SwiftUI)  ──HTTP/WS──►  Mac Server (Python)  ──AppleScript──►  iTerm2
     │                               │
     ├─ Volume button input          ├─ Window management
     ├─ Voice dictation              ├─ Keystroke injection
     └─ Minimal status UI            └─ Transcription (Speech.framework)
```

### Input Matrix

| Input              | Action                    |
|--------------------|---------------------------|
| Vol Up single      | Cycle to next terminal    |
| Vol Down single    | Cycle to previous terminal|
| Vol Up long press  | Start/stop dictation      |
| Vol Down long press| Send double-escape        |
| Both simultaneous  | TBD                       |
| Both long press    | TBD                       |

### Volume Button Interception (iOS)

iOS doesn't expose volume buttons directly. The technique:
1. Hide system volume HUD with a zero-frame `MPVolumeView`
2. Observe `AVAudioSession.sharedInstance().outputVolume` via KVO
3. Detect direction (up/down) from volume delta
4. Reset volume to 0.5 after each press (preserves both directions)
5. Long press = rapid repeated volume changes within a window
6. Dual press = up+down detected within ~100ms

### Server

Python HTTP server (like twist_server.py on port 9876). Manages:
- Window list snapshot (iTerm2 session IDs + names)
- Active window index
- Cycling (next/prev)
- Keystroke injection (dictated text, escape sequences)
- Visual highlight of active window (background color)

### Transcription

Reuse twist's approach: `SFSpeechRecognizer` via compiled Swift binary, or explore on-device transcription on iPhone (which has more power than Apple Watch).

## Design Language

- **Monochrome** — black, white, grays only
- **Low-poly** — geometric wireframe shapes as visual identity
- **Minimal UI** — the screen shows status, not controls
- **Typography** — bold lowercase with period (dispatch.)
- Refer to vibeKit brand image for aesthetic direction

## Build Rules

- Always use `timeout 300 xcodebuild ...` — never bare builds
- Use `-derivedDataPath ./build-debug` for consistent output paths
- Incremental builds only (no clean unless explicitly asked)
- Increment version on every build

## Agent Responsibilities

Five agents work on this project in parallel via worktrees:

1. **UI Agent** — SwiftUI views, layout, animations, low-poly visuals
2. **Button Agent** — Volume button interception, gesture recognition, input state machine
3. **Server Agent** — Python server, AppleScript integration, iTerm2 control
4. **Xcode Agent** — Project setup, build, deploy to device, troubleshoot
5. **Voice Agent** — Audio capture, speech recognition, dictation flow

## File Structure

```
dispatch/
├── Dispatch/                    # iOS app (SwiftUI)
│   ├── DispatchApp.swift       # Entry point
│   ├── ContentView.swift       # Main UI
│   ├── VolumeButtonManager.swift # Volume button interception
│   ├── NetworkManager.swift    # Server communication
│   ├── AudioManager.swift      # Recording + transcription
│   ├── Info.plist
│   └── Assets.xcassets/
├── server/                      # Mac-side server
│   ├── dispatch_server.py      # HTTP server + AppleScript
│   └── transcribe.swift        # Speech-to-text (from twist)
├── Dispatch.xcodeproj/
├── CLAUDE.md                    # This file
└── SESSION_LOG.md
```

## Reference Project

twist (Apple Watch app) at `~/Desktop/Claude Projects/twist/` — same architecture, different input method. Borrow patterns from:
- `twist_server.py` — server structure, AppleScript, window management
- `NetworkManager.swift` — HTTP client, polling, optimistic UI
- `transcribe.swift` — speech recognition binary
