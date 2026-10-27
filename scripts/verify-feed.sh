#!/usr/bin/env bash
# Checks a release's update feed the way a client will, with openssl instead of Security.framework. Exit 0 only if
#   1. the macos-arm64 entry of the feed names the SHA-256 of the archive, AND
#   2. its signature (RSA-4096, PKCS#1 v1.5 over the archive's SHA-256) verifies against the public key.
# The release workflow runs this on files it has just DOWNLOADED from the draft release, so what is checked is what the app
# will fetch; only then is the release published.
#
# Usage: scripts/verify-feed.sh <latest.json> <archive.zip> <public-key-pkcs1.pem>
#        (the key is a PKCS#1 "RSA PUBLIC KEY", the form packaging/updater/update-public-key.pub is in)
set -euo pipefail

fail() { echo "verify-feed: $*" >&2; exit 1; }

[ $# -eq 3 ] || fail "usage: scripts/verify-feed.sh <latest.json> <archive.zip> <public-key-pkcs1.pem>"
FEED=$1 ARCHIVE=$2 PUBKEY=$3
for file in "$FEED" "$ARCHIVE" "$PUBKEY"; do
  [ -f "$file" ] || fail "no such file: $file"
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The manifest's digest and signature, checked for shape, and the archive's own digest.
python3 - "$FEED" "$ARCHIVE" "$WORK" <<'PY'
import base64, hashlib, json, re, sys

feed, archive, work = sys.argv[1:]

def fail(message):
    print(f"verify-feed: {message}", file=sys.stderr)
    sys.exit(1)

try:
    with open(feed, encoding="utf-8") as f:
        entry = json.load(f)["entries"]["macos-arm64"]
    expected = entry["sha256"]
    signature = base64.b64decode(entry["sig"], validate=True)
    version = entry["version"]
except Exception as error:
    fail(f"the feed has no readable macos-arm64 entry ({type(error).__name__})")

if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
    fail("the feed's sha256 is not 64 lowercase hex characters")
if len(signature) != 512:
    fail(f"the feed's signature is {len(signature)} bytes, not the 512 of an RSA-4096 signature")

digest = hashlib.sha256()
with open(archive, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        digest.update(chunk)
actual = digest.hexdigest()
if actual != expected:
    fail(f"sha256 mismatch: the feed says {expected}, the archive is {actual}")

with open(f"{work}/signature", "wb") as f:
    f.write(signature)
with open(f"{work}/version", "w") as f:
    f.write(str(version))
PY

openssl rsa -RSAPublicKey_in -pubout -in "$PUBKEY" -out "$WORK/public.pem" 2>/dev/null || fail "the public key is not a PKCS#1 RSA public key: $PUBKEY"
result="$(openssl dgst -sha256 -verify "$WORK/public.pem" -signature "$WORK/signature" "$ARCHIVE" 2>&1 || true)"
[[ "$result" == *"Verified OK"* ]] || fail "the signature does not verify against $PUBKEY"

echo "feed verified: macos-arm64 $(cat "$WORK/version"): sha256 matches and the signature verifies"
