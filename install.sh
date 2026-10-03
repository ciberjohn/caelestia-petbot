#!/usr/bin/env bash
# PetBot ("Bloop") - install as a Caelestia Shell user plugin.
# Idempotent; re-run after a `git pull` to update. Restart the shell afterwards:
#   systemctl --user restart caelestia-shell.service
set -euo pipefail

SRC="$(cd "$(dirname "$0")/plugins/petbot" && pwd)"
DST="$HOME/.config/caelestia/plugins/petbot"

mkdir -p "$DST"
for f in metadata.json main.qml pin-on.wav pin-off.wav msg-pop-left.wav msg-pop-right.wav; do
    install -m 0644 "$SRC/$f" "$DST/$f"
    echo "installed $DST/$f"
done

echo
echo "Done. Restart the shell to meet Bloop:"
echo "  systemctl --user restart caelestia-shell.service"
echo "(or toggle PetBot off and on in Nexus -> Settings -> Plugins)"
