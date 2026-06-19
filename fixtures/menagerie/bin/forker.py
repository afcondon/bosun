#!/usr/bin/env python3
# Menagerie specimen: forker. Spawns 2 child workers IN ITS OWN PROCESS GROUP,
# then binds its port. Axis: pgid-tree reaping — `bosun down` does
# `kill -- -<pgid>` and MUST take the whole tree. This is the direct regression
# guard for the 2026-06-19 `down` no-op: an orphaned child after `down` = the bug
# back. The workers deliberately do NOT trap signals — the group-kill reaches
# them directly, which is exactly the property under test. No setsid, so the
# children share our group and inherit the reap. Stdlib only.
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])

workers = [
    subprocess.Popen([sys.executable, "-c", "import time\nwhile True: time.sleep(3600)"])
    for _ in range(2)
]


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(
            f"forker pid={os.getpid()} pgid={os.getpgrp()} workers={[w.pid for w in workers]}\n".encode()
        )

    def log_message(self, *a):
        pass


HTTPServer(("127.0.0.1", port), H).serve_forever()
