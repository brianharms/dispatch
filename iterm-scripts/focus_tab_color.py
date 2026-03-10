#!/usr/bin/env python3
"""
iTerm2 Focus Window Color
Colors the focused window's active tab medium blue; restores the original
color when the window loses focus. Works across separate iTerm2 windows.

Snapshots the tab's color immediately before applying blue each time,
so dynamic color changes (e.g. from Claude hooks) are preserved.

Toggle at runtime by creating/removing ~/.claude/focus_color_enabled.
When the file is missing, the script idles (and restores the current window).
"""

import os
import iterm2

# The color applied to the focused window's tab
FOCUS_COLOR = iterm2.Color(40, 80, 180)

ENABLED_FILE = os.path.expanduser("~/.claude/focus_color_enabled")

# Stores each window's active tab's pre-focus color: window_id -> (tab_id, use_tab_color, tab_color)
pre_focus_colors = {}


def is_enabled():
    return os.path.exists(ENABLED_FILE)


async def get_active_session(window):
    """Get the active session for a window (current tab's current session)."""
    if window and window.current_tab and window.current_tab.current_session:
        return window.current_tab.current_session
    return None


async def snapshot_and_apply_focus(window):
    """Read the window's active tab color, save it, then apply focus blue."""
    session = await get_active_session(window)
    if session is None:
        return
    tab_id = session.tab.tab_id if session.tab else None
    if tab_id is None:
        return
    profile = await session.async_get_profile()
    pre_focus_colors[window.window_id] = (
        tab_id,
        profile.use_tab_color,
        profile.tab_color,
    )
    change = iterm2.LocalWriteOnlyProfile()
    change.set_use_tab_color(True)
    change.set_tab_color(FOCUS_COLOR)
    await session.async_set_profile_properties(change)


async def restore_color(app, window_id):
    """Restore a window's tab to whatever color it had before focus."""
    saved = pre_focus_colors.pop(window_id, None)
    if saved is None:
        return
    tab_id, use_color, color = saved
    tab = app.get_tab_by_id(tab_id)
    if tab and tab.current_session:
        change = iterm2.LocalWriteOnlyProfile()
        change.set_use_tab_color(use_color)
        if color is not None:
            change.set_tab_color(color)
        await tab.current_session.async_set_profile_properties(change)


async def main(connection):
    app = await iterm2.async_get_app(connection)
    last_focused_window_id = None
    was_enabled = False

    async with iterm2.FocusMonitor(connection) as monitor:
        while True:
            enabled = is_enabled()

            # Just toggled OFF — restore the currently focused window and clear state
            if was_enabled and not enabled:
                if last_focused_window_id is not None:
                    await restore_color(app, last_focused_window_id)
                last_focused_window_id = None
                pre_focus_colors.clear()

            # Just toggled ON — color the current window
            if not was_enabled and enabled:
                if app.current_terminal_window:
                    window = app.current_terminal_window
                    await snapshot_and_apply_focus(window)
                    last_focused_window_id = window.window_id

            was_enabled = enabled

            update = await monitor.async_get_next_update()

            if not enabled:
                continue

            # Window became key (focused)
            if update.window_changed:
                wc = update.window_changed
                if wc.event == iterm2.FocusUpdateWindowChanged.Reason.TERMINAL_WINDOW_BECAME_KEY:
                    new_window_id = wc.window_id
                    if new_window_id != last_focused_window_id:
                        # Restore old window
                        if last_focused_window_id is not None:
                            await restore_color(app, last_focused_window_id)
                        # Snapshot and color new window
                        window = app.get_window_by_id(new_window_id)
                        if window:
                            await snapshot_and_apply_focus(window)
                        last_focused_window_id = new_window_id


iterm2.run_forever(main)
