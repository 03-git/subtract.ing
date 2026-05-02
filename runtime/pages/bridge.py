#!/usr/bin/env python3
"""HTTP adapter for multiplying.html — pipes intents through hosuni.sh."""
import subprocess, json, os
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from http.server import HTTPServer

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

SUBTRACT_DIR = os.path.expanduser("~/.subtract")
HOSUNI = os.path.join(SUBTRACT_DIR, "runtime", "hosuni.sh")
if not os.path.exists(HOSUNI):
    HOSUNI = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "hosuni.sh")
ENV = os.environ.copy()
ENV["TERM"] = "dumb"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        intent = body.get("intent", "").strip()
        if not intent:
            self._respond(400, {"error": "empty intent"})
            return
        req = json.dumps({"input": intent, "channel": body.get("thread", "default")})
        try:
            result = subprocess.run(
                ["bash", HOSUNI], input=req,
                capture_output=True, text=True, timeout=300, env=ENV
            )
            if result.stdout.strip():
                resp = json.loads(result.stdout.strip())
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                reply = resp.get("response") or resp.get("error") or ""
                source = resp.get("source", "hosuni")
                self.wfile.write(f"data: {json.dumps({'token': reply, 'source': source})}\n\n".encode())
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return
        except Exception:
            pass
        self._respond(200, {"stdout": "Couldn't resolve that.", "stderr": "", "exit": 1, "stream": False})

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def _respond(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", len(body))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass

if __name__ == "__main__":
    print("bridge on :8889")
    ThreadingHTTPServer(("0.0.0.0", 8889), Handler).serve_forever()
