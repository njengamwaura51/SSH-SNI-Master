#!/bin/sh
# Remove the /usr/local/bin symlink installed by deb-postinst.sh so apt purge
# leaves no broken links behind.
set -e
DST=/usr/local/bin/sni-hunter-desktop
if [ -L "$DST" ]; then
  rm -f "$DST"
fi
exit 0
