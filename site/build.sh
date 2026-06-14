#!/usr/bin/env bash
# Assemble the Bosun design docs + the spike into one self-contained HTML file.
# Reproducible: re-run after editing any doc. Requires pandoc.
#
#   ./site/build.sh        # → site/bosun-design.html (open or share; works offline)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/bosun-design.html"
TMP="$(mktemp -d)"
COMBINED="$TMP/combined.md"
DATE="$(date +%Y-%m-%d)"

# Reading order: colleague-facing intro first, then the design narrative,
# then the receipts, then the spike as an appendix.
DOCS=(FOR-DEVOPS PRINCIPLES DESIGN SCENARIOS DECISIONS PRIOR-ART)

{
  # ── Cover ──────────────────────────────────────────────────────────
  echo "# Bosun — Design Dossier"
  echo
  echo "<p class=\"cover-tag\">A typed deployment-DAG tool. \"The Go son.\" — a checker, reconciler, and generator that reads the deployment config you already have, across every tool it's smeared across, and tells you where it's wrong before anything runs.</p>"
  echo
  echo "<p class=\"cover-meta\">Status: design stage (no shipping product yet). Generated $DATE from the repo docs. Reading order below; the first chapter (<em>For people who run things</em>) needs no functional-programming background and is the right starting point for a devops reader.</p>"
  echo
  echo '---'
  echo

  # ── Chapters ───────────────────────────────────────────────────────
  for d in "${DOCS[@]}"; do
    cat "$ROOT/docs/$d.md"
    echo; echo; echo '---'; echo
  done

  # ── Appendix: the spike ────────────────────────────────────────────
  cat "$ROOT/spike/README.md"
  echo
  echo '### Appendix: `spike/Authoring.purs` (the compiled source)'
  echo
  echo '```purescript'
  cat "$ROOT/spike/Authoring.purs"
  echo '```'
} > "$COMBINED"

pandoc "$COMBINED" \
  --standalone \
  --embed-resources \
  --toc --toc-depth=2 \
  --highlight-style=tango \
  --metadata title="Bosun — Design Dossier" \
  --include-in-header="$HERE/header.html" \
  --include-after-body="$HERE/scrollspy.html" \
  -o "$OUT"

rm -rf "$TMP"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes)"
