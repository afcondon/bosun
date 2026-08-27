#!/usr/bin/env bash
# BUILD-PLAN Phase 7 — backend-go thunk thread-safety REGRESSION GUARD.
#
# Originally a spike to PROVE the roadblock (stock `_force` was a data race that
# could spuriously panic "cyclic strict initialization"). The fix — a per-thunk
# sync.Once in `_force` — is now UPSTREAM in backend-go/runtime.go (#20), so this
# script's job has flipped: it transpiles the RaceSpike harness, builds it with
# the Go race detector, forces one shared CAF from 16 goroutines, and asserts it
# runs CLEAN (exit 0, no race report). If this ever goes red again, the runtime
# regressed. (`scripts/race-fix.py` documents the diff that was upstreamed; the
# `--stock` flag below reverts it on a build-dir COPY to re-demonstrate the
# original breakage on demand — the source stays fixed.)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
BACKEND_GO="${BACKEND_GO:-$BOSUN/../../purescript-backends/purescript-go/backend-go}"
MAIN="Bosun.Conformance.RaceSpike"
OUT="${OUT:-/tmp/bosun-go-race}"
STOCK="${1:-}"

echo "==> build bosun (corefn)"
( cd "$BOSUN" && spago build >/dev/null 2>&1 )

echo "==> backend-go transpile (pruned to $MAIN)"
rm -rf "$OUT"
( cd "$BOSUN" && "$BACKEND_GO/bin/backend-go" --corefn-dir "$BOSUN/output" --output-dir "$OUT" --main "$MAIN" >/dev/null 2>&1 )
cp "$BACKEND_GO/runtime.go" "$OUT/runtime.go"

if [ "$STOCK" = "--stock" ]; then
  echo "==> --stock: reverting the sync.Once fix on the build COPY (source untouched) to re-show the original breakage"
  python3 "$HERE/race-fix.py" --revert "$OUT/runtime.go"
fi

echo "==> go build -race + run (16 goroutines forcing one CAF)"
( cd "$OUT" && go build -race -o /tmp/bgo_race *.go )
set +e
/tmp/bgo_race
code=$?
set -e
echo "==> exit code: $code  ($([ $code -eq 0 ] && echo 'clean' || echo 'BROKE — race/panic, as predicted'))"
