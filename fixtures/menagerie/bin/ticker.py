#!/usr/bin/env python3
# Menagerie specimen: ticker. Binds a TCP port immediately and increments a
# monotonic counter every 100 ms. Axis: fast-bind baseline; readiness == liveness
# (the port being up IS the health signal). Stdlib only; SIGTERM ends it cleanly.
import sys, threading, time
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
count = 0


def _tick():
    global count
    while True:
        count += 1
        time.sleep(0.1)


threading.Thread(target=_tick, daemon=True).start()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(f"tick {count}\n".encode())

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", port), H).serve_forever()
