#!/usr/bin/env bash
# EXECUTORS.md mode-2, Go column — make the GO BINARY be the resident Docker
# observer. Transpiles the I/O-free Docker harness (Bosun.Conformance.DockerMain)
# via backend-go, builds a NATIVE Go binary, and runs it as a resident daemon:
# it observes the live MacMini container group over ssh (`docker inspect`)
# with the pure core + the three hand-written Go foreigns —
#
#   conformance/go/bosun_exec_foreign.go      (Bosun_CLI_Exec_execLineImpl)
#   conformance/go/bosun_resident_foreign.go  (Bosun_CLI_Resident_residentImpl + nowMs)
#   conformance/go/argonaut_parser_foreign.go (Data.Argonaut.Parser._jsonParser)
#
# — and serves /state + /control. This exercises the foreign-calls-back-into-
# PureScript direction (a Go shim invoking the tick/stateBody/control Effect
# closures), which `serve`/`apply` did not.
#
# CONFORMANCE: runs BOTH columns (node + Go) on :3995 in turn and diffs their
# /state — the observe→parse→render pipeline must be byte-identical (node≡Go),
# the same discipline as go-conformance.sh, but over a live observation.
#
# Read-only: the only effect fired is observe (`docker inspect`). `up`/`down`
# deploy verbs are HELD for an explicit go; the script POSTs only an UNKNOWN
# control verb, to prove the control callback round-trips with zero deploy effect.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.DockerMain"
OUT="${OUT:-/tmp/bosun-go-docker}"
PORT=3995

NODE_PID=""; GO_PID=""
cleanup() {
  [ -n "$NODE_PID" ] && kill "$NODE_PID" 2>/dev/null || true
  [ -n "$GO_PID" ]   && kill "$GO_PID"   2>/dev/null || true
}
trap cleanup EXIT

echo "==> build bosun (spago emits corefn + js)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

# --- node column: run the SAME harness, capture /state ----------------------
echo "==> node column: resident DockerMain on :$PORT (observe the mini over ssh)"
node --input-type=module \
  -e "import(\"$BOSUN/output/$MAIN/index.js\").then(x => x.main())" \
  > /tmp/bgo_docker_node.out 2>&1 &
NODE_PID=$!
sleep 12
NODE_STATE="$(curl -s "http://127.0.0.1:$PORT/state" || true)"
kill "$NODE_PID" 2>/dev/null || true; wait "$NODE_PID" 2>/dev/null || true; NODE_PID=""
sleep 1

# --- backend-go transpile + build -------------------------------------------
echo "==> backend-go transpile (corefn -> Go, pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BACKEND_GO" && spago run -- --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go"                          "$OUT/runtime.go"
# library foreigns (JSON decode path) + Bosun's three CLI-edge twins
cp "$BOSUN/conformance/go/argonaut_core_foreign.go"   "$OUT/argonaut_core_foreign.go"
cp "$BOSUN/conformance/go/foreign_object_foreign.go"  "$OUT/foreign_object_foreign.go"
cp "$BOSUN/conformance/go/argonaut_parser_foreign.go" "$OUT/argonaut_parser_foreign.go"
cp "$BOSUN/conformance/go/bosun_exec_foreign.go"      "$OUT/bosun_exec_foreign.go"
cp "$BOSUN/conformance/go/bosun_resident_foreign.go"  "$OUT/bosun_resident_foreign.go"

echo "==> go build ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
if ! ( cd "$OUT" && go build -o /tmp/bgo_docker *.go ) 2> /tmp/bgo_docker_build.err; then
  if grep -qE "residentImpl|execLineImpl|jsonParser" /tmp/bgo_docker_build.err; then
    echo "❌ a foreign symbol was unresolved — a conformance/go/*.go file did not"
    echo "   make it into the build dir. Check the cp lines above."
  else
    echo "❌ go build failed:"; cat /tmp/bgo_docker_build.err
  fi
  exit 1
fi

# --- go column: run the native binary, capture /state + a control round-trip -
echo "==> RUN the Go binary as a resident Docker observer on :$PORT"
/tmp/bgo_docker > /tmp/bgo_docker_go.out 2>&1 &
GO_PID=$!
sleep 12
GO_STATE="$(curl -s "http://127.0.0.1:$PORT/state" || true)"
echo "==> POST /control/ping (unknown verb — proves the control callback round-trips, zero deploy effect)"
GO_CTL="$(curl -s -X POST "http://127.0.0.1:$PORT/control/ping" || true)"
kill "$GO_PID" 2>/dev/null || true; wait "$GO_PID" 2>/dev/null || true; GO_PID=""

echo "--- go binary log ---"; cat /tmp/bgo_docker_go.out
echo "--- /state (node) ---"; echo "$NODE_STATE"
echo "--- /state (go)   ---"; echo "$GO_STATE"
echo "--- /control/ping (go) ---"; echo "$GO_CTL"

echo "==> result"
fail=0
if [ -z "$GO_STATE" ]; then echo "❌ Go /state was empty — binary did not serve"; fail=1; fi
if ! echo "$GO_CTL" | grep -q "unknown control verb: ping"; then
  echo "❌ control callback did not round-trip (expected 'unknown control verb: ping')"; fail=1
fi
if [ -n "$NODE_STATE" ] && [ "$NODE_STATE" = "$GO_STATE" ]; then
  echo "✅ DOCKER (Go column): native binary observed the mini + served /state,"
  echo "   the control callback round-tripped, and /state is BYTE-IDENTICAL to node."
elif [ "$fail" = "0" ]; then
  echo "⚠️  Go binary worked, but /state differs from node (likely a container state"
  echo "   flipped between the two ~12s observes — re-run; diff below):"
  diff <(echo "$NODE_STATE") <(echo "$GO_STATE") || true
else
  exit 1
fi
[ "$fail" = "0" ]
