#!/usr/bin/env python3
"""Dispatch Server — control iTerm2 windows from iPhone."""

import json
import os
import socket
import subprocess
import tempfile
from http.server import HTTPServer, BaseHTTPRequestHandler

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TRANSCRIBE_BIN = os.path.join(SCRIPT_DIR, "transcribe")

PORT = 9876
TARGET_APP = "iTerm2"

# Blue-ish highlight for the active window
HIGHLIGHT_COLOR = "{8000, 12000, 28000}"

state = {
    "current_index": 0,
    "mode": "windows",
    "window_ids": [],
    "window_names": [],
    "saved_color": None,
    "highlighted_id": None,
}


# ---------------------------------------------------------------------------
# iTerm2 AppleScript helpers
# ---------------------------------------------------------------------------

def refresh_windows():
    """Get stable window ID/name pairs from iTerm2."""
    ids_script = f'tell application "{TARGET_APP}" to get id of every window'
    names_script = f'''
    tell application "{TARGET_APP}"
        set nameList to name of every window
        set AppleScript's text item delimiters to "|||"
        return nameList as text
    end tell
    '''
    try:
        ids_result = subprocess.run(
            ['osascript', '-e', ids_script],
            capture_output=True, text=True, timeout=5
        )
        names_result = subprocess.run(
            ['osascript', '-e', names_script],
            capture_output=True, text=True, timeout=5
        )
    except subprocess.TimeoutExpired:
        print("  [error] AppleScript timed out enumerating windows")
        return [], []

    ids_raw = ids_result.stdout.strip()
    names_raw = names_result.stdout.strip()

    if not ids_raw or not names_raw:
        print("  [warn] No iTerm2 windows found (is iTerm2 running?)")
        return [], []

    ids = [int(x.strip()) for x in ids_raw.split(',')]
    names = [n.strip() for n in names_raw.split('|||')]
    return ids, names


def lock_windows():
    """Snapshot the window list. Locked until /refresh or restart."""
    ids, names = refresh_windows()
    state["window_ids"] = ids
    state["window_names"] = names
    if state["current_index"] >= len(ids):
        state["current_index"] = 0
    print(f"  Locked {len(ids)} windows")


def get_window_name(index):
    """Get live name for window at index."""
    if index < 0 or index >= len(state["window_ids"]):
        return "?"
    wid = state["window_ids"][index]
    script = f'tell application "{TARGET_APP}" to get name of (first window whose id is {wid})'
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        name = result.stdout.strip()
        if name:
            state["window_names"][index] = name
            return name
    except subprocess.TimeoutExpired:
        pass
    return state["window_names"][index] if index < len(state["window_names"]) else "?"


def activate_and_highlight(new_index):
    """Activate window, restore old highlight, apply new highlight — single osascript call."""
    if new_index < 0 or new_index >= len(state["window_ids"]):
        return None
    new_id = state["window_ids"][new_index]
    old_id = state["highlighted_id"]
    old_color = state["saved_color"]

    parts = [f'tell application "{TARGET_APP}"']

    # Restore old window's background color
    if old_id is not None and old_color is not None:
        r, g, b = old_color.split(',')
        parts.append(f'''
        try
            set s to current session of current tab of (first window whose id is {old_id})
            set background color of s to {{{r}, {g}, {b}}}
        end try''')

    # Activate and select new window
    parts.append(f'''
        activate
        set w to (first window whose id is {new_id})
        select w''')

    # Save bg color, apply highlight, get name
    parts.append(f'''
        set s to current session of current tab of w
        set bg to background color of s
        set savedColor to (item 1 of bg as text) & "," & (item 2 of bg as text) & "," & (item 3 of bg as text)
        set background color of s to {HIGHLIGHT_COLOR}
        set winName to name of w
        return savedColor & "|||" & winName
    end tell''')

    script = '\n'.join(parts)
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        output = result.stdout.strip()
    except subprocess.TimeoutExpired:
        print("  [error] activate_and_highlight timed out")
        return state["window_names"][new_index] if new_index < len(state["window_names"]) else "?"

    if '|||' in output:
        saved, name = output.split('|||', 1)
        state["saved_color"] = saved
        state["highlighted_id"] = new_id
        state["window_names"][new_index] = name
        return name

    return state["window_names"][new_index] if new_index < len(state["window_names"]) else "?"


def set_bg_color(wid, color_str):
    """Set background color by stable window ID. color_str is 'r,g,b'."""
    r, g, b = color_str.split(',')
    script = f'''
    tell application "{TARGET_APP}"
        set s to current session of current tab of (first window whose id is {wid})
        set background color of s to {{{r}, {g}, {b}}}
    end tell
    '''
    try:
        subprocess.run(['osascript', '-e', script], capture_output=True, text=True, timeout=5)
    except subprocess.TimeoutExpired:
        pass


def type_text_iterm(text, enter=False):
    """Type text into the active iTerm2 session using iTerm2's native 'write text' API."""
    escaped = text.replace('\\', '\\\\').replace('"', '\\"')
    if enter:
        # write text already sends a newline, so just use it directly
        script = f'''
        tell application "{TARGET_APP}"
            tell current session of current tab of current window
                write text "{escaped}"
            end tell
        end tell
        '''
    else:
        # write text without newline: use 'write text ... newline NO' (iTerm2 3.x+)
        script = f'''
        tell application "{TARGET_APP}"
            tell current session of current tab of current window
                write text "{escaped}" newline no
            end tell
        end tell
        '''
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            print(f"  [error] type_text failed: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        print("  [error] type_text timed out")


def send_escape():
    """Send double-escape to active iTerm2 session."""
    script = f'''
    tell application "{TARGET_APP}"
        tell current session of current tab of current window
            write text (ASCII character 27) newline no
            write text (ASCII character 27) newline no
        end tell
    end tell
    '''
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            print(f"  [error] send_escape failed: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        print("  [error] send_escape timed out")


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def build_status():
    """Build status response dict."""
    total = len(state["window_ids"])
    idx = state["current_index"]
    name = get_window_name(idx) if total > 0 else "No Windows"
    windows = []
    for i, (wid, wname) in enumerate(zip(state["window_ids"], state["window_names"])):
        windows.append({"id": str(wid), "name": wname})
    return {
        "windows": windows,
        "current_index": idx,
        "total": total,
        "active_window": name,
        "mode": state["mode"],
    }


class DispatchHandler(BaseHTTPRequestHandler):
    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length == 0:
            return {}
        return json.loads(self.rfile.read(length))

    def log_message(self, format, *args):
        print(f"  {args[0]}")

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(204)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        if self.path == "/status":
            total = len(state["window_ids"])
            if total == 0:
                lock_windows()
            self.send_json(build_status())

        elif self.path == "/ping":
            self.send_json({"ok": True})

        else:
            self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        if self.path == "/dictate":
            length = int(self.headers.get('Content-Length', 0))
            audio_data = self.rfile.read(length) if length > 0 else b''
            if not audio_data:
                self.send_json({"error": "no audio"}, 400)
                return

            tmp = os.path.join(tempfile.gettempdir(), "dispatch_dictation.wav")
            with open(tmp, "wb") as f:
                f.write(audio_data)
            print(f"  Received {len(audio_data)} bytes of audio, transcribing...")

            text = ""
            try:
                result = subprocess.run(
                    [TRANSCRIBE_BIN, tmp],
                    capture_output=True, text=True, timeout=15
                )
                text = result.stdout.strip()
                if result.stderr.strip():
                    print(f"  Transcribe stderr: {result.stderr.strip()}")
            except subprocess.TimeoutExpired:
                print("  Transcription timed out")
            except FileNotFoundError:
                print(f"  [error] transcribe binary not found at {TRANSCRIBE_BIN}")
                print("  Build it with: swiftc -o server/transcribe server/transcribe.swift -framework Speech")

            if text:
                print(f"  Transcribed: {text}")
                type_text_iterm(text, enter=True)
            else:
                print("  No text transcribed")

            self.send_json({"ok": True, "text": text})
            return

        # All other POST endpoints expect JSON body
        body = self.read_body()

        if self.path == "/cycle":
            direction = body.get("direction", "next")
            total = len(state["window_ids"])

            if total == 0:
                self.send_json({"error": "no windows", "total": 0})
                return

            if direction == "next":
                state["current_index"] = (state["current_index"] + 1) % total
            else:
                state["current_index"] = (state["current_index"] - 1) % total

            idx = state["current_index"]
            name = activate_and_highlight(idx)
            print(f"  Cycled {direction} -> [{idx}] {name}")
            self.send_json(build_status())

        elif self.path == "/type":
            text = body.get("text", "")
            enter = body.get("enter", False)
            if text:
                type_text_iterm(text, enter=enter)
                print(f"  Typed: {repr(text)} (enter={enter})")
            self.send_json({"ok": True, "typed": text})

        elif self.path == "/escape":
            send_escape()
            print("  Sent double-escape")
            self.send_json({"ok": True})

        elif self.path == "/refresh":
            lock_windows()
            print("  Refreshed window list")
            self.send_json(build_status())

        else:
            self.send_json({"error": "not found"}, 404)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    hostname = socket.gethostname().replace('.local', '')
    lock_windows()

    print(f"\n  Dispatch Server running on port {PORT}")
    print(f"  URL: http://{hostname}.local:{PORT}")
    print(f"  Target app: {TARGET_APP}")
    print(f"  Windows locked: {len(state['window_ids'])}")
    for i, (wid, name) in enumerate(zip(state["window_ids"], state["window_names"])):
        print(f"    [{i}] id={wid} — {name}")
    print(f"\n  Waiting for phone...\n")

    server = HTTPServer(('0.0.0.0', PORT), DispatchHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        # Restore highlighted window's original color on shutdown
        if state["highlighted_id"] is not None and state["saved_color"] is not None:
            try:
                set_bg_color(state["highlighted_id"], state["saved_color"])
            except Exception:
                pass
        print("\n  Shutting down.")
        server.server_close()


if __name__ == '__main__':
    main()
