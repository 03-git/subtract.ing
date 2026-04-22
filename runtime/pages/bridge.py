#!/usr/bin/env python3
"""HTTP bridge: browser POSTs intent, subtract.sh handles it, response comes back.
Fast paths (T0/skills/kiwix) return immediately.
Inference streams token-by-token via SSE."""
import subprocess, json, os, re, urllib.request, urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = 8889
FAST_TIMEOUT = 5

ENV = os.environ.copy()
ENV["TERM"] = "dumb"

SUBTRACT_DIR = os.path.expanduser("~/.subtract")
INF_HOST = open(f"{SUBTRACT_DIR}/inference_host").read().strip() if os.path.exists(f"{SUBTRACT_DIR}/inference_host") else "localhost"
INF_PORT = open(f"{SUBTRACT_DIR}/inference_port").read().strip() if os.path.exists(f"{SUBTRACT_DIR}/inference_port") else "8083"

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()
        data = json.loads(body)
        intent = data.get("intent", "").strip()
        mode = data.get("mode", "r")
        thread_id = data.get("thread", "default")
        file_content = data.get("file")
        file_name = data.get("fileName")

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
            self._respond(200, {
                "stdout": result.stdout,
                "stderr": result.stderr,
                "exit": result.returncode,
                "stream": False
            })
        except subprocess.TimeoutExpired:
            self._stream_inference(intent, mode, thread_id)

    def _stream_inference(self, intent, mode, thread_id="default"):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

        if file_content and file_name:
            prompt = f"Here is {file_name}:\n\n{file_content}\n\nRequest: {intent}\n\nOutput ONLY the complete modified file, no commentary."
        else:
            prompt = f"Answer concisely: {intent}"

        # cloud first
        if self._try_stream_cloud(prompt, thread_id):
            return
        # local fallback
        self._try_stream_local(prompt)

    threads = {}

    def _try_stream_cloud(self, prompt, thread_id="default"):
        try:
            cmd = ["claude", "-p"]
            if thread_id in Handler.threads:
                cmd.append("-c")
            cmd.append(prompt)
            result = subprocess.run(
                cmd, capture_output=True, text=True, timeout=60, env=ENV
            )
            text = result.stdout.strip()
            if text:
                Handler.threads[thread_id] = True
                self.wfile.write(f"data: {json.dumps({'token': text})}\n\n".encode())
                self.wfile.flush()
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return True
            return False
        except (FileNotFoundError, subprocess.TimeoutExpired, Exception):
            return False

    def _try_stream_local(self, prompt):
        payload = json.dumps({
            "messages": [{"role": "user", "content": prompt}],
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
                req = urllib.request.Request(
                    f"http://localhost:{INF_PORT}/v1/chat/completions",
                    data=payload,
                    headers={"Content-Type": "application/json"}
                )
                resp = urllib.request.urlopen(req)
                fd = resp.fileno()

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
                            self.wfile.write(f"data: {json.dumps({'token': token})}\n\n".encode())
                            self.wfile.flush()
                    except (json.JSONDecodeError, IndexError, KeyError):
                        pass
        except Exception:
            self.wfile.write(f"data: {json.dumps({'token': 'no inference available'})}\n\n".encode())
            self.wfile.flush()
        finally:
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            if INF_HOST != "localhost" and 'proc' in dir():
                proc.wait()

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
    HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
