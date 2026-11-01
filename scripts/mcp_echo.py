#!/usr/bin/env python3
"""Minimal MCP stdio server: one tool, echo_text."""
import json, sys

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

TOOL = {
    "name": "echo_text",
    "description": "Echo back the given text, prefixed with PLUGIN-OK.",
    "inputSchema": {
        "type": "object",
        "properties": {"text": {"type": "string", "description": "Text to echo"}},
        "required": ["text"],
    },
}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    method, mid = msg.get("method"), msg.get("id")
    if mid is None:
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "echo-test", "version": "0.1.0"},
        }})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [TOOL]}})
    elif method == "tools/call":
        args = (msg.get("params") or {}).get("arguments") or {}
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "content": [{"type": "text", "text": "PLUGIN-OK: " + str(args.get("text", ""))}],
        }})
    else:
        send({"jsonrpc": "2.0", "id": mid,
              "error": {"code": -32601, "message": "Method not found"}})
