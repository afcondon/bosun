#!/usr/bin/env bash
# BUILD-PLAN Phase 7 (P3, Go column) — make the GO BINARY be the router.
#
# Transpiles the I/O-free serve harness (Bosun.Conformance.ServeMain) via
# backend-go, builds a NATIVE Go binary WITH THE RACE DETECTOR, and runs it as a
# resident reverse proxy: the binary computes the admission plan with the pure
# core (reconcile -> servePlan) and serves it via the one resident-proxy foreign
# (conformance/go/bosun_serve_foreign.go). Then it fires concurrent requests at
# the public port — each lazy-spawns (once) the python backend on the internal
# port and proxies — and asserts HTTP 200, clean under -race.
#
# Needs the sync.Once thunk runtime fix (committed in backend-go; see
# scripts/go-race.sh). Cleans up the binary + the spawned backend on exit.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.ServeMain"
OUT="${OUT:-/tmp/bosun-go-serve}"
PUBLIC=8775
INTERNAL=28775

cleanup() {
  [ -n "${SRV_PID:-}" ] && kill "$SRV_PID" 2>/dev/null || true
  pkill -f "http.server $INTERNAL" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> build bosun (spago emits corefn + js)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

echo "==> site dir + index.html (/tmp/bosun-serve-go)"
mkdir -p /tmp/bosun-serve-go
cat > /tmp/bosun-serve-go/index.html <<'HTML'
<!doctype html><meta charset="utf-8"><title>bosun serve (Go column)</title>
<h1>Served by a backend-go-compiled bosun serve</h1>
<p>A native Go binary — PureScript transpiled via backend-go — is the lazy-spawn
reverse proxy. The python backend behind this was not running until the first request.</p>
HTML

echo "==> backend-go transpile (corefn -> Go, pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BACKEND_GO" && spago run -- --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
# Bosun owns its one hand-written Go foreign (the resident proxy) — copied in so
# `go build *.go` resolves serveImpl. Keeps backend-go app-agnostic.
cp "$BOSUN/conformance/go/bosun_serve_foreign.go" "$OUT/bosun_serve_foreign.go"

echo "==> go build -race ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
if ! ( cd "$OUT" && go build -race -o /tmp/bgo_serve *.go ) 2> /tmp/bgo_serve_build.err; then
  if grep -q "serveImpl" /tmp/bgo_serve_build.err; then
    echo "❌ serveImpl unresolved — conformance/go/bosun_serve_foreign.go did not"
    echo "   make it into the build dir. Check the cp above / the file exists."
  else
    echo "❌ go build failed:"; cat /tmp/bgo_serve_build.err
  fi
  exit 1
fi

echo "==> RUN the Go binary as a resident router (background)"
GORACE="halt_on_error=1" /tmp/bgo_serve > /tmp/bgo_serve.out 2>&1 &
SRV_PID=$!

echo "==> fire 8 concurrent requests at :$PUBLIC (lazy-spawn + proxy, under -race)"
rm -f /tmp/bgo_serve.codes
curl_pids=()
for i in $(seq 1 8); do
  ( curl -s -o /dev/null -w "%{http_code}\n" --retry 20 --retry-connrefused --retry-delay 1 --max-time 40 "http://127.0.0.1:$PUBLIC/" ) >> /tmp/bgo_serve.codes &
  curl_pids+=("$!")
done
# wait ONLY on the curls — a bare `wait` would also block on the resident server
# ($SRV_PID), which never exits.
wait "${curl_pids[@]}"
codes="$(sort -u /tmp/bgo_serve.codes 2>/dev/null | tr '\n' ' ')"; rm -f /tmp/bgo_serve.codes

echo "--- router log ---"
cat /tmp/bgo_serve.out
echo "--- result ---"
echo "distinct HTTP codes across 8 concurrent requests: $codes"
if echo "$codes" | grep -q "200" && ! echo "$codes" | grep -qE "00[0-9]|5[0-9][0-9]" ; then
  echo "✅ SERVE (Go column): the native binary routed every request (HTTP 200), clean under -race"
else
  echo "❌ SERVE (Go column): unexpected codes ($codes) — see router log above"
  exit 1
fi
