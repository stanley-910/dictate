#!/bin/sh
# Download the Cohere Transcribe GGUF used by dictate into the models dir.
# Source: https://huggingface.co/handy-computer/cohere-transcribe-03-2026-gguf
# Usage: fetch-model.sh [q8|q4]
set -eu
QUANT="${1:-q8}"
REPO="handy-computer/cohere-transcribe-03-2026-gguf"
REV="dfa4adebb64f3076b7b6b90b721275cc069cb421"
case "$QUANT" in
  q8) FILE="cohere-transcribe-03-2026-Q8_0.gguf"
      SHA="931916663432fd895423a4291a8400221802b288967ca2d435fc5e3141c9e71e" ;;
  q4) FILE="cohere-transcribe-03-2026-Q4_K_M.gguf"
      SHA="" ;;
  *) echo "unknown quant: $QUANT (q8|q4)" >&2; exit 2 ;;
esac
DIR="${DICTATE_MODEL_DIR:-$HOME/.local/share/dictate/models}"
mkdir -p "$DIR"
DEST="$DIR/$FILE"
URL="https://huggingface.co/$REPO/resolve/$REV/$FILE"
if [ -f "$DEST" ] && [ -n "$SHA" ]; then
  if [ "$(shasum -a 256 "$DEST" | cut -d' ' -f1)" = "$SHA" ]; then
    echo "already present: $DEST"; exit 0
  fi
fi
echo "fetching $URL"
curl -fL -C - --progress-bar -o "$DEST.part" "$URL"
if [ -n "$SHA" ]; then
  actual="$(shasum -a 256 "$DEST.part" | cut -d' ' -f1)"
  if [ "$actual" != "$SHA" ]; then echo "checksum mismatch: $actual" >&2; exit 1; fi
fi
mv "$DEST.part" "$DEST"
echo "ok: $DEST"
