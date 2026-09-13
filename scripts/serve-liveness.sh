#!/usr/bin/env bash
# `bosun serve` liveness + child-lifetime regression gate (2026-08-17).
#
# Two defects, one shape — a belief formed once and then reported as current
# truth. Both are at the shim edge (`cli/src/Bosun/CLI/Serve.js`), below the
# pure plan, so the spec suite cannot reach them: they only exist when real
# ports are bound and real processes are spawned. Hence a live script.
#
#   A. ADOPTION IS NOT STICKY. A route whose public port is already held is
#      adopted (`external: true`, serve binds nothing). When that holder exits,
#      the router must NOTICE — drop the claim, take the port, and be
#      lazy-spawnable again — WITHOUT being restarted. It previously reported
#      `up: true` forever for a port with nothing listening on it, and
#      `/control/reload` could not clear it because a reload diffs CONFIG and
#      nothing in the config had changed.
#
#   B. A SPAWNED BACKEND MUST NOT OUTLIVE ITS ROUTER. Backends are `detached`
#      (they need their own process group so the whole subtree can be signalled),
#      which also means they survive the router unless something makes them not.
#      Two halves, and this exercises both: the exit hook (an orderly SIGTERM
#      takes its children with it) and the startup sweep (a SIGKILLed router
#      cannot run hooks, so the NEXT router reaps what it left on the internal
#      ports before binding).
#
# Runs a scratch router on its own control port (BOSUN_SERVE_STATUS_PORT) over a
# throwaway registry, so it never touches the live fleet on :3997.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"

STATUS=8788        # scratch control surface (the live router keeps :3997)
PORT_A=8786        # the adoption case
PORT_B=8787        # the orphan case
INT_A=$((PORT_A + 20000))
INT_B=$((PORT_B + 20000))
WORK=/tmp/bosun-liveness
REG=$WORK/registry.json
LOG=$WORK/serve.log

FAILED=0
ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; FAILED=1; }
state() { curl -s --max-time 5 "http://127.0.0.1:$STATUS/state"; }
# one route's field, by public port
field() { state | python3 -c "
import json,sys
d=json.load(sys.stdin)
r=[x for x in d['routes'] if x['publicPort']==$1]
print(r[0].get('$2') if r else 'NO-ROUTE')
"; }
listening() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

cleanup() {
  [ -n "${ROUTER_PID:-}" ] && kill -9 "$ROUTER_PID" 2>/dev/null
  [ -n "${EXTERNAL_PID:-}" ] && kill -9 "$EXTERNAL_PID" 2>/dev/null
  for p in $INT_A $INT_B $PORT_A $PORT_B; do
    pids=$(lsof -ti "tcp:$p" -sTCP:LISTEN 2>/dev/null)
    [ -n "$pids" ] && kill -9 $pids 2>/dev/null
  done
  return 0
}
trap cleanup EXIT

# `exec` matters: $! must be the ROUTER, not a shell that happens to have started
# one. Signalling the wrapper instead leaves the router (and its backends) alive,
# and the next start silently stacks a second router behind an EADDRINUSE.
start_router() {
  ( cd "$BOSUN" && exec env BOSUN_SERVE_STATUS_PORT=$STATUS node cli/run.js serve "$REG" >>"$LOG" 2>&1 ) &
  ROUTER_PID=$!
  for _ in $(seq 1 60); do listening $STATUS && return 0; sleep 0.25; done
  echo "router did not come up on :$STATUS — see $LOG"; exit 1
}

stop_router() {
  kill "-${1:-TERM}" "$ROUTER_PID" 2>/dev/null
  wait "$ROUTER_PID" 2>/dev/null
  for _ in $(seq 1 40); do listening $STATUS || return 0; sleep 0.25; done
  echo "the router on :$STATUS would not die — the rest of this run would be meaningless"; exit 1
}

echo "==> build"
( cd "$BOSUN" && spago build >/dev/null 2>&1 ) || { echo "build failed"; exit 1; }

echo "==> scratch registry + site ($WORK)"
rm -rf "$WORK"; mkdir -p "$WORK"
echo "<!doctype html><title>liveness</title><h1>ok</h1>" > "$WORK/index.html"
cat > "$REG" <<JSON
{ "servers": [
  { "id": 1, "projectId": "liveness", "projectName": "liveness", "role": "adopted",
    "port": $PORT_A, "host": "mbp", "environment": "native",
    "startCommand": "cd $WORK && python3 -m http.server $PORT_A --bind 127.0.0.1" },
  { "id": 2, "projectId": "liveness", "projectName": "liveness", "role": "orphan",
    "port": $PORT_B, "host": "mbp", "environment": "native",
    "startCommand": "cd $WORK && python3 -m http.server $PORT_B --bind 127.0.0.1" }
], "count": 2 }
JSON

# ── A. adoption is a claim about the world, re-checked ──────────────────────
echo
echo "==> A1. an external holder takes :$PORT_A before the router starts"
( cd "$WORK" && exec python3 -m http.server $PORT_A --bind 127.0.0.1 >/dev/null 2>&1 ) &
EXTERNAL_PID=$!
for _ in $(seq 1 40); do listening $PORT_A && break; sleep 0.25; done
listening $PORT_A && ok "external holder up on :$PORT_A (pid $EXTERNAL_PID)" || bad "external holder never bound :$PORT_A"

echo "==> A2. start the router; it must ADOPT, not shadow"
start_router
[ "$(field $PORT_A external)" = "True" ] && ok "external: true"   || bad "external is $(field $PORT_A external), want True"
[ "$(field $PORT_A up)"       = "True" ] && ok "up: true"         || bad "up is $(field $PORT_A up), want True"
[ "$(field $PORT_A pid)"      = "None" ] && ok "pid: null"        || bad "pid is $(field $PORT_A pid), want null"
[ "$(field $PORT_A bound)"    = "False" ] && ok "bound: false (the router holds nothing)" \
                                          || bad "bound is $(field $PORT_A bound), want False"

echo "==> A3. a reload must NOT invent a change (config has not moved)"
curl -s -X POST --max-time 10 "http://127.0.0.1:$STATUS/control/reload" >/dev/null
[ "$(field $PORT_A external)" = "True" ] && ok "still adopted after reload" \
                                         || bad "reload disturbed a live adoption"

echo "==> A4. kill the external holder — NO router restart from here on"
kill "$EXTERNAL_PID" 2>/dev/null; wait "$EXTERNAL_PID" 2>/dev/null; EXTERNAL_PID=
for _ in $(seq 1 40); do listening $PORT_A || break; sleep 0.25; done
listening $PORT_A && bad "the external holder is still listening" || ok ":$PORT_A is unheld"

echo "==> A5. the router must reclaim it on its own (watch loop, ≤10s)"
for _ in $(seq 1 40); do [ "$(field $PORT_A external)" = "False" ] && break; sleep 0.25; done
[ "$(field $PORT_A external)" = "False" ] && ok "external: false — the claim was dropped" \
                                          || bad "still external: the adoption outlived its evidence"
[ "$(field $PORT_A bound)"    = "True" ]  && ok "bound: true — the router took the port" \
                                          || bad "bound is $(field $PORT_A bound): the port was never reclaimed"
[ "$(field $PORT_A up)"       = "False" ] && ok "up: false — nothing is running, and it says so" \
                                          || bad "up is $(field $PORT_A up): up outlived its evidence"

echo "==> A6. and it lazy-spawns again"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 "http://127.0.0.1:$PORT_A/")
[ "$code" = "200" ] && ok "GET :$PORT_A -> 200 (backend lazy-spawned on :$INT_A)" \
                    || bad "GET :$PORT_A -> $code, want 200"
[ "$(field $PORT_A up)" = "True" ] && ok "up: true, with a real pid ($(field $PORT_A pid))" \
                                   || bad "up is $(field $PORT_A up) after a successful request"

# ── B. a backend must not outlive its router ────────────────────────────────
echo
echo "==> B1. spawn a backend via /control/spawn?port=$PORT_B"
curl -s -X POST --max-time 40 "http://127.0.0.1:$STATUS/control/spawn?port=$PORT_B" >/dev/null
listening $INT_B && ok "backend listening on :$INT_B" || bad "backend never bound :$INT_B"

echo "==> B2. stop the router politely (SIGTERM) — its children go with it"
stop_router TERM
for _ in $(seq 1 40); do listening $INT_B || break; sleep 0.25; done
listening $INT_B && bad ":$INT_B still held — the spawned backend outlived the router" \
                 || ok ":$INT_B released: no orphan"

echo "==> B3. now the case hooks cannot cover: SIGKILL the router"
start_router
curl -s -X POST --max-time 40 "http://127.0.0.1:$STATUS/control/spawn?port=$PORT_B" >/dev/null
listening $INT_B && ok "backend listening on :$INT_B again" || bad "backend never bound :$INT_B"
stop_router KILL
sleep 1
listening $INT_B && ok "orphan survives a SIGKILLed router (as it must — no hook can run)" \
                 || bad "expected an orphan after SIGKILL; the test cannot prove the sweep"

echo "==> B4. the NEXT router must reap it before binding"
start_router
listening $INT_B && bad ":$INT_B still held after startup — the orphan sweep did not run" \
                 || ok ":$INT_B swept clean at startup"
grep -q "orphaned .* backend from a previous router" "$LOG" && ok "the sweep said so in the log" \
                                                             || bad "no sweep line in $LOG"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 "http://127.0.0.1:$PORT_B/")
[ "$code" = "200" ] && ok "GET :$PORT_B -> 200 (a fresh backend, uncontested)" \
                    || bad "GET :$PORT_B -> $code, want 200"

echo
if [ $FAILED -eq 0 ]; then echo "✓ serve liveness: adoption re-checked, children reaped"; exit 0; fi
echo "✗ serve liveness FAILED — see $LOG"; exit 1
