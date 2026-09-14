#!/bin/bash
# DevinDesktopCUA installer — gives Devin CLI eyes + hands on your Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/guirguispierre/DevinDesktopCUA/main/install.sh | bash
#
# or from a clone:  ./install.sh            (build + install)
#                   ./install.sh --uninstall
set -euo pipefail

REPO="https://github.com/guirguispierre/DevinDesktopCUA"
TARBALL="$REPO/archive/refs/heads/main.tar.gz"
DEST="${CUA_INSTALL_DIR:-$HOME/.local/share/cua}"   # binaries, source, shots
BIN_DIR="${CUA_BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="$HOME/.config/devin/skills/computer-use"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------- uninstall ----------
if [[ "${1:-}" == "--uninstall" ]]; then
    say "Uninstalling DevinDesktopCUA…"
    "$BIN_DIR/cua" overlay off 2>/dev/null || true
    rm -f "$BIN_DIR/cua" "$BIN_DIR/cua-shot" "$BIN_DIR/cua-overlay"
    rm -rf "$SKILL_DIR"
    rm -rf "$DEST"
    say "Removed binaries, skill, and $DEST"
    exit 0
fi

# ---------- preflight ----------
[[ "$(uname)" == "Darwin" ]] || die "macOS only (this is $(uname))"

if ! command -v swiftc >/dev/null 2>&1; then
    warn "swiftc not found — installing Xcode Command Line Tools…"
    warn "A dialog will appear; click Install, then re-run this script."
    xcode-select --install 2>/dev/null || true
    exit 1
fi

mkdir -p "$DEST" "$BIN_DIR" "$SKILL_DIR"

# ---------- get source ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null || true)"
if [[ -n "${SCRIPT_DIR:-}" && -f "$SCRIPT_DIR/src/cua.swift" ]]; then
    SRC_DIR="$SCRIPT_DIR"           # running inside a clone
else
    say "Downloading source…"
    TMP="$(mktemp -d)"
    curl -fsSL "$TARBALL" | tar -xz -C "$TMP"
    SRC_DIR="$(echo "$TMP"/DevinDesktopCUA-*)"
fi

# ---------- build ----------
say "Compiling (swiftc -O)…"
mkdir -p "$DEST/bin"
swiftc -O -o "$DEST/bin/cua"         "$SRC_DIR/src/cua.swift"
swiftc -O -o "$DEST/bin/cua-overlay" "$SRC_DIR/src/cua-overlay.swift"
cp "$SRC_DIR/bin/cua-shot" "$DEST/bin/cua-shot"
chmod +x "$DEST/bin/cua" "$DEST/bin/cua-overlay" "$DEST/bin/cua-shot"

ln -sf "$DEST/bin/cua"         "$BIN_DIR/cua"
ln -sf "$DEST/bin/cua-shot"    "$BIN_DIR/cua-shot"
ln -sf "$DEST/bin/cua-overlay" "$BIN_DIR/cua-overlay"

# keep the source around for reference/rebuilds
mkdir -p "$DEST/src"
cp "$SRC_DIR"/src/*.swift "$DEST/src/" 2>/dev/null || true

# ---------- skill ----------
cp "$SRC_DIR/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
say "Installed skill → $SKILL_DIR/SKILL.md"

# ---------- PATH check ----------
if ! command -v cua >/dev/null 2>&1; then
    warn "~/.local/bin is not on your PATH — add:  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ---------- permissions ----------
cat <<'EOF'

┌─ One-time macOS permissions ──────────────────────────────────────────┐
│ System Settings will open twice. In each pane, enable your agent app │
│ (e.g. "Devin" — the app that runs the agent, not this terminal):     │
│                                                                      │
│   1. Privacy & Security → Screen & System Audio Recording            │
│   2. Privacy & Security → Accessibility                              │
│                                                                      │
│ You may need to restart the agent app after granting Screen          │
│ Recording.                                                           │
└──────────────────────────────────────────────────────────────────────┘
EOF
read -r -p "Open the settings panes now? [Y/n] " ans </dev/tty 2>/dev/null || ans="y"
if [[ "${ans:-y}" != "n" && "${ans:-y}" != "N" ]]; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture" || true
    sleep 1
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
fi

# ---------- verify ----------
say "Running cua doctor…"
"$BIN_DIR/cua" doctor || true

cat <<'EOF'

Done. Try it:
    cua doctor              # re-check permissions anytime
    cua shot                # screenshot (gridded) of the display under cursor
    cua overlay on          # Devin's purple ring cursor
    cua click 500 500       # click a point (global coords)
EOF
