#!/usr/bin/env bash
# STRESS-TEST-PLAN §3 — the adversarial registry corpus.
#
# A library of deliberately-nasty registries run through `bosun serve --plan`
# (the non-resident admission report), each diffed against a frozen golden. The
# point is to lock serve's CLASSIFIER against pathological input — and to
# document, in golden output, exactly where the boundaries are:
#
#   port-in-path    the public port appears in the cwd PATH, not the command →
#                   REJECTED (PortNotInStartCommand). The rewrite has nowhere to
#                   land; serve must not false-admit it.
#   flag-collision  a port-looking numeric flag (`--timeout 3050`) matches the
#                   public port → ADMITTED, and the textual rewrite WILL rewrite
#                   the flag too (a known limitation; the hazard is in the
#                   launchCommand, not the report). Documented, not fixed.
#   collision       two services on the same host:port → BOTH admitted. serve
#                   does not dedup; PortCollision is `bosun check`'s job, not the
#                   router's. Separation of concerns, made explicit.
#   malformed       empty startCommand → NoAbsoluteCwd; missing port →
#                   NoHostPort; missing `role` → silently ingest-skipped (absent
#                   from every bucket).
#   unicode         emoji/accented service id classified + rendered without
#                   crashing.
#
# Regenerate a golden deliberately (review the diff!) when an adapter/classifier
# change legitimately alters a finding:
#   spago run -p bosun-cli -- serve --plan fixtures/adversarial/<name>.json \
#     > fixtures/adversarial/expected/<name>.txt
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
DIR="fixtures/adversarial"
CASES="port-in-path flag-collision collision malformed unicode"

cd "$BOSUN"
echo "==> build"
spago build >/dev/null 2>&1

fail=0
for c in $CASES; do
  spago run -p bosun-cli -- serve --plan "$DIR/$c.json" 2>/dev/null > "/tmp/bosun-adv-$c.txt"
  if diff "$DIR/expected/$c.txt" "/tmp/bosun-adv-$c.txt" >/dev/null; then
    echo "  ✓ $c"
  else
    echo "  ✗ $c — admission report drifted:"
    diff "$DIR/expected/$c.txt" "/tmp/bosun-adv-$c.txt" || true
    fail=1
  fi
done

# huge-graph: classify 200 services without crashing or quadratic blowup. A
# count assertion, not a golden (the report would be unwieldy).
echo "==> huge graph (200 services, no-crash + count)"
python3 - > /tmp/bosun-huge.json <<'PY'
import json
servers = [{
  "role": "frontend", "projectName": f"svc{i}", "projectSlug": f"svc{i}",
  "port": 4000 + i, "host": "mbp",
  "startCommand": f"cd /srv/svc{i} && run -p {4000 + i}",
} for i in range(200)]
print(json.dumps({"servers": servers}))
PY
huge="$(spago run -p bosun-cli -- serve --plan /tmp/bosun-huge.json 2>/dev/null | head -1)"
if echo "$huge" | grep -q "ADMITTED — 200 routable"; then
  echo "  ✓ huge: 200/200 admitted"
else
  echo "  ✗ huge: expected 200 admitted, got: $huge"
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "✅ ADVERSARIAL CORPUS: all cases match their goldens"
else
  echo "❌ ADVERSARIAL CORPUS: drift above"
  exit 1
fi
