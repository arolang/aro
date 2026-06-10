#!/usr/bin/env python3
"""Stub backend for UptimeMonitor.

Three deterministic endpoints — one always healthy, one always
unhealthy, one always 200 but with a long body — so the canvas
shows both success and failure paths on a single run.
"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthy":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
        elif self.path == "/flaky":
            # Slow-but-OK: matches what most "passes but worth
            # watching" endpoints look like in real life.
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok, but slow")
        elif self.path == "/down":
            self.send_response(503)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"down")
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, *args, **kwargs):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18791
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
