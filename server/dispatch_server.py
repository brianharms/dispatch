#!/usr/bin/env python3
"""Dispatch Server — control iTerm2 windows from iPhone."""

import fcntl
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
from http.server import HTTPServer, BaseHTTPRequestHandler, ThreadingHTTPServer

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TRANSCRIBE_BIN = os.path.join(SCRIPT_DIR, "transcribe")
DICTATION_HUD_BIN = os.path.join(SCRIPT_DIR, "dictation_hud")
DEBUG_LOG_FILE = os.path.join(SCRIPT_DIR, "dictation_debug.log")

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
_last_text_seq = 0
_dictation_tty = None       # TTY path for the active dictation overlay
_dictation_final_text = ""   # Accumulated text to commit on dictation end

# Serialize all /stream-text read-diff-apply-update blocks
_text_lock = threading.Lock()

# Recording state — tracks whether we're in a recording session
_recording_active = False

# Dictation HUD process
_hud_process = None

# Cached status response — updated by background thread, served instantly
_cached_status = {}
_cache_lock = threading.Lock()

# Serialize ALL AppleScript calls — prevents race conditions between
# background cache refresh and /cycle endpoint, which cause iTerm2 to
# return duplicate/missing window IDs during concurrent enumeration
_applescript_lock = threading.Lock()

# Gate for /cycle background rebuilds — at most 1 in-flight + 1 queued
_rebuild_pending = threading.Event()  # set = a rebuild is already queued/waiting
_rebuild_in_flight = threading.Event()  # set = a rebuild is currently running

# Long-poll state change notification (focus, move, resize)
_state_changed = threading.Condition()
_last_active_id = None
_last_layout_fingerprint = None


def _layout_fingerprint(layout_windows):
    """Hash of window positions/sizes — changes on move or resize."""
    parts = []
    for w in sorted(layout_windows, key=lambda w: w.get("id", "")):
        parts.append(f"{w.get('id')}:{w.get('x')},{w.get('y')},{w.get('width')},{w.get('height')}")
    return "|".join(parts)


def _notify_focus_change(new_active_id):
    """Signal /watch long-poll clients that focus changed."""
    global _last_active_id
    if new_active_id != _last_active_id:
        _last_active_id = new_active_id
        with _state_changed:
            _state_changed.notify_all()


def _notify_layout_change(layout_windows):
    """Signal /watch long-poll clients that layout changed (move/resize)."""
    global _last_layout_fingerprint
    fp = _layout_fingerprint(layout_windows)
    if fp != _last_layout_fingerprint:
        _last_layout_fingerprint = fp
        with _state_changed:
            _state_changed.notify_all()


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
                if wName is not "Script" and wName does not start with "Scripts/" then
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
    with _text_lock:
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


def get_tty_size(tty_path):
    """Get terminal dimensions (rows, cols) from a TTY path."""
    try:
        with open(tty_path) as fd:
            result = fcntl.ioctl(fd.fileno(), termios.TIOCGWINSZ, b'\x00' * 8)
            rows, cols = struct.unpack('hh', result[:4])
            return rows, cols
    except Exception:
        return 24, 80  # fallback


def write_dictation_overlay(tty_path, text):
    """Show live dictation text in iTerm2's status bar via SetUserVar.

    Sets the iTerm2 session variable `user.dictationText`. To surface it, add
    an "Interpolated String" status-bar component in iTerm2 referencing
    \\(user.dictationText) (Settings -> Profiles -> Session -> Status Bar).
    Scroll-proof - status bar is fixed UI chrome.
    """
    if not tty_path:
        return
    try:
        import base64
        safe_text = text.replace('\n', ' ')
        encoded = base64.b64encode(safe_text.encode("utf-8")).decode("ascii")
        seq = f"\033]1337;SetUserVar=dictationText={encoded}\a"
        with open(tty_path, "w") as f:
            f.write(seq)
    except Exception as e:
        print(f"  [overlay] Failed to write: {e}")


def clear_dictation_overlay(tty_path):
    """Clear the dictation status bar text by setting the variable to empty."""
    if not tty_path:
        return
    try:
        import base64
        encoded = base64.b64encode(b"").decode("ascii")
        seq = f"\033]1337;SetUserVar=dictationText={encoded}\a"
        with open(tty_path, "w") as f:
            f.write(seq)
    except Exception as e:
        print(f"  [overlay] Failed to clear: {e}")


# Debounce window after a /recording-stop during which we refuse to spawn a
# new HUD. Prevents a race where a /stream-text or /recording-start in flight
# at the moment of pause re-spawns the HUD just after we killed it, leaving
# a ghost "Listening..." HUD on screen. Reset by the next /recording-start
# that arrives AFTER the window expires.
_hud_stop_debounce_until = 0.0

# Last requested HUD anchor position. Cached so a /hud-position request that
# arrives before the HUD process is spawned isn't lost — show_dictation_hud()
# applies it right after spawning.
_pending_hud_position = None


def show_dictation_hud():
    """Spawn the floating HUD window for dictation."""
    global _hud_process
    if time.time() < _hud_stop_debounce_until:
        # We just stopped the HUD; don't let a stale request resurrect it.
        return
    close_dictation_hud()
    try:
        _hud_process = subprocess.Popen(
            [DICTATION_HUD_BIN],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        print(f"  [hud] Spawned PID {_hud_process.pid}")
        # If a /hud-position arrived before this spawn, apply it now.
        if _pending_hud_position is not None:
            try:
                x, y, w, h = _pending_hud_position
                line = f"__POS__:{x},{y},{w},{h}\n"
                _hud_process.stdin.write(line.encode('utf-8'))
                _hud_process.stdin.flush()
                print(f"  [hud] Applied pending anchor x={int(x)} y={int(y)} w={int(w)} h={int(h)}")
            except (BrokenPipeError, OSError) as e:
                print(f"  [hud] Pending position write failed: {e}")
    except Exception as e:
        print(f"  [hud] Failed to spawn: {e}")
        _hud_process = None


def update_dictation_hud(text):
    """Send updated text to the HUD via stdin."""
    global _hud_process
    if _hud_process and _hud_process.poll() is None:
        try:
            line = text.replace('\n', ' ') + '\n'
            _hud_process.stdin.write(line.encode('utf-8'))
            _hud_process.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            print(f"  [hud] Write failed: {e}")
            _hud_process = None


def position_dictation_hud(x, y, w, h):
    """Tell the HUD to anchor itself above the given screen rect.

    Coords are macOS Cocoa screen coords (origin = bottom-left of the
    primary screen). The HUD interprets `__POS__:x,y,w,h` lines as a
    reposition command rather than text content.

    The latest position is also cached in `_pending_hud_position` so a
    /hud-position request that arrives BEFORE the HUD has been spawned
    isn't lost — the spawn path applies the cached position right after
    starting the HUD.
    """
    global _hud_process, _pending_hud_position
    _pending_hud_position = (x, y, w, h)
    if _hud_process and _hud_process.poll() is None:
        try:
            line = f"__POS__:{x},{y},{w},{h}\n"
            _hud_process.stdin.write(line.encode('utf-8'))
            _hud_process.stdin.flush()
        except (BrokenPipeError, OSError) as e:
            print(f"  [hud] Position write failed: {e}")
            _hud_process = None


def close_dictation_hud():
    """Close the HUD by closing stdin (triggers fade-out)."""
    global _hud_process, _hud_stop_debounce_until
    # Set the debounce BEFORE we actually close, so any /recording-start
    # racing with us is rejected by show_dictation_hud's check.
    _hud_stop_debounce_until = time.time() + 0.6
    if _hud_process:
        try:
            _hud_process.stdin.close()
        except Exception:
            pass
        try:
            _hud_process.wait(timeout=2)
        except Exception:
            _hud_process.kill()
        _hud_process = None
        _hud_process = None


def flush_text_with_submit(text):
    """Atomically type `text` and submit it to the active iTerm2 session.

    Splits the write into TWO `write text` calls (text, then a raw CR) inside
    a SINGLE osascript invocation, with a small delay between them. The delay
    creates a pty read boundary between content bytes and the CR, which is
    required by Ink-based TUIs (Claude Code, etc.) — they buffer text+CR
    arriving in one read as a single chunk and never dispatch the submit.

    Held under `_applescript_lock` so this serializes against dispatch's other
    AppleScript calls (the 0.5s cache-refresh layout poll, /cycle, HUD ops).
    """
    escaped = text.replace('\\', '\\\\').replace('"', '\\"')
    script = f'''
    tell application "{TARGET_APP}"
        tell current session of current tab of current window
            write text "{escaped}" newline no
            delay 0.05
            write text (ASCII character 13) newline no
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
            print(f"  [error] flush_text_with_submit failed: {result.stderr.strip()}")
            return False
        return True
    except subprocess.TimeoutExpired:
        print("  [error] flush_text_with_submit timed out")
        return False


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


def kill_line_and_retype_iterm(text):
    """Clear the current line with Ctrl-U then type the full text.

    Builds a single string: Ctrl-U + text, sent as one write text call.
    Ctrl-U (ASCII 21) kills from cursor to start of line in most shells/CLIs.
    """
    escaped = text.replace('\\', '\\\\').replace('"', '\\"')
    script = f'''
    tell application "{TARGET_APP}"
        tell current session of current tab of current window
            write text ((ASCII character 21) & "{escaped}") newline no
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
            print(f"  [error] kill_line_and_retype failed: {result.stderr.strip()}")
            return False
        return True
    except subprocess.TimeoutExpired:
        print("  [error] kill_line_and_retype timed out")
        return False


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
            else if name of w is "Script" then
            else if name of w starts with "Scripts/" then
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
    elif layout_windows and state["window_ids"]:
        # Re-sort locked windows by current x-position (handles rearranges)
        id_to_pos = {str(w["id"]): (w["x"], w["y"]) for w in layout_windows}
        current_id = str(state["window_ids"][idx]) if idx < len(state["window_ids"]) else None
        paired = list(zip(state["window_ids"], state["window_names"]))
        paired.sort(key=lambda p: id_to_pos.get(str(p[0]), (0, 0)))
        new_ids = [p[0] for p in paired]
        new_names = [p[1] for p in paired]
        if new_ids != state["window_ids"]:
            state["window_ids"] = new_ids
            state["window_names"] = new_names
            # Preserve which window is active after re-sort
            if current_id:
                for i, wid in enumerate(new_ids):
                    if str(wid) == current_id:
                        state["current_index"] = i
                        idx = i
                        break
            print(f"  [re-sort] Window order updated to match spatial layout")

    # Detect if the user changed the active window on the Mac side.
    # Skip while a phone-initiated cycle is in-flight (AppleScript hasn't
    # confirmed yet), so Mac-side focus is stale and would snap us backward.
    cycle_cooldown = state.get("cycle_confirmed_seq", 0) < state.get("last_cycle_seq", 0)
    if total > 0 and layout_windows and not cycle_cooldown:
        actual_active_id = layout_windows[layout_active_index]["id"] if layout_active_index < len(layout_windows) else None
        if actual_active_id is not None:
            # Find this window in our locked list
            for i, wid in enumerate(state["window_ids"]):
                if str(wid) == str(actual_active_id) and i != idx:
                    print(f"  [sync] Active window changed on Mac: [{idx}] -> [{i}]")
                    state["current_index"] = i
                    idx = i
                    name = get_window_name(idx)
                    # Signal long-poll /watch clients
                    _notify_focus_change(str(actual_active_id))
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
        "last_cycle_seq": state.get("cycle_confirmed_seq", 0),
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
            # Check for layout changes (move/resize) and notify /watch clients
            if status.get("layout"):
                _notify_layout_change(status["layout"])
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

        elif self.path == "/watch":
            # Long-poll: block until state changes (focus, move, resize) or 30s timeout
            snapshot_id = _last_active_id
            snapshot_layout = _last_layout_fingerprint
            changed = False
            with _state_changed:
                _state_changed.wait(timeout=30)
                changed = (_last_active_id != snapshot_id or
                           _last_layout_fingerprint != snapshot_layout)

            if changed:
                print(f"  [watch] PUSH focus={_last_active_id != snapshot_id} layout={_last_layout_fingerprint != snapshot_layout}")
                with _cache_lock:
                    cached = dict(_cached_status) if _cached_status else {}
                idx = state["current_index"]
                active_id = str(state["window_ids"][idx]) if idx < len(state["window_ids"]) else ""
                active_name = state["window_names"][idx] if idx < len(state["window_names"]) else ""
                self.send_json({
                    "changed": True,
                    "current_index": idx,
                    "active_window_id": active_id,
                    "active_window": active_name,
                    "layout": cached.get("layout", []),
                    "screen": cached.get("screen", {}),
                })
            else:
                self.send_json({"changed": False})

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
        global current_typed_text, _dictation_final_text, _dictation_tty, _last_text_seq

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
            seq = body.get("seq", 0)
            state["last_cycle_seq"] = seq
            # (cycle_pending_until removed — seq-based guard handles cooldown now)
            total = len(state["window_ids"])

            if total == 0:
                self.send_json({"error": "no windows", "total": 0})
                return

            if direction == "next":
                state["current_index"] = (state["current_index"] + 1) % total
            else:
                state["current_index"] = (state["current_index"] - 1) % total

            idx = state["current_index"]
            active_id = str(state["window_ids"][idx])

            # Run AppleScript synchronously — only respond after window is confirmed active.
            name = activate_and_highlight(idx)
            state["cycle_confirmed_seq"] = max(state.get("cycle_confirmed_seq", 0), seq)

            confirmed_name = name or (state["window_names"][idx] if idx < len(state["window_names"]) else "?")
            print(f"  Cycled {direction} -> [{idx}] {confirmed_name} (confirmed)")

            # Build minimal response from cached data — no AppleScript calls.
            # Grab screen_size and layout windows from the last cache so the
            # phone has something to render immediately.
            with _cache_lock:
                cached = dict(_cached_status) if _cached_status else {}

            response = {
                "active_window_id": active_id,
                "current_index": idx,
                "active_window": confirmed_name,
                "last_cycle_seq": seq,
            }
            # Overlay cached layout data so the phone can update its minimap
            if cached:
                response["screen"] = cached.get("screen", {})
                response["layout"] = cached.get("layout", [])
                response["total"] = cached.get("total", len(state["window_ids"]))
                response["mode"] = state["mode"]

            # Send response IMMEDIATELY — phone gets it without waiting for cache rebuild
            self.send_json(response)

            # Trigger background cache rebuild so next poll picks up fresh data
            # Gate: at most 1 in-flight + 1 queued rebuild (prevents rapid-cycle pile-up)
            if not _rebuild_pending.is_set():
                _rebuild_pending.set()

                def _bg_cache_rebuild():
                    global _cached_status
                    # Wait for any in-flight rebuild to finish before starting
                    while _rebuild_in_flight.is_set():
                        _rebuild_in_flight.wait()
                    _rebuild_in_flight.set()
                    _rebuild_pending.clear()  # allow next cycle to queue another
                    try:
                        status = build_status()
                        with _cache_lock:
                            _cached_status = status
                    except Exception as e:
                        print(f"  [cache] post-cycle rebuild error: {e}")
                    finally:
                        _rebuild_in_flight.clear()

                threading.Thread(target=_bg_cache_rebuild, daemon=True).start()
            else:
                print(f"  [cache] rebuild already queued, skipping")

        elif self.path == "/stream-text":
            text = body.get("text", "")
            is_final = body.get("is_final", False)
            seq = body.get("seq", 0)

            with _text_lock:
                # Reject out-of-order arrivals
                if seq > 0 and seq <= _last_text_seq:
                    print(f"  [stream-text] REJECT seq={seq} <= last={_last_text_seq}")
                    self.send_json({"ok": False, "reason": "stale_seq"})
                    return
                if seq > 0:
                    _last_text_seq = seq

                # Update overlay — no typing into terminal during dictation
                _dictation_final_text = text
                write_dictation_overlay(_dictation_tty, text)
                update_dictation_hud(text)
                print(f"  Overlay: {repr(text[:60])}{'...' if len(text) > 60 else ''} seq={seq}")

            self.send_json({"ok": True, "is_final": is_final})

        elif self.path == "/type":
            text = body.get("text", "")
            enter = body.get("enter", False)
            # If Enter with no explicit text, commit accumulated dictation text
            if enter and not text and _dictation_final_text:
                commit_text = _dictation_final_text
                with _text_lock:
                    _dictation_final_text = ""
                    current_typed_text = ""
                type_text_iterm(commit_text, enter=True)
                print(f"  Commit dictation: {repr(commit_text[:60])} + Enter")
            elif text or enter:
                type_text_iterm(text, enter=enter)
                print(f"  Typed: {repr(text)} (enter={enter})")
            if enter:
                with _text_lock:
                    current_typed_text = ""
            self.send_json({"ok": True, "typed": text})

        elif self.path == "/hud-position":
            # Anchor the floating HUD above a given screen rect (Cocoa coords).
            # Used by /talk to follow the active iTerm window.
            try:
                x = float(body.get("x", 0))
                y = float(body.get("y", 0))
                w = float(body.get("w", 0))
                h = float(body.get("h", 0))
                position_dictation_hud(x, y, w, h)
                self.send_json({"ok": True})
            except Exception as e:
                self.send_json({"ok": False, "reason": str(e)})

        elif self.path == "/flush":
            # Atomic text + Enter into the active iTerm2 session, with a
            # read-boundary between them so TUIs (Claude Code) reliably submit.
            # Used by the /talk skill's voice-listener.
            text = body.get("text", "")
            if not text:
                self.send_json({"ok": False, "reason": "empty_text"})
            else:
                ok = flush_text_with_submit(text)
                with _text_lock:
                    current_typed_text = ""
                    _dictation_final_text = ""
                print(f"  Flushed: {repr(text[:80])} (ok={ok})")
                self.send_json({"ok": ok, "typed": text})

        elif self.path == "/escape":
            clear_dictation_overlay(_dictation_tty)
            close_dictation_hud()
            send_escape()
            with _text_lock:
                current_typed_text = ""
                _dictation_final_text = ""
            print("  Sent double-escape (dictation state reset, overlay cleared)")
            self.send_json({"ok": True})

        elif self.path == "/recording-start":
            with _text_lock:
                current_typed_text = ""  # Reset dictation tracking for new session
                _last_text_seq = 0  # Reset sequence for new recording session
                _dictation_final_text = ""  # Reset accumulated text
            # Capture TTY for overlay writes
            idx = state["current_index"]
            if 0 <= idx < len(state["window_ids"]):
                _dictation_tty = get_session_tty(state["window_ids"][idx])
            else:
                _dictation_tty = None
            # Clear debug log for fresh session
            try:
                with open(DEBUG_LOG_FILE, "w") as f:
                    f.write(f"[{time.strftime('%H:%M:%S')}] === NEW RECORDING SESSION ===\n")
            except Exception:
                pass
            set_recording_color(on=True)
            show_dictation_hud()
            print(f"  Recording started — overlay tty={_dictation_tty}")
            self.send_json({"ok": True})

        elif self.path == "/recording-stop":
            # Clear overlay and commit final text to terminal
            clear_dictation_overlay(_dictation_tty)
            close_dictation_hud()
            set_recording_color(on=False)
            print(f"  Recording stopped — overlay cleared")
            self.send_json({"ok": True})

        elif self.path == "/focus-push":
            # Called by focus_tab_color.py when a window gains focus on Mac
            window_id = body.get("window_id", "")
            if window_id:
                for i, wid in enumerate(state["window_ids"]):
                    if str(wid) == str(window_id) and i != state["current_index"]:
                        print(f"  [focus-push] Mac focus -> [{i}] id={window_id}")
                        state["current_index"] = i
                        _notify_focus_change(str(window_id))
                        break
            self.send_json({"ok": True})

        elif self.path == "/debug-log":
            msg = body.get("message", "")
            if msg:
                timestamp = time.strftime("%H:%M:%S", time.localtime())
                ms = int((time.time() % 1) * 1000)
                line = f"[{timestamp}.{ms:03d}] {msg}\n"
                try:
                    with open(DEBUG_LOG_FILE, "a") as f:
                        f.write(line)
                except Exception as e:
                    print(f"  [debug-log] write error: {e}")
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


def get_tailscale_self_ip():
    """Return this Mac's Tailscale IPv4 address, or None if not available."""
    try:
        result = subprocess.run(
            ['tailscale', 'ip', '-4'],
            capture_output=True, text=True, timeout=3
        )
        ip = result.stdout.strip().split('\n')[0]
        if ip and ip.startswith('100.'):
            return ip
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def choose_bind_ip():
    """Interactive picker for the bind address.

    Reads --bind / --lan / --localhost / --tailscale flags from sys.argv if
    provided; otherwise prompts the user to choose between LAN, localhost, or
    this Mac's Tailscale IP.
    """
    argv = sys.argv[1:]
    for i, a in enumerate(argv):
        if a == '--bind' and i + 1 < len(argv):
            return argv[i + 1]
        if a.startswith('--bind='):
            return a.split('=', 1)[1]
    if '--lan' in argv:
        return '0.0.0.0'
    if '--localhost' in argv:
        return '127.0.0.1'
    if '--tailscale' in argv:
        ts = get_tailscale_self_ip()
        if not ts:
            print("  [error] --tailscale requested but Tailscale is not running")
            sys.exit(1)
        return ts

    ts = get_tailscale_self_ip()
    options = [
        ('1', '127.0.0.1', 'localhost only (this Mac)'),
        ('2', '0.0.0.0', 'LAN (anyone on Wi-Fi)'),
    ]
    if ts:
        options.append(('3', ts, f'Tailscale only (this Mac\'s tailnet IP {ts})'))

    print("\n  Where should dispatch listen?")
    for key, ip, label in options:
        print(f"    [{key}] {label}")
    default = '3' if ts else '1'
    try:
        choice = input(f"  Choice [{default}]: ").strip() or default
    except EOFError:
        choice = default
    for key, ip, _ in options:
        if choice == key:
            return ip
    print(f"  Unknown choice {choice!r} — defaulting to {options[0][1]}")
    return options[0][1]


def main():
    hostname = socket.gethostname().replace('.local', '')
    lock_windows()

    bind_ip = choose_bind_ip()

    print(f"\n  Dispatch Server running on port {PORT}")
    print(f"  Bound to: {bind_ip}:{PORT}")
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

    server = ThreadingHTTPServer((bind_ip, PORT), DispatchHandler)
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
