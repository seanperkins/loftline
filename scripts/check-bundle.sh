#!/bin/zsh
# Builds dist/LoftLine.app the ways the release does and checks what comes out: the version and channel in Info.plist,
# the update helper inside the bundle, the signature, and the Quick Look extension's sandbox entitlement (a
# `codesign --deep` regression would strip it). A real signing identity cannot be used here, so for that branch a stub
# `codesign` first on PATH records how bundle.sh calls it.
# Usage: scripts/check-bundle.sh     (release builds; the first run takes a few minutes)
set -euo pipefail
cd "${0:A:h}/.."

fail() { print -u2 -r -- "check-bundle: FAIL: $*"; exit 1 }

APP=dist/LoftLine.app
plist() { plutil -extract "$1" raw -o - "$APP/Contents/Info.plist" }
expect() { [[ "$2" == "$3" ]] || fail "$1: expected '$3', got '$2'" }

mkdir -p .tmp
work="$(mktemp -d .tmp/check-bundle.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# bundle NAME=VALUE...: runs scripts/bundle.sh with those variables and none of the caller's own.
bundle() {
  env -u LOFTLINE_VERSION -u LOFTLINE_CHANNEL -u LOFTLINE_SIGN_IDENTITY -u LOFTLINE_NO_QL_EXTENSION "$@" scripts/bundle.sh
}
built() {
  bundle "$@" > "$work/bundle.log" 2>&1 || { tail -20 "$work/bundle.log" >&2; fail "bundle.sh failed with: $*" }
}
refused() {
  if bundle "$@" > "$work/refused.log" 2>&1; then fail "bundle.sh accepted: $*"; fi
}

# Refusals come first and cost nothing: they must stop before any build.
refused LOFTLINE_CHANNEL=release
grep -q LOFTLINE_VERSION "$work/refused.log" || fail "a release without a version should name LOFTLINE_VERSION"
refused LOFTLINE_CHANNEL=release LOFTLINE_VERSION=v0.2.0
refused LOFTLINE_CHANNEL=bogus
grep -q LOFTLINE_CHANNEL "$work/refused.log" || fail "an unknown channel should name LOFTLINE_CHANNEL"
refused LOFTLINE_VERSION=0.2

# A real identity: the extension is signed first with its own entitlements, then the app, both hardened and
# timestamped, and nothing is signed with --deep.
mkdir -p "$work/bin"
cat > "$work/bin/codesign" <<'STUB'
#!/bin/sh
echo "$@" >> "$CODESIGN_LOG"
STUB
chmod +x "$work/bin/codesign"
identity="Developer ID Application: Test (ABCDE12345)"
built PATH="$work/bin:$PATH" CODESIGN_LOG="$work/codesign.log" \
  LOFTLINE_VERSION=0.2.0 LOFTLINE_CHANNEL=rehearsal "LOFTLINE_SIGN_IDENTITY=$identity"
expect "rehearsal channel" "$(plist LoftLineChannel)" rehearsal
signs=("${(@f)$(< "$work/codesign.log")}")
(( ${#signs} == 2 )) || fail "expected two codesign calls (extension, app), got ${#signs}"
[[ "$signs[1]" == *LoftLineThumbnail.appex ]] || fail "the extension must be signed first: $signs[1]"
[[ "$signs[1]" == *"--entitlements Extensions/QuickLookThumbnail/LoftLineThumbnail.entitlements"* ]] || fail "the extension needs its entitlements: $signs[1]"
[[ "$signs[2]" == *"$APP" ]] || fail "the app must be signed second: $signs[2]"
for call in $signs; do
  [[ "$call" == *"--options runtime"* && "$call" == *"--timestamp"* ]] || fail "hardened runtime and a timestamp are required: $call"
  [[ "$call" == *"--sign $identity"* ]] || fail "the identity is not used: $call"
  [[ "$call" != *"--deep"* ]] || fail "--deep re-signs the extension without its entitlements: $call"
done

built
expect "dev version" "$(plist CFBundleShortVersionString)" 0.0.0
expect "dev channel" "$(plist LoftLineChannel)" dev
[[ "$(plist CFBundleVersion)" == dev-* ]] || fail "a dev build's CFBundleVersion should start with dev-, got $(plist CFBundleVersion)"

built LOFTLINE_VERSION=0.2.0 LOFTLINE_CHANNEL=release
expect "release version" "$(plist CFBundleShortVersionString)" 0.2.0
expect "release build number" "$(plist CFBundleVersion)" 0.2.0
expect "release channel" "$(plist LoftLineChannel)" release

# The last bundle is a real ad-hoc one.
helper="$APP/Contents/Resources/updater.sh"
[[ -x "$helper" ]] || fail "$helper is missing or not executable"
cmp -s "$helper" packaging/updater/macos.sh || fail "$helper differs from packaging/updater/macos.sh"
codesign --verify --deep --strict "$APP" || fail "the bundle does not verify"
entitlements="$(codesign -d --entitlements - "$APP/Contents/PlugIns/LoftLineThumbnail.appex" 2>&1)"
[[ "$entitlements" == *com.apple.security.app-sandbox* ]] || fail "the Quick Look extension lost its sandbox entitlement"

print "bundle checks passed"
