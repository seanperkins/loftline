#!/bin/zsh
# Says whether the GitHub release for a tag may be uploaded to. Prints "absent" (nothing there yet) or "draft" and exits 0;
# exits 1 for a published release, or when GitHub's answer cannot be read. A published release is never touched:
# `gh release upload --clobber` deletes an asset before replacing it, which would leave a public zip and its update feed
# briefly inconsistent, so a fix ships as a new tag. The workflow runs this when the run starts (a doomed run fails in
# seconds) and again just before the upload, because a draft can be published while the build is running.
# Usage: scripts/check-release-state.sh <tag>
set -euo pipefail

(( $# == 1 )) || { print -u2 -r -- "usage: scripts/check-release-state.sh <tag>"; exit 1 }
tag=$1

if answer="$(gh release view "$tag" --json isDraft --jq .isDraft 2>&1)"; then
  if [[ $answer == true ]]; then
    print draft
    exit 0
  fi
  print -u2 -r -- "::error::The release for $tag is already published. Ship a fix as a new tag."
  exit 1
fi
if [[ ${answer:l} == *"not found"* ]]; then
  print absent
  exit 0
fi
print -u2 -r -- "::error::Could not look up the release for $tag: $answer"
exit 1
