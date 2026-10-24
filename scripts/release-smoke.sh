#!/bin/zsh
# Smoke test for a built LoftLine.app: runs the BUNDLED executable (the signed, hardened, notarised one) headless on the
# sample sign with the generic GRBL post and requires the program to be byte-identical to the committed golden. The
# separately built loftline-cli that check-samples.sh uses is not the signed binary and proves nothing about the hardened
# runtime; LoftLine and loftline-cli share main.swift, which handles `export` before any window system starts, so this
# exercises the same code path.
# Usage: scripts/release-smoke.sh <LoftLine.app>
#   LOFTLINE_SMOKE_EXPECTED_DIR  folder holding the golden sign.nc (default samples/expected/generic-grbl-mm); tests only
set -euo pipefail

fail() { print -u2 -r -- "release-smoke: $*"; exit 1 }

(( $# == 1 )) || fail "usage: scripts/release-smoke.sh <LoftLine.app>"
# Resolved before the cd below, so a relative path means what the caller meant.
app="${1:A}"
expected_dir="${LOFTLINE_SMOKE_EXPECTED_DIR:+${LOFTLINE_SMOKE_EXPECTED_DIR:A}}"
cd "${0:A:h}/.."
exe="$app/Contents/MacOS/LoftLine"
expected="${expected_dir:-samples/expected/generic-grbl-mm}/sign.nc"
[[ -x $exe ]] || fail "no executable at $exe"
[[ -f $expected ]] || fail "no golden program at $expected"

mkdir -p .tmp
work="$(mktemp -d .tmp/release-smoke.XXXXXX)"
trap 'rm -rf "$work"' EXIT

# --builtin-only: the posts and machines of whoever runs this must not change the result.
"$exe" export samples/sign.loftline --post generic-grbl-mm --builtin-only --out "$work" --quiet \
  || fail "the bundled executable could not post samples/sign.loftline"
[[ -f $work/sign.nc ]] || fail "the bundled executable wrote no sign.nc"
cmp -s "$work/sign.nc" "$expected" \
  || fail "the program from the bundled executable differs from $expected (did the hardened runtime change the output?)"
print -r -- "release smoke passed: the bundled executable posts samples/sign.loftline byte for byte"
