#!/bin/bash
# build.sh — compile the cua helpers and install symlinks into ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O -o bin/cua src/cua.swift
swiftc -O -o bin/cua-overlay src/cua-overlay.swift
swiftc -O -o bin/cua-guide src/cua-guide.swift
chmod +x bin/cua-shot

mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/bin/cua" "$HOME/.local/bin/cua"
ln -sf "$PWD/bin/cua-shot" "$HOME/.local/bin/cua-shot"
ln -sf "$PWD/bin/cua-overlay" "$HOME/.local/bin/cua-overlay"
ln -sf "$PWD/bin/cua-guide" "$HOME/.local/bin/cua-guide"

echo "built bin/cua + bin/cua-overlay + bin/cua-guide; linked into ~/.local/bin"
cua info
