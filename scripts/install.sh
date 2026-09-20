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
pkill -f "$DEST/Contents/MacOS/dictate" 2>/dev/null || true
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
if [ -f "$PLIST" ]; then
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "installed $DEST and loaded $LABEL"
else
  echo "installed $DEST (no launchd plist at $PLIST; start with: open $DEST)"
fi
