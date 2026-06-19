# Bosun artifacts — build once, run anywhere, same bytes

**Status:** DIRECTION (2026-06-18). The keystone that makes *"deploy the same
content whether native or in Docker, here or on the mini"* a **guarantee**, not a
convention. Prompted by a live finding: the public polyglot site (docker, on the
mini) serves stale Feb content while the MBP-native `static-httpd` serves the
current June site — the *same logical service*, two *different* contents, because
each substrate built from its own source.

## Deployment is a triple — (artifact, executor, target)

Three orthogonal axes:

- **artifact = WHAT runs** — the built bytes. **Substrate-independent.**
- **executor = HOW it runs** — process / docker / launchd / beam / systemd
  (`EXECUTORS.md`).
- **target = WHERE it runs** — mbp / macmini / … (`targets.json`).

The invariant the user wants: **the same artifact, run via any executor on any
target, yields the same content.** Today it doesn't — and that gap *is* the bug.

## The guarantee — build once, ship the artifact, run via executor

The only way "same content everywhere" is guaranteed and not hoped:

1. **Build the artifact ONCE** — one revision, one build, → a static dir / a
   binary / a bundle / an image.
2. **Ship that artifact** to each target — push an image to a registry the target
   pulls, or rsync the built dir. The shipped bytes are identical by construction.
3. **Run it via the substrate's executor** — process: `static-httpd -root <dir>`;
   docker: run the *shipped* image.

The anti-pattern (what we have now) is **build-per-host-from-local-source**: the
mini builds the website image from the mini's *own checkout* of
`purescript-polyglot`, which drifts from the MBP's. Same Dockerfile, different
source bytes → different content. Build-once-ship eliminates that by construction.

This is `bosun-daemon` rule #2 ("prebuilt artifact, not build-at-launch") raised
one level: **Bosun runs artifacts; building *and shipping* them is upstream.**

## The current violation (the worked example)

The polyglot **website**, one logical service:

- **MBP-native:** `static-httpd -root site/polyglot/public` → the current June
  static site. ✓
- **MacMini-docker:** compose `build: context: ../purescript-polyglot/site/website`
  → built *on the mini*, from the mini's checkout, from the *old Feb* dir. ✗✗

Two independent drifts (wrong dir **and** wrong host's source). Result:
hylograph.net serves stale content (with a broken `curl`-healthcheck) for months,
while the MBP would serve the right thing. Same disease as the `:3040 -root` and
the lifted `polyglot-core` compose — the same fact living in two places.

## Artifact kinds × executors

| artifact kind | process executor | docker executor |
|---|---|---|
| **static dir** | `static-httpd -root DIR` | nginx image with DIR as web root |
| **binary** | run the binary | image wrapping the binary |
| **bundle + runtime** | `node entry.mjs` | image: runtime + bundle |
| **image** | (n/a) | run the image |

Each cell is "run *this* artifact on *that* substrate." The artifact is identical
across the row — that's the guarantee. The executor only changes how it's run.

## How Bosun makes drift unrepresentable (MISU)

- A service declares its **artifact ONCE** — kind + source/ref (ideally a pinned
  digest/revision, so "what content" is fixed, not re-derived per host).
- Each executor's run-spec is **derived** from that single declaration. You
  *cannot* point the process at one dir and docker at another, because there is one
  source. ("Same service, different content per substrate" becomes unrepresentable
  — the project's MISU ethos applied to content.)
- `apply` for docker **pulls a shipped image** (or ships the dir); it does **not**
  `build` per host. Building + publishing is a distinct upstream step (CI, or a
  future `bosun publish`) that produces the artifact the deployment references.

## Near-term → long-term

1. **Now (polyglot-deploy):** point the website image's content at the *current*
   site (`site/polyglot/public`), and fix the `curl → wget` healthcheck. Stops the
   bleeding; still build-per-host, but at least the right source.
2. **Better:** build the site once and **ship** it — push the image to a registry
   the mini pulls, or rsync the built dir — so MBP-native and mini-docker consume
   the same bytes.
3. **Bosun (engine):** model `artifact` as a first-class service field; derive each
   executor's run-spec from it; make `apply` *pull/ship*, not *build*. This is what
   turns the guarantee from discipline into a type.

## Related

- `EXECUTORS.md` — the HOW axis (substrates). This adds the WHAT axis.
- `targets.json` — the WHERE axis.
- `AGENT-CONTRACT.md` / `bosun-daemon` — "prebuilt, not build-at-launch": the same
  principle for the process executor.
- `MARGINALIA-SEAM.md` — single source of truth; same disease, different facet.

---

## IMPLEMENTED (engine, 2026-06-18) — the model + detection landed

The WHAT axis is now first-class. What shipped this pass:

### The model — `Bosun.Artifact` (core)
- **`Artifact`** = `StaticDir | Binary | BundleRuntime | SourceBuild | Image`, each
  carrying an **`ArtifactRef { source, pin :: Maybe }`**. `SourceBuild` (a
  `build:` context, *built per host*) is deliberately distinct from `Image` (a
  *prebuilt, shippable* image — the build-once-ship target): the type now names
  the anti-pattern. The optional `pin` is where a digest/revision makes "what
  content" fixed rather than re-derived per host.
- **`artifactOf :: Executor -> Maybe Artifact`** — classifies the artifact an
  existing executor *implies* (the bridge from today's per-facet content to a
  single declaration). `image:` → `Image`; `build:` → `SourceBuild`; a process
  `-root DIR` → `StaticDir`; a node entry → `BundleRuntime`; an opaque launcher
  → `Binary` (no source dir).
- **`runCommandFor` / `containerSourceFor`** — the MISU machinery, the *inverse*:
  one artifact → each substrate's run-spec. A `StaticDir` derives
  `static-httpd -root … -port …`; a prebuilt `Image` derives the image AS the
  container source (not a build); everything else derives a build context. Because
  both run-specs are DERIVED from the one artifact, a process facet and a
  container facet *cannot* point at different content — the unrepresentability the
  axis exists to provide.

### The detection — `Bosun.Reconcile.ArtifactDrift` + `bosun check`
`reconcile` now computes the artifact each facet of a service implies and, via
`artifactConsensus`, flags **`ArtifactDrift`** when the facets name **different
source dirs** (compared by basename). It is a reconcile-level finding (sibling to
`Divergence`), NOT a `DeployError` — it does not block minting a
`ValidatedDeployment` (you may deploy the diverged thing while you fix it).
`renderArtifactDrift` surfaces it in `bosun check` (own section, so the
conformance-pinned `renderReport` is untouched).

**Conservative by design — no false positives.** Only facets that expose a
*source dir* (`StaticDir`, `SourceBuild`) participate; a prebuilt `Image` and an
opaque launcher carry none. So the canonical §7 divergence (`npx serve` native +
a prebuilt image) is correctly **not** flagged (verified by a guard test). The
real drift case — native `static-httpd -root site/polyglot/public` vs container
`build: …/site/website` — IS flagged (basename `public` ≠ `website`; reconcile
test proves it).

### Gates
144 tests (new `Test.Bosun.ArtifactSpec` + reconcile drift/guard cases), 0
warnings. **node≡Go byte-identical** (go-conformance) and the **frozen corpus
golden unchanged** (no drift on the 2026-06-14 rig — its website's `npx serve`
and the container both resolve to `site/website`, consistent).

### Honest reach + limits (the argument for a DECLARED artifact)
Detection over today's startCommands is bounded by two heuristics:
1. **`artifactOf` reads the command string**, so `npx serve <subdir>` (content
   relative to the process *cwd*) isn't seen as a source dir — only an explicit
   `-root DIR` is. (The corpus website is this case → not flagged, correctly
   consistent there.)
2. **Grouping process↔container facets is by directory basename** (`buildAliases`),
   which can miss a pairing whose dirs don't share a basename.

Both are exactly why the endgame is a **declared `x-bosun.artifact`**: a fact
replaces each guess, and the run-specs are *generated* from it rather than
ingested independently.

### NEXT (not in this pass)
1. **Declared `x-bosun.artifact`** on a compose service / registry row (kind +
   pinned ref) → reconcile checks each facet's ingested run-spec *against the
   declaration* (declared-vs-reality), and `artifactOf` is the fallback only when
   undeclared. Makes detection robust (no basename/cwd heuristics).
2. **`apply` pull/ship from the artifact** (bullet 3): thread `artifact` onto
   `LaunchSpec`; in `applyScript`, a prebuilt `Image` Start derives
   `docker compose pull <name>` → `up -d --no-build` (pull-not-build); a
   `SourceBuild` Start emits the up PLUS a build-once-ship advisory. Needs the
   apply-conformance goldens re-baselined, so it is its own focused follow-up.
   Meaningful only once a pinned `Image` is *declared* (#1) — without a pin, apply
   can only respect the host compose.

---

## The descriptor is an artifact too (real specimen, 2026-06-18)

A finding from the polyglot-deploy step-2 fix, and it widens the axis. The
original brief framed the disease as **build-per-host rebuilds stale content** —
the *bundles* drift. Reality was worse: the **deployed compose file on the mini
had itself silently diverged from the repo** — hand-edited in place with
different backend ports (`8083`/`5081:8081`/`5082:8082`) and an older
purerl-tidal path. So the thing that drifted was not (only) a built artifact but
the **orchestration descriptor** — the deployment config itself.

The lesson: **the deployment descriptor is an artifact.** "Build once, ship the
artifact" must cover the compose/orchestration file with the same discipline as
the bundles and images — one source of truth, shipped, not hand-edited per host.
A `StaticDir`/`Image` guarantee on the content is hollow if the *descriptor that
wires it up* is itself a per-host fork.

This connects three things already in the model:

- The flagged copy-drift: `fixtures/polyglot-core/compose.yml` is "lifted
  verbatim" from `polyglot-deploy/docker-compose.yml` — same disease, and now we
  know the *deployed* descriptor had also forked from *that*. There were three
  copies (repo, fixture, mini), none guaranteed equal.
- Bosun ingests a compose as **desired** config, but the **live deployed
  descriptor** on the host (what `docker compose config` actually resolves there)
  is a THIRD source that can disagree with both the repo and Bosun's model — a
  drift the current reconcile (compose-vs-registry) does not yet see.
- It is the mirror of **Portolan** (`[[project_portolan_discovery]]`: mine a
  running system → model): here we want to *observe the live descriptor and diff
  it against the source-of-truth descriptor*, flagging the fork.

### Consequence (future, not this pass)
A **descriptor-drift** detection: observe the host's effective compose
(`docker compose config` over ssh — the observe edge already does this class of
read) and reconcile it against the repo/SSOT descriptor, surfacing per-host
edits as drift — the same divergence-vs-conflict machinery, applied one level up
to the orchestration file. Pairs naturally with the build-once-ship `apply`
(task: declared `x-bosun.artifact` + apply pull/ship): ship the descriptor too,
then detect when a host has forked it.

---

## IMPLEMENTED (engine, 2026-06-18 pt.2) — apply pull/ship landed (task #22a)

The operational half of the axis. `LaunchSpec` now carries `artifact :: Maybe
Artifact` (reconcile fills it via `artifactOf` the representative executor), and
`applyScript` DERIVES a Container Start from it:

- **prebuilt `Image`** → `docker compose pull <name> && docker compose up -d
  --no-build <name>` — pulls the shipped bytes, REFUSES a per-host build even if
  the host compose declares one. Build-once-ship enforced at the launch.
- **`SourceBuild`** (built per host) → still `docker compose up -d <name>` (we
  cannot do better without a shipped image) PLUS a `# MANUAL: build-once-ship: …
  builds from source (<dir>) — ship a prebuilt image instead` advisory in the
  script — the anti-pattern made visible at apply time.
- everything else → unchanged.

**Proven:** ApplySpec pins both renderings; **node≡Go byte-identical**
(go-conformance, incl. the tidal-frontend container) and the **Go binary
deploys** (go-apply → HTTP 200) with the new field; and on the REAL polyglot-core
dry-run, both `edge` and `website` (real `build:` services) now emit the
build-once-ship advisory naming their source dir. 146 tests, build clean.

### Still remaining (task #22b): the DECLARED `x-bosun.artifact`
The artifact is still *heuristic* (`artifactOf` reads the executor). The
robustness half — a declared `x-bosun.artifact { kind, source, pin }` on a
compose service / registry row that (a) becomes the AUTHORITATIVE artifact
(`reconcile` prefers it over the heuristic, dropping the cwd/basename guesses),
(b) lets apply pull a *pinned* image (a digest, not a floating tag), and (c)
enables a declared-vs-reality drift check — is the next focused pass. It adds
`artifact` to `ServiceInstance` (a broad-but-mechanical ripple across the ingest
literals), so it is kept separate from this apply landing.

---

## IMPLEMENTED (engine, 2026-06-18 pt.3) — declared `x-bosun.artifact` (task #22b) — axis COMPLETE

The robustness half landed; the artifact axis is now end-to-end.

- **`ServiceInstance` gained `artifact :: Maybe Artifact`.** The Compose adapter
  parses **`x-bosun.artifact: { kind, source, pin? }`** (`kind` ∈ static-dir |
  binary | bundle(+runtime) | source-build | image) into a declared `Artifact`.
- **Declaration is authoritative.** `reconcile`'s `artifactFor` is
  `si.artifact <|> artifactOf si.executor` — the declared artifact wins over the
  heuristic, dropping its cwd/basename reach limits. Both the `LaunchSpec.artifact`
  (apply) and the cross-facet `artifactConsensus` (drift detection) use it.
- **End-to-end proven:** a `build:` service that declares
  `x-bosun.artifact: { kind: image, source: hylograph/demo, pin: sha256:… }`
  flips from the SourceBuild advisory to **pull-not-build**
  (`docker compose pull demo && docker compose up -d --no-build demo`) — the
  declaration overrides the `build:` heuristic and drives apply. A pinned image
  is now declarable, so "what content" can be FIXED rather than floating.

147 tests (declared-artifact parse test added), 0 warnings; **node≡Go
byte-identical** (go-conformance — the new field, Compose parse, and `<|>`
`artifactFor` all transpile) and the **corpus golden unchanged**.

### The axis, complete
`Bosun.Artifact` (model + derivation) → declared `x-bosun.artifact` (authoritative
content) → `reconcile` (drift detection + LaunchSpec.artifact) → `apply`
(pull-not-build / build-once-ship advisory). **polyglot-deploy can now adopt
build-once-ship**: declare `x-bosun.artifact: { kind: image, source, pin }` on the
website/edge services, ship the image, and `bosun apply` pulls it instead of
building per host. (Remaining nice-to-haves, NOT blocking: a declared-vs-reality
drift check — flag when a facet's *ingested* run-spec contradicts its
*declaration*; and the descriptor-drift detection from the post-step-2 finding.)

---

## The edge is topology, preserve it locally (IMPLEMENTED 2026-06-18)

The artifact axis kills "same service, different *content* per substrate." Its
sibling is "same service, different *topology* per substrate": the polyglot
**website** carries an implicit **routing contract** — its root-relative links
(`/`, `/ee`, `/ge`, `/atlas`) require a same-origin path-router fronting the
siblings. The artifact stays byte-identical across substrates (build-once-ship
working); what differs is whether the **executor supplies the edge**. Docker does
(the Lua `edge` container). A bare mbp/process bring-up does not → `/ee` 404s. The
gap was a browser 404, not a typed error. Now it is a typed finding.

### The model (engine-owned, per the cross-Claude labour split)
- **Route table R** = the union of every facet's declared `x-bosun.routes:
  [{ path, to }]` (already ingested; the Lua config Bosun can't introspect is
  replaced by the declaration — same philosophy as `x-bosun.artifact`). The edge
  declares R; backends are the route *targets*.
- **`Bosun.Reconcile.TopologyDrift`** — a sibling of `ArtifactDrift`, NOT a
  `DeployError` (non-blocking: a valid deployment can still be edge-missing on one
  host; you may deploy it while you add the local edge). `reconcile` computes,
  **per host H**: a route whose backend has a facet on H but whose path is served
  by NO facet on H is *edge-missing on H* — the executor that brought the backends
  up there dropped the front door. Hosts with ≥1 such route yield a
  `TopologyDrift { host, missing }`. `bosun check` renders an **EDGE MISSING**
  section (own section, like artifact drift — the conformance-pinned `renderReport`
  is untouched).
- **Conservatism (mirrors `artifactConsensus`'s basename rule):** the edge is
  expected *co-located* with the backends it fronts. A cross-host edge proxying to
  another host over the network is legitimate and not flagged (that richer case is
  deferred). Host-less instances are skipped (can't name the host to flag).

### Demonstrated
`fixtures/topologies/edge-missing/` — the polyglot story in miniature (edge on
macmini routing `/`,`/ee`,`/ge`; the routed services native on the mbp with no
edge). `bosun check` flags **`mbp serves none of /→website, /ee→ee-backend,
/ge→ge-backend`**. The `fixtures/topologies/valid/` fixture (routers co-located
with their backends) stays quiet — no false positive — as does the real
`fixtures/polyglot-core` (single-host docker fleet).

### Goes quiet when the edge is restored
Add the edge on the host that lacked it (Chair's `polyglot-up` 5th row — a local
edge process serving R on the mbp) and the finding disappears: the fix is
**topology, not content**. Forking the home page per environment would reintroduce
the exact artifact-drift anti-pattern this axis exists to kill.

151 tests (4 topology-drift cases: fires multi-host, quiet when co-located, quiet
for an unrouted backend, renders), 0 warnings; **node≡Go byte-identical**
(go-conformance — the new `ReconcileResult` field + per-host pure function
transpile). No Chair/polyglot contract change: no new ingest, no `/state`/control
change, `ReconcileView` untouched (additive field the View codec doesn't encode).
