"""A small JSON API in front of the stock table."""

import json
from http.server import BaseHTTPRequestHandler


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"status": "ok"}).encode()
        self.send_response(200)
        self.send_header("Content-Type",
                         "application/json")
        self.end_headers()
        self.wfile.write(body)
