#!/usr/bin/env bash
# Builds the signed update feed (latest.json) for a release tag. Run it from the repository root.
#
#   scripts/update-feed.sh v0.2.1 [--zip PATH] [--notes FILE] [--out PATH]
#   scripts/update-feed.sh genkey
#
# <tag> is vMAJOR.MINOR.PATCH. The archive defaults to build/LoftLine-<tag>-macos-arm64.zip (the name release.yml gives it)
# and the feed is written to build/latest.json. The archive is signed with RSA-4096 / PKCS#1 v1.5 over its SHA-256
# (`openssl dgst -sha256 -sign key -binary < archive`), which is what UpdateSignature.verify checks.
#
# The private key never ships and is never printed. Locally it lives in ~/.config/loftline/update_sign.key (or the file named
# by UPDATE_SIGN_KEY_FILE). In CI the Actions secret UPDATE_SIGN_KEY holds its base64 and the feed job decodes it to a file.
# Adapted from rootkit-game's tools/update_feed.sh, with its own key: that key is never reused.
set -euo pipefail

REPO="seanperkins/loftline"
KEY="${UPDATE_SIGN_KEY_FILE:-$HOME/.config/loftline/update_sign.key}"

usage() {
  echo "usage: scripts/update-feed.sh <vX.Y.Z> [--zip PATH] [--notes FILE] [--out PATH] | genkey" >&2
  exit 1
}

# Makes the signing key if there is none (never replacing one) and prints the PUBLIC key only. The private key and anything
# derived from it stay out of the terminal, so a pasted log or a screen share cannot leak them.
genkey() {
  if [ -f "$KEY" ]; then
    echo "key already exists at $KEY — not overwriting" >&2
  else
    (umask 077 && mkdir -p "$(dirname "$KEY")" && openssl genrsa -out "$KEY" 4096 2>/dev/null)
    chmod 600 "$KEY"
    echo "private key written to $KEY (mode 600); it is not printed. Keep it out of the repository." >&2
    echo "CI secret, run by you: gh secret set UPDATE_SIGN_KEY -R $REPO < <(base64 -i \"$KEY\")" >&2
  fi
  echo "public key (PKCS#1) for packaging/updater/update-public-key.pub and Sources/UpdateCore/UpdatePublicKey.swift:" >&2
  openssl rsa -in "$KEY" -RSAPublicKey_out 2>/dev/null
}

TAG="${1:-}"
[ -n "$TAG" ] || usage
if [ "$TAG" = genkey ]; then
  genkey
  exit 0
fi
shift

ZIP="" NOTES="" OUT="build/latest.json"
while [ $# -gt 0 ]; do
  case "$1" in
    --zip) [ $# -ge 2 ] || usage; ZIP="$2"; shift 2 ;;
    --notes) [ $# -ge 2 ] || usage; NOTES="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "the tag must look like v1.2.3, got '$TAG'" >&2; exit 1; }
ZIP="${ZIP:-build/LoftLine-$TAG-macos-arm64.zip}"
[ -f "$KEY" ] || { echo "missing signing key at $KEY — run scripts/update-feed.sh genkey" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "missing archive $ZIP" >&2; exit 1; }
[ -z "$NOTES" ] || [ -f "$NOTES" ] || { echo "missing notes file $NOTES" >&2; exit 1; }

# True when the posted programs or the golden fixtures differ between the previous tag and this one. With no previous tag
# there is nothing to compare against: false, and it says so.
gcode_changed() {
  local ref="$TAG" previous
  git rev-parse -q --verify "$TAG^{commit}" >/dev/null 2>&1 || ref=HEAD
  if ! previous="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$ref^" 2>/dev/null)"; then
    echo "no previous tag before $TAG: gcodeChanged is false" >&2
    return 1
  fi
  if git diff --quiet "$previous" "$ref" -- samples/expected Tests/Fixtures/golden; then
    return 1
  fi
  return 0
}
if gcode_changed; then CHANGED=true; else CHANGED=false; fi

# The newest release, up to this one, whose posted programs or golden fixtures differ from the release before it (its version,
# or nothing when none ever did). `gcode_changed` alone misses a skipped release: someone going from 0.2.0 straight to 0.2.3
# passes a change made in 0.2.1 even though 0.2.3 itself is clean. Releases are ordered by version, not by name or date.
gcode_changed_in() {
  local tags=() t i previous current
  while IFS= read -r t; do
    tags+=("$t")
    [ "$t" = "$TAG" ] && break
  done < <(git tag --list 'v[0-9]*' --sort=version:refname 2>/dev/null)
  # This release may not be tagged yet (a local run): then it is HEAD, after every tag there is.
  if [ "${#tags[@]}" -eq 0 ] || [ "${tags[${#tags[@]}-1]}" != "$TAG" ]; then tags+=("$TAG"); fi
  for (( i = ${#tags[@]} - 1; i >= 1; i-- )); do
    previous="${tags[i-1]}" current="${tags[i]}"
    git rev-parse -q --verify "$current^{commit}" >/dev/null 2>&1 || current=HEAD
    if ! git diff --quiet "$previous" "$current" -- samples/expected Tests/Fixtures/golden 2>/dev/null; then
      echo "${tags[i]#v}"
      return 0
    fi
  done
}
GCODE_IN="$(gcode_changed_in)"

SIGNATURE="$(openssl dgst -sha256 -sign "$KEY" -binary < "$ZIP" | openssl base64 -A)"

python3 - "$TAG" "$ZIP" "$SIGNATURE" "$CHANGED" "$NOTES" "$OUT" "$REPO" "$GCODE_IN" <<'PY'
import hashlib, json, os, sys

tag, zip_path, signature, changed, notes_path, out, repo, changed_in = sys.argv[1:]
version = tag[1:]
asset = f"LoftLine-{tag}-macos-arm64.zip"

digest = hashlib.sha256()
with open(zip_path, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        digest.update(chunk)

notes = ""
if notes_path:
    with open(notes_path, encoding="utf-8", errors="replace") as f:
        notes = f.read()[:4000]

manifest = {
    "version": version,
    "entries": {
        "macos-arm64": {
            "version": version,
            # Per tag, never /latest/: the entry must keep working after a newer release takes the "latest" redirect.
            "url": f"https://github.com/{repo}/releases/download/{tag}/{asset}",
            "sha256": digest.hexdigest(),
            "sig": signature,
            "gcodeChanged": changed == "true",
            "notes": notes,
        }
    },
}
if changed_in:
    manifest["entries"]["macos-arm64"]["gcodeChangedIn"] = changed_in
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
with open(out, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=1)
print(f"wrote {out}: macos-arm64 {version}, gcodeChanged={changed}, gcodeChangedIn={changed_in or 'none'}")
PY
