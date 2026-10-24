#!/bin/zsh
# Decides from a test log whether the run passed, without reading any exit code (AGENTS.md: judge a run by its result
# lines). scripts/test.sh prints one "Test run with N tests in S suites passed|failed ..." line per test target. The run
# counts only if there is at least one such line, every line says "passed", and the N values add up to at least
# <min-tests>, so a run that silently executed far fewer tests (a target that did not build or start) fails too.
# Usage: scripts/check-test-run.sh <logfile> <min-tests>
set -euo pipefail

fail() { print -u2 -r -- "check-test-run: $*"; exit 1 }

(( $# == 2 )) || fail "usage: scripts/check-test-run.sh <logfile> <min-tests>"
log=$1
min=$2
[[ -f $log ]] || fail "no such log: $log"
[[ $min == <-> ]] || fail "min-tests must be a whole number, got '$min'"

total=0
count=0
while IFS= read -r line; do
  [[ -n $line ]] || continue
  if [[ $line =~ 'Test run with ([0-9]+) tests? in [0-9]+ suites? (passed|failed)' ]]; then
    [[ $match[2] == passed ]] || fail "a test target failed: $line"
    total=$(( total + match[1] ))
    count=$(( count + 1 ))
  else
    fail "cannot read this result line: $line"
  fi
done < <(grep -E 'Test run with' -- "$log" || true)

(( count > 0 )) || fail "no result line (\"Test run with N tests ... passed\") in $log"
(( total >= min )) || fail "only $total tests ran across $count result lines, fewer than the minimum $min"
print -r -- "ok: $total tests passed across $count result lines (minimum $min)"
