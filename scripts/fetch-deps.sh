#!/bin/sh
# Download the prebuilt transcribe.cpp xcframework (Metal embedded) into Vendor/.
set -eu
VERSION="${TRANSCRIBE_CPP_VERSION:-v0.4.1}"
CHECKSUM="fb5646e564036a6c49659e3efcf72eb567af20da31b8569045c9a08181d35126"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/Vendor/TranscribeCpp.xcframework.zip"
URL="https://github.com/handy-computer/transcribe.cpp/releases/download/$VERSION/TranscribeCpp.xcframework.zip"
if [ -d "$ROOT/Vendor/TranscribeCpp.xcframework" ]; then
  echo "xcframework already present"; exit 0
fi
echo "fetching $URL"
curl -fL --progress-bar -o "$ZIP" "$URL"
actual="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
if [ "$actual" != "$CHECKSUM" ]; then
  echo "checksum mismatch: $actual" >&2; exit 1
fi
(cd "$ROOT/Vendor" && unzip -qo TranscribeCpp.xcframework.zip && rm TranscribeCpp.xcframework.zip)
echo "ok"
