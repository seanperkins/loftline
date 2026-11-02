#!/bin/zsh
# Runs a UI harness scenario against a debug build of LoftLine and writes screenshots and dumps.
#
#   scripts/ui.sh main                       # harness/scenarios/main.json, appearance from the file
#   scripts/ui.sh toolpaths --light          # force light (or --dark) mode
#   scripts/ui.sh main --size 1000x640       # window content size, overriding the scenario
#   scripts/ui.sh path/to/scenario.json --out .tmp/ui/mine --active
#
# Output goes to .tmp/ui/<scenario>-<time>/ (git-ignored): <name>.png, <name>.ax.txt (the accessibility
# tree), <name>.menus.txt and harness.log. The app runs with its own HOME inside that folder, which keeps its tool
# library and recovery files apart from yours; preferences are NOT isolated (UserDefaults ignores HOME, see
# docs/UI-HARNESS.md). No Screen Recording or Accessibility permission is needed: the app draws its own window
# into the PNG. Debug builds only.
#
# --active   make the app active so the window is drawn as the key window (it steals focus briefly)
# --key      draw the window as key without activating the app (your focus stays put; buttons take clicks, table rows do not)
# --offscreen park the window just past the edge of its screen for the run
# --no-build reuse the last build
# -- ARGS     everything after `--` goes to the app as launch arguments, which override a stored default for this run and
#            write nothing. A value is a string unless it is XML, so a boolean takes '<false/>':
#            `-- -preview3D.showToolpaths '<false/>'` (a plain `NO` is read as the string "NO" and the setting keeps its default)
# Run it OUTSIDE an agent's Bash sandbox: inside one the app hangs before the harness starts, so the script refuses
# (docs/UI-HARNESS.md). LOFTLINE_BUILD_FLAGS adds extra swift build flags. LOFTLINE_UI_TIMEOUT (seconds) caps a run;
# the default is the scenario's watchdog plus a minute, and a run stopped by it exits 2 like the watchdog.
set -euo pipefail
cd "${0:A:h}/.."
source scripts/swiftpm-env.sh

# macOS refuses to nest one sandbox in another, so a failed probe means this shell is already sandboxed (the probe
# swiftpm-env.sh uses). There the app cannot reach the HIServices XPC service and hangs with no output.
if command -v sandbox-exec >/dev/null 2>&1 && ! sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null; then
  echo "scripts/ui.sh: this shell is sandboxed, where the app hangs before the harness starts. Run it outside the" \
    "sandbox (Claude Code: list it in sandbox.excludedCommands, see docs/UI-HARNESS.md)." >&2
  exit 3
fi

scenario=""; out=""; extra=(); app_args=(); build=1
while (( $# )); do
  case "$1" in
    --out) out="$2"; shift 2 ;;
    --light) extra+=(--ui-appearance light); shift ;;
    --dark) extra+=(--ui-appearance dark); shift ;;
    --size) extra+=(--ui-size "$2"); shift 2 ;;
    --active) extra+=(--ui-active 1); shift ;;
    --key) extra+=(--ui-key 1); shift ;;
    --offscreen) extra+=(--ui-offscreen 1); shift ;;
    --no-build) build=0; shift ;;
    --) shift; app_args=("$@"); break ;;
    -h|--help) sed -n '2,/^set /{/^set /!p;}' "$0"; exit 0 ;;
    *) scenario="$1"; shift ;;
  esac
done
[[ -n "$scenario" ]] || { echo "usage: scripts/ui.sh <scenario|file.json> [--light|--dark] [--size WxH] [--out DIR]" >&2; exit 2; }
[[ -f "$scenario" ]] || scenario="harness/scenarios/${scenario%.json}.json"
[[ -f "$scenario" ]] || { echo "no such scenario: $scenario (scenarios: $(ls harness/scenarios | sed 's/\.json//' | tr '\n' ' '))" >&2; exit 2; }
[[ -n "$out" ]] || out=".tmp/ui/$(basename "${scenario%.json}")-$(date +%H%M%S)"

(( build )) && swift build "${SWIFTPM_FLAGS[@]}" -c debug --product LoftLine ${=LOFTLINE_BUILD_FLAGS:-} 2>&1 | grep -E 'error|Compiling|Build complete' | tail -3
BIN="$(swift build "${SWIFTPM_FLAGS[@]}" -c debug --show-bin-path ${=LOFTLINE_BUILD_FLAGS:-})/LoftLine"
mkdir -p "$out/home"
out="${out:A}"
echo "scenario: $scenario -> $out"
# The app's watchdog starts only once the harness does, so a hang before that (a sandboxed shell, a stuck launch) would
# never end; this cap stops the app instead. A scenario's "timeout" key raises its watchdog, and the cap with it.
watchdog=$(plutil -extract timeout raw -o - "$scenario" 2>/dev/null || echo 180)
limit=${LOFTLINE_UI_TIMEOUT:-$(( ${watchdog%.*} + 60 ))}
# The app's exit status is the result (0 ok, 1 a failed step, 2 the watchdog or the cap); grep only filters.
set +e
HOME="$out/home" CFFIXED_USER_HOME="$out/home" "$BIN" \
  --ui-scenario "${scenario:A}" --ui-out "$out" "${extra[@]}" "${app_args[@]}" \
  -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO > >(grep --line-buffered '^\[harness\]') 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null' INT TERM HUP
waited=0; capped=0
while kill -0 $pid 2>/dev/null; do
  if (( waited >= limit )); then
    echo "scripts/ui.sh: the app ran ${limit}s without finishing; stopping it" >&2
    kill $pid 2>/dev/null; sleep 2; kill -9 $pid 2>/dev/null
    capped=1; break
  fi
  sleep 1; (( waited++ ))
done
wait $pid; rc=$?
(( capped )) && rc=2
trap - INT TERM HUP
set -e
echo "--- outputs"; ls -1 "$out" | grep -v '^home$' || true
(( rc == 0 )) || echo "harness failed with status $rc (see $out/harness.log)" >&2
exit $rc
