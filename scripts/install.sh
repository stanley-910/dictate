#!/bin/sh
# Copy dist/Dictate.app to ~/Applications and (re)load the launchd agent.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/Dictate.app"
DEST="$HOME/Applications/Dictate.app"
LABEL="cc.stanleywang.dictate"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
[ "${1:-}" = "--no-build" ] || "$ROOT/scripts/build-app.sh"
[ -d "$SRC" ] || { echo "missing $SRC" >&2; exit 1; }
mkdir -p "$HOME/Applications"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# Exact match: only the daemon, never a `dictate listen` another app is running.
pkill -fx "$DEST/Contents/MacOS/dictate" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
if [ -f "$PLIST" ]; then
  # bootout returns before the old job is gone; bootstrap fails with EIO
  # ("Input/output error") until it is, so retry for a few seconds.
  tries=0
  until launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 10 ] || { launchctl bootstrap "gui/$(id -u)" "$PLIST"; exit 1; }
    sleep 0.5
  done
  echo "installed $DEST and loaded $LABEL"
else
  echo "installed $DEST (no launchd plist at $PLIST; start with: open $DEST)"
fi
