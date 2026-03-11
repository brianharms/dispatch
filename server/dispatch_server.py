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

# Recording indicator color (hex for escape sequences — no AppleScript focus side-effects)
RECORDING_HEX = "641414"  # dark red, ~RGB(100, 20, 20)

# focus_tab_color.py palette — used to restore color after recording
FOCUS_COLORS = {
    "reset": {"focused": "233367", "unfocused": "14191f"},
    "stop":  {"focused": "1d3a90", "unfocused": "002f00"},
}
FOCUS_ENABLED_FILE = os.path.expanduser("~/.claude/focus_color_enabled")
FOCUS_TTY_STATE_DIR = os.path.expanduser("~/.claude/tty_states")

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

# Recording state — tracks whether we're in a recording session
_recording_active = False

# Cached status response — updated by background thread, served instantly
_cached_status = {}
_cache_lock = threading.Lock()

# Serialize ALL AppleScript calls — prevents race conditions between
# background cache refresh and /cycle endpoint, which cause iTerm2 to
# return duplicate/missing window IDs during concurrent enumeration
_applescript_lock = threading.Lock()


# ---------------------------------------------------------------------------
# iTerm2 AppleScript helpers
# ---------------------------------------------------------------------------

def refresh_windows():
    """Get stable window ID/name pairs from iTerm2 (visible, non-minimized only)."""
    script = f'''
    tell application "{TARGET_APP}"
        set idList to {{}}
        set nameList to {{}}
        repeat with w in windows
            if miniaturized of w is false then
                set wName to name of w
                if wName does not contain "Script" then
                    set end of idList to id of w
                    set end of nameList to wName
                end if
            end if
        end repeat
        set AppleScript's text item delimiters to ","
        set idStr to idList as text
        set AppleScript's text item delimiters to "|||"
        set nameStr to nameList as text
        return idStr & ":::" & nameStr
    end tell
    '''
    try:
        with _applescript_lock:
            result = subprocess.run(
                ['osascript', '-e', script],
                capture_output=True, text=True, timeout=5
            )
    except subprocess.TimeoutExpired:
        print("  [error] AppleScript timed out enumerating windows")
        return [], []

    raw = result.stdout.strip()
    if not raw or ":::" not in raw:
        print("  [warn] No iTerm2 windows found (is iTerm2 running?)")
        return [], []

    ids_raw, names_raw = raw.split(":::", 1)
    ids = [int(x.strip()) for x in ids_raw.split(',') if x.strip()]
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
        with _applescript_lock:
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
        with _applescript_lock:
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


def get_session_tty(wid):
    """Get the TTY path for the active session in a window (by window ID)."""
    script = f'''
    tell application "{TARGET_APP}"
        set s to current session of current tab of (first window whose id is {wid})
        get tty of s
    end tell
    '''
    try:
        with _applescript_lock:
            result = subprocess.run(
                ['osascript', '-e', script],
                capture_output=True, text=True, timeout=5
            )
        tty = result.stdout.strip()
        if tty and tty.startswith("/dev/"):
            return tty
    except subprocess.TimeoutExpired:
        pass
    return None


def set_bg_via_tty(tty_path, hex_color):
    """Write an iTerm2 escape sequence to set background color on a TTY."""
    if not tty_path:
        return False
    try:
        seq = f"\033]1337;SetColors=bg={hex_color}\a"
        with open(tty_path, "w") as f:
            f.write(seq)
        return True
    except Exception as e:
        print(f"  [color] Failed to write to {tty_path}: {e}")
        return False


def get_restore_color(tty_path):
    """Determine what color to restore after recording, matching focus_tab_color.py."""
    if not os.path.exists(FOCUS_ENABLED_FILE):
        return "14191f"  # neutral dark when focus coloring is off

    # Check TTY state (stop vs reset)
    tty_state = "reset"
    if tty_path:
        try:
            safe_name = tty_path.replace("/", "_")
            state_file = os.path.join(FOCUS_TTY_STATE_DIR, safe_name)
            if os.path.exists(state_file):
                with open(state_file) as f:
                    s = f.read().strip()
                    if s in FOCUS_COLORS:
                        tty_state = s
        except Exception:
            pass

    # The recording window is the focused one
    return FOCUS_COLORS[tty_state]["focused"]


def set_recording_color(on: bool):
    """Set active window background via escape sequences (no focus side-effects)."""
    global _recording_active
    _recording_active = on
    idx = state["current_index"]
    if idx < 0 or idx >= len(state["window_ids"]):
        return
    wid = state["window_ids"][idx]

    tty = get_session_tty(wid)
    if not tty:
        print(f"  [color] Could not get TTY for window {wid}")
        return

    if on:
        set_bg_via_tty(tty, RECORDING_HEX)
        print(f"  [color] Recording ON — {tty} -> {RECORDING_HEX}")
    else:
        restore = get_restore_color(tty)
        set_bg_via_tty(tty, restore)
        print(f"  [color] Recording OFF — {tty} -> {restore}")


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
        with _applescript_lock:
            result = subprocess.run(
                ['osascript', '-e', script],
                capture_output=True, text=True, timeout=5
            )
        if result.returncode != 0:
            print(f"  [error] type_text failed: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        print("  [error] type_text timed out")


def send_backspaces_iterm(count):
    """Send N backspace/delete characters to the active iTerm2 session.

    Uses iTerm2's native 'write text' API with DEL characters (ASCII 127)
    instead of System Events keystrokes — focus-independent, no race conditions.
    """
    if count <= 0:
        return
    script = f'''
    tell application "{TARGET_APP}"
        tell current session of current tab of current window
            set delChar to ASCII character 127
            set delStr to ""
            repeat {count} times
                set delStr to delStr & delChar
            end repeat
            write text delStr newline no
        end tell
    end tell
    '''
    try:
        with _applescript_lock:
            result = subprocess.run(
                ['osascript', '-e', script],
                capture_output=True, text=True, timeout=5
            )
        if result.returncode != 0:
            print(f"  [warn] send_backspaces failed: {result.stderr.strip()}")
    except subprocess.TimeoutExpired:
        print("  [error] send_backspaces timed out")


def send_escape():
    """Send double-escape to active iTerm2 session."""
    script = f'''
    tell application "{TARGET_APP}"
        tell current session of current tab of current window
            write text (ASCII character 27) newline no
            delay 0.1
            write text (ASCII character 27) newline no
        end tell
    end tell
    '''
    try:
        with _applescript_lock:
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
        with _applescript_lock:
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
            if miniaturized of w is true then
            else if name of w contains "Script" then
            else
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
            end if
        end repeat
        return output & "ACTIVE:::" & activeWinID
    end tell
    '''
    try:
        with _applescript_lock:
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

    # Validate: reject layouts with duplicate window IDs (AppleScript race artifact)
    seen_ids = set()
    has_dupes = False
    for w in windows:
        if w["id"] in seen_ids:
            has_dupes = True
            break
        seen_ids.add(w["id"])

    if has_dupes:
        print(f"  [warn] Duplicate window IDs in layout — retrying once")
        # Retry immediately (the lock ensures no concurrent AppleScript)
        try:
            with _applescript_lock:
                result = subprocess.run(
                    ['osascript', '-e', script],
                    capture_output=True, text=True, timeout=5
                )
            retry_output = result.stdout.strip()
        except subprocess.TimeoutExpired:
            print("  [error] get_window_layout retry timed out")
            return windows, active_index  # Return the flawed layout rather than nothing

        if retry_output:
            # Re-parse the retry result
            retry_active_id = -1
            if "ACTIVE:::" in retry_output:
                main_part, active_part = retry_output.rsplit("ACTIVE:::", 1)
                retry_output = main_part
                try:
                    retry_active_id = int(active_part.strip())
                except (ValueError, IndexError):
                    pass

            retry_windows = []
            retry_active_index = 0
            entries = [e.strip() for e in retry_output.split("|||") if e.strip()]
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
                    if tab_count > 1:
                        tab_list = [t.strip() for t in tab_names_raw.split(";;;")]
                        win_data["tabs"] = tab_list
                        win_data["tab_count"] = tab_count
                        win_data["active_tab"] = active_tab - 1
                    if str(retry_active_id) == wid:
                        retry_active_index = i
                    retry_windows.append(win_data)
                except (ValueError, IndexError):
                    continue

            # Check retry for dupes too
            retry_ids = [w["id"] for w in retry_windows]
            if len(retry_ids) == len(set(retry_ids)):
                print(f"  [info] Retry succeeded — clean layout with {len(retry_windows)} windows")
                return retry_windows, retry_active_index
            else:
                print(f"  [warn] Retry also had duplicate IDs — returning original")

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

    # Filter layout to only include locked windows — prevents transient/ephemeral
    # windows (preferences, recolor flashes, etc.) from affecting the phone display
    locked_id_set = {str(wid) for wid in state["window_ids"]}
    if locked_id_set:
        filtered = [w for w in layout_windows if str(w["id"]) in locked_id_set]
        if len(filtered) == len(locked_id_set):
            layout_windows = filtered
        else:
            # Some locked windows missing from layout — keep full list as fallback
            print(f"  [warn] Layout missing locked windows: got {len(filtered)}/{len(locked_id_set)}")

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
            if text or enter:
                type_text_iterm(text, enter=enter)
                print(f"  Typed: {repr(text)} (enter={enter})")
            if enter:
                current_typed_text = ""
            self.send_json({"ok": True, "typed": text})

        elif self.path == "/escape":
            send_escape()
            current_typed_text = ""  # Cancel any in-progress dictation tracking
            print("  Sent double-escape (dictation state reset)")
            self.send_json({"ok": True})

        elif self.path == "/recording-start":
            current_typed_text = ""  # Reset dictation tracking for new session
            set_recording_color(on=True)
            print("  Recording started — background red, dictation state reset")
            self.send_json({"ok": True})

        elif self.path == "/recording-stop":
            set_recording_color(on=False)
            print("  Recording stopped — background restored")
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
