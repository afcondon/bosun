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
# Covers ALL verbs Node-free: check, plan, observe, apply [--dry-run],
# down [--dry-run], supervise [--port N], docker, AND serve / serve --audit
# (the reverse proxy + audit are now real Go foreigns — bosun_cli_{serve,audit}).
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
  [ -n "$(find "$BOSUN/cli" "$BOSUN/conformance/src" \
            -name '*.go' -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  # backend-go's own layers count too: the runtime, and (since 2026-08-24) the
  # per-package foreign/ directory. A fix landing upstream must reach the cached
  # binary, or the stress-testing this script exists for is testing yesterday.
  [ -n "$(find "$BACKEND_GO/runtime.go" "$BACKEND_GO/foreign" -newer "$BIN" -print -quit 2>/dev/null)" ] && return 0
  return 1
}

build(){
  [ -d "$BACKEND_GO" ] || { log "backend-go not found at $BACKEND_GO (set BACKEND_GO)"; exit 1; }
  log "building native binary (sources changed)…"
  ( cd "$BOSUN" && spago build ) >&2 || { log "spago build failed"; exit 1; }
  log "backend-go transpile (corefn -> Go, pruned to $MAIN)"
  rm -rf "$OUT"
  ( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" ) >&2 \
    || { log "backend-go transpile failed"; exit 1; }
  cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
  # NOTE: NOTHING of Bosun's is copied here any more, and that is the point.
  #
  # The LIBRARY foreigns — Foreign.Object, Data.Argonaut.{Core,Parser} — went to
  # backend-go's `foreign/` layer on 2026-08-24; Bosun's OWN foreigns went to the
  # file beside each `.purs` on 2026-08-27 (`Serve.purs`, `Serve.js`, `Serve.go`),
  # and the backend copies those itself, found via CoreFn `modulePath`. A list of
  # `cp` lines here was a list of things somebody had to remember, which is
  # precisely how the build stayed red for nine commits.
  #
  # Consequence: the transpile MUST run with the CWD at $BOSUN, since modulePath
  # is relative to wherever spago built. bin/backend-go exists to make that hard
  # to get wrong, and supplies the backend's own foreign/ as --foreign-dir.
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
