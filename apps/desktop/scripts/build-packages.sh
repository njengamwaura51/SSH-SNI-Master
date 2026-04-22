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

cat <<'EOF'

==> Runtime requirements
  .deb (Ubuntu/Debian):
    Declares bash, python3 (>=3.8), openssl, curl, dnsutils as Depends —
    apt resolves them automatically. The postinst symlinks the binary to
    /usr/local/bin/sni-hunter-desktop.

  AppImage:
    Bundles the bash hunter script + V2Ray client snippets; the host must
    provide bash, python3 (>=3.8), openssl and curl. On a stock Ubuntu
    22.04+ desktop these are present by default. Bundling a static
    python3 inside the AppImage is intentionally deferred (it more than
    doubles the AppImage size and conflicts with system PEP-668 venvs).
    To embed it anyway, drop a python-build-standalone tarball at
    src-tauri/bin/python3-${triple}/ before running this script and Tauri
    will include it automatically.
EOF
