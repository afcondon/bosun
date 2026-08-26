#!/usr/bin/env bash
# Regenerate the two modules derived from `machines/supervise-group.json`.
#
#   Bosun.Machine.SuperviseGroup        the alphabet, as rows — what makes a
#                                       forgotten state a compile error that
#                                       NAMES the state
#   Bosun.Machine.SuperviseGroupSource  the artifact verbatim, because the Go
#                                       conformance Main is transpiled and run
#                                       under backend-go and cannot open a file
#
# Run this after editing the artifact. Forgetting to is not silent: the daemon
# compares the alphabet with the artifact at boot (`Supervise.Machine.complaints`)
# and refuses to start on a machine whose words it cannot honour.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLASSBOX="${GLASSBOX:-/Users/afc/work/afc-work/purescript-hylograph-libs/purescript-glassbox}"

[ -d "$GLASSBOX/cli" ] || { echo "no glassbox at $GLASSBOX — set GLASSBOX"; exit 1; }

for verb in vocabulary embed; do
  ( cd "$GLASSBOX" && spago run -p glassbox-cli --quiet -- \
      "$verb" "$HERE/machines" "$HERE/cli/src/Bosun/Machine" \
      "Bosun.Machine" "scripts/machine-vocabulary.sh" )
done
