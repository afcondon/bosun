#!/usr/bin/env bash
# Stage 1 headline — the GO BINARY runs the FULL `bosun apply` against REAL FILES.
#
# Unlike go-apply.sh (which deploys a HARDCODED fixture so its only foreign is
# os-exec), this transpiles Bosun.Conformance.ApplyCliMain — the real runApply
# pipeline reading a compose + registry off disk — and so needs the Json-decode
# foreigns the hardcoded harnesses never exercised:
#   - conformance/go/argonaut_core_foreign.go   (Data.Argonaut.Core: _caseJson, from*, …)
#   - conformance/go/foreign_object_foreign.go  (Foreign.Object: _lookup, keys, …)
#   - conformance/go/bosun_applycli_foreign.go  (readJson/readYaml/argv/execLine)
# plus backend-go's runtime.go. All copied next to the generated `package main`
# sources where `go build *.go` resolves them. backend-go stays pristine.
#
# The binary reads a .json compose directly or a .yml compose via gopkg.in/yaml.v3
# (already in the module cache; the script sets up a one-line go.mod so the
# generated `package main` becomes a module that can import it). backend-go's
# output is dep-free; only Bosun's app foreign imports yaml.
# Args: [compose] [registry]   (default: the polyglot-up fixture, real compose.yml)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.ApplyCliMain"
OUT="${OUT:-/tmp/bosun-go-apply-cli}"
COMPOSE="${1:-$BOSUN/fixtures/polyglot-up/compose.yml}"
REGISTRY="${2:-$BOSUN/fixtures/polyglot-up/registry.json}"
YAML_VERSION="${YAML_VERSION:-v3.0.1}"

echo "==> build bosun (spago emits corefn + js)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

echo "==> backend-go transpile (corefn -> Go, pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BACKEND_GO" && spago run -- --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
cp "$BOSUN/conformance/go/argonaut_core_foreign.go"  "$OUT/argonaut_core_foreign.go"
cp "$BOSUN/conformance/go/foreign_object_foreign.go" "$OUT/foreign_object_foreign.go"
cp "$BOSUN/conformance/go/bosun_applycli_foreign.go" "$OUT/bosun_applycli_foreign.go"

echo "==> go module setup (yaml.v3 from cache) + build ($(ls "$OUT"/*.go | wc -l | tr -d ' ') Go files)"
(
  cd "$OUT"
  go mod init bosunapplycli >/dev/null 2>&1
  go mod edit -require=gopkg.in/yaml.v3@"$YAML_VERSION"
  GOFLAGS=-mod=mod go build -o /tmp/bgo_apply_cli .
) 2> /tmp/bgo_apply_cli_build.err || { echo "❌ go build failed:"; cat /tmp/bgo_apply_cli_build.err; exit 1; }

echo "==> RUN the Go binary — it reads the files and performs the deploy"
echo "    compose:  $COMPOSE"
echo "    registry: $REGISTRY"
echo "    ----------------------------------------------------------------"
/tmp/bgo_apply_cli "$COMPOSE" "$REGISTRY"
