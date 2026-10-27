#!/usr/bin/env bash
# Runs a command and, if it fails, tries it again: for steps that talk to a service that sometimes drops the connection
# (Apple's notary and ticket servers; the v0.2.0 release run died when `stapler validate` lost its link to CloudKit, after the
# build had been Accepted). The wait grows with each attempt: <seconds>, then twice that, then three times.
#
# Usage: scripts/retry.sh <attempts> <seconds> <command> [arguments...]
#
# After the last attempt the command's own exit status is returned, so the caller still sees why it failed. Arguments are passed
# through untouched. LOFTLINE_RETRY_SLEEP replaces `sleep` (tests).
set -u

usage() {
  echo "usage: scripts/retry.sh <attempts> <seconds> <command> [arguments...]  (attempts at least 1; seconds a whole number)" >&2
  exit 2
}

[ $# -ge 3 ] || usage
attempts=$1
seconds=$2
shift 2
case "$attempts" in ''|*[!0123456789]*) usage ;; esac
case "$seconds" in ''|*[!0123456789]*) usage ;; esac
[ "$attempts" -ge 1 ] || usage

attempt=1
while true; do
  "$@" && exit 0
  status=$?
  if [ "$attempt" -ge "$attempts" ]; then
    echo "retry: '$1' still failing after $attempts attempts (exit $status)" >&2
    exit "$status"
  fi
  wait=$((seconds * attempt))
  echo "retry: '$1' failed (exit $status), attempt $attempt of $attempts; trying again in ${wait}s" >&2
  "${LOFTLINE_RETRY_SLEEP:-sleep}" "$wait"
  attempt=$((attempt + 1))
done
