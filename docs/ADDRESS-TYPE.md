# `Address` — refining `Exposure` into a reachability address

> **Status: ADOPTED — experiment ran 2026-06-16 on branch `address-type`, all
> gates green, merged to `main`.** Originally a Pillar-3 design proposal (below,
> unchanged for the record). The visual work on "how is a service reached"
> surfaced four things the current `Exposure` sum could not express; this note
> proposed a richer type and asked the engine session to try it in a branch.
> **It did not flame out — see §11 for the result.** `Reachability`/`Address`/
> `BindScope` landed additively-by-replacement; `Exposure` survives as the
> derived `classify` projection exactly as proposed.

---

## 0. The ask

Apply the proposed `Reachability`/`Address` type (§2) on a feature branch,
**additively** (§7) — keep `Exposure` working as a derived classification — and
walk the watch-list (§8). Report: which consumers pass through unchanged, which
get *better* with the richer type, and which (if any) actively resist. §9 says
what would falsify "strictly inferior."

This came from the *viz* side informing the *spec* side: the exposure badge we're
designing for the graph wants to render an address (host-scope, port, path,
socket — with wildcards), and we found the IR can't supply it. That's the signal
that the type, not the picture, is the thing that's underspecified.

---

## 1. Why — what `Exposure` cannot express

Current type (`core/src/Bosun/Exposure.purs`):

```purescript
data Exposure
  = HostPort     Port
  | InternalPort Port
  | ProxyRoute   { proxy :: ServiceId, path :: RoutePath }
  | PublicDomain Domain
  | UnixSocket   AbsPath
  | NoNetwork
```

Four concrete gaps, all hit during the badge design:

1. **Bind-address / interface scope.** `HostPort Port` carries the port but not
   *which interface it binds*. So `0.0.0.0:8080` (every interface — a public
   attack surface) and `127.0.0.1:8080` (loopback — sealed) are **both** just
   `HostPort 8080`, indistinguishable — despite being opposite ends of the
   security spine. This is the headline gap; it bites even on a homelab.
2. **Host scope is a spectrum modelled as a binary.** `HostPort | InternalPort`
   is "host-published or not." Reality grades: internet / all-interfaces /
   tailnet-or-LAN / cluster-internal / loopback. The sum can't say where on the
   ramp a service sits.
3. **Composition.** A service's `exposure` is *singular*. But services compose:
   proxied at `/api` **and** listening on an internal `:5432`; or a public domain
   via CDN **and** a direct host port for health checks. The hybrid is
   unrepresentable.
4. **Per-constructor partial addresses.** Even within one kind the address is
   incomplete: `HostPort` doesn't carry its `Host`, `PublicDomain` doesn't carry
   port or backing. The segments are scattered across constructors rather than a
   uniform address.

The address *segments* already exist in the spec as atoms — `Domain`, `Host`,
`Port`, `RoutePath`, `AbsPath` (`core/src/Bosun/Atoms.purs`) — which is the
positive sign: the vocabulary is there, it's just never unified into one address.

---

## 2. The proposed types

A service's reachability is a **set of addresses** (composition), each address a
**tight sum** (illegal addresses unrepresentable), with the missing axis —
**bind scope** — made explicit. Reuses the existing atoms; respects the
recompile test (closed sums only for categories the program enumerates; the host
*identity* stays an opaque `Host`).

```purescript
-- How a service can be reached. `Set.empty` = no inbound surface (the old
-- `NoNetwork`, now a principled degenerate case rather than a constructor).
-- A SET, not an Array: order is meaningless and a service "reached two identical
-- ways" is just one way — Set dedups by construction (a small MISU win, §5).
newtype Reachability = Reachability (Set Address)

-- One inbound address — a tight sum reusing the atoms. The VIZ projects this
-- onto a uniform NAME·HOST·PORT·PATH·SINK stack for display; the TYPE stays
-- tight (you cannot build a portless Listening). Same type, spec side and viz
-- side (§6).
data Address
  = Listening { bind :: BindScope, port :: Port }        -- a network listener
  | Proxied   { proxy :: ServiceId, path :: RoutePath }  -- behind a reverse proxy at a path
  | Published Domain                                     -- a public DNS name (CDN / ingress)
  | Socket    AbsPath                                    -- a unix-domain socket (es9 / fh2 daemons)

-- Where a listener binds — the security-relevant scope `HostPort`/`InternalPort`
-- could not grade. THIS closes gap (1): 0.0.0.0 vs 127.0.0.1.
data BindScope
  = AllIfaces        -- 0.0.0.0 / [::]  — every interface (widest surface)
  | HostIface Host   -- a specific host/interface (opaque Host: tailnet / LAN / public)
  | Internal         -- cluster/network-internal only (k8s ClusterIP; on-net, not host-published)
  | Loopback         -- 127.0.0.1 / ::1 — same machine only

derive instance Eq Reachability
derive instance Eq Address
derive instance Ord Address          -- needed to live in a Set; derivable —
derive instance Eq BindScope         -- the record-carrying constructors have Ord
derive instance Ord BindScope        -- as long as BindScope + Port do, and they will.
```

No hand-rolled instances: `derive instance Ord Address` works because every
constructor argument (including the records and `BindScope`) is itself `Ord`,
and the atoms already derive `Ord`.

---

## 3. Strict generalization — the old → new mapping

Total one direction, lossy the other (which is the definition of "strictly more
expressive"):

| old `Exposure` | new `Reachability` |
|---|---|
| `HostPort p` | `{ Listening {AllIfaces \| HostIface _, p} }` |
| `InternalPort p` | `{ Listening {Internal, p} }` |
| `ProxyRoute r` | `{ Proxied r }` |
| `PublicDomain d` | `{ Published d }` |
| `UnixSocket a` | `{ Socket a }` |
| `NoNetwork` | `{}` (empty) |

Every old value maps to a new one; the reverse loses bind scope (gap 1) and
composition (gap 3) entirely. So `Exposure` is a *lossy projection* of
`Reachability` — strictly inferior, **provided** the refactor cost is acceptable
(that's what the experiment measures).

---

## 4. `Exposure` survives as a derived classification

It does not die — it becomes the projection, which is what keeps every existing
consumer compiling during migration (§7):

```purescript
classify :: Reachability -> Exposure
-- {}                              → NoNetwork
-- single Socket a                 → UnixSocket a
-- single Published d              → PublicDomain d
-- single Proxied r                → ProxyRoute r
-- single Listening {Internal|Loopback, p} → InternalPort p
-- single Listening {AllIfaces|HostIface _, p} → HostPort p
-- MULTIPLE                        → the most-exposed member (LOSSY — and the loss is the point)

-- the spine, for the viz colour-ramp AND security checks — derived, not stored
-- (derive-don't-store). Tune the exact ladder later.
data Openness = NoneOpen | LocalOnly | ClusterOnly | HostScoped | WideOpen | InternetWide
derive instance Eq Openness
derive instance Ord Openness

openness :: Address -> Openness
-- Socket _ , Listening {Loopback,_}        → LocalOnly
-- Listening {Internal,_}                   → ClusterOnly
-- Proxied _                                → HostScoped   (via the proxy)
-- Listening {HostIface _,_}                → HostScoped
-- Listening {AllIfaces,_}                  → WideOpen
-- Published _                              → InternetWide
```

`classify` being lossy on the multiple case is not a wart — it *is* the evidence
that the old type couldn't represent composition. A security check like "is
anything `WideOpen` that shouldn't be?" runs on `openness`, not `classify`.

---

## 5. MISU analysis — preserved / traded / gained

- **Preserved.** Illegal addresses stay unrepresentable: you cannot build a
  portless `Listening`, a schemeless `Published`, etc. The atoms keep their
  smart-constructor guarantees (`Port` 1..65535, `AbsPath` leading `/`).
- **Traded.** The old singular `Exposure` gave "exactly one way to be reached"
  *for free, by construction*. `Set Address` gives that up to gain real
  composition — so "two listeners on the same port" moves from unrepresentable
  to a **validate-time** check. This is the one genuine give-up. It's the right
  trade (composition is real, and that invariant was *also* forbidding the
  legitimate proxied-and-internal case), but name it explicitly.
- **Gained back.** `Set` dedups by construction, so "reached two *identical*
  ways" isn't representable — the part of the old invariant actually worth
  keeping, recovered for free. It also normalises serialization (order of
  ingestion can't perturb the round-trip form — friendly to the differential
  tests).

---

## 6. Spec ↔ viz convergence (why this is worth the churn)

The exposure badge (Pillar 3) is being built as a **Siglet** — one semantic
model, a family of scale-dependent renderings (cells / track / vertical stack /
concentric rings), chosen by zoom and available space. Its semantic model **is
`Address`.** The "NAME·HOST·PORT·PATH·SINK stack" the badge draws is just
`Address` projected onto a uniform display template (with cells bound /
wildcarded / absent). So the *same type* serves the IR constraint and the glyph's
render-AST — the convergence the design was probing for. Pipeline:
`Address → (zoom) → LayoutNode → HATS → SVG`. The richer the type, the more the
badge can honestly show (e.g. `AllIfaces` warm/loud, `Loopback` cool/quiet).

This is the standing reason to prefer the integrated type even if the migration
is a little of a slog: it makes the spec and the picture one thing.

---

## 7. How to run the experiment — add alongside, derive, migrate opportunistically

**Do not rip `Exposure` out.** Add `reachability` and derive `exposure`:

1. Add `Reachability`/`Address`/`BindScope` to a new module (or `Exposure.purs`).
2. On `ServiceInstance` (`core/src/Bosun/Service/Internal.purs`), add
   `reachability :: Reachability` *alongside* the existing `exposure :: Exposure`
   — or replace `exposure` with `reachability` and expose
   `exposure si = classify si.reachability` as a helper. Start with the
   additive form; it keeps the tree green.
3. Make the adapters produce `Reachability` (compose `0.0.0.0` vs `127.0.0.1`
   becomes expressible; `expose:` vs `ports:` distinguishes `Internal` from
   `HostScoped`).
4. Let everything downstream keep reading the derived `exposure` until you
   choose to migrate a consumer to the richer type.
5. Migrate consumers **opportunistically**, watching the §8 list. The thesis is
   confirmed if each consumer either passes through `classify` unchanged or gets
   *better*; it's challenged if one fundamentally needs the single value.

---

## 8. The watch-list — consumers of `Exposure`, with predictions

| Consumer | File | Prediction |
|---|---|---|
| **port-collision check** | `core/src/Bosun/Validate.purs` | **Gets better** — can become scope-aware: two services on `:9000` both bound `Loopback` don't actually collide; `AllIfaces` vs `Internal` matters. Positive evidence. |
| **reconcile facet model** | `core/src/Bosun/Reconcile.purs` | Watch: exposure is facet-local (DECISIONS E3) — confirm `Reachability` still partitions per facet (differs between facets, agrees within). |
| **compose adapter** | `adapters/src/Bosun/Adapters/Compose.purs` | Must emit `Reachability`; gains expressiveness (interface/scope, composition). Retires the InternalPort-vs-NoNetwork blind spot we hit. |
| **registry adapter** | `adapters/src/Bosun/Adapters/Registry.purs` | Maps host:port rows to `Listening {HostIface host, port}`. |
| **`exposureLabel` + the wire** | `core/src/Bosun/View.purs` (label currently via `Reconcile`) | The badge wants the full `Address`, so `AnalyzeResult` grows a `reachability` field (not just the string). |
| **serve admission** | `core/src/Bosun/Serve.purs` | Does it assume a single host port? `AllIfaces`/`Internal` may *sharpen* admission rather than break it. |
| **plan / apply** | `core/src/Bosun/Plan.purs`, CLI | Should be indifferent (they act on services, not exposure shape) — confirm. |

---

## 9. What would falsify "strictly inferior"

The proposal is *wrong to adopt* if any of these turn up:

- A consumer genuinely *depends* on exposure being a single value in a way
  `classify` can't paper over, and the richer type makes it materially worse.
- The migration ripples far beyond the watch-list (a sign exposure was load-
  bearing in places we didn't model).
- `Set Address` admits a nonsense composition that needs a new validation pass
  heavier than the expressiveness is worth (e.g. contradictory addresses).
- The added cardinality (composition) buys nothing real for any actual fixture /
  scenario — i.e. it's expressiveness nobody uses. (The proxied-and-internal
  hybrid and the `0.0.0.0`-vs-loopback distinction suggest otherwise, but the
  experiment should confirm with a real fixture.)

If none of these bite, the old sum is proven a lossy projection with no hidden
cost, and `Reachability` should land — with `Exposure` kept as `classify`.

---

## 11. Experiment result (2026-06-16, branch `address-type`)

**Verdict: LAND IT.** None of the §9 falsifiers bit. `Exposure` is proven a
lossy projection of `Reachability` with no hidden cost.

**What was done.** Went straight to the §7 *replace* end-state rather than the
additive scaffold — it is *less* total churn (no double-set at the ~30 fixture
construction sites) and a truer test. `Bosun.Reachability` is a new module
(types + smart constructors mirroring the old `Exposure` constructors +
`classify`/`openness`/`maxOpenness`). The stored field `exposure :: Exposure`
on the three service records became `reachability :: Reachability`; readers that
only need the old view call `classify s.reachability`. **`Bosun.Exposure` is
untouched** and remains `classify`'s codomain.

**Gates.** `spago build` 7 packages 0 warnings / 0 errors · `spago test` 90
passing (13 new in `ReachabilitySpec`) · frozen-corpus golden byte-identical (15
divergences + the macmini:80 collision) · **backend-go differential
byte-identical, node vs Go, 34 Go files** — i.e. `Set Address` and a *derived*
`Ord` over record-carrying constructors transpile and run cleanly through the
optimizer column.

**Watch-list outcomes (§8).**

| Consumer | Outcome |
|---|---|
| port-collision (`Validate`) | **GOT BETTER.** Now iterates the address *set*: every host-published listener (`AllIfaces`/`HostIface`) contributes a `(host,port)` claim, so a service's *second* published port is finally checkable — unrepresentable under singular `Exposure`. New test proves the gain and its control. `Internal`/`Loopback` don't contend (≡ old `InternalPort`, which never collided). |
| reconcile facet model | **PASS-THROUGH.** `withinFacetConflict` compares `exposureLabel (classify …)`; per-facet partitioning unchanged; golden identical. |
| compose adapter | **MIGRATED, better.** Emits `hostPort` = `AllIfaces` — the true `0.0.0.0` semantics of `ports:`. Composition now expressible. |
| registry adapter | **MIGRATED, better.** Emits `Listening (HostIface host)` per §8 — host-scoped, not all-interfaces. |
| `exposureLabel` + the wire (`View`) | **PASS-THROUGH.** Wire stays `exposure :: String` (via `classify`), so the Chair MVP *and* the Pillar-3 graph keep working untouched. The wire *could* grow a `reachability` field for the badge — deliberately left to the viz session (no codec/ frontend churn from this branch). |
| serve admission | **PASS-THROUGH.** `admit` reads `classify s.reachability`; behaviour identical. Could later sharpen (reject a loopback-bound port as unpublishable) — not needed yet. |
| plan / apply | **INDIFFERENT, confirmed.** They act on services, not exposure shape; backend-go conformance is byte-identical including the plan and the apply script. |
| observe (CLI) | **PASS-THROUGH.** `effectiveProbe` reads `classify`. |

**Resisters: none.** The migration stayed inside the watch-list plus mechanical
fixture renames (`exposure = HostPort p` → `reachability = hostPort p`, etc.).

**One honest wrinkle (a §10.1 follow-up, not a blocker).** The collision check
treats `Loopback`/`Internal` binds as non-contending — which *preserves* the old
`InternalPort` behaviour but is technically imprecise: two processes binding
`127.0.0.1:9000` on the *same* host do collide in reality, and a `0.0.0.0:p`
listener subsumes a `127.0.0.1:p` one. The richer type now makes this
*fixable* (the scope is finally visible); it was deliberately left unchanged to
keep the experiment scoped. A future `bind-scope-overlap` refinement could close
it. The §8 example's "two loopback services don't collide" is, strictly, this
same imprecision rather than a clean win — the clean win is composition.

---

## 10. Open questions

1. **`BindScope` grain.** Is `AllIfaces / HostIface / Internal / Loopback` the
   right closed set, or should `Internal` be graded further (cluster vs
   same-LAN)? Kept to four to stay on the right side of the recompile test.
2. **Naming.** `Reachability` (field) / `Address` (element) / `BindScope`.
   "Address" honours the framing that started this; swap if another reads truer.
3. **Additive vs replace.** Start additive (`reachability` + derived `exposure`)
   for a green tree; decide whether to drop the stored `Exposure` field once the
   migration settles.

---

## Appendix — current `Exposure`, for reference

```purescript
-- core/src/Bosun/Exposure.purs
data Exposure
  = HostPort     Port                                      -- published to host (3000:3000)
  | InternalPort Port                                      -- network-internal; siblings reach it
  | ProxyRoute   { proxy :: ServiceId, path :: RoutePath } -- behind edge/ingress
  | PublicDomain Domain                                    -- CDN / ingress host
  | UnixSocket   AbsPath                                   -- ~/.es9/control.sock
  | NoNetwork                                              -- worker / one-shot
```
