#!/usr/bin/env python3
"""Tiny offline stub for the StandupDigest example.

Mirrors the bits of GitLab/GitHub API that the digest pulls so the
example runs in CI without network or auth.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


COMMITS = [
    {"message": "feat(auth): bcrypt password hashing",
     "author": "Mira Chen"},
    {"message": "fix(db): connection pool deadlock under load",
     "author": "Petr Novak"},
    {"message": "docs: clarify retry semantics in webhook handler",
     "author": "Sam Rao"},
]

PULLS = [
    {"title": "Replace ad-hoc cache with LRU"},
    {"title": "Promote /v2/orders to GA"},
]

ISSUES = [
    {"title": "Investigate 504s on /v1/search", "assignee": "Mira"},
    {"title": "Wire up plugin telemetry",       "assignee": "Petr"},
]


ROUTES = {
    "/commits": COMMITS,
    "/pulls":   PULLS,
    "/issues":  ISSUES,
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = ROUTES.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        payload = json.dumps(body).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args, **kwargs):
        pass  # quiet under test runner


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18781
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
