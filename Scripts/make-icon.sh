#!/usr/bin/env bash
#
# Renders the app icon at every size macOS asks for and builds Casa.icns.
#
# The icon is drawn procedurally by Scripts/IconTools/MakeIcon.swift, so there
# is no binary master to keep in sync — change a parameter, re-run this, and
# every size follows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$ROOT/build/icon-tools/MakeIcon"
SET="$ROOT/build/Casa.iconset"
OUT="$ROOT/Resources/Casa.icns"

mkdir -p "$ROOT/build/icon-tools"
swiftc -O "$ROOT/Scripts/IconTools/MakeIcon.swift" -o "$TOOL"

rm -rf "$SET"; mkdir -p "$SET"

# The ten entries iconutil expects. 16pt through 512pt, each at 1x and 2x.
render() { "$TOOL" "$1" "$SET/$2" >/dev/null; }
render 16    icon_16x16.png
render 32    icon_16x16@2x.png
render 32    icon_32x32.png
render 64    icon_32x32@2x.png
render 128   icon_128x128.png
render 256   icon_128x128@2x.png
render 256   icon_256x256.png
render 512   icon_256x256@2x.png
render 512   icon_512x512.png
render 1024  icon_512x512@2x.png

iconutil -c icns "$SET" -o "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
