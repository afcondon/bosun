#!/usr/bin/env bash
# STRESS-TEST-PLAN §2 — chaos monkeys against a LIVE `bosun serve` (node column).
#
# Stands up a resident serve over a chaos registry (a good backend, a hang-on-
# request backend, a bind-then-die backend), then unleashes monkeys and asserts
# the router stays UP and behaves: single-flight under flood, self-heal after a
# backend is killed, 504 (not a wedge) on a hung backend, survival through a
# SIGHUP storm against a flapping registry, and no deadlock on bind-then-die.
#
# Each monkey prints PASS/FAIL; a non-zero exit means the router misbehaved.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/../.." && pwd)"
GOOD=8210 SLOW=8211 DIE=8212 STATUS=3997
REG=/tmp/bosun-chaos-reg.json
LOG=/tmp/bosun-chaos-serve.log
SRV_PID=""
fail=0

cd "$BOSUN"

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  pkill -f "http.server 28210" 2>/dev/null
  pkill -f "chaos/slow-backend.py" 2>/dev/null
  pkill -f "chaos/die-backend.py" 2>/dev/null
}
trap cleanup EXIT

alive() { kill -0 "$SRV_PID" 2>/dev/null; }
pass()  { echo "  ✓ $1"; }
flunk() { echo "  ✗ $1"; fail=1; }

writeReg() {  # $1 = include the "extra" flapping service?
  cat > "$REG" <<JSON
{ "servers": [
  { "role": "web", "projectName": "good-svc", "projectSlug": "good-svc", "port": $GOOD, "host": "mbp",
    "startCommand": "cd /tmp && python3 -m http.server $GOOD" },
  { "role": "web", "projectName": "slow-svc", "projectSlug": "slow-svc", "port": $SLOW, "host": "mbp",
    "startCommand": "cd $BOSUN && python3 scripts/chaos/slow-backend.py $SLOW" },
  { "role": "web", "projectName": "die-svc", "projectSlug": "die-svc", "port": $DIE, "host": "mbp",
    "startCommand": "cd $BOSUN && python3 scripts/chaos/die-backend.py $DIE" }$(
  [ "${1:-}" = "extra" ] && echo ',
  { "role": "web", "projectName": "extra-svc", "projectSlug": "extra-svc", "port": 8213, "host": "mbp",
    "startCommand": "cd /tmp && python3 -m http.server 8213" }')
] }
JSON
}

echo "==> build + start serve"
spago build >/dev/null 2>&1
writeReg
node cli/run.js serve "$REG" > "$LOG" 2>&1 &
SRV_PID=$!
for i in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$STATUS/state" 2>/dev/null && break; done

# ── monkey 1: request flood → all 200, single-flight (one spawn) ─────────────
echo "==> flood: 40 concurrent requests at the good route"
pids=()
for i in $(seq 1 40); do
  ( curl -s -o /dev/null -w "%{http_code}\n" --max-time 20 "http://127.0.0.1:$GOOD/" ) >> /tmp/bosun-chaos-flood &
  pids+=("$!")
done
wait "${pids[@]}" 2>/dev/null
ok200=$(grep -c '^200$' /tmp/bosun-chaos-flood 2>/dev/null); rm -f /tmp/bosun-chaos-flood
spawns=$(grep -c '⟳ spawn good-svc:web' "$LOG")
{ [ "$ok200" = "40" ] && alive; } && pass "flood: 40/40 → 200, router up" || flunk "flood: $ok200/40 200 (alive=$(alive && echo y || echo n))"
[ "$spawns" = "1" ] && pass "flood: single-flight (1 spawn for 40 concurrent)" || flunk "flood: $spawns spawns (expected 1)"

# ── monkey 2: backend killer → respawn + 200 ─────────────────────────────────
echo "==> killer: SIGKILL the good backend, then re-request"
pkill -9 -f "http.server 28210" 2>/dev/null
for i in $(seq 1 30); do curl -s -o /dev/null "http://127.0.0.1:$GOOD/" 2>/dev/null && break; done
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "http://127.0.0.1:$GOOD/")
{ [ "$code" = "200" ] && alive; } && pass "killer: respawned → 200, router up" || flunk "killer: got $code"

# ── monkey 3: hung backend → 504 (proxy timeout), not a wedge ────────────────
echo "==> slow: request the hang-forever backend (expect 504 via 8s proxy timeout)"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "http://127.0.0.1:$SLOW/")
{ [ "$code" = "504" ] && alive; } && pass "slow: 504 (timed out, not wedged), router up" || flunk "slow: got $code (expected 504)"

# ── monkey 4: bind-then-die → no deadlock, router survives ───────────────────
echo "==> die: request the bind-then-die backend (expect 502/504, no hang)"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "http://127.0.0.1:$DIE/")
{ alive; } && pass "die: router survived (code $code), no deadlock" || flunk "die: router died"

# ── monkey 5: SIGHUP storm on a flapping registry → survive + converge ───────
echo "==> sighup storm: 6 reloads flapping the registry"
for i in $(seq 1 6); do
  if [ $((i % 2)) -eq 0 ]; then writeReg extra; else writeReg; fi
  kill -HUP "$SRV_PID" 2>/dev/null
done
writeReg extra; kill -HUP "$SRV_PID" 2>/dev/null
for i in $(seq 1 40); do curl -s "http://127.0.0.1:$STATUS/state" 2>/dev/null | grep -q 8213 && break; done
state=$(curl -s --max-time 3 "http://127.0.0.1:$STATUS/state")
{ alive && echo "$state" | grep -q '"publicPort": 8213'; } && pass "sighup storm: survived 7 reloads, converged to final registry" || flunk "sighup storm: alive=$(alive && echo y || echo n), 8213 present=$(echo "$state" | grep -q 8213 && echo y || echo n)"

echo "── serve log tail ──"; tail -6 "$LOG"
if [ "$fail" -eq 0 ]; then echo "✅ CHAOS: the router held under every monkey"; else echo "❌ CHAOS: a monkey broke it (above)"; fi
exit "$fail"
