#!/usr/bin/env bash
# Detect-tier regression gate over the FROZEN polyglot corpus (the
# parser-hardening track). `fixtures/polyglot-2026-06-14/` is a snapshot of the
# real rig as it stood on 2026-06-14 — the live `/api/ports` registry + the
# `polyglot-deploy/docker-compose.yml` — captured BEFORE the #134 redeploy
# reshapes it. The mess is the asset: this locks Bosun's findings on real,
# heterogeneous, multi-source config so Detect coverage cannot silently
# regress as the adapters evolve, independent of the live rig's future.
#
# It re-runs `bosun check` over the frozen files and diffs against the golden
# `expected-check.txt`. Byte-identical = the corpus still parses + reconciles +
# validates exactly as captured (15 facet divergences incl. tilted-radio; the
# macmini:80 edge port-collision). Regenerate the golden file deliberately
# (and review the diff) if a real adapter improvement changes the findings.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
CORPUS="fixtures/polyglot-2026-06-14"
GOLDEN="$CORPUS/expected-check.txt"

cd "$BOSUN"
echo "==> build"
spago build >/dev/null 2>&1

echo "==> bosun check over the frozen corpus"
spago run -p bosun-cli -- check "$CORPUS/docker-compose.yml" "$CORPUS/registry.json" 2>/dev/null > /tmp/bosun-corpus.txt

echo "==> diff vs golden"
if diff "$GOLDEN" /tmp/bosun-corpus.txt >/dev/null; then
  echo "✅ CORPUS: bosun check matches the frozen golden output"
  echo "   ($(grep -c 'deployment facets' "$GOLDEN") facet divergences, $(grep -c 'port collision' "$GOLDEN") collision)"
else
  echo "❌ CORPUS DRIFT: bosun check no longer matches the golden output:"
  diff "$GOLDEN" /tmp/bosun-corpus.txt
  exit 1
fi
