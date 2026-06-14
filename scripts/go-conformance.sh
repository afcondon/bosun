#!/usr/bin/env bash
# purescript-go conformance column (Phase 4 — the backend-go MVP gate).
#
# The plan: compile bosun-core (the pure Detect tier) with the
# purescript-go backend, run the same `bosun check` over the same
# corpus, and diff its report byte-for-byte against the node column.
# Identical output is the signal-box conformance pattern realised, and
# the gate purescript-go must pass to ship its MVP. See BUILD-PLAN.md
# Phase 4 and docs/PRINCIPLES.md (the signal-box lineage section).
#
# Not wired yet — this is the placeholder the build plan asks Phase 0 to
# stub.
set -euo pipefail

echo "bosun: purescript-go conformance column not yet wired (Phase 4)." >&2
echo "       Develop on the node backend; this stub gates the go column." >&2
exit 1
