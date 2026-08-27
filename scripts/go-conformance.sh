#!/usr/bin/env bash
# purescript-go conformance column (BUILD-PLAN Phase 4 — the backend-go MVP gate).
#
# Compile the pure Detect pipeline (reconcile -> validate -> renderReport) over
# a fixed fixture (Bosun.Conformance.Main, no I/O) two ways — the standard node
# backend and purescript-go (backend-go, Path B via the optimizer) — and diff
# the two report strings. Byte-identical = the signal-box conformance pattern
# realised for Bosun, and the gate purescript-go must pass to ship its MVP.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.Main"
OUT="${OUT:-/tmp/bosun-go-conf}"

echo "==> build bosun (spago emits corefn + js)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

echo "==> node column"
node --input-type=module \
  -e "import(\"$BOSUN/output/$MAIN/index.js\").then(x => x.main())" > /tmp/bgo_node.txt

echo "==> backend-go transpile (corefn -> Go, pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"

echo "==> go build + run ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
( cd "$OUT" && go build -o /tmp/bgo_bosun *.go )
/tmp/bgo_bosun > /tmp/bgo_go.txt

echo "==> diff"
if diff /tmp/bgo_node.txt /tmp/bgo_go.txt >/dev/null; then
  echo "✅ CONFORMANCE: node and purescript-go are byte-identical"
  echo "--- report (both columns) ---"
  cat /tmp/bgo_go.txt
else
  echo "❌ DIVERGENCE between node and purescript-go:"
  diff /tmp/bgo_node.txt /tmp/bgo_go.txt
  exit 1
fi
