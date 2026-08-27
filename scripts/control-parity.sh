#!/usr/bin/env bash
# CONTROL-SURFACE PARITY — the router's two columns must answer the same verbs.
#
# ── the failure this exists to make loud ─────────────────────────────────────
#
# Broker mode was built entirely in `cli/src/Bosun/CLI/Serve.js` — a broker
# table, a 307 listener, ensure-and-locate, `GET /where`, and `/control/spawn|
# stop` reaching brokered services. The Go shim it is supposed to be the twin of
# grew none of it. That went unnoticed for a week, and it went unnoticed for a
# structural reason: NOTHING COULD TELL. The two files are 1400 and 900 lines of
# prose-commented shim, they are never read side by side, and the only script
# that builds the Go router (`scripts/gnomon-bosun.sh`) is run by hand or not at
# all — its own header carries a standing instruction from 2026-06-19 to use it
# "all the time to stress test the backend", and its build was nonetheless RED
# for nine commits before anyone looked.
#
# So the remedy is not another instruction. It is a check that costs nothing,
# runs on a command people already type (`npm test`), and goes red on its own.
#
# ── what it checks, and what it does NOT ─────────────────────────────────────
#
# It derives the surface from the TWO SOURCES THEMSELVES — there is no
# hand-maintained list of endpoints to fall out of date, because the thing being
# compared is what each dispatcher literally matches on. Three dimensions:
#
#   PATHS    every path literal either router dispatches on
#   QUERIES  every query-string key either router reads
#   HEADERS  every `x-bosun-*` response header either router sets
#
# WOULD IT HAVE CAUGHT THE BUG IT IS NAMED FOR? Yes, on all three dimensions:
# node dispatched `/where` and `/where/` and read `?service=` and set
# `x-bosun-mediation`; Go did none of those. It goes red the moment one column
# grows a verb, a selector or a contract header the other lacks.
#
# WHAT IT CANNOT CATCH, said plainly because a gate you trust further than it
# reaches is worse than no gate:
#
#   * a verb both columns answer with DIFFERENT SEMANTICS. Presence is not
#     agreement. That is `scripts/go-broker.sh`'s job — it runs the same request
#     sequence against both routers and diffs the answers field by field.
#   * the METHOD a path is dispatched under. The three sets are compared
#     independently, so a path served under GET in one column and POST in the
#     other reads as parity here.
#   * behaviour reachable by no new path — a body field, a status code, a
#     changed sentence. Again: go-broker.sh.
#   * a dispatcher rewritten in a shape these patterns do not match. Guarded, not
#     solved: each extraction has a FLOOR, and falling under it fails the check
#     rather than passing with an empty set. An empty extraction is the one way a
#     text-derived gate turns green by going blind.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
# Overridable so the check can be pointed at a historical copy of either shim —
# which is how you demonstrate that it goes RED on the state it was written to
# catch, rather than merely asserting that it would have.
NODE_SHIM="${NODE_SHIM:-$BOSUN/cli/src/Bosun/CLI/Serve.js}"
GO_SHIM="${GO_SHIM:-$BOSUN/cli/src/Bosun/CLI/Serve.go}"

FAILED=0
bad() { echo "  ✗ $*"; FAILED=1; }
ok()  { echo "  ✓ $*"; }

for f in "$NODE_SHIM" "$GO_SHIM"; do
  [ -f "$f" ] || { echo "❌ missing router shim: $f"; exit 1; }
done

# ── extraction ───────────────────────────────────────────────────────────────
# Deliberately narrow patterns: they match the DISPATCH expressions, not any
# string that happens to start with a slash, so a log line or a doc comment
# mentioning `/where` cannot fake parity.

node_paths() {
  {
    grep -Eo 'u\.pathname === "[^"]+"' "$NODE_SHIM" | sed 's/.*"\(.*\)"/\1/'
    grep -Eo 'u\.pathname\.startsWith\("[^"]+"\)' "$NODE_SHIM" | sed 's/.*"\(.*\)".*/\1/'
  } | sort -u
}

go_paths() {
  {
    grep -Eo 'r\.URL\.Path == "[^"]+"' "$GO_SHIM" | sed 's/.*"\(.*\)"/\1/'
    grep -Eo 'strings\.HasPrefix\(r\.URL\.Path, "[^"]+"\)' "$GO_SHIM" | sed 's/.*"\(.*\)".*/\1/'
  } | sort -u
}

node_queries() { grep -Eo 'searchParams\.get\("[^"]+"\)' "$NODE_SHIM" | sed 's/.*"\(.*\)".*/\1/' | sort -u; }
go_queries()   { grep -Eo 'r\.URL\.Query\(\)\.Get\("[^"]+"\)' "$GO_SHIM" | sed 's/.*"\(.*\)".*/\1/' | sort -u; }

# The contract headers. `x-bosun-mediation` is broker mode's whole promise
# ("bosun is not carrying this traffic") stated on the wire, so a column that
# stops emitting it has stopped making the promise.
node_headers() { grep -Eo '"x-bosun-[a-z-]+"' "$NODE_SHIM" | tr -d '"' | sort -u; }
go_headers()   { grep -Eo '"x-bosun-[a-z-]+"' "$GO_SHIM"   | tr -d '"' | sort -u; }

compare() {
  local what="$1" floor="$2" nodeset="$3" goset="$4"
  local n g only_node only_go
  n=$(echo "$nodeset" | grep -c .)
  g=$(echo "$goset" | grep -c .)
  only_node=$(comm -23 <(echo "$nodeset") <(echo "$goset"))
  only_go=$(comm -13 <(echo "$nodeset") <(echo "$goset"))
  if [ -z "$only_node" ] && [ -z "$only_go" ]; then
    # AGREEMENT — but agreement between two empty sets is a blind extractor, not
    # parity, and that is the one way a text-derived check turns green by seeing
    # nothing. The floor is checked HERE, where the shortfall has no other
    # explanation; a genuine gap is reported as a gap, below.
    if [ "$n" -lt "$floor" ] || [ "$g" -lt "$floor" ]; then
      bad "$what: both columns agree on $n item(s), below the floor of $floor."
      echo "      Agreement this thin means the dispatchers have been written in a"
      echo "      shape these patterns cannot read — the check has gone blind."
      echo "      Fix the patterns in scripts/control-parity.sh; do NOT lower the floor."
      return
    fi
    ok "$what: both columns ($n) — $(echo "$nodeset" | tr '\n' ' ')"
    return
  fi
  bad "$what: the two columns disagree ($n node / $g go)."
  [ -n "$only_node" ] && echo "      node only (MISSING FROM THE GO COLUMN, which is the primary one):" \
    && echo "$only_node" | sed 's/^/        · /'
  [ -n "$only_go" ] && echo "      go only (missing from the node shim):" \
    && echo "$only_go" | sed 's/^/        · /'
  echo "      node: $NODE_SHIM"
  echo "      go:   $GO_SHIM"
}

echo "control-surface parity — cli/src/Bosun/CLI/Serve.js  ≟  cli/src/Bosun/CLI/Serve.go"
echo
compare "dispatched paths"  5 "$(node_paths)"   "$(go_paths)"
compare "query selectors"   2 "$(node_queries)" "$(go_queries)"
compare "x-bosun headers"   1 "$(node_headers)" "$(go_headers)"

# ── every Bosun FFI declaration needs a Go twin ──────────────────────────────
#
# A DIFFERENT failure from the one above, found the same day and worth its own
# check: the Go build of the real CLI (`scripts/gnomon-bosun.sh`) had been RED
# for nine commits, because three `foreign import`s landed in cli/src with no
# Go counterpart and `go build` is the only thing that would have said so — and
# nothing runs it. This is the same fact for the price of a grep: a `foreign
# import name` in `Module.Path` needs a `var Module_Path_name`, or the primary
# runtime will not LINK, let alone diverge.
#
# Since the foreigns co-located (2026-08-27) this asks a sharper question than
# it used to. It no longer accepts the symbol appearing SOMEWHERE in a pile of
# Go; it wants it in the file next door — `Serve.purs` -> `Serve.go` — which is
# also the file the fix goes in, so the failure names its own remedy.
#
# Scope and its limit: this sees Bosun's OWN foreign imports. It cannot see a
# library foreign that PureScript code newly pulls in — `Foreign.Object.ST.poke`
# and `Data.Argonaut.Core.stringify` were two of the six missing symbols and
# neither is declared anywhere in this repo. Only a real `go build` finds those,
# which is what `scripts/go-broker.sh` and `scripts/gnomon-bosun.sh` do.
ffi_check() {
  local missing=0 total=0 sym mod name
  while IFS= read -r line; do
    src=$(echo "$line" | cut -d: -f1)
    twin="${src%.purs}.go"
    mod=$(echo "$src" | sed 's|.*/cli/src/||; s|\.purs$||; s|/|_|g')
    name=$(echo "$line" | sed 's/.*foreign import //; s/ *::.*//')
    [ -z "$name" ] && continue
    total=$((total + 1))
    sym="${mod}_${name}"
    if [ ! -f "$twin" ] || ! grep -qE "^var $sym any" "$twin"; then
      [ "$missing" -eq 0 ] && bad "Bosun FFI twins: declared in PureScript, absent from the co-located Go —"
      echo "        · $sym   wanted in $twin"
      missing=$((missing + 1))
    fi
  done < <(grep -rn "^foreign import" "$BOSUN"/cli/src)
  if [ "$total" -lt 10 ]; then
    bad "Bosun FFI twins: only $total foreign imports found under cli/src — the scan has gone blind."
    return
  fi
  if [ "$missing" -eq 0 ]; then
    ok "Bosun FFI twins: all $total cli/src foreign imports have a co-located Go twin"
  else
    echo "      The Go binary will not link. scripts/gnomon-bosun.sh is the proof."
  fi
}
ffi_check

echo
if [ "$FAILED" -eq 0 ]; then
  echo "✅ CONTROL PARITY: the two router columns dispatch the same surface."
  echo "   (Presence only. Whether they AGREE is scripts/go-broker.sh.)"
else
  echo "❌ CONTROL PARITY: one column serves something the other does not."
  echo "   Gnomon (PureScript→Go) is the PRIMARY runtime; node is the development"
  echo "   shell. A verb that exists only in the JS is a feature that is MISSING"
  echo "   FROM THE PRIMARY RUNTIME, not a Go port that is merely pending."
fi
exit $FAILED
