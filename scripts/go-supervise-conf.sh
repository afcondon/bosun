#!/usr/bin/env bash
# Conformance column for the SUPERVISOR's pure tick-transition
# (Bosun.Supervisor — the relaunch-storm fix). Same pattern as go-conformance.sh:
# compile Bosun.Conformance.SuperviseMain (a scripted, I/O-free walk through
# refine -> recordLaunches over a fixed (now, observation) sequence) two ways —
# node and purescript-go (backend-go) — and diff. Byte-identical = the
# supervisor's decision logic (boot-grace, backoff, badge counters) is provably
# the same on both backends, like plan/applyScript before it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.SuperviseMain"
OUT="${OUT:-/tmp/bosun-go-supconf}"

echo "==> build bosun (spago emits corefn + js)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

echo "==> node column"
node --input-type=module \
  -e "import(\"$BOSUN/output/$MAIN/index.js\").then(x => x.main())" > /tmp/bsup_node.txt

echo "==> backend-go transpile (corefn -> Go, pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"

echo "==> go build + run ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
( cd "$OUT" && go build -o /tmp/bsup_bosun *.go )
/tmp/bsup_bosun > /tmp/bsup_go.txt

echo "==> diff"
if diff /tmp/bsup_node.txt /tmp/bsup_go.txt >/dev/null; then
  echo "✅ CONFORMANCE: supervisor transition is byte-identical (node ≡ purescript-go)"
  echo "--- digest (both columns) ---"
  cat /tmp/bsup_go.txt
else
  echo "❌ DIVERGENCE between node and purescript-go:"
  diff /tmp/bsup_node.txt /tmp/bsup_go.txt
  exit 1
fi
