#!/usr/bin/env python3
"""Dispatch Server — control iTerm2 windows from iPhone."""

import json
import os
import socket
import subprocess
import tempfile
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TRANSCRIBE_BIN = os.path.join(SCRIPT_DIR, "transcribe")

PORT = 9876
TARGET_APP = "iTerm2"

# Medium blue highlight for the active window — obvious but not harsh
# RGB ~30, 60, 120 mapped to 16-bit AppleScript color space
HIGHLIGHT_COLOR = "{7700, 15400, 30840}"

state = {
    "current_index": 0,
    "mode": "windows",
    "window_ids": [],
    "window_names": [],
    "saved_color": None,
    "highlighted_id": None,
}

# Streaming dictation state
current_typed_text = ""

# Cached status response — updated by background thread, served instantly
_cached_status = {}
_cache_lock = threading.Lock()


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
    """Snapshot the window list, sorted by x-position (left to right)."""
    ids, names = refresh_windows()

    # Sort windows by x-position so "next" = right, "prev" = left
    if ids:
        layout_windows, _ = get_window_layout()
        id_to_pos = {str(w["id"]): (w["x"], w["y"]) for w in layout_windows}
        paired = list(zip(ids, names))
        paired.sort(key=lambda p: id_to_pos.get(str(p[0]), (0, 0)))
        ids = [p[0] for p in paired]
        names = [p[1] for p in paired]

    state["window_ids"] = ids
    state["window_names"] = names
    if state["current_index"] >= len(ids):
        state["current_index"] = 0
    print(f"  Locked {len(ids)} windows (sorted left-to-right)")


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
    """Activate and select window. Color highlighting is handled by iTerm2's focus_tab_color.py."""
    global current_typed_text

    if new_index < 0 or new_index >= len(state["window_ids"]):
        return None
    new_id = state["window_ids"][new_index]

    # Reset streaming dictation state when cycling windows
    current_typed_text = ""

    script = f'''
    tell application "{TARGET_APP}"
        activate
        set w to (first window whose id is {new_id})
        select w
        return name of w
    end tell
    '''
    name = None
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=3
        )
        name = result.stdout.strip() or None
    except subprocess.TimeoutExpired:
        print("  [error] activate_and_highlight timed out")

    if name:
        state["window_names"][new_index] = name

    return name or (state["window_names"][new_index] if new_index < len(state["window_names"]) else "?")


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


def send_backspaces_iterm(count):
    """Send N backspace/delete characters to the active iTerm2 session."""
    if count <= 0:
        return
    # Use System Events key code 51 (Delete key) — most reliable for terminal backspace
    script = f'''
    tell application "{TARGET_APP}" to activate
    tell application "System Events"
        repeat {count} times
            key code 51
        end repeat
    end tell
    '''
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            print(f"  [warn] send_backspaces via key code 51 failed: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        print("  [error] send_backspaces timed out")


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


def get_screen_size():
    """Get screen resolution via Finder desktop bounds."""
    script = '''
    tell application "Finder"
        get bounds of window of desktop
    end tell
    '''
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        output = result.stdout.strip()
        if output:
            # Returns "0, 0, width, height"
            parts = [int(x.strip()) for x in output.split(',')]
            if len(parts) == 4:
                return {"width": parts[2], "height": parts[3]}
    except subprocess.TimeoutExpired:
        print("  [error] get_screen_size timed out")
    return {"width": 0, "height": 0}


def get_window_layout():
    """Get positions, sizes, tabs, and active tab info for all iTerm2 windows.

    Returns (windows_list, active_index).
    Each window dict: {id, name, x, y, width, height, tabs?, tab_count?, active_tab?}
    iTerm2 bounds = {left, top, right, bottom} — normalized to {x, y, width, height}.
    """
    script = f'''
    tell application "{TARGET_APP}"
        set output to ""
        set activeWinID to id of current window
        repeat with w in windows
            set wID to id of w
            set wName to name of w
            set wBounds to bounds of w
            set bLeft to item 1 of wBounds
            set bTop to item 2 of wBounds
            set bRight to item 3 of wBounds
            set bBottom to item 4 of wBounds

            -- Tab info
            set tabNames to ""
            set tabCount to count of tabs of w
            set activeTabIdx to 0
            repeat with ti from 1 to tabCount
                set t to tab ti of w
                set tName to name of current session of t
                if ti > 1 then set tabNames to tabNames & ";;;"
                set tabNames to tabNames & tName
                if t is equal to current tab of w then
                    set activeTabIdx to ti
                end if
            end repeat

            set output to output & wID & ":::" & wName & ":::" & bLeft & "," & bTop & "," & bRight & "," & bBottom & ":::" & tabCount & ":::" & activeTabIdx & ":::" & tabNames & "|||"
        end repeat
        return output & "ACTIVE:::" & activeWinID
    end tell
    '''
    try:
        result = subprocess.run(
            ['osascript', '-e', script],
            capture_output=True, text=True, timeout=5
        )
        output = result.stdout.strip()
    except subprocess.TimeoutExpired:
        print("  [error] get_window_layout timed out")
        return [], 0

    if not output:
        return [], 0

    # Parse active window ID from the tail
    active_id = -1
    if "ACTIVE:::" in output:
        main_part, active_part = output.rsplit("ACTIVE:::", 1)
        output = main_part
        try:
            active_id = int(active_part.strip())
        except (ValueError, IndexError):
            pass

    windows = []
    active_index = 0
    entries = [e.strip() for e in output.split("|||") if e.strip()]

    for i, entry in enumerate(entries):
        fields = entry.split(":::")
        if len(fields) < 6:
            continue
        try:
            wid = fields[0].strip()
            wname = fields[1].strip()
            bounds_parts = [int(x.strip()) for x in fields[2].split(',')]
            tab_count = int(fields[3].strip())
            active_tab = int(fields[4].strip())
            tab_names_raw = fields[5].strip()

            left, top, right, bottom = bounds_parts
            win_data = {
                "id": wid,
                "name": wname,
                "x": left,
                "y": top,
                "width": right - left,
                "height": bottom - top,
            }

            # Include tab info when there are multiple tabs
            if tab_count > 1:
                tab_list = [t.strip() for t in tab_names_raw.split(";;;")]
                win_data["tabs"] = tab_list
                win_data["tab_count"] = tab_count
                win_data["active_tab"] = active_tab - 1  # 0-indexed for JSON

            if str(active_id) == wid:
                active_index = i

            windows.append(win_data)
        except (ValueError, IndexError) as e:
            print(f"  [warn] Failed to parse window entry: {entry} ({e})")
            continue

    return windows, active_index


def calculate_typing_diff(old_text, new_text):
    """Calculate diff between already-typed text and new text.

    Returns (chars_to_delete, chars_to_type).
    """
    common_len = 0
    for i in range(min(len(old_text), len(new_text))):
        if old_text[i] == new_text[i]:
            common_len += 1
        else:
            break

    chars_to_delete = len(old_text) - common_len
    chars_to_type = new_text[common_len:]
    return chars_to_delete, chars_to_type


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

def build_status():
    """Build status response dict with layout data included."""
    total = len(state["window_ids"])
    idx = state["current_index"]
    name = get_window_name(idx) if total > 0 else "No Windows"

    screen = get_screen_size()
    layout_windows, layout_active_index = get_window_layout()

    # Auto-refresh locked windows if layout has windows we don't know about
    layout_ids = {str(w["id"]) for w in layout_windows}
    locked_ids = {str(wid) for wid in state["window_ids"]}
    if layout_ids != locked_ids:
        print(f"  [auto-refresh] Layout has {len(layout_ids)} windows, locked has {len(locked_ids)} — re-locking")
        lock_windows()
        total = len(state["window_ids"])
        idx = state["current_index"]
        name = get_window_name(idx) if total > 0 else "No Windows"

    # Detect if the user changed the active window on the Mac side
    if total > 0 and layout_windows:
        actual_active_id = layout_windows[layout_active_index]["id"] if layout_active_index < len(layout_windows) else None
        if actual_active_id is not None:
            # Find this window in our locked list
            for i, wid in enumerate(state["window_ids"]):
                if str(wid) == str(actual_active_id) and i != idx:
                    print(f"  [sync] Active window changed on Mac: [{idx}] -> [{i}]")
                    state["current_index"] = i
                    idx = i
                    name = get_window_name(idx)
                    break

    # Sort layout windows spatially: left-to-right, top-to-bottom (reading order)
    if layout_windows:
        layout_windows.sort(key=lambda w: (w["x"], w["y"]))

    # Active window ID for the app to match against layout
    active_id = str(state["window_ids"][idx]) if total > 0 else ""

    return {
        "current_index": idx,
        "total": total,
        "active_window": name,
        "active_window_id": active_id,
        "mode": state["mode"],
        "screen": screen,
        "layout": layout_windows,
    }


def _refresh_cache_loop():
    """Background thread: refresh cached status every 0.5s."""
    global _cached_status
    while True:
        try:
            total = len(state["window_ids"])
            if total == 0:
                lock_windows()
            status = build_status()
            with _cache_lock:
                _cached_status = status
        except Exception as e:
            print(f"  [cache] refresh error: {e}")
        time.sleep(0.5)


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

    # -- GET endpoints -----------------------------------------------------

    def do_GET(self):
        if self.path == "/status":
            with _cache_lock:
                status = dict(_cached_status) if _cached_status else {}
            if status:
                self.send_json(status)
            else:
                # First request before cache is populated
                self.send_json(build_status())

        elif self.path == "/ping":
            self.send_json({"ok": True})

        elif self.path == "/layout":
            screen = get_screen_size()
            layout_windows, active_index = get_window_layout()
            self.send_json({
                "screen": screen,
                "windows": layout_windows,
                "active_index": active_index,
            })

        else:
            self.send_json({"error": "not found"}, 404)

    # -- POST endpoints ----------------------------------------------------

    def do_POST(self):
        global current_typed_text

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
            active_id = str(state["window_ids"][idx])
            print(f"  Cycled {direction} -> [{idx}] {name}")
            # Return minimal response — skip heavy build_status() AppleScript calls
            self.send_json({
                "active_window_id": active_id,
                "current_index": idx,
                "active_window": name,
            })

        elif self.path == "/stream-text":
            text = body.get("text", "")
            is_final = body.get("is_final", False)
            previous_length = body.get("previous_length", 0)

            # Reset tracking if this is a new dictation session
            if previous_length == 0:
                current_typed_text = ""

            # Calculate diff between what we already typed and what we need
            chars_to_delete, chars_to_type = calculate_typing_diff(
                current_typed_text, text
            )

            # Apply corrections (backspaces) if speech engine revised earlier words
            if chars_to_delete > 0:
                send_backspaces_iterm(chars_to_delete)
                print(f"  Stream: deleted {chars_to_delete} chars")

            # Type new characters without newline
            if chars_to_type:
                type_text_iterm(chars_to_type, enter=False)
                print(f"  Stream: typed {repr(chars_to_type)}")

            # Update tracked state
            current_typed_text = text

            # On final result, press Enter and reset
            if is_final:
                type_text_iterm("", enter=True)
                current_typed_text = ""
                print("  Stream: finalized with enter")

            self.send_json({
                "ok": True,
                "typed_so_far": current_typed_text,
                "is_final": is_final,
            })

        elif self.path == "/type":
            text = body.get("text", "")
            enter = body.get("enter", False)
            if text:
                type_text_iterm(text, enter=enter)
                print(f"  Typed: {repr(text)} (enter={enter})")
            self.send_json({"ok": True, "typed": text})

        elif self.path == "/escape":
            send_escape()
            current_typed_text = ""  # Cancel any in-progress dictation tracking
            print("  Sent double-escape (dictation state reset)")
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

def start_bonjour():
    """Advertise this server via Bonjour/mDNS so the phone can find it."""
    try:
        from zeroconf import Zeroconf, ServiceInfo
    except ImportError:
        print("  [bonjour] zeroconf not installed — run: pip install zeroconf")
        print("  [bonjour] Phone will need manual IP configuration")
        return None, None

    hostname = socket.gethostname()
    if not hostname.endswith('.local.'):
        hostname_mdns = hostname.replace('.local', '') + '.local.'
    else:
        hostname_mdns = hostname

    # Get local IP for the service info
    local_ip = socket.gethostbyname(socket.gethostname())

    info = ServiceInfo(
        "_dispatch._tcp.local.",
        "Dispatch Server._dispatch._tcp.local.",
        addresses=[socket.inet_aton(local_ip)],
        port=PORT,
        properties={"version": "1"},
        server=hostname_mdns,
    )

    zc = Zeroconf()
    zc.register_service(info)
    print(f"  [bonjour] Advertising as _dispatch._tcp on {local_ip}:{PORT}")
    return zc, info


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

    # Advertise via Bonjour
    zc, zc_info = start_bonjour()

    # Start background cache refresh — keeps /status instant
    cache_thread = threading.Thread(target=_refresh_cache_loop, daemon=True)
    cache_thread.start()

    server = HTTPServer(('0.0.0.0', PORT), DispatchHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n  Shutting down.")
        if zc and zc_info:
            zc.unregister_service(zc_info)
            zc.close()
        server.server_close()


if __name__ == '__main__':
    main()
