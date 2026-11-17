#!/usr/bin/env bash
# The Menagerie — DUAL-RUNTIME behavioural conformance rig (docs/MENAGERIE.md),
# MVP triad. Boots ticker + slowboot + forker under `bosun supervise` and asserts
# REAL effects (not command strings — a byte-diff can't catch "recorded pgid ≠
# live", the 2026-06-19 `down` no-op): ports actually bind, boot-grace is held
# with no relaunch storm, `down` reaps the whole pgid tree (forker's child
# workers too — the direct regression guard), `up` returns to green.
#
# Runs the SAME assertions against BOTH runtimes, SEQUENTIALLY on :8788, each
# the real CLI `bosun supervise`:
#   · NODE — output/…/Bosun.CLI.Main via run.js
#   · BEAM — the same source lowered by purerl (beam/bosun)
# Then diffs the two `/state` snapshots at the green checkpoint (modulo
# timestamps). If erl is absent, the BEAM column is SKIPPED (not failed).
# (There was a third, Go column until 2026-11-17.)
#
# CAUTION: the BEAM column runs beam/build.sh in this checkout. Do not run this
# where a live supervisor runs from beam/ebin; use a worktree.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
FIX="$BOSUN/fixtures/menagerie"
PORT=8788                       # control surface (distinct from supervise's 3996 default)
TICKER=8790 SLOWBOOT=8791 FORKER=8792
PORTS=($TICKER $SLOWBOOT $FORKER)
SUP_PID=""
fail=0

ok()  { echo "   ✓ $*"; }
bad() { echo "   ✗ $*"; fail=1; }
note(){ echo "   · $*"; }

state(){ curl -s "http://127.0.0.1:$PORT/state" 2>/dev/null; }
ctl(){ curl -s -X POST "http://127.0.0.1:$PORT/control/$1" 2>/dev/null; }
count_token(){ state | grep -o "\"$1\"" | wc -l | tr -d ' '; }
listeners(){ lsof -ti :"$1" 2>/dev/null | wc -l | tr -d ' '; }
group_size(){ ps -Ao pgid= 2>/dev/null | tr -d ' ' | grep -cx "$1"; }
# canonicalise a /state body for the cross-runtime diff: only timestamps vary at
# a quiescent green checkpoint (restarts/fails 0, suspendedUntil null).
# (The BEAM prints a float as 1.79e+12 where node prints 1790000000000.0: the
# same number, so the pattern takes an exponent too.)
# The `holders` map carries live process ids, which differ on every run: mask
# them too. (They joined /state after this rig was written, and from then until
# 2026-11-11 the parity diff below failed on every run for that reason alone.)
canon(){ sed -E 's/"lastTransitionAt": [0-9.e+]+/"lastTransitionAt": T/g; s/"pids": \[[0-9, ]*\]/"pids": P/g'; }

cleanup_ports(){
  # touch ONLY menagerie processes — never a blanket /tmp pidfile wipe (those may
  # belong to a real supervisor / the Chair).
  for p in "${PORTS[@]}"; do
    pid=$(lsof -ti :"$p" 2>/dev/null | head -1)
    [ -n "$pid" ] && kill -- -"$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" 2>/dev/null
  done
  pkill -f 'menagerie/bin' 2>/dev/null
  true
}
stop_supervisor(){
  [ -n "$SUP_PID" ] && kill "$SUP_PID" 2>/dev/null
  SUP_PID=""
  sleep 1
  cleanup_ports
}
trap stop_supervisor EXIT INT TERM

wait_control(){
  for _ in $(seq 1 15); do [ -n "$(state)" ] && return 0; sleep 1; done
  return 1
}

# Run the full behavioural battery against the supervisor already serving :8788.
# $1 = column label; $2 = file to write the canonical green /state to (for the diff).
assert_column(){
  local label="$1" out="$2" green=0 g2=0 allfree=0 free fpid fpgid gs gsa p n
  echo ""
  echo "== [$label] boot-grace (slowboot Starting; ticker+forker Running) =="
  sleep 4
  [ "$(count_token starting)" -ge 1 ] && ok "[$label] slowboot 'starting' during its 8s boot (boot-grace held)" \
                                       || bad "[$label] expected a 'starting' service during boot, got none"
  [ "$(count_token running)" -ge 2 ] && ok "[$label] ticker + forker already 'running'" \
                                      || bad "[$label] expected >=2 'running' early, got $(count_token running)"

  echo "== [$label] steady state (all green within boot grace; NO relaunch storm) =="
  for _ in $(seq 1 15); do [ "$(count_token running)" -ge 3 ] && { green=1; break; }; sleep 1; done
  [ "$green" = 1 ] && ok "[$label] all 3 specimens 'running'" || bad "[$label] rig did not reach 3 running"
  [ "$(count_token starting)" -eq 0 ] && ok "[$label] no service stuck 'starting'" || bad "[$label] a service still 'starting'"
  if state | grep -qE '"restarts": [1-9]'; then
    bad "[$label] a service restarted during bring-up — relaunch storm (slowboot should launch ONCE)"
  else
    ok "[$label] zero restarts during bring-up — slowboot launched exactly once (no storm)"
  fi
  for p in "${PORTS[@]}"; do
    n=$(listeners "$p")
    [ "$n" -eq 1 ] && ok "[$label] port $p: exactly one listener" || bad "[$label] port $p: $n listeners (expected 1)"
  done
  state | canon > "$out"        # capture the green checkpoint for the cross-runtime diff

  echo "== [$label] forker's process group has its 2 child workers =="
  fpid=$(lsof -ti :"$FORKER" 2>/dev/null | head -1)
  fpgid=$(ps -o pgid= -p "$fpid" 2>/dev/null | tr -d ' ')
  gs=$(group_size "$fpgid")
  note "forker pid=$fpid pgid=$fpgid group_size=$gs"
  [ "$gs" -ge 3 ] && ok "[$label] forker group = forker + 2 workers ($gs procs)" \
                  || bad "[$label] forker group has $gs procs (expected >=3)"

  echo "== [$label] down: ALL ports free AND forker's whole tree reaped (THE regression guard) =="
  ctl down >/dev/null
  for _ in $(seq 1 12); do
    free=1; for p in "${PORTS[@]}"; do [ "$(listeners "$p")" -ne 0 ] && free=0; done
    [ "$free" = 1 ] && { allfree=1; break; }; sleep 1
  done
  [ "$allfree" = 1 ] && ok "[$label] all specimen ports freed" || bad "[$label] a specimen port still bound after down"
  gsa=$(group_size "$fpgid")
  [ "$gsa" -eq 0 ] && ok "[$label] forker's child workers reaped too — no orphans (down bug stays fixed)" \
                   || bad "[$label] forker group still has $gsa procs after down — ORPHANED CHILDREN (the bug)"

  echo "== [$label] up: clean return to full green =="
  ctl up >/dev/null
  for _ in $(seq 1 20); do [ "$(count_token running)" -ge 3 ] && { g2=1; break; }; sleep 1; done
  [ "$g2" = 1 ] && ok "[$label] rig back to 3 running after up" || bad "[$label] rig did not return to green after up"
}

echo "==> build bosun"
( cd "$BOSUN" && spago build >/dev/null 2>&1 ) || { echo "build failed"; exit 1; }
cleanup_ports; sleep 1

# ── NODE column ──────────────────────────────────────────────────────────────
echo "==> [node] boot the rig under the real CLI (supervise on :$PORT)"
node "$BOSUN/cli/run.js" supervise --port "$PORT" "$FIX/compose.yml" "$FIX/registry.json" >/tmp/menagerie-node.log 2>&1 &
SUP_PID=$!
wait_control || { echo "   ✗ [node] control surface never came up — see /tmp/menagerie-node.log"; cat /tmp/menagerie-node.log; exit 1; }
ok "[node] control surface answering on :$PORT"
assert_column node /tmp/menagerie-state-node.txt
stop_supervisor

# ── BEAM column ──────────────────────────────────────────────────────────────
# The real CLI again, lowered by purerl and run on the BEAM (beam/README.md).
# Same compose file, read by yamerl. SKIPPED, not failed, when erl is absent.
BEAM_RAN=0
if ! command -v erl >/dev/null 2>&1 || [ ! -x "$BOSUN/beam/build.sh" ]; then
  echo ""
  note "erl or beam/build.sh not found: BEAM column SKIPPED"
else
  echo ""
  echo "==> [beam] purerl build (PureScript -> Erlang -> .beam)"
  if ! "$BOSUN/beam/build.sh"; then
    bad "[beam] build failed"
  else
    echo "==> [beam] RUN the real CLI on the BEAM as the resident supervisor on :$PORT"
    "$BOSUN/beam/bosun" supervise --port "$PORT" "$FIX/compose.yml" "$FIX/registry.json" >/tmp/menagerie-beam.log 2>&1 &
    SUP_PID=$!
    if wait_control; then
      ok "[beam] control surface answering on :$PORT"
      assert_column beam /tmp/menagerie-state-beam.txt
      BEAM_RAN=1
    else
      bad "[beam] control surface never came up: see /tmp/menagerie-beam.log"
    fi
    stop_supervisor

    echo ""
    echo "== /state cross-runtime parity (node ≡ beam, modulo timestamps) =="
    if [ -s /tmp/menagerie-state-node.txt ] && [ -s /tmp/menagerie-state-beam.txt ]; then
      if diff /tmp/menagerie-state-node.txt /tmp/menagerie-state-beam.txt >/dev/null; then
        ok "green /state is byte-identical across runtimes (the BEAM matches the Node oracle)"
      else
        bad "/state DIVERGED between node and beam:"
        diff /tmp/menagerie-state-node.txt /tmp/menagerie-state-beam.txt
      fi
    else
      bad "missing a /state snapshot: cannot diff runtimes"
    fi
  fi
fi

echo ""
if [ "$fail" = 0 ]; then
  echo "✅ MENAGERIE: all behavioural assertions passed (node$([ "$BEAM_RAN" = 1 ] && echo ' + beam'), /state parity)"
else
  echo "❌ MENAGERIE: failures above — see /tmp/menagerie-{node,beam}.log"
fi
exit $fail
