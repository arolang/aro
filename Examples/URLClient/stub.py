#!/usr/bin/env python3
"""Local stub for the URLClient example's HTTP endpoints.

Mirrors the shapes of jsonplaceholder.typicode.com and httpbin.org so the
integration tests do not depend on live third-party services (both flake
from cloud runners — httpbin regularly returns 503 HTML error pages, which
broke this example's output comparison in CI and locally).

Behaviour:
- Listens on 127.0.0.1:<port> (default 18767, override with $1).
- GET  /todos/1  -> canned jsonplaceholder TODO
- GET  /headers  -> httpbin-style echo of the request headers
- POST /posts    -> 201 + echo body with jsonplaceholder's canonical id 101
- GET  /users/1  -> canned jsonplaceholder user
- Self-terminates after STUB_TIMEOUT seconds (default 1800) so a leaked
  process cannot survive a CI job.
"""
import http.server
import json
import os
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("STUB_PORT", "18767"))

TODO = {"userId": 1, "id": 1, "title": "delectus aut autem", "completed": False}

USER = {
    "id": 1,
    "name": "Leanne Graham",
    "username": "Bret",
    "email": "Sincere@april.biz",
}


class Handler(http.server.BaseHTTPRequestHandler):
    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/todos/1":
            self._send_json(TODO)
        elif path == "/headers":
            # httpbin.org/headers format: {"headers": {"Name": "value", ...}}
            self._send_json({"headers": {k: v for k, v in self.headers.items()}})
        elif path == "/users/1":
            self._send_json(USER)
        else:
            self._send_json({"error": "not found", "path": path}, status=404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {}
        if not isinstance(payload, dict):
            payload = {"data": payload}
        payload["id"] = 101  # jsonplaceholder always answers with id 101
        self._send_json(payload, status=201)

    def log_message(self, *args):  # keep test output clean
        pass


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    timeout = int(os.environ.get("STUB_TIMEOUT", "1800"))
    threading.Timer(timeout, server.shutdown).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
