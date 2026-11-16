#!/usr/bin/env bash
# beam/build.sh: PureScript -> Erlang (purerl) -> .beam, into beam/ebin.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
[ -d node_modules ] || npm install --silent
spago build -p bosun-beam >/dev/null 2>&1 || { spago build -p bosun-beam 2>&1 | tail -30; echo "purerl build failed"; exit 1; }
# erlc one file at a time (a batch stops at the first failure) and only what
# changed; maybe_expr off because purerl's Data.Maybe defines `maybe`.
mkdir -p ebin
while IFS= read -r f; do
  beam="ebin/$(basename "${f%.erl}").beam"
  if [ ! -f "$beam" ] || [ "$f" -nt "$beam" ]; then
    erlc -disable-feature maybe_expr -W0 -o ebin "$f" || { echo "erlc failed: $f"; exit 1; }
  fi
done < <(find output-erl -name '*.erl')

# yamerl: the YAML reader behind `readYamlImpl` on the BEAM. Pure Erlang, BSD
# 2-Clause, no dependencies. Pinned to the commit of its v0.10.0 tag and built
# with plain erlc; fetched once.
YAMERL_COMMIT=39981b9cb9d9edc227cf43a3e19dd16869493553
if [ ! -d deps/yamerl ]; then
  mkdir -p deps
  git clone -q https://github.com/yakaz/yamerl.git deps/yamerl
fi
if [ "$(git -C deps/yamerl rev-parse HEAD)" != "$YAMERL_COMMIT" ]; then
  git -C deps/yamerl checkout -q "$YAMERL_COMMIT" || { echo "yamerl: cannot check out $YAMERL_COMMIT"; exit 1; }
  rm -rf deps/yamerl/ebin
fi
if [ ! -f deps/yamerl/ebin/yamerl.app ]; then
  mkdir -p deps/yamerl/ebin
  for f in deps/yamerl/src/*.erl; do
    erlc -W0 -I deps/yamerl/include -o deps/yamerl/ebin "$f" || { echo "erlc failed: $f"; exit 1; }
  done
  cp deps/yamerl/src/yamerl.app.src deps/yamerl/ebin/yamerl.app
fi
