# Bosun on the BEAM: a spike

**Status: spike, 2026-11-11. Nothing here runs in production.** Plan and
acceptance criteria: `docs/kb/plans/conformance-and-subsidiarity.md`, step 3.

The question: can Bosun's shell be Erlang, with the existing PureScript
lowered by purerl? **Answer: yes for `supervise`.** The real `bosun supervise`
runs on the BEAM, reads the same YAML, and matches node on every check there
is. Two things are unbuilt (several groups in one VM, `serve`); see the end.

## Use

    beam/build.sh                 # PureScript -> Erlang -> beam/ebin
    beam/bosun check <compose.yml> <registry.json>
    beam/bosun supervise --port N <compose.yml> <registry.json>
    beam/conformance.sh           # node against the BEAM, byte for byte
    scripts/menagerie-conf.sh     # behaviour: node, Go and the BEAM

Needs `spago`, `node` (to run purerl's backend, and as the oracle), `erl` and
`erlc` (OTP 27 or later, for the `json` module), and `git` once, to fetch
yamerl.

## What is here

| Path | What |
|---|---|
| `spago.yaml` | a purerl workspace over `../core`, `../protocol`, `../adapters`, `../cli` and Glassbox, by path |
| `purescript-backends/purerl-ports` (outside this repository, by path) | `st`, `foreign-object`, `argonaut-core`: upstream's PureScript, foreign modules rewritten in Erlang. `parsing`: upstream v10, less three modules purerl cannot build. Moved out of `vendor/` here on 2026-11-11 so they can be offered upstream (Marginalia 319) |
| `../cli/src/Bosun/CLI/*.erl` | the Erlang twins of the effectful edges (368 lines), beside the `.js` and `.go` twins |
| `deps/yamerl` | the YAML reader: fetched by `build.sh` at a pinned commit, not committed |
| `test/` | two YAML files for the reader comparison |
| `src/` | two small pure modules and links to three programs in `../conformance` |
| `build.sh`, `bosun`, `conformance.sh` | build, launcher, harness |

No PureScript source in Bosun was changed to make it run on the BEAM.

## Findings

**1. Everything compiles unchanged.** All of `bosun-core`, `bosun-protocol`,
`bosun-adapters` and `bosun-cli`, and Glassbox, lower to Erlang against the
purerl package set of June 2022.

**2. "Pure" was not the whole story.** Eight of the 33 pure modules import
`argonaut-core`, `codec-argonaut` or `foreign-object`. The first and last
have JavaScript foreign code and are absent from the purerl set, as is `st`.
`purescript-backends/purerl-ports` holds a port of each. `codec` and `codec-argonaut` are pure and
come from upstream unchanged.

**3. Key order is behaviour.** A JavaScript object enumerates array-index
keys first, in numeric order, then every other key in insertion order, and
Bosun's output depends on it. The port represents an `Object` as an ordered
list of pairs, not an Erlang map, and keeps exactly that order. Reversing
the parser's key order turns 6 of 13 real-file cases red.

**4. The BEAM has no NaN and no infinity,** and purerl's `Data.Number`
exports neither. Two consequences, both small: Glassbox's canonical printer
now tests `n /= n` instead of importing `isNaN`, and the ported parser's
`number` no longer accepts the strings "NaN" and "Infinity".

**5. `show :: Number` differs.** JavaScript prints `3000.0`; purerl prints
`3.00000000000000000000e+03`. It shows in two places. The supervisor
harness printed times with `show` (now whole milliseconds). And `/state` is
built by string concatenation with `show`, so on the BEAM
`lastTransitionAt` reads `1.79e+12`: the same number, valid JSON, different
bytes. Building `/state` with the shared codec (plan step 2) removes it.

**6. Glassbox ran with two edits and now has a third runtime.** Its one
foreign function was `JSON.stringify(j, null, 2)`, which argonaut already
provides as `stringifyWithIndent 2`; the JavaScript file is gone. The BEAM
regenerates all seven committed vector files byte for byte.

**7. No native helper is needed to manage operating-system processes.**
Bosun never held its children. The pure core writes shell lines that launch
into a new process group, record it in a pidfile, and later signal the
group. The edge only runs a line. node's edge adds `detached: true` so the
launching shell has a group of its own; `open_port` already does that, on
macOS and Linux (measured on both).

**8. The HTTP surface needs no web server.** `/state` and `/control` are
about 100 lines on the BEAM's own sockets (`{packet, http_bin}`). One owner
process runs every tick and every callback in turn, because the PureScript
behind them was written for node's single thread.

**9. YAML: yamerl agrees with js-yaml on every real file, with two repairs.**
All 23 YAML files under `fixtures/` read identically. A file of awkward
scalars found two differences. yamerl does not apply the merge key `<<`
(YAML 1.1, which js-yaml and docker-compose files use); the read edge now
applies it, js-yaml's way. And yamerl 0.10.0 misreads an anchor on a flow
collection (`&name {a: 1}`), silently; the read edge refuses such a file
with an error that says why. An anchor on a block collection is fine.

## Evidence

`beam/conformance.sh`: 99 cases, node against the BEAM, all byte-identical.

| Cases | What |
|---|---|
| 2 | Detect and the supervisor transition, hardcoded fixtures |
| 13 | `/analyze` over real compose files and the fleet registry (31 to 39 KB each) |
| 25 | the YAML readers: 23 real files, one file of awkward scalars, one file that must be refused |
| 52 | the command line: `check`, `plan`, `apply --dry-run`, `down --dry-run` on 13 fixtures, both sides reading the YAML |
| 7 | Glassbox's committed vector files, regenerated |

Shown to fail: printing whole numbers as `3.0`, reversing the parser's key
order, and prepending a new key each turn cases red. Mutate the source, not
`ebin/`: the harness rebuilds.

`scripts/menagerie-conf.sh`: the existing behavioural rig, now with a BEAM
column. 12 assertions per runtime on real effects (boot grace, no relaunch
storm, one listener per port, a forked process tree reaped on `down`, a
clean `up`), then `/state` compared with node's. node, Go and the BEAM pass.

That rig's `/state` comparison had been failing for Go on every run, since
`/state` gained live process ids. The ids are now masked.

By hand, on a private two-service group: bring-up in dependency order;
`kill -9` of a service detected and relaunched in about a second; `restart`,
`down`, `up` through `/control`; an unknown verb refused with 400; `restart`
while held refused; `down` leaving no process, a grandchild included.

**Killing the supervisor.** Children survive `kill -9` of the BEAM and keep
serving. A fresh supervisor reaps them and launches again. node does exactly
the same; neither adopts. (An earlier note here said today's Bosun adopts.
It does not.)

## Measurements

MBP, 2026-11-11. Memory is `footprint`'s `phys_footprint`; resident size
under-reports on this machine, which compresses memory.

| | node | BEAM |
|---|---|---|
| One supervisor, one group | 35 to 43 MB | 67 MB |
| Today's five Bosun processes | 205 MB in total | |
| `/state` answering after launch | | 0.5 s |
| Detect case, start to finish | about 95 ms | about 190 ms |

One BEAM supervisor is bigger than one node supervisor. The saving comes
only from putting several groups in one VM, which is not built: four node
supervisors are about 165 MB, and one VM holding four groups should be near
70 MB. `serve` stays on node either way.

## Not done

- **Several groups in one VM,** and OTP supervising the group supervisors,
  which is what would replace today's meta-supervisor on :3990.
- **`serve`.** A reverse proxy living in 1,500 lines of foreign code. Not
  ported, on purpose; `Serve.erl` and `Audit.erl` are stubs that say so.
- **A release.** `beam/bosun` runs `erl -pa ebin`. No OTP application,
  no boot script.
- **Divergences documented but not tested:** very large and very small
  number printing, and strings beyond the Basic Multilingual Plane in
  `Json` ordering.
