#!/usr/bin/env bash
# STRESS-TEST-PLAN §4 — the Go column under load, with the RACE DETECTOR.
#
# Re-runs the chaos monkeys that the single-fixture ServeMain harness supports —
# a heavy concurrent flood and a backend-kill self-heal — against the NATIVE
# backend-go binary, built with `-race` and GORACE=halt_on_error=1. This is the
# concurrency tier: goroutine-per-request + the sync.Once runtime. A surviving,
# correct run with no DATA RACE report is the pass.
#
# (The slow-backend and SIGHUP-storm monkeys need a registry-driven Go serve,
# which doesn't exist yet — ServeMain hardcodes one good fixture. Those stay on
# the node column until the Go CLI lands; noted, not silently skipped.)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.ServeMain"
OUT="${OUT:-/tmp/bosun-go-chaos}"
PUBLIC=8775 INTERNAL=28775
LOG=/tmp/bgo_chaos.out
SRV_PID=""
fail=0

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  pkill -f "http.server $INTERNAL" 2>/dev/null
}
trap cleanup EXIT

cd "$BOSUN"
echo "==> build + transpile + go build -race"
spago build >/dev/null 2>&1
mkdir -p /tmp/bosun-serve-go
echo '<!doctype html><title>go-chaos</title><h1>ok</h1>' > /tmp/bosun-serve-go/index.html
rm -rf "$OUT"
( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
( cd "$OUT" && go build -race -o /tmp/bgo_chaos *.go ) || { echo "❌ go build -race failed"; exit 1; }

echo "==> run the Go binary (resident, -race)"
GORACE="halt_on_error=1" /tmp/bgo_chaos > "$LOG" 2>&1 &
SRV_PID=$!
for i in $(seq 1 60); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PUBLIC/" 2>/dev/null && break; done

alive() { kill -0 "$SRV_PID" 2>/dev/null; }

# ── flood: 50 concurrent → all 200, race-clean ───────────────────────────────
echo "==> flood: 50 concurrent requests, under -race"
pids=()
for i in $(seq 1 50); do
  ( curl -s -o /dev/null -w "%{http_code}\n" --max-time 25 "http://127.0.0.1:$PUBLIC/" ) >> /tmp/bgo_chaos_codes &
  pids+=("$!")
done
wait "${pids[@]}" 2>/dev/null
ok=$(grep -c '^200$' /tmp/bgo_chaos_codes 2>/dev/null); rm -f /tmp/bgo_chaos_codes
{ [ "$ok" = "50" ] && alive; } && echo "  ✓ flood: 50/50 → 200, binary up" || { echo "  ✗ flood: $ok/50 200 (alive=$(alive && echo y || echo n))"; fail=1; }

# ── killer: SIGKILL the backend, re-request → respawn + 200 ──────────────────
echo "==> killer: SIGKILL the backend, then re-request"
pkill -9 -f "http.server $INTERNAL" 2>/dev/null
for i in $(seq 1 40); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PUBLIC/" 2>/dev/null && break; done
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 25 "http://127.0.0.1:$PUBLIC/")
{ [ "$code" = "200" ] && alive; } && echo "  ✓ killer: respawned → 200, binary up" || { echo "  ✗ killer: got $code"; fail=1; }

# ── race detector verdict ────────────────────────────────────────────────────
if grep -q "DATA RACE" "$LOG"; then echo "  ✗ DATA RACE reported:"; grep -A3 "DATA RACE" "$LOG" | head; fail=1
else echo "  ✓ no DATA RACE under load"; fi

echo "── binary log tail ──"; tail -5 "$LOG"
if [ "$fail" -eq 0 ]; then echo "✅ GO CHAOS: the native router held under concurrent load, race-clean"; else echo "❌ GO CHAOS: failure above"; fi
exit "$fail"
