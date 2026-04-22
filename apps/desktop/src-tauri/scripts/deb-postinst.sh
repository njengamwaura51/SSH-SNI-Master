#!/bin/sh
# Tauri's deb bundler installs the main binary at /usr/bin/sni-hunter-desktop.
# task-19 spec requires it also be reachable at /usr/local/bin/sni-hunter-desktop
# so power users who put /usr/local/bin first on PATH can still launch it.
# Use ln -sf so re-installs and upgrades stay idempotent.
set -e
SRC=/usr/bin/sni-hunter-desktop
DST=/usr/local/bin/sni-hunter-desktop
if [ -x "$SRC" ]; then
  mkdir -p /usr/local/bin
  ln -sf "$SRC" "$DST"
fi
exit 0
