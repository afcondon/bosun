# Bosun stress-test plan

Bosun is feature-complete through `serve` P2 (both columns). Before documenting
and releasing it alongside the purescript-go backend, harden the design against
chaos. Four dimensions, cheapest-and-highest-confidence first. `serve --audit`
is the spine that several of these reuse.

The standing strategy still holds: the **frozen Detect corpus**
(`fixtures/polyglot-2026-06-14/`) is the regression floor; **PBT owns infinite
stress**; the **adversarial corpus** owns the named pathologies. Nothing below
weakens those.

## 1. Property-based tests on the pure core (extends `PBTSpec`)

The pure functions are total by construction; PBT proves it over generated
chaos. Reuse the existing legal-by-construction generator + fault injectors;
add a `serve`-flavoured registry generator (random host / port / executor /
command, including malformed ones).

Properties:
- **partition totality & disjointness** — `|routes| + |redirects| + |rejected|
  == |services|`; no service appears twice.
- **admission soundness** — every `Route.launchCommand` contains the literal
  `internalPort`; `internalPort == publicPort + 20000`; every admitted route is
  local; every `Redirect` is remote.
- **rewrite faithfulness** — the only digit-run that changed from the registry
  command to `launchCommand` is the public→internal port (no collateral
  rewrites of unrelated numbers in the *flagged* set; document the known
  false-positive case — see corpus item *port-in-path*).
- **serveDiff laws** — `serveDiff p p` is empty (reflexive); applying a diff to
  `old`'s port-set yields exactly `new`'s port-set (completeness); a second
  `serveDiff new new` after applying is empty (idempotence); every port whose
  signature differs appears in the diff (no missed change).
- **validate ∘ ingest never crashes** — over any generated registry, `check`
  terminates with a `V` value (no partial-function blow-up).

## 2. Chaos-monkey scripts (`scripts/chaos/`)

Against a *live resident* `serve` (node first, then Go — see §4) with a set of
controllable dummy backends. Each monkey asserts the router stays up, `/state`
stays reachable and consistent, and the system converges + leaves no orphaned
processes or held ports on teardown.

- **request flood** — N concurrent clients hammering random public ports;
  assert eventual 200 and single-flight (one spawn per down backend, not N).
- **backend killer** — SIGKILL backends mid-request; assert respawn on the next
  request and eventual 200 (self-heal).
- **SIGHUP storm** — rapid reloads against a *flapping* registry (services
  appear/vanish/mutate each tick); assert no port leak, `/state` matches the
  last registry, no EADDRINUSE wedge.
- **slow/hung backend** — a backend that accepts then never responds (or never
  binds); assert the serve-layer timeout fires (504 / clean error), no handler
  or goroutine wedged forever.
- **bind-then-die** — a backend that binds then exits immediately; assert
  single-flight doesn't deadlock and the next request respawns.

## 3. Adversarial registry corpus (`fixtures/adversarial/` + golden outputs)

Hand-crafted nasty registries, each run through `check` / `plan` /
`serve --audit` with frozen golden output (a `scripts/corpus-adversarial.sh`
diffs, like the existing `corpus-check.sh`). Names to cover:

- dependency cycle; port collision (same host); dangling dependency; selector
  not closed; uncheckable gate.
- malformed `startCommand`: no `cd` anchor; no literal port; **port-in-path**
  (`cd /srv/app3050 && run` — the port appears in the path, not the command:
  the documented false-positive boundary); `ssh …`/`docker …` shapes; empty /
  null command.
- structural: duplicate ids; missing `role`; missing `port`; unicode / emoji
  service names; a **huge graph** (1000 services — perf + no quadratic blowup);
  deeply chained deps.

Golden outputs make a regression in any renderer or classifier loud.

## 4. Go-column parity under load (`scripts/go-chaos.sh`)

Re-run the §2 chaos suite against the **backend-go** binary, under
`go build -race` with `GORACE=halt_on_error=1`. This is the concurrency tier —
goroutine-per-request + the `sync.Once` runtime. Assert: survives the same
abuse, **no race report**, and the same convergence/`/state` as the node column
(a cross-column behavioural diff, like the existing conformance gate but under
chaos rather than a fixed fixture).

## Sequencing

1 (PBT) → 3 (corpus) are pure/cheap and land first. 2 (chaos) needs a live
target and a backend-control harness — which is exactly what **Bosun's Chair**
provides, so it pairs with that build. 4 (Go under load) reuses 2's harness
against the transpiled binary. Bosun's Chair can both *drive* the chaos and
*visualise* it, doubling as the test cockpit.
