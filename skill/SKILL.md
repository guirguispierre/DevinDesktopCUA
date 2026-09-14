---
name: computer-use
description: See and control this Mac's screen — screenshots, mouse clicks/drags, typing, hotkeys, scrolling, window/app control. Use whenever a task requires real GUI interaction (clicking things, navigating apps, checking on-screen state).
triggers: [user, model]
permissions:
  allow:
    - Exec(cua-shot)
    - Exec(cua shot)
    - Exec(cua info)
    - Exec(cua pos)
    - Exec(cua windows)
    - Exec(screencapture)
    - Exec(sips)
    - Exec(pbpaste)
    - Exec(cua doctor)
    - Read(~/.local/share/cua/shots/**)
    - Write(~/.local/share/cua/shots/**)
  ask:
    - Exec(cua click)
    - Exec(cua rclick)
    - Exec(cua dclick)
    - Exec(cua move)
    - Exec(cua drag)
    - Exec(cua scroll)
    - Exec(cua type)
    - Exec(cua key)
    - Exec(cua hotkey)
    - Exec(cua do)
    - Exec(cua overlay)
    - Exec(osascript)
    - Exec(open)
    - Exec(pbcopy)
---

# Computer Use

You can see this Mac's screen and drive its mouse and keyboard. Everything runs
through `cua` and `cua-shot` (installed in `~/.local/bin`; source:
https://github.com/guirguispierre/DevinDesktopCUA). Screenshots land in
`~/.local/share/cua/shots`. If anything misbehaves, run `cua doctor`.

## The core loop

1. **Observe:** `cua shot` → prints JSON `{path, ...}` → `read` the PNG to see the screen.
2. **Act:** batch actions with `cua do` — one call runs a whole sequence.
3. **Verify:** `cua shot` again and `read` it — confirm the screen changed as expected before continuing.

Never chain blind actions on screen state you have not observed. If the result
of an action doesn't match what you expected, re-screenshot instead of
retrying; at most 2 retries, then stop and ask the user.

## Speed

- **Batch:** `cua do 'click 500 300' 'type hello' 'key return' 'shot'` runs all
  of it in one process — prefer one `do` per action batch over separate calls.
  `sleep <ms>` works inside `do` for UI settle time.
- **Shoot less:** only screenshot when you need new visual state. After typing
  into a field you already clicked, skip the shot and go straight to the next
  action; shoot once at the end of the batch.
- **Shoot smaller:** `cua shot -r x,y,w,h` (region in global points) is faster
  and easier to read than a full display for checking a specific area.
- `cua shot` ≈ 0.2s end-to-end. `cua-shot` still works as an alias.

## Devin's cursor

A purple ring marks your action points on screen (the `cua-overlay` daemon —
it auto-starts on the first input command). It fades out when the user moves
the real mouse. `cua overlay off` disables it; `cua overlay on` re-enables;
`cua overlay status` checks it.

## Coordinates — read carefully

- All `cua` coordinates are **global display points**: origin (0,0) = top-left
  of the main display, y grows downward; secondary displays can have negative
  x/y.
- `cua-shot`'s gridded image (`path`) has **gridlines every 100 global points
  labeled with the global coordinate** — the numbers ARE what you pass to
  `cua click`. Locate the target between two labeled lines, interpolate, and
  use those numbers directly. No pixel math needed.
- Example: a button sits ~40% between the `-1900` and `-1800` vertical lines,
  just below the `400` horizontal line → `cua click -1860 415`.
- The grid labels account for Retina scaling and display offsets for you.
- Displays can change at any time (lid close, monitor unplug). `cua info` is
  queried fresh by `cua-shot`, so stale indices fail cleanly — just re-shoot
  without `-d` or with the new index.

## Command reference

```
cua info                      displays as JSON (x,y,w,h,scale — Quartz points)
cua pos                       cursor position "x,y"
cua windows                   on-screen windows as JSON (id, app, title, bounds)

cua shot [-d N]               screenshot display N (default: display under cursor)
cua shot -r x,y,w,h           screenshot a region (global points)
cua shot -w WINID             screenshot one window (id from `cua windows`)
                              → JSON: path = gridded image (read this one),
                                clean_path = unobstructed capture
cua do '<cmd>' ['<cmd>' ...]  batch subcommands in one process
cua overlay on|off|status     the purple-ring Devin cursor

cua move <x> <y>              move cursor
cua click <x> <y>             left click
cua dclick <x> <y>            double click
cua rclick <x> <y>            right click
cua drag <x1> <y1> <x2> <y2>  left-button drag
cua scroll <x> <y> <dy> [dx]  scroll at point (dy>0 = down, dx>0 = right)
cua type <text>               type text (full Unicode; no shell quoting issues if you quote the arg)
cua key <name>                return, tab, space, esc, delete, fwddelete,
                              up/down/left/right, home, end, pgup, pgdn, f1-f12
cua hotkey <mods+key>         e.g. cmd+c, cmd+shift+4, cmd+space, cmd+opt+esc
```

macOS built-ins that pair well:

```
open -a "Safari"                       launch/focus an app
osascript -e 'tell application "Safari" to activate'
osascript -e 'tell application "System Events" to get name of every process whose background only is false'
osascript -e 'tell application "System Events" to tell process "Safari" to get {position, size} of window 1'
pbcopy < file ; cua hotkey cmd+v       paste long/awkward text via clipboard
screencapture -x -l <WINID> out.png    raw window capture (cua-shot -w preferred)
```

## Targeting strategy

Prefer semantic targeting over blind pixel clicks:

1. `cua windows` to find the app window and its bounds.
2. `osascript` System Events to query UI elements / press menus when the target
   is a standard control (e.g. `click menu item "New Tab" of menu "File" of
   menu bar 1`).
3. Pixel coordinates from a screenshot as the general fallback.

## Safety rules

- **Announce before acting:** briefly state what you're about to click/type
  before each batch so the user knows hands are off.
- **Hands off:** the user must not touch the mouse/keyboard while you act —
  tell them when a batch starts and ends.
- **Irreversible actions need explicit confirmation:** purchases, deletes,
  sends/posts/messages, form submissions, "Are you sure?" dialogs — stop and
  ask before executing, every time.
- **No secrets:** never type passwords, tokens, or anything from `.env`,
  keychains, or credential stores. If a password field is needed, ask the user
  to type it themselves.
- **Secure fields** (password prompts, some banking sites) silently reject
  synthetic events — this is a macOS limitation, not a bug.

## Troubleshooting

- Screenshot is wallpaper-only / `screencapture` errors → Devin lacks
  **Screen Recording**: run `cua guide screenrec` — it opens the pane and
  plays a drag-and-drop animation showing the user what to do (restart
  Devin required after).
- Input commands run without error but nothing happens → Devin lacks
  **Accessibility**: run `cua guide accessibility`.
- `osascript` control of another app may trigger a one-time **Automation**
  consent dialog — that's expected; tell the user to approve it.
