#!/usr/bin/env python3
# Chaos backend: binds the given port (so serve's waitForPort succeeds) but
# hangs forever on every request — exercises serve's proxy timeout (→ 504).
import sys, time, http.server
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): time.sleep(600)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
