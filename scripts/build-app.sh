#!/bin/sh
# Build a release binary, wrap it in dist/Dictate.app, and sign it.
#
# Signing identity: set DICTATE_SIGN_IDENTITY to the name of a self-signed
# code-signing certificate in your login keychain (Keychain Access > Certificate
# Assistant > Create a Certificate, type "Code Signing"). A stable identity keeps
# the Accessibility and Microphone grants across rebuilds. Without one, the
# script falls back to ad-hoc signing and macOS will re-prompt after every build.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
IDENTITY="${DICTATE_SIGN_IDENTITY:-dictate-dev}"
APP="$ROOT/dist/Dictate.app"

swift build -c release 2>&1 | tail -1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp ".build/release/dictate" "$APP/Contents/MacOS/dictate"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
# CTranscribe ships as a dynamic framework inside the xcframework; bundle it.
cp -R "Vendor/TranscribeCpp.xcframework/macos-arm64_x86_64/CTranscribe.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/dictate" 2>/dev/null || true

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/CTranscribe.framework"
  codesign --force --sign "$IDENTITY" --identifier cc.stanleywang.dictate "$APP"
  echo "signed with $IDENTITY"
else
  codesign --force --sign - "$APP/Contents/Frameworks/CTranscribe.framework"
  codesign --force --sign - --identifier cc.stanleywang.dictate "$APP"
  echo "ad-hoc signed (no '$IDENTITY' certificate found; TCC grants will not survive rebuilds)"
fi
codesign --verify --verbose=1 "$APP"
echo "built $APP"
