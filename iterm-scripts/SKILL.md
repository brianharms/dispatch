---
name: focus-color
description: Toggle iTerm2 focus tab coloring on or off. Usage: /focus-color
---

Toggle the iTerm2 focus-tab-color feature on or off (takes effect immediately, no restart needed).

The script always runs via AutoLaunch, but checks for `~/.claude/focus_color_enabled` to decide whether to apply colors.

## Steps

1. Check if the file `~/.claude/focus_color_enabled` exists.
2. If it EXISTS (feature is currently ON):
   - Delete it: `rm ~/.claude/focus_color_enabled`
   - Tell the user: "Focus tab coloring is now **OFF**."
3. If it does NOT exist (feature is currently OFF):
   - Create it: `touch ~/.claude/focus_color_enabled`
   - Tell the user: "Focus tab coloring is now **ON**."
4. Remind the user: the change takes effect on the next tab switch.
