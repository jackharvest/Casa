#!/usr/bin/env bash
#
# Cuts a release: builds, packages, signs, tags, and publishes to GitHub.
#
#   Scripts/release.sh                     # uses VERSION, notes from git log
#   Scripts/release.sh --notes NOTES.md    # notes from a file
#   Scripts/release.sh --dry-run           # build and sign, publish nothing
#
# The app's updater will only install an archive whose SHA-256 digest is signed
# by private/casa-update.key, so releasing without that key produces something
# every installed copy will correctly refuse.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="$ROOT/private/casa-update.key"
DIST="$ROOT/build/dist"
TOOLS="$ROOT/build/update-tools"

DRY_RUN=0
NOTES_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --notes)   NOTES_FILE="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
TAG="v$VERSION"
echo "==> releasing $TAG"

# --- preflight --------------------------------------------------------------
[ -f "$KEY" ] || { echo "no signing key at $KEY — run Scripts/keygen.sh" >&2; exit 1; }

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "working tree is dirty. Commit before releasing so the tag means something." >&2
    git -C "$ROOT" status --short >&2
    exit 1
fi

if git -C "$ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "tag $TAG already exists. Bump VERSION first." >&2
    exit 1
fi

# --- build ------------------------------------------------------------------
"$ROOT/Scripts/build-app.sh" release

STAMPED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
            "$ROOT/build/Casa.app/Contents/Info.plist")"
[ "$STAMPED" = "$VERSION" ] || { echo "built $STAMPED but releasing $VERSION" >&2; exit 1; }

# --- package ----------------------------------------------------------------
rm -rf "$DIST"; mkdir -p "$DIST"
ARCHIVE="$DIST/Casa-$VERSION.zip"

echo "==> packaging"
# `ditto -c -k --keepParent` is the only archiver that reliably preserves the
# bundle's code signature and extended attributes. `zip` strips both, and the
# updater then refuses the result.
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/Casa.app" "$ARCHIVE"

# --- sign -------------------------------------------------------------------
echo "==> signing"
mkdir -p "$TOOLS"
swiftc -O "$ROOT/Scripts/UpdateTools/Sign.swift" -o "$TOOLS/Sign" 2>/dev/null
SIGNED="$("$TOOLS/Sign" "$KEY" "$ARCHIVE")"
DIGEST="$(echo "$SIGNED" | sed -n 1p)"
SIGNATURE="$(echo "$SIGNED" | sed -n 2p)"

printf '%s\n' "$DIGEST" > "$ARCHIVE.sha256"
printf '%s\n' "$SIGNATURE" > "$ARCHIVE.sig"

SIZE="$(du -h "$ARCHIVE" | cut -f1 | tr -d ' ')"
echo "    archive   $(basename "$ARCHIVE")  ($SIZE)"
echo "    sha256    $DIGEST"
echo "    signature ${SIGNATURE:0:24}…"

# --- notes ------------------------------------------------------------------
NOTES="$DIST/notes.md"
if [ -n "$NOTES_FILE" ]; then
    cp "$NOTES_FILE" "$NOTES"
else
    PREVIOUS="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || true)"
    {
        if [ -n "$PREVIOUS" ]; then
            echo "## Changes since $PREVIOUS"
            echo
            git -C "$ROOT" log --no-merges --pretty='- %s' "$PREVIOUS..HEAD"
        else
            echo "## First release"
            echo
            echo "- A fast, chromeless photo viewer for macOS"
        fi
        echo
        echo "---"
        echo
        echo "Casa verifies this download against an Ed25519 signature before"
        echo "installing, so an update can only come from the author."
    } > "$NOTES"
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "dry run — nothing published. Artifacts in $DIST"
    exit 0
fi

# --- publish ----------------------------------------------------------------
echo "==> tagging"
git -C "$ROOT" tag -a "$TAG" -m "Casa $VERSION"
git -C "$ROOT" push origin "$TAG"

echo "==> publishing"
gh release create "$TAG" \
    --repo "$(/usr/libexec/PlistBuddy -c 'Print :CasaUpdateRepository' "$ROOT/build/Casa.app/Contents/Info.plist")" \
    --title "Casa $VERSION" \
    --notes-file "$NOTES" \
    "$ARCHIVE" "$ARCHIVE.sha256" "$ARCHIVE.sig"

echo
echo "released $TAG"
