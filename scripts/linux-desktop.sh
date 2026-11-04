#!/bin/zsh
# Builds the desktop app (desktop/) on Linux in Docker, runs it under Xvfb on a sample and takes a screenshot, the real shell and
# the real WebKit. Needs Docker, outside an agent's Bash sandbox.
# Usage: scripts/linux-desktop.sh [output folder]
set -euo pipefail
cd "${0:A:h}/.."
out=${1:-.tmp/linux-desktop}
mkdir -p "$out"
docker build -q -t loftline-desktop -f docker/desktop.Dockerfile docker >/dev/null
exec docker run --rm -v "$PWD:/src" -w /src -v loftline-desktop-cargo:/opt/cargo/registry -v loftline-desktop-node:/src/desktop/node_modules \
  -e OUT="$out" loftline-desktop bash scripts/linux-desktop-inner.sh
