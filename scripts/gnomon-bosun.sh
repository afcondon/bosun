#!/usr/bin/env bash
# gnomon-bosun — the Gnomon (backend-go) build of the REAL `bosun` CLI.
#
# AC (2026-06-19): "from here on use the gnomon version all the time to stress
# test the backend." So this transpiles the actual `Bosun.CLI.Main` to a NATIVE
# Go binary (via backend-go) and runs it with your args — every invocation
# exercises backend-go on real files, the way the Menagerie caught the setsid /
# zombie-reap fidelity bugs. The binary is CACHED at $BIN and rebuilt only when a
# .purs or app-foreign .go is newer (so day-to-day use is just a native exec).
#
# Reads real compose.yml via gopkg.in/yaml.v3 (the go-apply-cli pattern: a
# one-line go.mod makes the generated `package main` a module that can import it;
# backend-go output stays dep-free — only Bosun's IO foreign imports yaml).
#
# Covers the DEPLOY/SUPERVISE verbs: check, plan, observe, apply [--dry-run],
# down [--dry-run], supervise [--port N], docker. `serve` / `serve --audit` are
# STUBBED (deferred) — use the node CLI (`node cli/run.js serve …`) for those.
#
# Usage:  scripts/gnomon-bosun.sh <verb> [args…]      (same args as node bosun)
#   e.g.  scripts/gnomon-bosun.sh check  fixtures/menagerie/compose.yml fixtures/menagerie/registry.json
#         scripts/gnomon-bosun.sh apply --dry-run <compose> <registry>
#         BACKEND_GO=/path scripts/gnomon-bosun.sh plan <compose> <registry>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.CLI.Main"
OUT="${OUT:-/tmp/bosun-gnomon-cli}"
BIN="${BIN:-/tmp/gnomon-bosun}"
YAML_VERSION="${YAML_VERSION:-v3.0.1}"

log(){ echo "gnomon-bosun: $*" >&2; }   # build chatter to stderr; stdout stays the binary's

stale(){
  [ ! -x "$BIN" ] && return 0
  [ -n "$(find "$BOSUN/cli" "$BOSUN/core" "$BOSUN/adapters" "$BOSUN/conformance/src" \
            -name '*.purs' -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  [ -n "$(find "$BOSUN/conformance/go" -name '*.go' -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  return 1
}

build(){
  [ -d "$BACKEND_GO" ] || { log "backend-go not found at $BACKEND_GO (set BACKEND_GO)"; exit 1; }
  log "building native binary (sources changed)…"
  ( cd "$BOSUN" && spago build ) >&2 || { log "spago build failed"; exit 1; }
  log "backend-go transpile (corefn -> Go, pruned to $MAIN)"
  rm -rf "$OUT"
  ( cd "$BACKEND_GO" && spago run -- --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" ) >&2 \
    || { log "backend-go transpile failed"; exit 1; }
  cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
  # library decode foreigns + Bosun's CLI-edge twins (REAL Bosun_CLI_* symbols,
  # so fixes like exec's setsid/reap propagate to the binary automatically).
  cp "$BOSUN"/conformance/go/argonaut_core_foreign.go         "$OUT/"
  cp "$BOSUN"/conformance/go/argonaut_parser_foreign.go       "$OUT/"
  cp "$BOSUN"/conformance/go/foreign_object_foreign.go        "$OUT/"
  cp "$BOSUN"/conformance/go/bosun_io_foreign.go              "$OUT/"
  cp "$BOSUN"/conformance/go/bosun_exec_foreign.go            "$OUT/"
  cp "$BOSUN"/conformance/go/bosun_probe_foreign.go           "$OUT/"
  cp "$BOSUN"/conformance/go/bosun_resident_foreign.go        "$OUT/"
  cp "$BOSUN"/conformance/go/bosun_serve_audit_stub_foreign.go "$OUT/"
  log "go build ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files; yaml.v3 from cache)"
  (
    cd "$OUT"
    go mod init gnomonbosun >/dev/null 2>&1
    go mod edit -require=gopkg.in/yaml.v3@"$YAML_VERSION"
    GOFLAGS=-mod=mod go build -o "$BIN" .
  ) >/tmp/gnomon-bosun-build.err 2>&1 || { log "go build failed — see /tmp/gnomon-bosun-build.err"; cat /tmp/gnomon-bosun-build.err >&2; exit 1; }
  log "built $BIN"
}

stale && build
exec "$BIN" "$@"
