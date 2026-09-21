#!/usr/bin/env bash
#
# Assembles Casa.app from the SwiftPM executable.
#
# There is no Xcode on this machine, only Command Line Tools, so there is no
# xcodebuild and no .xcodeproj. SwiftPM produces the binary; this script wraps
# it in the bundle layout Launch Services needs in order to treat it as an app
# that can own a document type.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Casa.app"

cd "$ROOT"
echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Casa"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

echo "==> assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Casa"

# --- version stamping -------------------------------------------------------
# One source of truth for the marketing version; the build number is the commit
# count, which is monotonic, reproducible from any checkout, and needs no state
# of its own.
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
echo "==> stamping $VERSION ($BUILD)"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The icon is drawn procedurally rather than committed as a binary master, so
# generate it on demand the first time it is needed.
if [ ! -f "$ROOT/Resources/Casa.icns" ]; then
    echo "==> generating icon"
    "$ROOT/Scripts/make-icon.sh" >/dev/null
fi
cp "$ROOT/Resources/Casa.icns" "$APP/Contents/Resources/Casa.icns"

# Ad-hoc signature. Unsigned bundles are refused outright by recent macOS when
# launched from Finder; ad-hoc is enough for local use and for Launch Services
# to register the document types.
echo "==> codesign (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/    /'

# Tell Launch Services the bundle exists, so "Open With" lists it without a
# logout. Harmless if it has already been registered.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" || true

echo "==> built $APP"
du -sh "$APP" | sed 's/^/    /'
