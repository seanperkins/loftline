#!/bin/zsh
# Drives a built loftline-mcp through a short session and checks every reply: both protocol generations, then a new project,
# a rectangle, a profile on it and a post into a temporary allowed folder (program and job sheet).
# Usage: scripts/mcp-smoke.sh [path to loftline-mcp]   (builds the debug one when no path is given)
# --live (Mac only) also runs the live link: the app under the UI harness (scenario assistant-smoke) allows the assistant, which
# then adds a shape to the open window and posts it (spec 2).
set -euo pipefail
cd "${0:A:h}/.."
live=0
if [[ "${1:-}" == "--live" ]]; then live=1; shift; fi
bin="${1:-}"
if [[ -z "$bin" ]]; then
  source scripts/swiftpm-env.sh
  swift build "${SWIFTPM_FLAGS[@]}" --product loftline-mcp >&2
  bin="$(swift build "${SWIFTPM_FLAGS[@]}" --show-bin-path)/loftline-mcp"
fi
[[ -x "$bin" ]] || { print -u2 "mcp-smoke: no executable at $bin"; exit 1 }
work="$(mktemp -d "${TMPDIR:-/tmp}/mcp-smoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/allowed"
allowed="${work:A}/allowed"
ui=""
if (( live )); then
  [[ "$(uname)" == Darwin ]] || { print -u2 "mcp-smoke: --live needs the Mac app"; exit 1 }
  print -r -- "{\"allowedFolders\":[\"$allowed\"],\"liveLink\":true}" > "$work/assistant.json"
  LOFTLINE_ASSISTANT_SETTINGS="$work/assistant.json" scripts/ui.sh assistant-smoke > "$work/ui.log" 2>&1 &
  ui=$!
else
  print -r -- "{\"allowedFolders\":[\"$allowed\"]}" > "$work/assistant.json"
fi
LOFTLINE_ASSISTANT_SETTINGS="$work/assistant.json" python3 - "$bin" "$allowed" "$live" <<'PY'
import json, os, subprocess, sys, time
binary, allowed, live = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}
def send(message, reply=True):
    p.stdin.write(json.dumps(message) + "\n"); p.stdin.flush()
    if not reply: return None
    r = json.loads(p.stdout.readline())
    assert "error" not in r, r
    assert not r["result"].get("isError"), r["result"]
    return r["result"]
def tool(i, name, args):
    res = send({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"_meta": meta, "name": name, "arguments": args}})
    text = res["content"][0]["text"]
    return json.loads(text[text.index("\n{") + 1:]) if "\n{" in text else text
init = send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}}})
assert init["serverInfo"]["name"] == "loftline", init
send({"jsonrpc": "2.0", "method": "notifications/initialized"}, reply=False)
discover = send({"jsonrpc": "2.0", "id": 2, "method": "server/discover", "params": {"_meta": meta}})
assert "2026-07-28" in discover["supportedVersions"], discover
tool(3, "new_project", {"units": "inch", "width": 12, "height": 8, "thickness": 0.75, "name": "Smoke"})
shape = tool(4, "add_shapes", {"shapes": [{"type": "rectangle", "x": 2, "y": 2, "width": 4, "height": 3}]})["ids"][0]
tool(5, "add_toolpath", {"kind": "profile", "shape_ids": [shape]})
tool(6, "post_gcode", {"folder": allowed, "mode": "one_file"})
if live:
    # The open window: wait for the app, claim the sign (the harness clicks Allow), edit it, describe and post it.
    docs, deadline = [], time.time() + 120
    while not docs and time.time() < deadline:
        found = tool(10, "list_open_documents", {})
        docs = found.get("documents", []) if isinstance(found, dict) else []
        if not docs: time.sleep(1)
    assert docs, "mcp-smoke: no open document listed"
    tool(11, "use_open_document", {"document": docs[0]["id"]})
    tool(12, "add_shapes", {"shapes": [{"type": "rectangle", "x": 1, "y": 1, "width": 1, "height": 1}]})
    described = tool(13, "describe_project", {})
    assert isinstance(described, dict) and "document" in described, described
    os.makedirs(os.path.join(allowed, "live"))
    tool(14, "post_gcode", {"folder": os.path.join(allowed, "live"), "mode": "one_file", "job_sheet": False})
    assert os.listdir(os.path.join(allowed, "live")), "mcp-smoke: the open window posted nothing"
p.stdin.close(); p.wait(timeout=30)
files = sorted(os.listdir(allowed))
assert any(f.endswith(".tap") for f in files), files
assert any(f.endswith(" job sheet.html") for f in files), files
print("mcp-smoke: ok:", ", ".join(files) + (" and the open window" if live else ""))
PY
if [[ -n "$ui" ]]; then
  wait "$ui" || { cat "$work/ui.log" >&2; exit 1 }
  grep -q "allowAssistant: allowed" "$work/ui.log" || { cat "$work/ui.log" >&2; exit 1 }
fi
