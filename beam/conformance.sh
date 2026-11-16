#!/usr/bin/env bash
# beam/conformance.sh: Bosun's pure core on node and on the BEAM, byte for byte.
#
# Three kinds of case, all from ONE PureScript source compiled twice:
#   Detect     Bosun.Conformance.Main           hardcoded fixture, reconcile -> validate -> report
#   Supervise  Bosun.Conformance.SuperviseMain  hardcoded fixture, the supervisor transition
#   Analyze    Bosun.Conformance.AnalyzeText    real compose + registry files, through the JSON
#                                               parser, the adapters and the wire codec
#   State      Bosun.Conformance.StateText      /state documents, read and printed by the description
#   Glassbox   Bosun.Beam.GlassboxVectors       every machine's committed vector file, regenerated
#   YAML       Bosun.CLI.IO (foreign)           js-yaml against yamerl, every YAML file in fixtures/
#   Commands   Bosun.CLI.Main                   check, plan, apply --dry-run, down --dry-run
#
# The Analyze cases hand both runtimes the same JSON text (js-yaml's reading
# of each compose file), so they hold the JSON path alone. The YAML readers
# are compared separately, and the Commands cases read the YAML on both sides.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOSUN="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0

echo "==> build: node column"
( cd "$BOSUN" && spago build >/dev/null 2>&1 ) || { echo "node build failed"; exit 1; }
echo "==> build: purerl column"
"$HERE/build.sh"

check() { # label, node output file, beam output file
  if cmp -s "$2" "$3"; then echo "  ✓ $1 ($(wc -c <"$2" | tr -d ' ') bytes)"
  else echo "  ✗ $1: node ≢ beam"; diff <(head -c 4000 "$2") <(head -c 4000 "$3") | head -8 | sed 's/^/      /' || true; fail=1; fi
}

echo "==> hardcoded fixtures"
for m in Main SuperviseMain; do
  node --input-type=module -e "import('$BOSUN/output/Bosun.Conformance.$m/index.js').then(x => x.main())" > "$TMP/$m.node"
  mod="bosun_conformance_$(echo "${m:0:1}" | tr 'A-Z' 'a-z')${m:1}@ps"
  erl -noshell -pa "$HERE/ebin" -eval "('$mod':main())(), halt()." > "$TMP/$m.beam"
  check "Bosun.Conformance.$m" "$TMP/$m.node" "$TMP/$m.beam"
done

echo "==> analyze, real files"
REG="$BOSUN/registry/fleet.json"
for compose in "$BOSUN"/fixtures/*/compose.yml; do
  name="$(basename "$(dirname "$compose")")"
  [ -r "$compose" ] || { echo "  - $name (compose.yml is a dangling link; skipped)"; continue; }
  ( cd "$BOSUN" && node --input-type=module -e "
    import yaml from 'js-yaml';
    import { readFileSync, writeFileSync } from 'node:fs';
    writeFileSync('$TMP/$name.json', JSON.stringify(yaml.load(readFileSync('$compose', 'utf8'))));" )
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { analyzeText } from '$BOSUN/output/Bosun.Conformance.AnalyzeText/index.js';
    process.stdout.write(analyzeText(readFileSync('$TMP/$name.json', 'utf8'))(readFileSync('$REG', 'utf8')));" > "$TMP/$name.node"
  erl -noshell -pa "$HERE/ebin" -eval "
    {ok, C} = file:read_file(\"$TMP/$name.json\"), {ok, R} = file:read_file(\"$REG\"),
    ok = file:write_file(\"$TMP/$name.beam\", 'bosun_conformance_analyzeText@ps':analyzeText(C, R)), halt()."
  check "$name" "$TMP/$name.node" "$TMP/$name.beam"
done

# /state: every document in protocol/vectors/state, read and printed again
# through the one description (Bosun.Protocol.State). Three things are held:
# node and the BEAM agree; a document the daemon wrote comes back unchanged;
# and one with an .expected file beside it comes back as that file says.
echo "==> /state, the described document"
for doc in "$BOSUN"/protocol/vectors/state/*.json; do
  name="state-$(basename "$doc" .json)"
  node --input-type=module -e "
    import { readFileSync } from 'node:fs';
    import { stateText } from '$BOSUN/output/Bosun.Conformance.StateText/index.js';
    process.stdout.write(stateText(readFileSync('$doc', 'utf8')));" > "$TMP/$name.node"
  erl -noshell -pa "$HERE/ebin" -eval "
    {ok, D} = file:read_file(\"$doc\"),
    ok = file:write_file(\"$TMP/$name.beam\", 'bosun_conformance_stateText@ps':stateText(D)), halt()."
  check "$name" "$TMP/$name.node" "$TMP/$name.beam"
  want="${doc%.json}.expected"; [ -f "$want" ] || want="$doc"
  if cmp -s "$TMP/$name.node" "$want"; then echo "  ✓ $name is what $(basename "$want") says"
  else echo "  ✗ $name: not what $(basename "$want") says"; diff <(head -c 4000 "$want") <(head -c 4000 "$TMP/$name.node") | head -6 | sed 's/^/      /' || true; fail=1; fi
done
ls "$BOSUN"/protocol/vectors/state/*.json >/dev/null 2>&1 || { echo "  ✗ no /state vectors found"; fail=1; }

# The two YAML readers: js-yaml on node, yamerl on the BEAM. Each reads the
# same file through Bosun's own read edge, and the JSON each makes of it is
# compared. Every YAML file under fixtures/, and a file of awkward scalars.
echo "==> YAML readers (js-yaml against yamerl)"
while IFS= read -r yml; do
  [ -r "$yml" ] || continue
  label="${yml#$BOSUN/}"
  ( cd "$BOSUN" && node --input-type=module -e "
      import { readYamlImpl } from '$BOSUN/output/Bosun.CLI.IO/foreign.js';
      process.stdout.write(JSON.stringify(readYamlImpl('$yml')));" ) > "$TMP/yaml.node" 2>&1 || true
  ( cd "$BOSUN" && erl -noshell -pa "$HERE/ebin" -pa "$HERE/deps/yamerl/ebin" -eval "
      J = ('bosun_cLI_iO@foreign':readYamlImpl())(<<\"$yml\"/utf8>>),
      ok = file:write_file(\"$TMP/yaml.beam\", 'data_argonaut_core@foreign':stringify(J)), halt()." ) > "$TMP/yaml.beam.err" 2>&1 || cp "$TMP/yaml.beam.err" "$TMP/yaml.beam"
  check "$label" "$TMP/yaml.node" "$TMP/yaml.beam"
done < <(find "$BOSUN/fixtures" "$HERE/test" \( -name '*.yml' -o -name '*.yaml' \) ! -name 'yaml-refused.yml' | sort)
# One known fault in yamerl, which the read edge must refuse and not misread.
refusal="$( cd "$BOSUN" && "$HERE/bosun" check "$HERE/test/yaml-refused.yml" "$REG" 2>&1 || true )"
if [[ "$refusal" == *yaml_anchor_on_a_flow_collection* ]]; then
  echo "  ✓ beam/test/yaml-refused.yml is refused (an anchor on a flow collection)"
else
  echo "  ✗ beam/test/yaml-refused.yml was not refused"; fail=1
fi

# The command line itself: the same read-only commands through `node
# cli/run.js` and through beam/bosun, both reading the YAML. This exercises
# the Erlang twins of the IO edge and the real Main.
echo "==> command line, read-only commands"
for compose in "$BOSUN"/fixtures/*/compose.yml; do
  name="$(basename "$(dirname "$compose")")"
  [ -r "$compose" ] || continue
  for verb in "check" "plan" "apply --dry-run" "down --dry-run"; do
    ( cd "$BOSUN" && node cli/run.js $verb "$compose" "$REG" ) > "$TMP/cli.node" 2>&1 || true
    ( cd "$BOSUN" && "$HERE/bosun" $verb "$compose" "$REG" ) > "$TMP/cli.beam" 2>&1 || true
    check "$name: $verb" "$TMP/cli.node" "$TMP/cli.beam"
  done
done

# Glassbox on the BEAM: regenerate each machine's committed vector file. The
# committed files were written by node (`make vectors` in purescript-glassbox).
echo "==> glassbox vectors, regenerated on the BEAM"
GLASSBOX="$(cd "$BOSUN/../../purescript-hylograph-libs/purescript-glassbox" && pwd)"
for machine in "$GLASSBOX"/core/machines/*.json; do
  name="$(basename "$machine" .json)"
  erl -noshell -pa "$HERE/ebin" -eval "
    {ok, A} = file:read_file(\"$machine\"),
    ok = file:write_file(\"$TMP/$name.vectors\", 'bosun_beam_glassboxVectors@ps':vectorsText(A)), halt()."
  check "$name" "$GLASSBOX/conformance/vectors/$name.json" "$TMP/$name.vectors"
done

[ "$fail" = 0 ] && echo "beam conformance: ALL IDENTICAL" || { echo "beam conformance: DIVERGED"; exit 1; }
