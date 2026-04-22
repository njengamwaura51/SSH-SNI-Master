#!/usr/bin/env bash
# Copy tools/sni-hunter.sh into apps/desktop/src-tauri/bin/ with the
# platform-suffixed names that Tauri's externalBin expects. The same script
# is bash and is portable across all linux targets, so we just symlink (or
# copy on systems where symlinks aren't honored by the bundler) into every
# triple this build host might produce.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SRC="$ROOT/tools/sni-hunter.sh"
DEST_DIR="$HERE/../src-tauri/bin"

if [ ! -f "$SRC" ]; then
  echo "[prepare-sidecar] tools/sni-hunter.sh not found at $SRC" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

# Detect the host triple Cargo will use. `rustc -vV` prints `host: ...`.
# Tolerate rustc being absent (set -e + pipefail would otherwise abort).
HOST_TRIPLE=""
if command -v rustc >/dev/null 2>&1; then
  HOST_TRIPLE="$(rustc -vV 2>/dev/null | awk '/^host:/ {print $2}' || true)"
fi
if [ -z "$HOST_TRIPLE" ]; then
  # Fallback to a sensible Linux x86_64 default; cross-compile users should
  # set the env var explicitly.
  HOST_TRIPLE="${TAURI_TARGET_TRIPLE:-x86_64-unknown-linux-gnu}"
  echo "[prepare-sidecar] rustc not found; defaulting to ${HOST_TRIPLE}" >&2
fi

# Always install the unsuffixed name (used by some plugin paths) plus the
# triple-suffixed name (used by tauri bundler).
install -m 0755 "$SRC" "$DEST_DIR/sni-hunter"
install -m 0755 "$SRC" "$DEST_DIR/sni-hunter-${HOST_TRIPLE}"

# Cover the most common Linux triples so a user can `tauri build --target X`
# without re-running this script. Cheap (file is tiny).
for t in \
  x86_64-unknown-linux-gnu \
  x86_64-unknown-linux-musl \
  aarch64-unknown-linux-gnu \
  aarch64-unknown-linux-musl
do
  install -m 0755 "$SRC" "$DEST_DIR/sni-hunter-${t}"
done

echo "[prepare-sidecar] installed sidecar for ${HOST_TRIPLE} (and 4 common linux triples)"
