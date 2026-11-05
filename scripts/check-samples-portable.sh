#!/bin/bash
# The Linux check of scripts/check-samples.sh (zsh and the Mac): posts every sample with every built-in post and compares each
# program, byte for byte, with the one the Mac committed. It never rewrites samples/expected: a difference here is a bug or a
# line in docs/PLATFORMS.md. Run through scripts/linux.sh:
#   scripts/linux.sh scripts/check-samples-portable.sh
set -euo pipefail
scratch=${LOFTLINE_SCRATCH:-.build-linux}
swift build --scratch-path "$scratch" --product loftline-cli >&2
cli="$(swift build --scratch-path "$scratch" --show-bin-path)/loftline-cli"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0 count=0
ids="$("$cli" posts --builtin-only | cut -f1)"
[[ -n "$ids" ]] || { echo "FAIL: no posts" >&2; exit 1; }
for id in $ids; do
  for sample in samples/*.loftline; do
    name="$(basename "$sample" .loftline)"
    want="$(ls samples/expected/"$id"/"$name".* 2>/dev/null | head -1 || true)"
    [[ -n "$want" ]] || { echo "FAIL: no committed program for $id/$name" >&2; fail=1; continue; }
    if ! "$cli" export "$sample" --post "$id" --builtin-only --quiet --out - > "$work/out" 2> "$work/err"; then
      echo "FAIL: $id/$name did not post: $(head -2 "$work/err")" >&2; fail=1; continue
    fi
    count=$((count + 1))
    if ! cmp -s "$work/out" "$want"; then
      echo "DIFF: $id/$name" >&2
      diff "$want" "$work/out" | head -8 >&2 || true
      fail=1
    fi
  done
done
[[ $fail -eq 0 ]] || { echo "samples/expected differs on $(uname -sm)" >&2; exit 1; }
echo "samples/expected matches on $(uname -sm): $count programs"
