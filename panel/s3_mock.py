#!/usr/bin/env python3
"""Local S3 stand-in for tests. It stores bytes and checks nothing secret is required to read them back."""

import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STORE = {}


class Handler(BaseHTTPRequestHandler):
    def do_PUT(self):
        length = int(self.headers.get("Content-Length", "0"))
        STORE[self.path] = self.rfile.read(length)
        self.send_response(200)
        self.end_headers()

    def do_GET(self):
        body = STORE.get(self.path)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        return


def main():
    port = int(sys.argv[1])
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
