#!/usr/bin/env bash
# Exports the file open in the Rive desktop editor to content/<name>.riv via
# the editor's local MCP server (the editor is sandboxed and can't write into
# this repo itself). Usage: tools/export_riv.sh [output-name]  (default: scene)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NAME="${1:-scene}"
URL=http://127.0.0.1:9791/mcp
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SID=$(curl -si "$URL" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"rive-vr-export","version":"1"}}}' \
  | tr -d '\r' | sed -n 's/^mcp-session-id: //p')
curl -s "$URL" -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' -H "mcp-session-id: $SID" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"export_file","arguments":{"format":"riv","destination":"'"$TMP"'","inline_base64":true}}}' \
  > "$TMP/response.txt"

python3 - "$TMP/response.txt" "$ROOT/content/$NAME.riv" <<'PY'
import base64, json, sys
raw = open(sys.argv[1], encoding='utf-8').read()
lines = [l[5:].strip() for l in raw.splitlines() if l.startswith('data:')]
body = json.loads(lines[-1] if lines else raw)
payload = json.loads(body['result']['content'][0]['text'])
if 'data' not in payload:
    sys.exit('export did not return inline data: ' + json.dumps(payload)[:300])
open(sys.argv[2], 'wb').write(base64.b64decode(payload['data']))
print(sys.argv[2])
PY
