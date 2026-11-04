#!/bin/bash
# The container's half of scripts/linux-desktop.sh.
set -euo pipefail
scratch=.build-linux
swift build --scratch-path "$scratch" -c release --product loftline-core >&2
core="$(swift build --scratch-path "$scratch" -c release --show-bin-path)/loftline-core"
triple="$(rustc -vV | sed -n 's/^host: //p')"
mkdir -p desktop/src-tauri/binaries
cp "$core" "desktop/src-tauri/binaries/loftline-core-$triple"
cd desktop
npm install --no-audit --no-fund >&2
npx tauri build --no-bundle >&2
cd ..
app=desktop/src-tauri/target/release/loftline-desktop
export LOFTLINE_CORE="$PWD/desktop/src-tauri/binaries/loftline-core-$triple"
export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1
mkdir -p "$OUT"
Xvfb :9 -screen 0 1440x900x24 >/dev/null 2>&1 &
export DISPLAY=:9
sleep 2
dbus-run-session -- "$app" samples/sign.loftline > "$OUT/app.log" 2>&1 &
pid=$!
sleep 12
import -window root "$OUT/linux-app.png"
if ! kill -0 "$pid" 2>/dev/null; then echo "FAIL: the app exited" >&2; cat "$OUT/app.log" >&2; exit 1; fi
ls -la "$app" "$LOFTLINE_CORE" | awk '{print $5, $9}'
echo "ran: $OUT/linux-app.png"
