#!/usr/bin/env bash
#
# Regenerates the test corpus used by `--selftest` and `--bench`.
#
# Everything here is synthesized from files macOS already ships, so the corpus
# is reproducible on any Mac and nothing large is committed to the repo.
#
#   Scripts/make-corpus.sh [out-dir]      # default: build/corpus
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/corpus}"
TOOLS="$ROOT/build/corpus-tools"
BIG="$OUT/../corpus-large"

rm -rf "$OUT" "$BIG"
mkdir -p "$OUT" "$BIG" "$TOOLS"

# A large, real, high-resolution source: a system wallpaper. 6016 x 6016 HEIC,
# ~25 MB, and crucially it has NO embedded thumbnail — which is what exposed
# the missing rung in the decode ladder (finding 2 in the performance log).
SRC="$(find /System/Library/Desktop\ Pictures -maxdepth 1 -name '*.heic' 2>/dev/null | sort | head -1)"
[ -n "$SRC" ] || { echo "no system wallpaper found; pass your own source image" >&2; exit 1; }
echo "source: $SRC"

echo "==> compiling corpus tools"
for tool in WriteStills WriteAnimations WriteVideo; do
    swiftc -O "$ROOT/Scripts/CorpusTools/$tool.swift" -o "$TOOLS/$tool" 2>/dev/null
done

echo "==> stills (every ImageIO-writable type)"
"$TOOLS/WriteStills" "$SRC" "$OUT"

echo "==> sips conversions (a second, independent encoder)"
cp "$SRC" "$OUT/sample.heic"
for format in jpeg png tiff gif bmp jp2 psd tga pdf; do
    sips -s format "$format" --resampleWidth 900 "$SRC" --out "$OUT/sample.$format" >/dev/null 2>&1 \
        && echo "   sample.$format" || echo "   (skipped $format)"
done

echo "==> animations"
"$TOOLS/WriteAnimations" "$OUT"

echo "==> video"
"$TOOLS/WriteVideo" "$OUT/sample_video.mov"
"$TOOLS/WriteVideo" "$OUT/sample_video2.mp4"

echo "==> vector"
cat > "$OUT/sample.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240" width="240" height="240">
  <rect width="240" height="240" fill="#14171b"/>
  <circle cx="120" cy="120" r="70" fill="#e8743b"/>
  <text x="120" y="212" font-family="Helvetica" font-size="22" fill="#eee" text-anchor="middle">SVG</text>
</svg>
SVG

echo "==> adversarial fixtures (expected to be REJECTED, not decoded)"
: > "$OUT/bad_empty.jpg"                          # zero bytes, photo extension
: > "$OUT/bad_zero_bytes.dds"                     # zero bytes, exotic extension
head -c 600 "$OUT/sample.jpeg" > "$OUT/bad_truncated.jpg"   # valid header, cut mid-scan
head -c 4096 /dev/urandom > "$OUT/bad_random.png"           # noise wearing a .png name

echo "==> identity fixtures"
cp "$OUT/sample.jpeg" "$OUT/mislabelled.png"      # JPEG bytes, PNG name: content must win
cp "$OUT/sample.jpeg" "$OUT/noextension_jpeg"     # no extension: open-only, not listed

echo "==> large folder for navigation benchmarks"
i=1
find /System/Library/Desktop\ Pictures -maxdepth 1 -name '*.heic' 2>/dev/null | sort | head -12 | while read -r f; do
    cp "$f" "$BIG/IMG_$i.heic"; i=$((i + 1))
done
sips -s format jpeg "$SRC" --out "$BIG/tmp.jpg" >/dev/null 2>&1
sips --resampleWidth 9000 "$BIG/tmp.jpg" --out "$BIG/IMG_huge_9000px.jpg" >/dev/null 2>&1
sips --resampleWidth 120 "$SRC" -s format png --out "$BIG/IMG_tiny_120px.png" >/dev/null 2>&1
rm -f "$BIG/tmp.jpg"

echo
echo "corpus:       $OUT        ($(ls "$OUT" | wc -l | tr -d ' ') files)"
echo "large folder: $BIG  ($(ls "$BIG" | wc -l | tr -d ' ') files)"
echo
echo "next:  build/Casa.app/Contents/MacOS/Casa --selftest $OUT"
