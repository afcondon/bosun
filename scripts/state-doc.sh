#!/usr/bin/env bash
# state-doc.sh: the tables of protocol/STATE.md, from the description.
#
#   scripts/state-doc.sh           rewrite the generated part of protocol/STATE.md
#   scripts/state-doc.sh --check   fail if it is stale (run by `npm test`)
#
# The generated parts lie between marker lines; the rest is by hand.
set -euo pipefail
BOSUN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$BOSUN/protocol/STATE.md"
( cd "$BOSUN" && spago build >/dev/null 2>&1 ) || { echo "state-doc: build failed"; exit 1; }
NEW="$(mktemp)"; trap 'rm -f "$NEW"' EXIT
node --input-type=module -e "
  import { readFileSync } from 'node:fs';
  import { stateDocument, routerDocument } from '$BOSUN/output/Bosun.Conformance.StateText/index.js';
  let text = readFileSync('$DOC', 'utf8');
  // Each generated part lies between its own pair of marker lines.
  const fill = (open, close, body) => {
    const from = text.indexOf(open), to = text.indexOf(close);
    if (from < 0 || to < from) { console.error('state-doc: markers not found in protocol/STATE.md: ' + open); process.exit(1); }
    text = text.slice(0, from + open.length) + '\n\n' + body + '\n\n' + text.slice(to);
  };
  fill('<!-- generated: scripts/state-doc.sh -->', '<!-- end generated -->', stateDocument);
  fill('<!-- generated router: scripts/state-doc.sh -->', '<!-- end generated router -->', routerDocument);
  process.stdout.write(text);" > "$NEW"
if [ "${1:-}" = "--check" ]; then
  cmp -s "$NEW" "$DOC" && echo "state-doc: protocol/STATE.md is current" || { echo "state-doc: protocol/STATE.md is stale; run scripts/state-doc.sh"; exit 1; }
else
  cp "$NEW" "$DOC"; echo "state-doc: wrote protocol/STATE.md"
fi
