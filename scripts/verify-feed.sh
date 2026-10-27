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
import base64, hashlib, json, os, re, sys

feed, archive, work = sys.argv[1:]

# The client's contract (UpdateCore/UpdateManifest.swift). A feed a client refuses must never be published: no installed app
# could update from it. The prefix is the same string as UpdateManifest.urlPrefix, and a test keeps the two equal.
PREFIX = "https://github.com/seanperkins/loftline/releases/download/"
VERSION = re.compile(r"[0-9][0-9A-Za-z.+-]{0,31}")

def fail(message):
    print(f"verify-feed: {message}", file=sys.stderr)
    sys.exit(1)

def newer(a, b):
    """True when version a is newer than b: dot-separated numbers, a suffix after - or + ignored."""
    def parts(v):
        return [int(re.match(r"[0-9]*", p).group() or 0) for p in re.split(r"[-+]", v)[0].split(".")]
    x, y = parts(a), parts(b)
    n = max(len(x), len(y))
    return x + [0] * (n - len(x)) > y + [0] * (n - len(y))

if os.path.getsize(feed) > 256 * 1024:
    fail("the feed is too large (the client refuses a document over 256 KiB)")

try:
    with open(feed, encoding="utf-8") as f:
        entry = json.load(f)["entries"]["macos-arm64"]
    expected = entry["sha256"]
    signature = base64.b64decode(entry["sig"], validate=True)
except Exception as error:
    fail(f"the feed has no readable macos-arm64 entry ({type(error).__name__})")

version = entry.get("version")
if not isinstance(version, str) or not VERSION.fullmatch(version):
    fail("the feed's version is not a version number")
name = os.path.basename(archive)
if name != f"LoftLine-v{version}-macos-arm64.zip":
    fail(f"the feed's version {version} does not match the archive name {name}")
if entry.get("url") != f"{PREFIX}v{version}/{name}":
    fail(f"the feed's url is not the download URL of {name}: {entry.get('url')!r}")
if not isinstance(entry.get("notes", ""), str) or len(entry.get("notes", "")) > 4000:
    fail("the feed's notes are not a string of at most 4000 characters")
if "gcodeChanged" in entry and not isinstance(entry["gcodeChanged"], bool):
    fail("the feed's gcodeChanged is not true or false")
if "gcodeChangedIn" in entry:
    changed_in = entry["gcodeChangedIn"]
    if not isinstance(changed_in, str) or not VERSION.fullmatch(changed_in) or newer(changed_in, version):
        fail("the feed's gcodeChangedIn is not a version up to this release")

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
