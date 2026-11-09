"""Mock AIOStreams dashboard API and NzbNest upload endpoint for run.sh.

Usage: mock_server.py <tmp-dir>. Writes the port it listens on to <tmp-dir>/port
and appends each upload to <tmp-dir>/uploads.log.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
TMP = sys.argv[1]
with open(os.path.join(HERE, "fixtures", "library.json")) as f:
    LIBRARY = json.load(f)
with open(os.path.join(HERE, "fixtures", "media-info.json")) as f:
    MEDIA_INFO = json.load(f)
PAGE = 2  # small pages, so the exporter has to page


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(code)
        for header in headers:
            self.send_header(*header)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        url = urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if url.path == "/api/v1/auth/login":
            cookie = ("Set-Cookie", "aiostreams.session=ok; Path=/")
            return self.reply(200, {"success": True}, [cookie])
        if url.path == "/v1/upload":
            parts = re.findall(rb'name="(\w+)"; filename="([^"]*)"', body)
            fields = " ".join(f"{n.decode()}={fn.decode()}" for n, fn in parts)
            with open(os.path.join(TMP, "uploads.log"), "a") as log:
                log.write(f"cat={parse_qs(url.query)['cat'][0]} {fields}\n")
            return self.reply(200, {"success": True})
        self.reply(404, {})

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        if "aiostreams.session=ok" not in (self.headers.get("Cookie") or ""):
            return self.reply(401, {})
        if url.path == "/api/v1/dashboard/usenet/library":
            offset = int(query.get("offset", ["0"])[0])
            page = LIBRARY[offset : offset + PAGE]
            return self.reply(200, {"data": {"entries": page, "total": len(LIBRARY)}})
        if url.path == "/api/v1/dashboard/media-info/files":
            items = MEDIA_INFO.get(query["nzb"][0], [])
            return self.reply(200, {"data": {"items": items}})
        self.reply(404, {})


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(TMP, "port"), "w") as f:
    f.write(str(server.server_port))
server.serve_forever()
