#!/usr/bin/env python3
"""Local stub for the Open-Meteo weather API.

Used by the WeatherClient example so that integration tests do not depend on
api.open-meteo.com (which has occasional 502s and breaks unrelated CI runs).

Behaviour:
- Listens on 127.0.0.1:<port> (default 18766, override with $1).
- Responds to any GET with a canned forecast JSON payload that mirrors the
  fields the example expects (current_weather, latitude, longitude, ...).
- Self-terminates after 60s so a leaked process cannot survive a CI job.
"""
import http.server
import json
import os
import sys
import threading

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("STUB_PORT", "18766"))

PAYLOAD = {
    "latitude": 52.52,
    "longitude": 13.41,
    "current_weather": {
        "temperature": 12.3,
        "windspeed": 9.4,
        "winddirection": 210,
        "weathercode": 3,
    },
}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(PAYLOAD).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args, **_kwargs):
        pass


def main():
    server = http.server.HTTPServer(("127.0.0.1", PORT), Handler)
    threading.Timer(60.0, server.shutdown).start()
    server.serve_forever()


if __name__ == "__main__":
    main()
