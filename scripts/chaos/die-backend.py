#!/usr/bin/env python3
# Chaos backend: binds the given port, then exits ~immediately — exercises the
# bind-then-die path (serve must not deadlock; the next request respawns).
import sys, socket, time
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port)); s.listen()
time.sleep(0.4)
