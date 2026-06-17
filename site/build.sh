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

# Reading order — a coherent arc:
#   why (FOR-DEVOPS) → discipline (PRINCIPLES) → the model (DESIGN + the two
#   type refinements ADDRESS-TYPE, PLACEMENT-TYPE) → does it handle reality?
#   (SCENARIOS) → the hard calls (DECISIONS) → it runs, resident (BOSUN-SERVE,
#   CONTROL-SURFACE) → seeing into the BEAM (BEAM-OBSERVER) → where it's going
#   (ROADMAP) → how it scales (FEDERATION) → the intellectual lineage (PRIOR-ART)
#   → how you see it (GRAPH-GRAMMAR) → the spike as an appendix.
# Working docs deliberately excluded (handoffs, phase logs, stress-test plan):
#   internal, not dossier chapters; build history lives in docs/BUILD-PLAN.md.
DOCS=(FOR-DEVOPS PRINCIPLES DESIGN ADDRESS-TYPE PLACEMENT-TYPE SCENARIOS DECISIONS BOSUN-SERVE CONTROL-SURFACE BEAM-OBSERVER ROADMAP FEDERATION PRIOR-ART GRAPH-GRAMMAR)

{
  # ── Cover ──────────────────────────────────────────────────────────
  echo "# Bosun — Design Dossier"
  echo
  echo "<p class=\"cover-tag\">A typed substrate for distributed process management. It reads the deployment config you already have, across every tool it's smeared across, checks it and tells you where it's wrong before anything runs &mdash; then plans, applies, and supervises it.</p>"
  echo
  echo "<p class=\"cover-meta\">Status: active development, past first proof. The <strong>Detect &rarr; Plan &rarr; Apply</strong> pipeline is built and proven on two runtimes &mdash; the Node reference and, compiled via the Gnomon PureScript&rarr;Go backend, a native binary that performs real file-driven deploys <em>byte-identical</em> to Node. A resident lazy-spawn router (<code>serve</code>) and a live operational + control surface (the Chair) run today. Where it's going is the <em>Roadmap</em> chapter (Stages 1&ndash;3); how it scales without becoming baroque is <em>Federation</em>. Generated $DATE from the repo docs. The first chapter (<em>For people who run things</em>) needs no functional-programming background and is the right starting point for a devops reader.</p>"
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
