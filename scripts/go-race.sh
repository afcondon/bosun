#!/usr/bin/env bash
# BUILD-PLAN Phase 7 spike — probe backend-go thunk thread-safety (the gating
# unknown for `bosun serve`, the concurrent router). Transpiles the RaceSpike
# harness, builds it with the Go race detector, and runs it: a shared CAF forced
# from 16 goroutines. Expect BREAKAGE on the stock runtime (a data race and/or a
# spurious "cyclic strict initialization" panic) — that's the finding.
#
# Pass `--fixed` to build against a sync.Once-patched copy of runtime.go (the
# proposed fix) and show it run clean.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.RaceSpike"
OUT="${OUT:-/tmp/bosun-go-race}"
FIXED="${1:-}"

echo "==> build bosun (corefn)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

echo "==> backend-go transpile (pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BACKEND_GO" && spago run -- --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"
cp "$BOSUN/conformance/go/bosun_race_foreign.go" "$OUT/bosun_race_foreign.go"

if [ "$FIXED" = "--fixed" ]; then
  echo "==> applying the sync.Once fix to the runtime COPY (source runtime.go untouched)"
  python3 "$HERE/race-fix.py" "$OUT/runtime.go"
fi

echo "==> go build -race + run (16 goroutines forcing one CAF)"
( cd "$OUT" && go build -race -o /tmp/bgo_race *.go )
set +e
/tmp/bgo_race
code=$?
set -e
echo "==> exit code: $code  ($([ $code -eq 0 ] && echo 'clean' || echo 'BROKE — race/panic, as predicted'))"
