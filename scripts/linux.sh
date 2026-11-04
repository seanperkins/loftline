#!/bin/zsh
# Runs a command in the Swift Linux image, on this checkout, with its own build folder so the Mac's .build is not touched.
# Needs Docker, and runs outside an agent's Bash sandbox (the Docker socket is denied inside it).
# Usage: scripts/linux.sh build               swift build
#        scripts/linux.sh test [--filter X]   swift test
#        scripts/linux.sh <any command>       runs it in the container
#        LOFTLINE_LINUX_ARCH=amd64 scripts/linux.sh …   the x86-64 image (emulated on Apple Silicon)
set -euo pipefail
cd "${0:A:h}/.."
image=${LOFTLINE_LINUX_IMAGE:-swift:6.4}
arch=${LOFTLINE_LINUX_ARCH:-}
platform=(); scratch=.build-linux
if [[ -n "$arch" ]]; then platform=(--platform "linux/$arch"); scratch=".build-linux-$arch"; fi
case "${1:-}" in
  build) shift; set -- swift build --scratch-path "$scratch" "$@" ;;
  test) shift; set -- swift test --scratch-path "$scratch" "$@" ;;
esac
exec docker run --rm "${platform[@]}" -v "$PWD:/src" -w /src -e LOFTLINE_SCRATCH="$scratch" "$image" "$@"
