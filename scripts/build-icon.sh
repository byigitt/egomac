#!/usr/bin/env bash
# Generates assets/AppIcon.icns from assets/icon-1024.png at all
# macOS-required resolutions, plus a 16/32/64 menu-bar template.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="assets/icon-1024.png"
ICONSET="assets/AppIcon.iconset"
ICNS="assets/AppIcon.icns"

if [[ ! -f "$SOURCE" ]]; then
    echo "▸ Re-rendering icon master… (output ${SOURCE})"
    python3 scripts/make-icon.py assets/cepte-original.png "$SOURCE"
fi

echo "▸ Building ${ICONSET}…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Standard macOS icon set sizes.
declare -a sizes=(16 32 64 128 256 512 1024)
declare -a doubles=(32 64 128 256 512 1024)

# Plain @1x sizes.
sips -z 16   16   "$SOURCE" --out "$ICONSET/icon_16x16.png"     >/dev/null
sips -z 32   32   "$SOURCE" --out "$ICONSET/icon_32x32.png"     >/dev/null
sips -z 128  128  "$SOURCE" --out "$ICONSET/icon_128x128.png"   >/dev/null
sips -z 256  256  "$SOURCE" --out "$ICONSET/icon_256x256.png"   >/dev/null
sips -z 512  512  "$SOURCE" --out "$ICONSET/icon_512x512.png"   >/dev/null

# @2x sizes.
sips -z 32   32   "$SOURCE" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 64   64   "$SOURCE" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 256  256  "$SOURCE" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 512  512  "$SOURCE" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
cp "$SOURCE" "$ICONSET/icon_512x512@2x.png"

echo "▸ Packing ${ICNS}…"
iconutil -c icns "$ICONSET" -o "$ICNS"

echo "✓ $ICNS ($(du -h "$ICNS" | cut -f1))"
