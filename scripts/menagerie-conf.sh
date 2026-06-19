#!/usr/bin/env bash
# The Menagerie — behavioural conformance rig (docs/MENAGERIE.md), MVP triad.
#
# Boots ticker + slowboot + forker under `bosun supervise` and asserts REAL
# effects, not command strings: ports actually bind, boot-grace is held with no
# relaunch storm, `down` reaps the whole pgid tree (forker's child workers too),
# and `up` returns to green. This is the run-it-for-real tier the 2026-06-19
# `down` no-op proved we lacked — a byte-diff can't catch "recorded pgid ≠ live".
# forker is the direct regression guard for that bug.
#
# This is the NODE column. The Gnomon column (TCP/HTTP/socket probe foreigns in
# Go + a supervise-resident conformance main, then a /state cross-runtime diff)
# is the next increment — the existing resident + exec foreigns already cover
# part of it (see scripts/go-docker.sh / go-apply.sh).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
FIX="$BOSUN/fixtures/menagerie"
PORT=8788                       # control surface (distinct from supervise's 3996 default)
TICKER=8790 SLOWBOOT=8791 FORKER=8792
PORTS=($TICKER $SLOWBOOT $FORKER)
SUP_PID=""
LOG=/tmp/menagerie-node.log
fail=0

ok()  { echo "   ✓ $*"; }
bad() { echo "   ✗ $*"; fail=1; }
note(){ echo "   · $*"; }

state(){ curl -s "http://127.0.0.1:$PORT/state" 2>/dev/null; }
ctl(){ curl -s -X POST "http://127.0.0.1:$PORT/control/$1" 2>/dev/null; }
# count a status token as it appears as a quoted /state value (e.g. "running")
count_token(){ state | grep -o "\"$1\"" | wc -l | tr -d ' '; }
listeners(){ lsof -ti :"$1" 2>/dev/null | wc -l | tr -d ' '; }
# how many live processes share the given pgid
group_size(){ ps -Ao pgid= 2>/dev/null | tr -d ' ' | grep -cx "$1"; }

cleanup(){
  [ -n "$SUP_PID" ] && kill "$SUP_PID" 2>/dev/null
  # belt-and-braces: reap any specimen still bound, by its process GROUP, then
  # mop up by command match. We touch ONLY menagerie processes — never a blanket
  # /tmp pidfile wipe (those may belong to a real supervisor / the Chair).
  for p in "${PORTS[@]}"; do
    pid=$(lsof -ti :"$p" 2>/dev/null | head -1)
    [ -n "$pid" ] && kill -- -"$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null
  done
  pkill -f 'menagerie/bin' 2>/dev/null
  true
}
trap cleanup EXIT INT TERM

echo "==> build bosun"
( cd "$BOSUN" && spago build >/dev/null 2>&1 ) || { echo "build failed"; exit 1; }

# start clean: nothing of ours should be lingering on the specimen ports
for p in "${PORTS[@]}"; do
  pid=$(lsof -ti :"$p" 2>/dev/null | head -1)
  [ -n "$pid" ] && kill -- -"$(ps -o pgid= -p "$pid" | tr -d ' ')" 2>/dev/null
done
sleep 1

echo "==> boot the rig under the NODE binary (supervise on :$PORT)"
node "$BOSUN/cli/run.js" supervise --port "$PORT" "$FIX/compose.yml" "$FIX/registry.json" >"$LOG" 2>&1 &
SUP_PID=$!

# wait for the control surface
up=0
for _ in $(seq 1 15); do [ -n "$(state)" ] && { up=1; break; }; sleep 1; done
[ "$up" = 1 ] || { echo "   ✗ control surface never came up — see $LOG"; cat "$LOG"; exit 1; }
ok "control surface answering on :$PORT"

echo ""
echo "== boot-grace (slowboot is Starting, not Down; ticker+forker already Running) =="
sleep 4
S="$(state)"
note "/state: $S"
[ "$(count_token starting)" -ge 1 ] && ok "slowboot reads 'starting' during its 8s boot (boot-grace held)" \
                                     || bad "expected a 'starting' service during boot, got none"
[ "$(count_token running)" -ge 2 ] && ok "ticker + forker already 'running'" \
                                    || bad "expected >=2 'running' early, got $(count_token running)"

echo ""
echo "== steady state (all green within boot grace; NO relaunch storm) =="
green=0
for _ in $(seq 1 15); do [ "$(count_token running)" -ge 3 ] && { green=1; break; }; sleep 1; done
[ "$green" = 1 ] && ok "all 3 specimens 'running'" || bad "rig did not reach 3 running"
[ "$(count_token starting)" -eq 0 ] && ok "no service stuck 'starting'" || bad "a service is still 'starting'"
# no storm: nobody restarted during the slow boot
if state | grep -qE '"restarts": [1-9]'; then
  bad "a service restarted during bring-up — relaunch storm (slowboot should launch ONCE)"
else
  ok "zero restarts during bring-up — slowboot launched exactly once (no storm)"
fi
# one listener per port (no duplicate launches)
for p in "${PORTS[@]}"; do
  n=$(listeners "$p")
  [ "$n" -eq 1 ] && ok "port $p: exactly one listener" || bad "port $p: $n listeners (expected 1)"
done

echo ""
echo "== forker's process group has its 2 child workers =="
FPID=$(lsof -ti :"$FORKER" 2>/dev/null | head -1)
FPGID=$(ps -o pgid= -p "$FPID" 2>/dev/null | tr -d ' ')
GS=$(group_size "$FPGID")
note "forker pid=$FPID pgid=$FPGID group_size=$GS"
[ "$GS" -ge 3 ] && ok "forker group has forker + 2 workers ($GS procs)" \
                || bad "forker group has $GS procs (expected >=3: forker + 2 workers)"

echo ""
echo "== down: ALL ports free AND forker's whole tree reaped (THE regression guard) =="
ctl down >/dev/null
allfree=0
for _ in $(seq 1 12); do
  free=1; for p in "${PORTS[@]}"; do [ "$(listeners "$p")" -ne 0 ] && free=0; done
  [ "$free" = 1 ] && { allfree=1; break; }; sleep 1
done
[ "$allfree" = 1 ] && ok "all specimen ports freed" || bad "a specimen port still bound after down"
GS_AFTER=$(group_size "$FPGID")
[ "$GS_AFTER" -eq 0 ] && ok "forker's child workers reaped too — no orphans (down bug stays fixed)" \
                      || bad "forker group still has $GS_AFTER procs after down — ORPHANED CHILDREN (the bug)"

echo ""
echo "== up: clean return to full green =="
ctl up >/dev/null
green2=0
for _ in $(seq 1 20); do [ "$(count_token running)" -ge 3 ] && { green2=1; break; }; sleep 1; done
[ "$green2" = 1 ] && ok "rig back to 3 running after up" || bad "rig did not return to green after up"

echo ""
if [ "$fail" = 0 ]; then
  echo "✅ MENAGERIE (node): all behavioural assertions passed"
else
  echo "❌ MENAGERIE (node): failures above — see $LOG"
fi
exit $fail
