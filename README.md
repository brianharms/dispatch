# dispatch.

> ## ⚠️ Before you start — what YOU (the human) must do
>
> An AI agent can run every command in this README, but a few things require **you**, because macOS and Apple security won't let any script do them. Read this first.
>
> **You need installed first:**
> - **Xcode** (to build the iPhone app)
> - Python 3 (server, stdlib-only — no install)
>
> **Steps only a human can do (your AI agent will pause and ask for these):**
> - **Server side:** just run `server/dispatch_server.py` — and approve the **macOS Automation prompt** for iTerm2 on first run.
> - **iPhone app:** open the project in Xcode, set **your own Apple Team ID** (Signing & Capabilities), and build to a **physical iPhone** (volume events don't work in the Simulator). Trust the developer cert on the phone: Settings → General → VPN & Device Management.
> - Grant **Microphone + Speech Recognition** on the phone the first time you use voice.

> **Experimental software. This project is a personal research prototype — it is unstable, under active development, and likely has bugs. Use at your own risk.**

> A walkie-talkie for vibecoding with Claude.

**Run multiple Claude Code sessions from your phone, hands-free.** dispatch is an iPhone app that lets you control multiple terminal windows on your Mac using only the volume buttons and your voice. Kick your feet up, hold your phone, and project-manage four Claude Code sessions with two buttons and dictation.

It pairs an iOS app with a small Python server running on your Mac. The server snapshots iTerm2 windows; your phone cycles between them and pipes dictated speech in as keystrokes.

---

## What It Does

- **Volume buttons control your terminals.** Single press cycles between iTerm2 windows. Long press starts dictation. The phone never has to be unlocked or focused on the app.
- **Voice → keystrokes.** Speak; on-device speech recognition transcribes and the server types your text into the focused terminal.
- **Multi-window orchestration.** Sit on the couch and bounce between four agents working on four different things.
- **Visual highlight.** The active iTerm2 window gets a colored tab so you can glance at the screen and know where input is going.
- **Local-only.** Server can bind to `localhost`, your LAN, or your [Tailscale](https://tailscale.com/) tailnet — your call.

### Input matrix

| Input | Action |
|---|---|
| Volume Up — single press | Cycle to next terminal |
| Volume Down — single press | Cycle to previous terminal |
| Volume Up — long press | Start / stop dictation |
| Volume Down — long press | Send double-escape (clears Claude Code prompt) |

---

## Requirements

- macOS with [iTerm2](https://iterm2.com/) installed
- Python 3.10+ on the Mac
- iPhone running iOS 17+
- A Mac with Xcode 15+ to build the iOS app
- Either a **free Apple ID** (sideloading works — see "About signing" below) or a paid Apple Developer account
- Optional: [Tailscale](https://tailscale.com/) for secure phone↔Mac connection from anywhere

---

## Privacy

- **All processing is local.** Speech transcription runs on-device on the iPhone (via Apple's `Speech` framework). The server runs on your Mac. No third-party cloud services are involved.
- **No telemetry, no analytics, no crash reporting.**
- **Bind to whatever network you want.** Localhost only, your LAN, or your tailnet — picked at server startup.

---

## About signing (free vs. paid Apple Developer)

You don't need a paid Apple Developer account to run dispatch on your own iPhone — a free Apple ID works. The tradeoffs:

| | Free Apple ID | Paid Developer Program ($99/yr) |
|---|---|---|
| Install on personal devices | ✅ | ✅ |
| Re-sign required every | **7 days** | 1 year |
| Active app IDs at once | 3 | unlimited |
| TestFlight / App Store | ❌ | ✅ |

For just trying dispatch on your own iPhone, the free path is fine.

---

## Setup

### 1. Clone

```bash
git clone https://github.com/brianharms/dispatch
cd dispatch
```

### 2. Start the Mac server

The server is a single Python file that runs on the Python standard library alone (+ AppleScript via `osascript`) — no install step required. **Optional:** `pip install zeroconf` enables Bonjour/mDNS auto-discovery so the iPhone app finds the Mac automatically; without it, the server still runs fine and you just enter the Mac's IP manually.

```bash
cd server
./dispatch_server.py
```

On first run it'll prompt you for which IP to bind to:

```
Choose where to bind:
  1) localhost only (this Mac)
  2) LAN (anyone on Wi-Fi)
  3) Tailscale only (this Mac's tailnet IP 100.x.y.z)
```

You can skip the prompt with a flag:

```bash
./dispatch_server.py --tailscale     # bind to your Tailscale IP only
./dispatch_server.py --lan           # bind to 0.0.0.0 (LAN)
./dispatch_server.py --localhost     # bind to 127.0.0.1
./dispatch_server.py --bind 1.2.3.4  # bind to a specific IP
```

The server runs on port `9876`.

> **iTerm2 permissions:** The first time the server tries to read your iTerm2 window list, macOS will prompt for AppleScript / Automation permission. Grant it.

### 3. Build the iOS app

```bash
open Dispatch.xcodeproj
```

Before building:

1. Select the `Dispatch` target → **Signing & Capabilities** → choose **your team** (sign in with your Apple ID if needed)
2. Change the **Bundle Identifier** to something unique (e.g. `com.YOURNAME.dispatch`) — Apple won't let two developers share the same one
3. Plug your iPhone in, select it as the target, and hit Run

### 4. Connect the phone to the server

On first launch, the iOS app asks for the server's IP address. Enter whatever the server told you it was binding to (e.g. `100.x.y.z:9876` if you used `--tailscale`).

---

## How it works

### Volume button interception (iOS)

iOS doesn't expose volume buttons as a standard input. The technique:

1. Hide the system volume HUD with a zero-frame `MPVolumeView`
2. Observe `AVAudioSession.sharedInstance().outputVolume` via KVO
3. Detect direction (up/down) from the volume delta
4. Reset volume to `0.5` after each press (preserves both directions)
5. Long press = rapid repeated volume changes within a time window
6. Single vs. long-press disambiguated with a short hold timer

The app keeps the audio session alive in the background so volume events keep firing even when the screen is off.

### Server architecture

```
iPhone (SwiftUI)  ──HTTP/WS──►  Mac Server (Python)  ──AppleScript──►  iTerm2
     │                               │
     ├─ Volume button input          ├─ Window snapshot
     ├─ Voice dictation              ├─ Keystroke injection
     └─ Status UI                    └─ Active-window highlight
```

The server:
- Snapshots iTerm2 windows (session IDs + names)
- Tracks the "active" window index
- Cycles next / prev on volume input
- Injects dictated text as keystrokes via AppleScript
- Optionally tints the active window's tab color via the iTerm2 Python API

### File structure

```
dispatch/
├── Dispatch/                         # iOS app (SwiftUI)
│   ├── DispatchApp.swift             # Entry point
│   ├── ContentView.swift             # Main UI
│   ├── VolumeButtonManager.swift     # Volume button interception
│   ├── NetworkManager.swift          # HTTP/WebSocket client
│   ├── AudioManager.swift            # Recording + transcription
│   └── Assets.xcassets/
├── Dispatch Watch App/               # Optional Apple Watch companion
├── server/
│   ├── dispatch_server.py            # HTTP server + AppleScript
│   └── transcribe.swift              # Speech-to-text helper
├── iterm-scripts/
│   └── focus_tab_color.py            # Optional iTerm2 tab-color highlight
└── Dispatch.xcodeproj/
```

---

## Design

- **Monochrome.** Black, white, grays only.
- **Low-poly.** Geometric wireframe shapes as visual identity.
- **Minimal UI.** The screen shows status, not controls. You're not supposed to be looking at it.
- **Typography.** Bold lowercase with period (`dispatch.`).

---

## Troubleshooting

**"Phone can't reach dispatch server"** — First check whether your Mac's IP rotated. Run `ipconfig getifaddr en0` on the Mac and compare to what the iOS app is configured with. DHCP leases drop and the IP can change without warning. Using `--tailscale` avoids this entirely.

**"One window is missing from the cycle"** — The server filters out iTerm2 automation script windows. If a window's name happens to start with the substring "Script", it'll be excluded. Rename it.

**Volume buttons don't do anything** — On iOS, the app needs to be running (foreground or background — not killed). Audio session must be active. Open the app, play a sound, then re-test.

**iTerm2 AppleScript permission denied** — System Settings → Privacy & Security → Automation → make sure Terminal/your shell has permission to control iTerm2.

---

## License

MIT — [Ritual.Industries](https://ritual.industries)

## For AI coding agents

This repo is a two-part system: an iOS+watchOS Swift app and a zero-dependency Python Mac server. They talk over plain HTTP on port `9876`. Read the files below before editing — don't infer behavior from names.

### Repo layout (top level)
- `Dispatch/` — the iOS app (SwiftUI, Swift 6.0). Volume-button interception, networking, audio capture, terminal-status UI.
- `Dispatch Watch App/` — optional watchOS companion (Swift 5.0); its own `AudioRecorder`, `NetworkManager`, `ContentView`, `SettingsView`.
- `server/` — the Mac server. `dispatch_server.py` (stdlib-only HTTP server + AppleScript driver) plus two pre-compiled Swift helper binaries with their sources alongside: `transcribe`/`transcribe.swift` (on-device `Speech` STT) and `dictation_hud`/`dictation_hud.swift` (floating live-dictation panel). `.gitkeep` keeps the dir tracked.
- `iterm-scripts/` — `focus_tab_color.py` (optional iTerm2 active-window tab tint) and a `SKILL.md`.
- `project.yml` — XcodeGen spec; the `Dispatch.xcodeproj` is generated from it.
- `Dispatch.xcodeproj/`, `README.md`, `LICENSE` (MIT), `.gitignore`.

### Key entry points (read first)
- `server/dispatch_server.py` — the protocol's source of truth. `DispatchHandler` defines every route. Endpoints: `GET /status`, `/watch`, `/ping`, `/layout`; `POST /cycle`, `/dictate`, `/stream-text`, `/type`, `/escape`, `/flush`, `/recording-start`, `/recording-stop`, `/hud-position`, `/focus-push`, `/debug-log`, `/refresh`. `main()` + `choose_bind_ip()` handle startup and binding.
- `Dispatch/DispatchApp.swift` (app entry), `Dispatch/VolumeButtonManager.swift` (the volume-HUD interception technique), and `Dispatch/NetworkManager.swift` (the client side of every route above — keep its endpoint strings in lockstep with the server).

### Build / run / test
- Server: `cd server && ./dispatch_server.py`. No pip install — Python 3.10+ stdlib only, drives iTerm2 via `osascript`. Flags skip the interactive bind prompt: `--localhost`, `--lan` (`0.0.0.0`), `--tailscale`, `--bind <ip>`. Always listens on `9876`. First run triggers a macOS Automation permission prompt for iTerm2.
- Swift helpers: rebuild from source when you touch the `.swift` files (the server prints the exact command), e.g. `swiftc -o server/transcribe server/transcribe.swift -framework Speech` and the analogous build for `dictation_hud`. Commit the rebuilt binary alongside the source.
- iOS/watchOS: project is generated — run `xcodegen generate` after editing `project.yml`, then `open Dispatch.xcodeproj`. Set your own signing team in Xcode and build to a device. There is no automated test suite; verify on a physical iPhone (volume events don't fire reliably in Simulator).

### Invariants — do not break
- **`DEVELOPMENT_TEAM` must stay `""`** in `project.yml` (both the `Dispatch` and `Dispatch Watch App` targets). It's intentionally blank so each contributor supplies their own team; never commit a real team ID.
- **Keep the server stdlib-only at its core.** It must run with no install step. The one third-party import, `zeroconf`, is **optional** and guarded by `try/except ImportError` (Bonjour auto-discovery degrades gracefully to manual IP). Don't add *required* third-party imports or a mandatory `requirements.txt`; keep any new optional dep import-guarded the same way.
- **Don't hardcode paths.** The server already resolves everything relative to itself: `SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))`, with `TRANSCRIBE_BIN`/`DICTATION_HUD_BIN`/`DEBUG_LOG_FILE` derived from it, and config under `os.path.expanduser(...)` (`~/.config/dispatch/`, `~/.claude/...`). Keep these parameterized — no absolute or user-specific paths.
- **Bind IP stays user-chosen at runtime.** `choose_bind_ip()` must keep defaulting safely (localhost/Tailscale) and never bake in a specific LAN/tailnet IP. Don't widen the default bind.
- **Keep the HTTP protocol in sync across all three clients.** Route paths, JSON keys, and the cycle `seq` token (`last_cycle_seq`/`cycle_confirmed_seq` ordering guard that prevents stale `/cycle` responses from snapping the active window backward) are a shared contract between `dispatch_server.py`, `Dispatch/NetworkManager.swift`, and the watch app's `NetworkManager.swift`. Change all sides together.
- **Respect `.gitignore` secrets/state.** `.env*`, `certs/`, `*.pem`/`*.key`/`*.p12`, `credentials.json`, logs (`*.log`, `dictation_debug.log`), `*.pid`, `*.jsonl`, `state/`, and internal notes (`CLAUDE.md`, `SESSION_LOG.md`, `.claude/`) must never be committed.
- **iTerm2 window filtering:** the server excludes windows whose name starts with `Script`. Preserve that filter (it hides automation/HUD windows from the cycle list).

### Placeholdered / personal values to keep generic
- Bundle IDs in `project.yml` use the generic `com.ritualindustries.dispatch` / `.watch` prefix — treat as a placeholder; contributors change it in Xcode. Don't substitute a real personal identifier.
- All network addresses are runtime-supplied (server bind flags; the iOS app's `serverURL` defaults to `http://localhost:9876` and is set via Bonjour discovery or manual entry). No real LAN/Tailscale IPs are checked in — keep it that way.
- `iterm-scripts/focus_tab_color.py` and the server's focus integration read from `~/.claude/...` toggle/state files; these are environment lookups, not committed config — leave them as `expanduser` lookups.
