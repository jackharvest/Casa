#!/usr/bin/env bash
#
# Generates the release signing keypair and embeds the public half in the app.
#
# Run this ONCE. The private key lands in private/ (gitignored) and must be
# backed up somewhere safe — if it is lost, every installed copy of Casa will
# reject all future updates until users reinstall by hand.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="$ROOT/private/casa-update.key"
SOURCE="$ROOT/Sources/Casa/Update/UpdateSecurity.swift"

mkdir -p "$ROOT/private"
chmod 700 "$ROOT/private"

if [ -f "$KEY" ]; then
    echo "A signing key already exists at $KEY" >&2
    echo "Delete it deliberately if you really mean to rotate keys — every" >&2
    echo "installed copy of Casa will reject updates signed by the new one." >&2
    exit 1
fi

mkdir -p "$ROOT/build/update-tools"
swiftc -O "$ROOT/Scripts/UpdateTools/KeyGen.swift" -o "$ROOT/build/update-tools/KeyGen"
PUBLIC="$("$ROOT/build/update-tools/KeyGen" "$KEY")"

# Embed the public half so the shipped app can verify signatures.
python3 - "$SOURCE" "$PUBLIC" <<'PY'
import sys, pathlib, re
source, public = pathlib.Path(sys.argv[1]), sys.argv[2]
text = source.read_text()
text = re.sub(r'(static let publicKeyBase64 = ")[^"]*(")', r'\g<1>' + public + r'\g<2>', text)
source.write_text(text)
PY

echo
echo "public key embedded: $PUBLIC"
echo "private key:         $KEY  (chmod 600, gitignored)"
echo
echo "BACK UP THE PRIVATE KEY NOW. Without it you cannot ship updates."
