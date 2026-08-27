#!/usr/bin/env bash
# The Menagerie — DUAL-RUNTIME behavioural conformance rig (docs/MENAGERIE.md),
# MVP triad. Boots ticker + slowboot + forker under `bosun supervise` and asserts
# REAL effects (not command strings — a byte-diff can't catch "recorded pgid ≠
# live", the 2026-06-19 `down` no-op): ports actually bind, boot-grace is held
# with no relaunch storm, `down` reaps the whole pgid tree (forker's child
# workers too — the direct regression guard), `up` returns to green.
#
# Runs the SAME assertions against BOTH binaries, SEQUENTIALLY on :8788:
#   · NODE   — the real CLI `bosun supervise` (output/…/Bosun.CLI.Main via run.js)
#   · GNOMON — the backend-go native binary of Bosun.Conformance.MenagerieMain,
#              which runs the IDENTICAL `superviseResident` over the same embedded
#              cast (only new Go surface: cli/src/Bosun/CLI/Observe.go).
# Then diffs the two `/state` snapshots at the green checkpoint (modulo
# timestamps) — the dual-runtime dogfood: anything Gnomon gets wrong, Node is the
# oracle. If backend-go is absent, the Gnomon column is SKIPPED (not failed).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
FIX="$BOSUN/fixtures/menagerie"
MAIN="Bosun.Conformance.MenagerieMain"
OUT="${OUT:-/tmp/bosun-go-menagerie}"
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
canon(){ sed -E 's/"lastTransitionAt": [0-9.]+/"lastTransitionAt": T/g'; }

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

# ── GNOMON column ────────────────────────────────────────────────────────────
if [ ! -d "$BACKEND_GO" ]; then
  echo ""
  note "backend-go not found at $BACKEND_GO — Gnomon column SKIPPED (set BACKEND_GO to enable the dual-runtime diff)"
else
  echo ""
  echo "==> [gnomon] backend-go transpile (corefn -> Go, pruned to $MAIN)"
  rm -rf "$OUT"
  ( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
  cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
  # Bosun's OWN FFI only; the library foreigns are backend-go's foreign/ layer.
  echo "==> [gnomon] go build ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
  if ! ( cd "$OUT" && go build -o /tmp/bgo_menagerie *.go ) 2> /tmp/bgo_menagerie_build.err; then
    if grep -qE "probe(Http|Tcp|Socket|PgidAlive)Impl|execLineImpl|residentImpl|jsonParser" /tmp/bgo_menagerie_build.err; then
      echo "   ✗ a foreign symbol was unresolved — a co-located *.go was not picked up into $OUT"
    else
      echo "   ✗ go build failed:"; cat /tmp/bgo_menagerie_build.err
    fi
    fail=1
  else
    echo "==> [gnomon] RUN the native binary as the resident supervisor on :$PORT"
    /tmp/bgo_menagerie >/tmp/menagerie-go.log 2>&1 &
    SUP_PID=$!
    if wait_control; then
      ok "[gnomon] control surface answering on :$PORT"
      assert_column gnomon /tmp/menagerie-state-go.txt
    else
      bad "[gnomon] control surface never came up — see /tmp/menagerie-go.log"
    fi
    stop_supervisor

    echo ""
    echo "== /state cross-runtime parity (node ≡ gnomon, modulo timestamps) =="
    if [ -s /tmp/menagerie-state-node.txt ] && [ -s /tmp/menagerie-state-go.txt ]; then
      if diff /tmp/menagerie-state-node.txt /tmp/menagerie-state-go.txt >/dev/null; then
        ok "green /state is byte-identical across runtimes (the dogfood: Gnomon matches the Node oracle)"
      else
        bad "/state DIVERGED between node and gnomon:"
        diff /tmp/menagerie-state-node.txt /tmp/menagerie-state-go.txt
      fi
    else
      bad "missing a /state snapshot — cannot diff runtimes"
    fi
  fi
fi

echo ""
if [ "$fail" = 0 ]; then
  echo "✅ MENAGERIE: all behavioural assertions passed (node$([ -x /tmp/bgo_menagerie ] && echo ' + gnomon, /state parity'))"
else
  echo "❌ MENAGERIE: failures above — see /tmp/menagerie-{node,go}.log"
fi
exit $fail
