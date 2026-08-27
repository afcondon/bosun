#!/usr/bin/env bash
# BROKER MODE, GO COLUMN — the native binary ensures-and-locates, and answers
# the lifecycle verbs (2026-08-24).
#
# WHY A NEW SCRIPT AND NOT AN EXTENSION OF go-serve.sh. `go-serve.sh` drives
# `Bosun.Conformance.ServeMain`: a hardcoded `ServiceInstance` array through the
# UNHINTED `servePlan`, served by the narrow `bosun_serve_foreign.go`. Broker
# mode cannot be reached from there at all — a broker exists only because a
# REGISTRY ROW said `serveMode: broker`, which arrives through
# `registryHints` → `servePlanWith`, and the harness has no registry. And the
# shim where the divergence actually was is the OTHER one,
# `bosun_cli_serve_foreign.go`, the twin of `cli/src/Bosun/CLI/Serve.js`. So this
# script exercises the REAL CLI — `Bosun.CLI.Main`, transpiled by backend-go and
# built WITH THE RACE DETECTOR — over a real registry, which is the only vehicle
# on which the thing under test exists.
#
# It then replays the identical request sequence against the NODE router on the
# same fixture and diffs the two answers, because "Go does something" and "the
# two columns agree" are different claims and only the second one is parity.
#
# SAFE: every service is a `python3 -m http.server` or an `nc` under /tmp, on
# scratch ports 8180-8183 with the control surface on :3996 — the live routers
# (:3990, :3994, :3997) are never touched, and the script refuses to start if
# anything already holds a port it needs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.CLI.Main"
OUT="${OUT:-/tmp/bosun-go-broker-build}"
BIN="${BIN:-/tmp/bgo_broker}"
YAML_VERSION="${YAML_VERSION:-v3.0.1}"

STATUS=3996                 # scratch control surface; the live router keeps :3997
REWRITABLE=8180             # broker the plan CAN move: router holds :8180, 307s to :28180
REWRITTEN=$((REWRITABLE + 20000))
FIXED=8181                  # broker the plan CANNOT move: stays on :8181, router binds nothing
UDP=8182                    # broker with no checkable readiness signal (probe: none)
PROXY=8183                  # the control: an ordinary proxied route
WORK=/tmp/bosun-go-broker
REG=$WORK/registry.json

FAILED=0
ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; FAILED=1; }
note() { echo "  · $*"; }

listening() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
freeport()  { local p; for p in "$@"; do lsof -ti "tcp:$p" -sTCP:LISTEN 2>/dev/null | xargs -r kill -9 2>/dev/null; done; }

cleanup() {
  [ -n "${ROUTER_PID:-}" ] && kill -9 "$ROUTER_PID" 2>/dev/null
  [ -n "${EXTERNAL_PID:-}" ] && kill -9 "$EXTERNAL_PID" 2>/dev/null
  freeport $STATUS $REWRITABLE $REWRITTEN $FIXED $UDP $PROXY $((PROXY + 20000))
  pkill -f "bosun-go-broker" 2>/dev/null
  rm -f /tmp/bosun-broker-demo.sock
}
trap cleanup EXIT

# ── refuse to run if any scratch port is already someone else's ───────────────
for p in $STATUS $REWRITABLE $REWRITTEN $FIXED $UDP $PROXY; do
  if listening "$p"; then
    echo "❌ :$p is already held — this script would fight a live process. Aborting."
    lsof -nP -iTCP:"$p" -sTCP:LISTEN
    exit 1
  fi
done

echo "==> fixture ($WORK)"
mkdir -p "$WORK/site"
cat > "$WORK/site/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>bosun broker fixture</title><h1>brokered</h1>
HTML
cat > "$REG" <<JSON
{
  "_comment": "Scratch broker fixture for scripts/go-broker.sh. Ports 8180-8183, control :3996. Every backend is a harmless python3/nc under /tmp.",
  "servers": [
    { "id": 1, "role": "worker", "projectName": "loopdemo", "projectSlug": "loopdemo",
      "port": $REWRITABLE, "host": "mbp", "serveMode": "broker",
      "startCommand": "cd $WORK/site && python3 -m http.server $REWRITABLE",
      "url": "http://127.0.0.1:$REWRITABLE",
      "description": "BROKER, rewritable: moved to :$REWRITTEN, router holds :$REWRITABLE for the 307." },
    { "id": 2, "role": "api", "projectName": "rigdemo", "projectSlug": "rigdemo",
      "port": $FIXED, "host": "mbp", "serveMode": "broker",
      "startCommand": "cd $WORK/site && python3 -m http.server \$((8000+181))",
      "url": "http://127.0.0.1:$FIXED",
      "description": "BROKER, NOT rewritable (no literal port in the command): keeps :$FIXED, router binds nothing." },
    { "id": 3, "role": "worker", "projectName": "udpdemo", "projectSlug": "udpdemo",
      "port": $UDP, "host": "mbp", "serveMode": "broker",
      "startCommand": "cd /tmp && nc -u -l $UDP",
      "url": "udp://127.0.0.1:$UDP",
      "description": "BROKER over UDP: located but deliberately NOT probed, so probe reads none." },
    { "id": 4, "role": "frontend", "projectName": "plaindemo", "projectSlug": "plaindemo",
      "port": $PROXY, "host": "mbp",
      "startCommand": "cd $WORK/site && python3 -m http.server $PROXY",
      "url": "http://127.0.0.1:$PROXY",
      "description": "NO serveMode — the control. Proxied exactly as before broker mode existed." }
  ]
}
JSON

echo "==> build bosun (spago emits corefn + js)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 ) || { echo "❌ spago build failed"; exit 1; }

echo "==> backend-go transpile (corefn -> Go, pruned to $MAIN)"
[ -d "$BACKEND_GO" ] || { echo "❌ backend-go not found at $BACKEND_GO (set BACKEND_GO)"; exit 1; }
rm -rf "$OUT"
( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 ) \
  || { echo "❌ backend-go transpile failed"; exit 1; }
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
# Only Bosun's OWN FFI twins. Foreign.Object and Data.Argonaut.{Core,Parser}
# are backend-go's foreign/ layer since 2026-08-24 and it links them itself.

echo "==> go build -race ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
(
  cd "$OUT"
  go mod init gnomonbroker >/dev/null 2>&1
  go mod edit -require=gopkg.in/yaml.v3@"$YAML_VERSION"
  GOFLAGS=-mod=mod go build -race -o "$BIN" .
) > /tmp/bgo_broker_build.err 2>&1 || { echo "❌ go build -race failed:"; cat /tmp/bgo_broker_build.err; exit 1; }
ok "native binary built with the race detector: $BIN"

# ── the request sequence, run against whichever router is up ─────────────────
#
# Identical for both columns, so the two transcripts are directly comparable.
# `record <name>` writes the answer to $1/<name>.json (+ .head for the headers).
run_sequence() {
  local dir="$1"
  mkdir -p "$dir"
  local base="http://127.0.0.1:$STATUS"

  # 1. the 307 door: dialling the REGISTERED port ensures the service, then gets
  #    out of the way. This is broker mode's whole claim in one request.
  curl -sS -D "$dir/redirect.head" -o "$dir/redirect.body" --max-time 40 "http://127.0.0.1:$REWRITABLE/" >/dev/null

  # 2. ensure-and-locate on a broker the router does NOT hold a port for
  curl -sS -o "$dir/where-fixed.json" -w '%{http_code}' --max-time 40 "$base/where?port=$FIXED" > "$dir/where-fixed.code"
  # 3. and on one addressed by service id
  curl -sS -o "$dir/where-id.json" -w '%{http_code}' --max-time 40 "$base/where/loopdemo:worker" > "$dir/where-id.code"

  # 4. STOP the brokered service the router started, then respawn it. The port is
  #    checked between the two calls, not after both — `stop` claims the daemon
  #    has actually EXITED, and that claim is only testable before the respawn.
  curl -sS -X POST -o "$dir/stop.json" -w '%{http_code}' --max-time 20 "$base/control/stop?port=$REWRITABLE" > "$dir/stop.code"
  listening "$REWRITTEN" && echo held > "$dir/after-stop.port" || echo free > "$dir/after-stop.port"
  curl -sS -X POST -o "$dir/spawn.json" -w '%{http_code}' --max-time 40 "$base/control/spawn?port=$REWRITABLE" > "$dir/spawn.code"
  listening "$REWRITTEN" && echo held > "$dir/after-spawn.port" || echo free > "$dir/after-spawn.port"

  # 5. the ADOPTED refusal: something is running at the broker's address and the
  #    router did not start it. `/where` in step 2 made rigdemo:api OURS, so stop
  #    it first — the whole point is a router that holds no child for an address
  #    that is nonetheless answering.
  curl -sS -X POST -o /dev/null --max-time 20 "$base/control/stop?service=rigdemo:api"
  for _ in $(seq 1 40); do listening "$FIXED" || break; sleep 0.1; done
  python3 -m http.server "$FIXED" --directory "$WORK/site" >/dev/null 2>&1 &
  EXTERNAL_PID=$!
  for _ in $(seq 1 60); do listening "$FIXED" && break; sleep 0.1; done
  curl -sS -X POST -o "$dir/stop-adopted.json" -w '%{http_code}' --max-time 20 "$base/control/stop?service=rigdemo:api" > "$dir/stop-adopted.code"
  # probe-first: spawn on something already running must NOT start a second copy
  curl -sS -X POST -o "$dir/spawn-running.json" -w '%{http_code}' --max-time 20 "$base/control/spawn?service=rigdemo:api" > "$dir/spawn-running.code"
  kill "$EXTERNAL_PID" 2>/dev/null; wait "$EXTERNAL_PID" 2>/dev/null; EXTERNAL_PID=""

  # 6. the UNKNOWN verdict: no child of ours, and no probe that could say
  #    whether one is needed. Stop the UDP broker twice — the second has neither.
  curl -sS -X POST -o /dev/null --max-time 20 "$base/control/spawn?port=$UDP"
  curl -sS -X POST -o /dev/null --max-time 20 "$base/control/stop?port=$UDP"
  curl -sS -X POST -o "$dir/stop-unknown.json" -w '%{http_code}' --max-time 20 "$base/control/stop?port=$UDP" > "$dir/stop-unknown.code"

  # 7. the two "no route" diagnostics, which want opposite responses
  curl -sS -X POST -o "$dir/stop-nothing.json" -w '%{http_code}' --max-time 20 "$base/control/stop?port=9999" > "$dir/stop-nothing.code"

  # 8. the whole view
  curl -sS -o "$dir/state.json" --max-time 20 "$base/state"
}

start_router() {
  local what="$1" log="$2"
  case "$what" in
    go)   BOSUN_SERVE_STATUS_PORT=$STATUS GORACE="halt_on_error=1" "$BIN" serve "$REG" > "$log" 2>&1 & ;;
    node) BOSUN_SERVE_STATUS_PORT=$STATUS node "$BOSUN/cli/run.js" serve "$REG" > "$log" 2>&1 & ;;
  esac
  ROUTER_PID=$!
  for _ in $(seq 1 100); do listening "$STATUS" && return 0; sleep 0.1; done
  echo "❌ the $what router never bound :$STATUS"; cat "$log"; return 1
}

stop_router() {
  [ -n "${ROUTER_PID:-}" ] || return 0
  kill "$ROUTER_PID" 2>/dev/null
  for _ in $(seq 1 60); do listening "$STATUS" || break; sleep 0.1; done
  freeport $STATUS $REWRITABLE $REWRITTEN $FIXED $UDP $PROXY $((PROXY + 20000))
  ROUTER_PID=""
}

# ── the Go column ────────────────────────────────────────────────────────────
echo
echo "==> RUN the Go binary as the router (-race, control on :$STATUS)"
rm -rf /tmp/bosun-broker-go /tmp/bosun-broker-node
start_router go /tmp/bgo_broker.out || exit 1
run_sequence /tmp/bosun-broker-go

echo
echo "── Go column assertions ──"
G=/tmp/bosun-broker-go

grep -qi "^HTTP/1.1 307" "$G/redirect.head" \
  && ok "GET :$REWRITABLE → 307" || bad "GET :$REWRITABLE did not answer 307 ($(head -1 "$G/redirect.head"))"
grep -qi "^location: http://127.0.0.1:$REWRITTEN/" "$G/redirect.head" \
  && ok "location is the INTERNAL address :$REWRITTEN — bosun is not in the path" \
  || bad "location header wrong: $(grep -i '^location' "$G/redirect.head")"
grep -qi "^x-bosun-mediation: broker" "$G/redirect.head" \
  && ok "x-bosun-mediation: broker" || bad "no x-bosun-mediation header"

field() { python3 -c "
import json,sys
d=json.load(open('$1'))
v=d
for k in '$2'.split('.'): v = v.get(k) if isinstance(v,dict) else None
print(json.dumps(v))
" 2>/dev/null; }

[ "$(cat "$G/where-fixed.code")" = "200" ] && ok "/where?port=$FIXED → 200" || bad "/where?port=$FIXED → $(cat "$G/where-fixed.code")"
[ "$(field "$G/where-fixed.json" started)" = "true" ] && ok "/where STARTED the absent backend (started: true)" \
  || bad "/where did not start it: started=$(field "$G/where-fixed.json" started)"
[ "$(field "$G/where-fixed.json" ready)" = "true" ] && ok "and waited for it: ready: true before answering" \
  || bad "answered before ready: $(field "$G/where-fixed.json" detail)"
[ "$(field "$G/where-fixed.json" at.port)" = "$FIXED" ] && ok "and located it at its OWN port :$FIXED (router binds nothing)" \
  || bad "wrong locator: $(field "$G/where-fixed.json" at.port)"
[ "$(field "$G/where-id.json" mediation)" = '"broker"' ] && ok "/where/loopdemo:worker resolves by service id → mediation broker" \
  || bad "/where by id: $(cat "$G/where-id.json")"
[ "$(field "$G/where-id.json" at.port)" = "$REWRITTEN" ] && ok "and hands back the REWRITTEN address :$REWRITTEN" \
  || bad "/where by id locator: $(field "$G/where-id.json" at.port)"

[ "$(cat "$G/stop.code")" = "200" ] && [ "$(field "$G/stop.json" wasRunning)" = "true" ] \
  && ok "POST /control/stop on a brokered route → 200, wasRunning: true" \
  || bad "stop: $(cat "$G/stop.code") $(cat "$G/stop.json")"
[ "$(cat "$G/after-stop.port")" = "free" ] && ok "and it is really gone — :$REWRITTEN free before the answer's ink dried" \
  || bad "the daemon is still on :$REWRITTEN after a stop that claimed it exited"
[ "$(cat "$G/spawn.code")" = "200" ] && [ "$(field "$G/spawn.json" started)" = "true" ] \
  && ok "POST /control/spawn → 200, started: true (respawn)" \
  || bad "spawn: $(cat "$G/spawn.code") $(cat "$G/spawn.json")"
[ "$(cat "$G/after-spawn.port")" = "held" ] && ok "and it is back on :$REWRITTEN" \
  || bad "respawn did not reach :$REWRITTEN"

[ "$(cat "$G/stop-adopted.code")" = "409" ] && [ "$(field "$G/stop-adopted.json" adopted)" = "true" ] \
  && ok "stop on an ADOPTED broker → 409 adopted (bosun does not kill what it did not start)" \
  || bad "adopted refusal: $(cat "$G/stop-adopted.code") $(cat "$G/stop-adopted.json")"
[ "$(field "$G/spawn-running.json" started)" = "false" ] \
  && ok "spawn on a running broker → started: false (probe first, no second copy)" \
  || bad "probe-first: $(cat "$G/spawn-running.json")"
[ "$(cat "$G/stop-unknown.code")" = "409" ] && [ "$(field "$G/stop-unknown.json" adopted)" = "null" ] \
  && ok "stop with no child and no probe → 409 unknown (not a fabricated 'it is down')" \
  || bad "unknown verdict: $(cat "$G/stop-unknown.code") $(cat "$G/stop-unknown.json")"
grep -q "no proxy route, no broker and no redirect" "$G/stop-nothing.json" \
  && ok "stop on nothing → the three-way diagnostic" || bad "diagnostic: $(cat "$G/stop-nothing.json")"

python3 -c "
import json
d=json.load(open('$G/state.json'))
b=d.get('brokered')
assert isinstance(b,list) and len(b)==3, b
assert [x['serviceId'] for x in b]==['loopdemo:worker','rigdemo:api','udpdemo:worker'], b
assert len(d['routes'])==1, d['routes']
" 2>/dev/null && ok "/state carries the brokered bucket (3 brokers + 1 proxy route)" \
  || bad "/state brokered bucket: $(python3 -c "import json;print(json.load(open('$G/state.json')).get('brokered'))" 2>/dev/null)"

if grep -q "DATA RACE" /tmp/bgo_broker.out; then
  bad "the race detector fired — see /tmp/bgo_broker.out"
else
  ok "clean under -race (no DATA RACE in the router log)"
fi

stop_router

# ── the node column, same fixture, same requests ─────────────────────────────
echo
echo "==> RUN the node router on the SAME fixture and replay the SAME requests"
start_router node /tmp/bnode_broker.out || exit 1
run_sequence /tmp/bosun-broker-node
stop_router

echo
echo "── node ≡ Go ──"
python3 - <<'PY'
import json, os, re, sys

GO, NODE = "/tmp/bosun-broker-go", "/tmp/bosun-broker-node"

# Fields that CANNOT be equal and are excluded by name, with the reason:
#   pid          — a process id, different in every run of either column
#   plannedAt    — a wall-clock stamp taken at router start
#   modifiedAt   — the registry file's mtime
#   detail       — carries the pid in exactly one branch of ensure-and-locate
# Everything else is compared exactly, including every status code, every
# verdict, every error sentence and every locator.
DROP = {"pid", "plannedAt", "modifiedAt"}

# KNOWN, NAMED DIVERGENCES — a LEDGER, not an exclusion list, and the difference
# matters. Every entry must still be divergent: a gap that has been closed FAILS
# this check, so the ledger cannot quietly outlive the thing it excuses. Anything
# divergent that is NOT listed here fails too. Between the two, the only way to
# stay green is for the two columns to differ in exactly the ways someone wrote
# down and gave a reason for.
KNOWN = {
    "$.routes[].adoptedBackend":
        "adopt-or-spawn (relay to a backend already on the internal port) is node-only",
    "$.routes[].adoptedBackendAt":
        "same feature: the Go column has no adopted-backend claim to timestamp",
    "$.routes[].externalCheckedAt":
        "recheckAdopted (re-probe an adopted public port on a clock) is node-only",
}

def norm(x):
    if isinstance(x, dict):
        return {k: norm(v) for k, v in sorted(x.items()) if k not in DROP}
    if isinstance(x, list):
        return [norm(v) for v in x]
    return x

def diffs(a, b, path="$"):
    """Every leaf on which the two answers disagree, named by its path — a
    whole-body dump makes a one-field divergence unfindable."""
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            out += diffs(a.get(k, "<absent>"), b.get(k, "<absent>"), f"{path}.{k}")
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out += diffs(x, y, f"{path}[{i}]")
        return out
    return [] if a == b else [(path, a, b)]

def generic(path):
    """`$.routes[3].pid` → `$.routes[].pid` — the ledger keys on the FIELD, not
    on which element of the fixture happened to expose it."""
    return re.sub(r"\[\d+\]", "[]", path)

names = ["where-fixed", "where-id", "stop", "spawn", "stop-adopted",
         "spawn-running", "stop-unknown", "stop-nothing", "state"]
bad = 0
seen = set()
for n in names:
    gp, np_ = f"{GO}/{n}.json", f"{NODE}/{n}.json"
    if not (os.path.exists(gp) and os.path.exists(np_)):
        print(f"  ✗ {n}: missing on one column"); bad += 1; continue
    try:
        g, nd = norm(json.load(open(gp))), norm(json.load(open(np_)))
    except Exception as e:
        print(f"  ✗ {n}: unparseable ({e})"); bad += 1; continue
    gc = open(f"{GO}/{n}.code").read().strip() if os.path.exists(f"{GO}/{n}.code") else ""
    nc = open(f"{NODE}/{n}.code").read().strip() if os.path.exists(f"{NODE}/{n}.code") else ""
    if gc != nc:
        print(f"  ✗ {n}: status {gc} (go) vs {nc} (node)"); bad += 1; continue
    found = diffs(g, nd)
    unexpected = [(p, a, b) for p, a, b in found if generic(p) not in KNOWN]
    seen |= {generic(p) for p, _, _ in found}
    if unexpected:
        print(f"  ✗ {n}: bodies differ in a way nobody wrote down")
        for path, a, b in unexpected:
            print(f"      {path}: go={json.dumps(a)[:120]}  node={json.dumps(b)[:120]}")
        bad += 1
        continue
    if found:
        print(f"  ! {n}: agrees except on {len(found)} LEDGERED field(s) (status {gc})")
        for path, _, _ in found:
            print(f"      {path} — {KNOWN[generic(path)]}")
        continue
    print(f"  ✓ {n}: identical (status {gc}) once pid/plannedAt/modifiedAt are excluded")

for obs, what in (("after-stop.port", "the port is free after a stop"),
                  ("after-spawn.port", "the port is held after a respawn")):
    g, nd = open(f"{GO}/{obs}").read().strip(), open(f"{NODE}/{obs}").read().strip()
    if g == nd:
        print(f"  ✓ {obs}: both columns observe {g} — {what}")
    else:
        print(f"  ✗ {obs}: go={g} node={nd}"); bad += 1

for f in ("redirect.head",):
    def hdr(p):
        out = {}
        for line in open(p):
            if ":" in line and not line.startswith("HTTP/"):
                k, _, v = line.partition(":")
                out[k.strip().lower()] = v.strip()
        return out
    g, nd = hdr(f"{GO}/{f}"), hdr(f"{NODE}/{f}")
    keys = ["location", "x-bosun-mediation", "x-bosun-ready"]
    if all(g.get(k) == nd.get(k) for k in keys):
        print(f"  ✓ {f}: location + x-bosun-* headers identical ({g.get('location')})")
    else:
        print(f"  ✗ {f}: {[(k, g.get(k), nd.get(k)) for k in keys]}"); bad += 1


# The ledger must not outlive the gaps it excuses. An entry nobody found any
# more is a divergence that has been CLOSED, and leaving it listed is how a
# check quietly stops checking.
for stale in sorted(set(KNOWN) - seen):
    print(f"  ✗ {stale} no longer diverges — delete it from KNOWN in this script")
    bad += 1

sys.exit(1 if bad else 0)
PY
[ $? -ne 0 ] && FAILED=1

echo
if [ "$FAILED" -eq 0 ]; then
  echo "✅ BROKER (Go column): the native binary brokers, locates and controls — and agrees with node."
else
  echo "❌ BROKER (Go column): see the ✗ lines above. Router logs: /tmp/bgo_broker.out /tmp/bnode_broker.out"
fi

echo
echo "==> cleanup check"
for p in $STATUS $REWRITABLE $REWRITTEN $FIXED $UDP $PROXY; do
  listening "$p" && { echo "  ! :$p still held"; FAILED=1; } || echo "  · :$p released"
done
exit $FAILED
