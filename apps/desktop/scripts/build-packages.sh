#!/usr/bin/env bash
# One-command build: produces both an AppImage and a .deb under
# src-tauri/target/release/bundle/{appimage,deb}. Requires:
#   - Rust toolchain (rustup default stable)
#   - pnpm
#   - System libs: libwebkit2gtk-4.1-dev libssl-dev libayatana-appindicator3-dev
#                  librsvg2-dev libgtk-3-dev pkg-config
#   - For AppImage: linuxdeploy (downloaded automatically by tauri bundler)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v cargo >/dev/null 2>&1; then
  echo "Rust toolchain not found. Install via: https://rustup.rs/" >&2
  exit 1
fi
if ! command -v pnpm >/dev/null 2>&1; then
  echo "pnpm not found. Install via: npm i -g pnpm" >&2
  exit 1
fi

pnpm install --frozen-lockfile=false
pnpm prepare-sidecar
pnpm tauri:build

echo
echo "==> Built packages:"
find src-tauri/target/release/bundle -maxdepth 3 \
  \( -name '*.AppImage' -o -name '*.deb' \) -print
