#!/bin/zsh
# Drives a built loftline-mcp through a short session and checks every reply: both protocol generations, then a new project,
# a rectangle, a profile on it and a post into a temporary allowed folder (program and job sheet).
# Usage: scripts/mcp-smoke.sh [path to loftline-mcp]   (builds the debug one when no path is given)
set -euo pipefail
cd "${0:A:h}/.."
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
print -r -- "{\"allowedFolders\":[\"$allowed\"]}" > "$work/assistant.json"
LOFTLINE_ASSISTANT_SETTINGS="$work/assistant.json" python3 - "$bin" "$allowed" <<'PY'
import json, os, subprocess, sys
binary, allowed = sys.argv[1], sys.argv[2]
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
p.stdin.close(); p.wait(timeout=30)
files = sorted(os.listdir(allowed))
assert any(f.endswith(".tap") for f in files), files
assert any(f.endswith(" job sheet.html") for f in files), files
print("mcp-smoke: ok:", ", ".join(files))
PY
