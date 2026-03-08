# dispatch. — Session Log

## Session 1 — 2026-03-08 — Project Kickoff

### Status: Planning complete, ready for implementation

### What happened:
- Created project directory and CLAUDE.md
- Defined architecture: iPhone → HTTP → Mac Server → iTerm2
- Mapped volume button inputs to actions (cycle, dictate, escape)
- Identified volume button interception technique (AVAudioSession KVO)
- Defined 5-agent breakdown: UI, Button, Server, Xcode, Voice

### Next steps:
- Xcode Agent: Create Xcode project, configure signing, get a blank app on device
- Button Agent: Implement VolumeButtonManager with gesture recognition
- Server Agent: Port twist_server.py → dispatch_server.py
- UI Agent: Build minimal status screen (active terminal name, connection status)
- Voice Agent: Implement audio capture + transcription pipeline

### Known considerations:
- Volume button interception is not officially supported by Apple — may need testing on real device
- Long press detection needs tuning (rapid-repeat threshold)
- Dual button press timing window (~100ms) needs real-device calibration
- iPhone has enough power for on-device speech recognition (no need for server-side transcribe)
