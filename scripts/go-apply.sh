#!/usr/bin/env bash
# BUILD-PLAN Phase 6C (Go column) — make the GO BINARY do the devops.
#
# Transpiles the I/O-free apply harness (Bosun.Conformance.ApplyMain) via
# backend-go, builds a native Go binary, and runs it: the binary computes the
# command script with the pure core and EXECUTES it via the one os-exec foreign.
#
# PREREQUISITE (one-time, manual): add the `Bosun_Conformance_ApplyMain_execLineImpl`
# shim to backend-go/runtime.go and ensure `os/exec` is imported. The exact code
# is in docs/PHASE-6C-GO.md. Until then `go build` fails with an undefined symbol
# (this script detects that and points you at the doc).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.ApplyMain"
OUT="${OUT:-/tmp/bosun-go-apply}"

echo "==> build bosun (spago emits corefn + js)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

mkdir -p /tmp/bosun-hello-go

echo "==> backend-go transpile (corefn -> Go, pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
# Bosun owns its one hand-written Go foreign (the os-exec shim) — copied in next
# to the generated sources so `go build *.go` resolves execLineImpl. Keeps
# backend-go app-agnostic; nothing there can clobber it.

echo "==> go build ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
if ! ( cd "$OUT" && go build -o /tmp/bgo_apply *.go ) 2> /tmp/bgo_apply_build.err; then
  if grep -q "execLineImpl" /tmp/bgo_apply_build.err; then
    echo "❌ execLineImpl unresolved — conformance/src/Bosun/Conformance/ApplyMain.go did"
    echo "   not make it into the build dir. Check the cp above / the file exists."
  else
    echo "❌ go build failed:"; cat /tmp/bgo_apply_build.err
  fi
  exit 1
fi

echo "==> RUN the Go binary (it executes the deploy)"
/tmp/bgo_apply

sleep 1
echo "==> verify (independent of the binary): the servers answer HTTP"
curl -s -o /dev/null -w "   8773 -> HTTP %{http_code}\n" http://localhost:8773/ || true
curl -s -o /dev/null -w "   8774 -> HTTP %{http_code}\n" http://localhost:8774/ || true
echo "   (clean up: pkill -f 'http.server 877')"
