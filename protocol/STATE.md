# `/state`: what Bosun's residents say

Every resident answers `GET /state` with one JSON document. There are two
documents, because there are two kinds of resident:

| Resident | Document | Described in | Printed through it |
|---|---|---|---|
| `bosun supervise` | the group document | `src/Bosun/Protocol/State.purs` | yes, on node and the BEAM |
| `bosun docker` | the group document, reader's form | the same module (`Group`) | yes |
| `bosun serve` | the router document | `src/Bosun/Protocol/ServeState.purs` | no: the router is JavaScript and builds it there |

Both descriptions are written with Hawser, and the tables below are
generated from them. The Chair reads both documents through them.

A group and a router are not one shape, and are not meant to be. A group
has services it keeps up; a router has routes it may never have bound,
services it refused, and registry rows it has not seen. What they share is
the rules below.

`bosun supervise` promises more than a reader may count on from every group
resident: `docker` watches containers it does not keep alive, so it has no
phase and no times. The first set of tables is what `supervise` writes. The
tables under "The group document, for a reader" are what any group resident
writes, with the fields only one of them knows marked optional.

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
| `services` | table of string | each service's status: `running`, `starting`, `in-backoff` (it will be tried again), `failed` (it will not, when its row says `gaveUp`), `down`, `completed-ok` or `unknown` |
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
| `verdict` | string | `reaped`, `killed`, `already-gone`, `no-record`, `survived`, `refused` or `unreadable` |
| `settled` | true or false | true when the verdict establishes that the service is down: `reaped`, `killed` or `already-gone` |
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

## The group document, for a reader

What a reader may count on from any resident that answers for a group: `bosun supervise`, whose document is the one above, and `bosun docker`. A field that only one of them knows is optional here.

### The group

A group, as any resident that answers for one says it.

| Field | Holds | Meaning |
|---|---|---|
| `desired` | string | `up` or `down` |
| `phase` | string, optional | the lifecycle phase. From `supervise` only |
| `supervised` | true or false | true when this resident relaunches what fails: `supervise`. False from `docker` |
| `services` | table of string | each service's status |
| `supervision` | table of progress row | each service's progress row |
| `teardown` | table of teardown row, optional | what the last `down` found, per service. From `supervise` only |
| `holders` | table of holder row, optional | who holds each service's TCP port. From `supervise` only |
| `selfHeals` | true or false, optional | true when something other than this resident relaunches what fails. From `docker` only |
| `keepAliveOwner` | string, optional | what that something is, such as `docker` |

### The progress row

One service's row, as any group resident says it.

| Field | Holds | Meaning |
|---|---|---|
| `restarts` | whole number | how many times it has been relaunched. Zero from `docker`, which does not count |
| `fails` | whole number | failures in a row. Zero from `docker` |
| `lastTransitionAt` | time in ms, optional | when its status last changed |
| `suspendedUntil` | time in ms, optional | while backing off, when the next try is due |
| `retryCap` | whole number, optional | the most failures in a row before the supervisor stops trying |
| `gaveUp` | true or false, optional | true when the supervisor has stopped trying |
| `health` | string, optional | Docker's verdict on the container's own health check. From `docker` only |
| `keepAliveOwner` | string, optional | what relaunches this service, when it is not this resident |

<!-- end generated -->

## The router document

`bosun serve` on :3997. A time here is ISO 8601 text, not milliseconds: the
router has always written it so, and its readers show it as written.

<!-- generated router: scripts/state-doc.sh -->

### The router state

The router, as it finds itself now.

| Field | Holds | Meaning |
|---|---|---|
| `routes` | array of route | the lazy-spawn routes |
| `redirects` | array of redirect | ports answered with a redirect to another host |
| `rejected` | array of refusal | services the router saw and cannot use |
| `brokered` | array of brokered service, optional | services the router locates and does not carry |
| `drift` | array of drift entry, optional | ports where the registry on disk and the router's plan disagree. Empty means none; when `registry.error` is set it is the last answer, not a current one |
| `stale` | true or false, optional | true when `drift` is not empty |
| `registry` | registry, optional | where the plan came from |

### The route

One lazy-spawn route.

| Field | Holds | Meaning |
|---|---|---|
| `serviceId` | string | the service, as the registry names it |
| `publicPort` | whole number | the registered port, which the router listens on |
| `internalPort` | whole number | the port the backend is launched on |
| `up` | true or false | true when something is serving this route: a backend the router started, one it relays to, or an outside process holding the public port |
| `pid` | whole number, optional | the backend's process, when the router started it |
| `external` | true or false, optional | true when a process the router did not start holds the public port itself |
| `externalCheckedAt` | string, optional | when that was last probed |
| `adoptedBackend` | true or false, optional | true when the router relays to a backend it did not start, so there is no `pid` and no idle stop |
| `adoptedBackendAt` | string, optional | when that was last probed |
| `bound` | true or false, optional | true when the router holds the public port. False and not `external` means nothing is listening, so no request can arrive |
| `bindError` | string, optional | why the router could not bind the port |

### The brokered service

A service the router locates and does not carry.

| Field | Holds | Meaning |
|---|---|---|
| `serviceId` | string | the service |
| `publicPort` | whole number, optional | its registered port. Often absent, which is normal: a socket or a UDP service has none |
| `at` | string, optional | where it is, once running |
| `url` | string, optional | the same as a URL, when it has one |
| `transport` | string, optional | how it is reached, such as `http` or `unix` |
| `probe` | string, optional | which readiness check the plan chose. `none` means nothing was checked, not that a check failed |
| `pid` | whole number, optional | its process, when the router started it |
| `bound` | true or false, optional | true when the router holds the registered port to answer with a redirect |
| `bindError` | string, optional | why the router could not bind that port |
| `door` | string, optional | the standing of that listener: `none`, `open`, `aside`, `reclaim` or `blocked` |
| `doorCheckedAt` | string, optional | when that was last probed |

### The redirect

A port answered with a redirect to another host.

| Field | Holds | Meaning |
|---|---|---|
| `serviceId` | string | the service |
| `publicPort` | whole number | the port that redirects |
| `host` | string | the host the service runs on |
| `target` | string | where the redirect sends a request |

### The refusal

A service the router saw and cannot use.

| Field | Holds | Meaning |
|---|---|---|
| `serviceId` | string | the service |
| `publicPort` | whole number, optional | the port it asked for |
| `reason` | string | why, as a sentence |

### The drift entry

A port where the registry on disk and the router's plan disagree.

| Field | Holds | Meaning |
|---|---|---|
| `serviceId` | string | the service |
| `publicPort` | whole number | the port |
| `kind` | string | `unrouted`, `altered` or `departed` |
| `note` | string | the disagreement, as a sentence |

### The registry

Where the router's plan came from, and when.

| Field | Holds | Meaning |
|---|---|---|
| `source` | string | the registry file |
| `plannedAt` | string, optional | when the router last planned from it |
| `modifiedAt` | string, optional | when the file last changed |
| `error` | string, optional | why the drift check could not be made. When set, `drift` and `stale` are not current |

<!-- end generated router -->

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

The reading side is held by `test/test/Test/Bosun/StateSpec.purs`, run by
`npm test`:

- every document `supervise` has answered reads as a group document, and
  says the same thing either way;
- what `docker` prints reads as a group document, and is refused as a
  `supervise` one (it has no phase);
- the document the running router answered on 2026-11-17
  (`vectors/serve-state/live-mbp-serve-node.json`) reads as a router
  document, as does one with every optional part filled in and a field from
  a newer router; a port written as text and a missing table are refused.

Not held: that the router goes on writing what the description says. It is
checked against one captured document, not against the JavaScript that
builds it. That closes when the router is written in PureScript and prints
through the description.

**No Go column.** Bosun had one until 2026-11-17. Go was demoted as a runtime
on 2026-11-16 (Andrew: where Go was meant, use the BEAM or Rust), and the
column, its scripts and its `.go` twins were removed the next day.

## Who reads it, and how each is held

| Reader | Held by |
|---|---|
| Bosun's Chair (`chair/src/Chair/State.purs`) | reads both documents through the descriptions (`readGroup`, `readServeState`) |
| Brunel's Chair (`minard-for-nix/src/Chair/State.purs`) | the same |
| Triggerfish's Dashboard (`Triggerfish/Bosun.purs`) | reads the supervise document through the description (`readState`), since 2026-11-17 |
| `scripts/menagerie-conf.sh` | greps the text; relies on the fixed spacing |
