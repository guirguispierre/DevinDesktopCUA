#!/bin/bash
# build.sh — compile the cua helpers and install symlinks into ~/.local/bin
set -euo pipefail
cd "$(dirname "$0")"

swiftc -O -o bin/cua src/cua.swift
swiftc -O -o bin/cua-overlay src/cua-overlay.swift
chmod +x bin/cua-shot

mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/bin/cua" "$HOME/.local/bin/cua"
ln -sf "$PWD/bin/cua-shot" "$HOME/.local/bin/cua-shot"
ln -sf "$PWD/bin/cua-overlay" "$HOME/.local/bin/cua-overlay"

echo "built bin/cua + bin/cua-overlay; linked cua, cua-shot, cua-overlay into ~/.local/bin"
cua info
