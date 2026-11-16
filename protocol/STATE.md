# `/state`: what a group supervisor says

`bosun supervise` answers `GET /state` with one JSON document: the group's
lifecycle phase, each service's status, and what the supervisor has done
about each. The Chair, Triggerfish's Dashboard and shell scripts read it.

The description is `src/Bosun/Protocol/State.purs`, written with Hawser.
The daemon prints through it on node and on the BEAM, and a PureScript
reader reads through it. The tables below are generated from it.

Two other residents answer `/state` with documents of their own, and
neither is described here: `bosun serve` (routes, redirects, refusals) and
`bosun docker` (`desired`, `services`, and a shorter supervision row, with
`supervised: false`). One shape for every level is step 2 of
`docs/kb/plans/conformance-and-subsidiarity.md`, and is not done.

## Rules for both ends

- **A reader ignores what it does not know.** Supervisors on different
  machines are updated at different times, and one Chair reads them all. A
  field or a status word added later must not break a reader built before
  it. So a writer may add a field; it may not remove one or change what one
  holds.
- **A time is a whole number of milliseconds since 1970.** Until
  2026-11-16 node wrote `1794690259979.0` and the BEAM
  `1.79469025997900000000e+12`. Both now write `1794690259979`.
- **The spacing is fixed:** `{ "desired": "up", ... }`, as the hand-built
  document had it, because scripts grep it.
- **A table is keyed by service id.** `services` and `supervision` have the
  same keys. After a `down` both are empty until the next tick.

## The document

<!-- generated: scripts/state-doc.sh -->

### The state

The group, as its supervisor sees it now.

| Field | Holds | Meaning |
|---|---|---|
| `desired` | string | `up` or `down`: whether the supervisor is keeping the group up. Follows from `phase` |
| `phase` | string | the state of the group's lifecycle machine (`machines/supervise-group.json`), such as `raised` or `held` |
| `supervised` | true or false | always true: this is a supervisor, not `bosun serve` |
| `services` | table of string | each service's status: `running`, `starting`, `in-backoff`, `failed`, `down`, `completed-ok` or `unknown` |
| `supervision` | table of supervision row | each service's supervision row |
| `teardown` | table of teardown row, optional | what the last `down` found, per service. Left out when there is nothing to say |
| `holders` | table of holder row, optional | who holds each service's TCP port. Services with no port are left out, and so is the field when none has one |

### The supervision row

What the supervisor has done about one service.

| Field | Holds | Meaning |
|---|---|---|
| `restarts` | whole number | how many times it has been relaunched |
| `fails` | whole number | failures in a row since it last ran well |
| `lastTransitionAt` | time in ms | when its status last changed |
| `suspendedUntil` | time in ms or null | while backing off, when the next try is due |
| `retryCap` | whole number or null | the most failures in a row before the supervisor stops trying, where the service sets one |
| `gaveUp` | true or false | true when `fails` has reached `retryCap`: nothing more happens until someone restarts it |

### The teardown row

What the last `down` established about one service.

| Field | Holds | Meaning |
|---|---|---|
| `verdict` | string | `reaped`, `already-gone`, `no-record`, `survived`, `refused` or `unreadable` |
| `settled` | true or false | true when the verdict establishes that the service is down |
| `at` | time in ms | when it was judged |

### The holder row

Whose process is listening on one service's port.

| Field | Holds | Meaning |
|---|---|---|
| `verdict` | string | `ours`, `stranger`, `none` or `unobservable` |
| `claimable` | true or false, optional | for a stranger: true when it runs from the service's own directory, so a restart may replace it |
| `pids` | array of whole number, optional | the processes listening |
| `ours` | array of whole number, optional | for a stranger: listeners this supervisor did start, beside it |
| `detail` | string, optional | who the stranger is, or why the port could not be read |

<!-- end generated -->

## How it is held

`beam/conformance.sh` reads and prints every document in `vectors/state/`
through the description, on node and on the BEAM:

- the two runtimes give the same bytes;
- a document the daemon wrote comes back unchanged. Five of the vectors are
  the answers of the five supervisors running on 2026-11-16 (three on the
  BEAM, two on node), with their times rewritten as whole numbers;
- `from-a-newer-supervisor` has fields this description has not heard of,
  and is read with them dropped;
- the `refused-*` documents are not read at all.

`scripts/state-doc.sh --check` fails when the tables above are stale.

**Not held on Go, by decision.** The Gnomon build of Bosun stops at this
module: Hawser's byte functions have JavaScript and Erlang twins and no Go
one (found by `scripts/menagerie-conf.sh`). Go was demoted as a runtime the
same day (Andrew, 2026-11-16: where Go was meant, use the BEAM or Rust), so
no Go twin will be written. Bosun's Go column, its scripts and its `.go`
twins are still in the repository and are due to be removed.

## Who reads it, and how each is held

| Reader | Held by |
|---|---|
| Brunel's Chair (`minard-for-nix/src/Chair/State.purs`) | not yet: its own argonaut decoder, reading `desired`, `services`, `restarts`, `holders` |
| Triggerfish's Dashboard (`Triggerfish/Bosun.js`) | not held: hand-written JavaScript, reading `desired`, `phase`, `services`, `restarts`, `gaveUp`, `lastTransitionAt` |
| `scripts/menagerie-conf.sh` | greps the text; relies on the fixed spacing |
