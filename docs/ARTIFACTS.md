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
