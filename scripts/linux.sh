#!/bin/zsh
# Runs a command in the Swift Linux image, on this checkout, with its own build folder so the Mac's .build is not touched.
# Needs Docker, and runs outside an agent's Bash sandbox (the Docker socket is denied inside it).
# Usage: scripts/linux.sh build               swift build
#        scripts/linux.sh test [--filter X]   swift test
#        scripts/linux.sh <any command>       runs it in the container
#        LOFTLINE_LINUX_ARCH=amd64 scripts/linux.sh …   the x86-64 image (emulated on Apple Silicon)
set -euo pipefail
cd "${0:A:h}/.."
arch=${LOFTLINE_LINUX_ARCH:-}
platform=(); scratch=.build-linux; image=loftline-linux
if [[ -n "$arch" ]]; then platform=(--platform "linux/$arch"); scratch=".build-linux-$arch"; image="loftline-linux-$arch"; fi
# Built once, then cached by Docker.
docker build -q "${platform[@]}" -t "$image" -f docker/linux.Dockerfile docker >/dev/null
case "${1:-}" in
  build) shift; set -- swift build --scratch-path "$scratch" "$@" ;;
  test) shift; set -- swift test --scratch-path "$scratch" "$@" ;;
esac
exec docker run --rm "${platform[@]}" -v "$PWD:/src" -w /src -e LOFTLINE_SCRATCH="$scratch" "$image" "$@"
