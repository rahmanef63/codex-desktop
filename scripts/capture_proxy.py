#!/usr/bin/env python3
"""Capture-and-forward proxy: logs Codex request body to /tmp/dump, forwards to 9router."""
import json, os, sys, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UP = "https://router.antinrml.com"
KEY = os.environ.get("UP_KEY", "")
N = [0]

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length") or 0))
        N[0] += 1
        try:
            j = json.loads(body)
            tools = j.get("tools") or []
            summary = [
                {"type": t.get("type"), "name": t.get("name"),
                 "has_function": bool(t.get("function")),
                 "format": (t.get("format") or {}).get("type")}
                for t in tools
            ]
            with open(f"/tmp/dump{N[0]}.json", "w") as f:
                json.dump({"tools_count": len(tools), "tools": summary, "full": j}, f, indent=1)
            with open("/tmp/dump-summary.txt", "a") as f:
                f.write(json.dumps({"n": N[0], "tools_count": len(tools), "tools": summary[:40]}) + "\n")
        except Exception as e:
            with open("/tmp/dump-summary.txt", "a") as f:
                f.write(f"parse error {e}\n")

        req = urllib.request.Request(UP + self.path, data=body, method="POST",
                                     headers={"Authorization": "Bearer " + KEY,
                                              "Content-Type": "application/json"})
        try:
            resp = urllib.request.urlopen(req, timeout=300)
            code, hdrs, payload = resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            code, hdrs, payload = e.code, e.headers, e.read()
        except Exception as e:
            code, hdrs, payload = 502, {}, json.dumps({"error": str(e)}).encode()

        self.send_response(code)
        ct = hdrs.get("content-type", "application/json")
        self.send_header("Content-Type", ct)
        self.send_header("Content-Length", str(len(payload)))
        if "text/event-stream" in ct:
            self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "17")
        self.end_headers()
        self.wfile.write(b'{"data":[],"ok":1}')

ThreadingHTTPServer(("127.0.0.1", 8787), H).serve_forever()
