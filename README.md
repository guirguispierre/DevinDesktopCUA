# DevinDesktopCUA — computer use for Devin on macOS

Give [Devin](https://devin.ai) eyes and hands on your Mac: it can see the
screen, click, type, scroll, press hotkeys, and manage windows — with a
purple ring cursor so you can watch it work. No third-party dependencies:
three small Swift binaries + a Devin skill.

```
Devin ──exec──► cua shot ──► PNG ──► Devin `read` (vision)
  │                                     │
  └──exec──► cua do 'click …' 'type …' ◄── grid labels = global coords
              └──► cua-overlay: purple ring marks every action
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/guirguispierre/DevinDesktopCUA/main/install.sh | bash
```

The installer will:

1. Compile `cua` + `cua-overlay` into `~/.local/share/cua/bin` and symlink
   `cua`, `cua-shot`, `cua-overlay` into `~/.local/bin`.
2. Install the `computer-use` skill to `~/.config/devin/skills/` so Devin
   automatically picks up the workflow in every project.
3. Run a **guided permission walkthrough** — an on-screen animation shows
   you dragging your agent app into each settings list — then `cua doctor`
   verifies the grants.

### Required permissions (one-time, granted to Devin.app)

| Permission | Needed for |
|---|---|
| Screen & System Audio Recording | `cua shot`, window titles |
| Accessibility | all `cua` input commands |

If the agent app isn't listed, use `+` and add `/Applications/Devin.app`.
Restart Devin after granting Screen Recording. Run `cua doctor` anytime to
re-check, and `cua guide screenrec` / `cua guide accessibility` to replay
the guided animation.

> **Heads up:** this gives an AI agent real mouse/keyboard control. Devin's
> skill permissions prompt you before input actions by default
> (`cua click`/`type`/`do` ask; `cua shot`/`info` are free) and the skill
> requires confirmation before irreversible actions (sends, deletes,
> purchases).

## What Devin can do

```
cua info        displays as JSON            cua shot [-d N]       display N
cua pos         cursor "x,y"                cua shot -r x,y,w,h   region
cua windows     windows as JSON             cua shot -w WINID     one window

cua move x y            cua scroll x y dy [dx]      (dy>0 = down)
cua click / rclick      cua type "text"             (full Unicode)
cua dclick              cua key return|esc|tab|arrows|f1-f12|…
cua drag x1 y1 x2 y2    cua hotkey cmd+c | cmd+shift+4 | cmd+space

cua do 'c1' 'c2' …      batch a whole sequence in one process
cua overlay on|off|status   purple ring cursor (auto-starts on first action)
cua doctor              self-check permissions + setup
cua guide screenrec|accessibility   replay the permission animation
```

### How coordinates work

`cua shot` returns a gridded PNG plus JSON. **The grid labels are global click
coordinates** — read a target's position straight off the image and pass it to
`cua click`; Retina scaling and multi-monitor offsets are already handled.
Images are sized to the agent's vision render width for 1:1 reading.

## For developers

```bash
git clone https://github.com/guirguispierre/DevinDesktopCUA
cd DevinDesktopCUA && ./build.sh    # builds src/*.swift into bin/, symlinks
```

- `src/cua.swift` — CGEvent input, CGDisplay geometry, CGWindowList windows,
  ScreenCaptureKit capture, grid overlay, unix-socket overlay notifications.
- `src/cua-overlay.swift` — borderless click-through always-on-top ring;
  fades when the human moves the real mouse.
- `src/cua-guide.swift` — guided drag-and-drop animation for the two
  permission panes; auto-exits when the grant lands.
- `bin/cua-shot` — compat wrapper for `cua shot`.
- `skill/SKILL.md` — the Devin skill (installed globally by install.sh).
- Uninstall: `./install.sh --uninstall`.

## Limitations

- Foreground only — drives the real cursor; hands off while it acts.
- Secure input fields (passwords) reject synthetic events — by macOS design.
- macOS 14+ recommended (ScreenCaptureKit `SCScreenshotManager`).

## Roadmap

- MCP server wrapper (`mcp__computer__*` tools)
- Background control via `CGEventPostToPid` (drive a window without focus steal)

## License

MIT
