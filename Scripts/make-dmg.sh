#!/usr/bin/env bash
#
# Builds the drag-and-drop disk image.
#
#   Scripts/make-dmg.sh          # -> build/dist/Casa-<version>.dmg
#
# A DMG is what people expect to download for a Mac app: mount it, drag the app
# into the Applications alias, eject. A bare .zip leaves them to work out where
# the app is supposed to live.
#
# NOTE: arranging the window needs to drive Finder via AppleScript, which means
# whatever runs this script needs Automation permission for Finder. It is a
# one-time prompt on the machine that cuts releases; it does not affect anyone
# downloading the result.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
APP="$ROOT/build/Casa.app"
DIST="$ROOT/build/dist"
STAGE="$ROOT/build/dmg-stage"
VOLUME="Casa $VERSION"
DMG="$DIST/Casa-$VERSION.dmg"
TEMP_DMG="$ROOT/build/casa-rw.dmg"

WINDOW_W=620
WINDOW_H=420
ICON_SIZE=112

[ -d "$APP" ] || { echo "no app at $APP — run Scripts/build-app.sh first" >&2; exit 1; }

echo "==> staging"
rm -rf "$STAGE" "$TEMP_DMG"; mkdir -p "$STAGE" "$DIST"
ditto "$APP" "$STAGE/Casa.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$STAGE/.background"
mkdir -p "$ROOT/build/icon-tools"
swiftc -O "$ROOT/Scripts/IconTools/MakeDMGBackground.swift" -o "$ROOT/build/icon-tools/MakeDMGBackground"
"$ROOT/build/icon-tools/MakeDMGBackground" "$WINDOW_W" "$WINDOW_H" "$STAGE/.background/background.png"

echo "==> creating read-write image"
# Sized from the payload with generous slack; hdiutil fails outright if the
# filesystem ends up too small for the .DS_Store Finder is about to write.
SIZE_KB=$(( $(du -sk "$STAGE" | cut -f1) + 20000 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" -format UDRW -size "${SIZE_KB}k" "$TEMP_DMG" >/dev/null

echo "==> arranging"
DEVICE="$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep -E '^/dev/' | head -1 | awk '{print $1}')"
MOUNT="/Volumes/$VOLUME"
# Give the volume a moment to appear before Finder is told about it.
for _ in $(seq 1 40); do [ -d "$MOUNT" ] && break; sleep 0.25; done

osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        -- AppleScript bounds are {left, top, right, bottom}, NOT
        -- {x, y, width, height}. Passing the size directly makes a window far
        -- too small for the background, and the icon positions then land
        -- outside it.
        set the bounds of container window to {200, 160, 200 + ${WINDOW_W}, 160 + ${WINDOW_H}}
        set options to the icon view options of container window
        set arrangement of options to not arranged
        set icon size of options to $ICON_SIZE
        set background picture of options to file ".background:background.png"
        set position of item "Casa.app" of container window to {160, 195}
        set position of item "Applications" of container window to {458, 195}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
APPLESCRIPT

# Make the layout readable by everyone who mounts it, not just the author.
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$DEVICE" >/dev/null

echo "==> compressing"
rm -f "$DMG"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TEMP_DMG"
rm -rf "$STAGE"

echo "wrote $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
