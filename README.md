# dispatch.

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
- **Local by default.** The server listens on this Mac only. Reaching it from your phone over your LAN or [Tailscale](https://tailscale.com/) tailnet is an explicit opt-in, and then every request from another device must carry a shared token.

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
- **Nothing reaches your terminal without your token.** dispatch types into iTerm2, and whatever it types gets run, so see [Security](#security) before turning on remote access.

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

The server is a single Python file with no third-party dependencies (uses only the Python standard library + AppleScript via `osascript`).

```bash
cd server
./dispatch_server.py
```

By default it listens on `127.0.0.1` only (this Mac). Your phone is another device, so to use the iPhone app you opt into remote access, either per run with a flag:

```bash
./dispatch_server.py --tailscale     # bind to your Tailscale IP only (recommended)
./dispatch_server.py --lan           # bind to 0.0.0.0 (LAN + tailnet)
./dispatch_server.py --bind 1.2.3.4  # bind to a specific IP
./dispatch_server.py --localhost     # this Mac only (the default)
```

or once, with a one-word file that every later start (including `talk`'s) picks up:

```bash
mkdir -p ~/.config/dispatch && echo tailscale > ~/.config/dispatch/remote   # or: lan
```

The first remote start creates a random token in `~/.config/dispatch/token` (mode 600). Other devices must sign every request with it (the token itself never crosses the network); the iOS app gets it baked in at build time (step 3). Run interactively with no flag and no `remote` file, the server asks where to listen and defaults to localhost.

The server runs on port `9879`.

> **iTerm2 permissions:** The first time the server tries to read your iTerm2 window list, macOS will prompt for AppleScript / Automation permission. Grant it.

### 3. Build the iOS app

```bash
open Dispatch.xcodeproj
```

Before building:

1. Select the `Dispatch` target → **Signing & Capabilities** → choose **your team** (sign in with your Apple ID if needed)
2. Change the **Bundle Identifier** to something unique (e.g. `com.YOURNAME.dispatch`) — Apple won't let two developers share the same one
3. Give the app your token (only needed for remote access): create `Dispatch/Token.xcconfig` containing `DISPATCH_TOKEN = <the contents of ~/.config/dispatch/token>`, then in Xcode open the project → Info → Configurations and set it as the configuration file for the `Dispatch` target (or build from the command line with `xcodebuild ... -xcconfig Dispatch/Token.xcconfig`). `*.xcconfig` holding the token is git-ignored; never commit it. The token lands in the app's Info.plist as `DispatchToken`; the app signs every request with it.
4. Plug your iPhone in, select it as the target, and hit Run

### 4. Connect the phone to the server

On first launch, the iOS app asks for the server's IP address. Enter whatever the server told you it was binding to (e.g. `100.x.y.z:9879` if you used `--tailscale`).

---

## Security

dispatch's job is to type into your terminal, and a terminal runs what it's given. So the server only takes orders from you:

- **Localhost by default.** Remote access (LAN / Tailscale) is opt-in: a flag or `~/.config/dispatch/remote`.
- **Signed requests from other devices.** In remote mode every request from another machine must carry `X-Dispatch-Auth: v1 <unix-seconds> <nonce> <hex>`, where `hex = HMAC-SHA256(token, "METHOD\nPATH?QUERY\nSECONDS\nNONCE\n" + body)`. The token never goes over the wire, so sniffing plain HTTP on the LAN or posing as dispatch over Bonjour reveals nothing reusable. Requests more than 90 s off, with a nonce seen before, or with a changed path/body are refused (`401`). Only `GET /ping` is open. Prefer `--tailscale` anyway: it encrypts the traffic too.
- **No web pages.** Requests carrying browser headers (`Origin`, `Sec-Fetch-*`) are refused, and no CORS headers are sent, so a website you visit can't reach dispatch through `localhost`.
- **No DNS rebinding.** Requests from the Mac itself need no token, but their `Host` must be `localhost` or an IP address.
- **JSON only.** `POST` bodies must be `application/json` (`/dictate` takes `audio/*`), and bodies are size-capped.
- **Bonjour only in remote mode.** A localhost-only server doesn't advertise itself.

Rotate the token by deleting `~/.config/dispatch/token`, restarting the server, and rebuilding the app.

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

**Server log says `refused ... bad signature` (or `missing or malformed X-Dispatch-Auth`)** — the phone's token doesn't match `~/.config/dispatch/token` on the Mac it's talking to. Rebuild the app with the current token (Setup step 3). If you run dispatch on more than one Mac, copy the same token file to each. `stale request` means the phone's and Mac's clocks disagree by more than 90 s.

**"One window is missing from the cycle"** — The server filters out iTerm2 automation script windows. If a window's name happens to start with the substring "Script", it'll be excluded. Rename it.

**Volume buttons don't do anything** — On iOS, the app needs to be running (foreground or background — not killed). Audio session must be active. Open the app, play a sound, then re-test.

**iTerm2 AppleScript permission denied** — System Settings → Privacy & Security → Automation → make sure Terminal/your shell has permission to control iTerm2.

---

## License

MIT — [Ritual.Industries](https://ritual.industries)
