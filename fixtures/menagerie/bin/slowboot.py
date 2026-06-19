#!/usr/bin/env python3
# Menagerie specimen: slowboot. Sleeps 8 s BEFORE binding its port. Axis:
# boot-grace — a launched-but-not-yet-ready process must read `Starting` (not
# `Down`), so the supervisor does NOT relaunch it (ONE launch, no storm) during
# the boot window. With bootGraceMs=60000 and a 3 s tick, this spends ~3 ticks
# `Starting` then flips to `Running`. Stdlib only.
import sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
time.sleep(8)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"slowboot up\n")

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", port), H).serve_forever()
