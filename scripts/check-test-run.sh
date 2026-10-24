#!/bin/zsh
# Decides from a test log whether the run passed, without reading any exit code (AGENTS.md: judge a run by its result
# lines). scripts/test.sh prints one "Test run with N tests [in S suites] passed|failed ..." line per test target (the
# suite clause depends on the Swift Testing version: Xcode 16.4 omits it). The run counts only if there is at least one
# such line, every line says "passed", the N values add up to at least <min-tests> (a run that silently executed far
# fewer tests fails), and, when <expected-result-lines> is given, exactly that many target lines printed. The count
# catches what the total cannot: a small target that printed nothing still leaves the total above the minimum.
# Usage: scripts/check-test-run.sh <logfile> <min-tests> [<expected-result-lines>]
set -euo pipefail

fail() { print -u2 -r -- "check-test-run: $*"; exit 1 }

(( $# == 2 || $# == 3 )) || fail "usage: scripts/check-test-run.sh <logfile> <min-tests> [<expected-result-lines>]"
log=$1
min=$2
expected_lines=${3:-}
[[ -f $log ]] || fail "no such log: $log"
[[ $min == <-> ]] || fail "min-tests must be a whole number, got '$min'"
if [[ $# == 3 ]]; then
  [[ $expected_lines == <-> && $expected_lines != 0 ]] || fail "expected-result-lines must be a positive whole number, got '$expected_lines'"
fi

total=0
count=0
while IFS= read -r line; do
  [[ -n $line ]] || continue
  if [[ $line =~ 'Test run with ([0-9]+) tests? (in [0-9]+ suites? )?(passed|failed)' ]]; then
    [[ $match[3] == passed ]] || fail "a test target failed: $line"
    total=$(( total + match[1] ))
    count=$(( count + 1 ))
  else
    fail "cannot read this result line: $line"
  fi
done < <(grep -E 'Test run with' -- "$log" || true)

(( count > 0 )) || fail "no result line (\"Test run with N tests ... passed\") in $log"
(( total >= min )) || fail "only $total tests ran across $count result lines, fewer than the minimum $min"
if [[ -n $expected_lines ]]; then
  (( count == expected_lines )) || fail "expected $expected_lines result lines (one per test target), found $count"
fi
print -r -- "ok: $total tests passed across $count result lines (minimum $min)"
