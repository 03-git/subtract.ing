#!/usr/bin/env python3
"""HTTP bridge: browser POSTs intent, subtract.sh handles it, response comes back.
Fast paths (T0/skills/kiwix) return immediately.
Inference streams token-by-token via SSE."""
import subprocess, json, os, re, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from http.server import HTTPServer

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True

PORT = 8889
FAST_TIMEOUT = 5

ENV = os.environ.copy()
ENV["TERM"] = "dumb"

SUBTRACT_DIR = os.path.expanduser("~/.subtract")
INF_HOST = open(f"{SUBTRACT_DIR}/inference_host").read().strip() if os.path.exists(f"{SUBTRACT_DIR}/inference_host") else "localhost"
INF_PORT = open(f"{SUBTRACT_DIR}/inference_port").read().strip() if os.path.exists(f"{SUBTRACT_DIR}/inference_port") else "8083"
SYSTEM_PROMPT = open(f"{SUBTRACT_DIR}/SOUL.txt").read().strip() if os.path.exists(f"{SUBTRACT_DIR}/SOUL.txt") else ""

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        data = json.loads(body)
        intent = data.get("intent", "").strip()
        mode = data.get("mode", "r")
        thread_id = data.get("thread", "default")
        files = data.get("files", [])

        if not intent:
            self._respond(400, {"error": "empty intent"})
            return

        needs_full = bool(re.search(r'https?://[^\s]*(youtube\.com|youtu\.be)[^\s]*', intent))
        timeout = 120 if needs_full else FAST_TIMEOUT

        try:
            result = subprocess.run(
                ["bash", "-c",
                 'source ~/.subtract/subtract.sh; '
                 f'__subtract_set_mode "{mode}"; '
                 f'__subtract_handle {subprocess.list2cmdline([intent])}'],
                capture_output=True, text=True, timeout=timeout,
                input="\n\n\n",
                env=ENV
            )
            stdout = result.stdout
            # strip handler prompt lines, keep the answer; extract source tier
            lines = stdout.splitlines()
            clean_lines = []
            source = None
            for line in lines:
                stripped = line.strip()
                m = re.match(r'^\[(T\d(?:\.\d)?)[:\]]', stripped)
                if m:
                    source = m.group(1)
                    continue
                if re.match(r'^\[kiwix\]', stripped):
                    source = 'kiwix'
                    clean_lines.append(stripped[len('[kiwix] '):])
                    continue
                if re.match(r'^\[apropos\]', stripped):
                    source = 'apropos'
                    continue
                if re.match(r'^\[skill', stripped):
                    source = 'skills'
                    continue
                if stripped in ("[enter/n]", "[y/n]", "[DESTRUCTIVE]", ""):
                    continue
                if stripped.startswith("[enter/n] "):
                    line = stripped[len("[enter/n] "):]
                elif stripped.startswith("[y/n] "):
                    line = stripped[len("[y/n] "):]
                clean_lines.append(line)
            stdout = "\n".join(clean_lines).strip()
            resp = {
                "stdout": stdout,
                "stderr": result.stderr,
                "exit": result.returncode,
                "stream": False
            }
            if source:
                resp["source"] = source
            self._respond(200, resp)
        except subprocess.TimeoutExpired:
            self._stream_inference(intent, mode, thread_id, files)

    def _stream_inference(self, intent, mode, thread_id="default", files=None):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        cloud_ai = ""
        cloud_ai_path = os.path.join(SUBTRACT_DIR, "cloud_ai")
        if os.path.exists(cloud_ai_path):
            cloud_ai = open(cloud_ai_path).read().strip()

        if files:
            names = ", ".join(f["name"] for f in files)
            if cloud_ai in ("xai", "grok"):
                parts = []
                for f in files:
                    content = f.get("content", "")
                    if content:
                        parts.append(f"--- {f['name']} ---\n{content}")
                    else:
                        parts.append(f"--- {f['name']} --- (empty)")
                prompt = "\n".join(parts) + f"\n\n{intent}"
            else:
                prompt = f"Find and read these files on this machine: {names}. Then: {intent}"
        else:
            prompt = f"Answer concisely: {intent}"

        # local first
        if self._try_stream_local(prompt):
            return
        # cloud fallback
        if cloud_ai in ("xai", "grok"):
            if self._try_stream_xai(prompt, thread_id):
                return
        elif self._try_stream_cloud(prompt, thread_id):
            return

    threads = {}
    xai_threads = {}

    def _try_stream_xai(self, prompt, thread_id="default"):
        try:
            xai_key_path = os.path.join(SUBTRACT_DIR, "xai_key")
            if not os.path.exists(xai_key_path):
                return False
            xai_key = open(xai_key_path).read().strip()

            payload = json.dumps({
                "model": "grok-4.20-0309-reasoning",
                "messages": [{"role": "user", "content": prompt}],
                "max_tokens": 4096
            }).encode()

            req = urllib.request.Request(
                "https://api.x.ai/v1/chat/completions",
                data=payload,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {xai_key}"
                }
            )
            resp = urllib.request.urlopen(req, timeout=120)
            result = json.loads(resp.read().decode())

            text = result.get("choices", [{}])[0].get("message", {}).get("content", "")

            if text:
                Handler.xai_threads[thread_id] = True
                self.wfile.write(f"data: {json.dumps({'token': text, 'source': 'cloud'})}\n\n".encode())
                self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return True
            return False
        except Exception:
            return False

    def _try_stream_cloud(self, prompt, thread_id="default"):
        try:
            cmd = ["claude", "-p"]
            if thread_id in Handler.threads:
                cmd.append("-c")
            cmd.append("-")
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=120,
                input=prompt, env=ENV, cwd=os.path.expanduser("~")
            )
            text = result.stdout.strip()
            if text:
                Handler.threads[thread_id] = True
                self.wfile.write(f"data: {json.dumps({'token': text, 'source': 'cloud'})}\n\n".encode())
                self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return True
            return False
        except (FileNotFoundError, subprocess.TimeoutExpired, Exception):
            return False

    def _try_stream_local(self, prompt):
        messages = []
        if SYSTEM_PROMPT:
            messages.append({"role": "system", "content": SYSTEM_PROMPT})
        messages.append({"role": "user", "content": prompt})
        payload = json.dumps({
            "messages": messages,
            "max_tokens": 2048,
            "stream": True
        }).encode()

        try:
            if INF_HOST != "localhost":
                curl_cmd = f'curl -s -N http://localhost:{INF_PORT}/v1/chat/completions -H "Content-Type: application/json" -d @-'
                proc = subprocess.Popen(
                    ["ssh", "-o", "ConnectTimeout=5", INF_HOST, curl_cmd],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    bufsize=0
                )
                proc.stdin.write(payload)
                proc.stdin.close()
                fd = proc.stdout.fileno()
            else:
                proc = subprocess.Popen(
                    ["curl", "-s", "-N", f"http://localhost:{INF_PORT}/v1/chat/completions",
                     "-H", "Content-Type: application/json", "-d", "@-"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    bufsize=0
                )
                proc.stdin.write(payload)
                proc.stdin.close()
                fd = proc.stdout.fileno()

            got_tokens = False
            buf = b""
            while True:
                chunk = os.read(fd, 4096)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    raw_line, buf = buf.split(b"\n", 1)
                    line = raw_line.decode().strip()
                    if not line.startswith("data: "):
                        continue
                    payload_str = line[6:]
                    if payload_str == "[DONE]":
                        break
                    try:
                        obj = json.loads(payload_str)
                        delta = obj.get("choices", [{}])[0].get("delta", {})
                        token = delta.get("content", "")
                        if token:
                            got_tokens = True
                            self.wfile.write(f"data: {json.dumps({'token': token, 'source': 'local'})}\n\n".encode())
                            self.wfile.flush()
                    except (json.JSONDecodeError, IndexError, KeyError):
                        pass

            if 'proc' in dir():
                proc.wait()
            if got_tokens:
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return True
            return False
        except Exception:
            return False

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
    print(f"bridge on :{PORT}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
