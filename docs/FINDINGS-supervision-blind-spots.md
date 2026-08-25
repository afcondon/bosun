# Three ways supervision reported health it did not have

Found 2026-08-18 while bringing the Atlantis rig up by the book. All three are
the same defect in different clothes: **the signal the supervisor publishes is
not measuring the thing that matters**, and the failure therefore presents as
silence rather than as an error.

Recorded here rather than fixed on the spot because each wants a decision, and
because the evidence — process ages, PPIDs, counters — is only readable while
the processes are alive.

## 1. A service failed 4133 times and looked ordinary

`bosun supervise` on the Atlantis group reported `link-spike: in-backoff` with
`restarts: 4133, fails: 4133`. At the 60 s backoff cap that is roughly **65
hours** of continuous failure, presented identically to a service that had
restarted once a moment ago. es9-daemon showed 4140/1626, fh2-daemon likewise.

**Root cause of the invisibility is a last-hop discard.** The daemon emits both
counters and `/state` carries both — verified live. But
`chair/src/Chair/State.purs:119` decodes:

```purescript
type SupervisionRow = { restarts :: Int }
```

with a comment saying `fails` is dropped on purpose, to be widened "when the
sparkline work lands". So the Chair renders `↻ 4133` from `restarts`, which is
cumulative-since-forever and reads as *busy*; the number that resets on health
and therefore means *broken right now* is thrown away at the last hop.

**Fix:** widen `SupervisionRow` with `fails :: Maybe Int` (Maybe for pre-D-S1
daemons), thread through `Main.purs:1046` `rowEntry` → `Graph.purs:617`
`autoRestart`, and render it distinctly from `restarts`.

**Recommend NOT lengthening the backoff.** The retries cost nothing measurable,
and a longer window directly slows the legitimate case — you plug the ES-9 back
in and want it up now, not in ten minutes. The defect was 65 hours of silence,
not the frequency.

### 1a. `decide` returns one value to two audiences

`core/src/Bosun/Supervisor.purs:176` reports an *exhausted* service — one that
has hit `maxRetries` and will never be retried — as `InBackoff`, because the
planner must `NoOp` a suspended service and `decide` returns a single `Status`
serving both the planner and the operator badge. "Given up permanently" and
"waiting five seconds" are deliberately made indistinguishable.

Splitting the planner's signal from the operator's badge is the deeper fix, and
would make 1 above easy rather than a widening exercise.

## 2. `probe: process` is satisfied by a ghost

Three rig daemons — link-spike, es9-daemon, continuo — were running with **PPID
1**: orphans reparented to launchd when an earlier supervisor exited. The
current supervisor could not start its own copies because the orphans held the
ports, which is what produced the 4133. Killing each orphan let supervision take
ownership immediately (link-spike came up within one backoff window, es9-daemon
within 55 s).

continuo had **two** identical orphans, aged 7d12h and 2d21h, ~41 MB and ~44 MB.

**The probe cannot tell the difference.** `probe: process` asks whether a
matching process exists, not whether it is *ours*, so a supervisor can report
`running` for a process it did not start and does not control — supervising in
name while merely observing.

**Fix directions:** record the pids `supervise` starts and reap strays at boot;
make `probe: process` require ownership rather than existence; or detect "the
exposed port is held by a pid I did not start", which is the specific condition
that occurred and would turn "failed 4133 times" into "port 57122 held by pid N,
which I did not start".

## 3. A parent process is not the service

`superdirt` also uses `probe: process`, matching `sclang`. A stray sclang
instance took the BlackHole device and the **live scsynth died**, leaving sclang
alive with no audio server. Bosun reported `superdirt: running, fails: 0`
throughout. The rig made no sound and supervision saw nothing wrong.

`audio/boot-superdirt.sh` already locates the child (`pgrep -P "$SC_PID" -x
scsynth`), so a child-existence probe is available without new machinery.

## Not a bug

Two SuperCollider processes in normal operation are `sclang` + `scsynth`, which
is how it runs; `fleet.json`'s es9-daemon row already documents 57120 as
"SuperDirt's sclang+scsynth". Do not chase that one.

---

# Two more, from putting a performance rig through it (2026-08-19)

Found while moving `producing-with-your-feet` further into Atlantis. Same
character as the three above: the signal is fine, what it *measures* is not
quite the thing that matters.

## 4. `serve` and `supervise` disagree about how to name a service

The router's control verbs take a **public port**; a supervise group's take a
**service name**. So the natural first move on a misbehaving daemon —

```
POST :3994/control/restart?service=itajara
```

— answers `no service `itajara` in this group`. Which is true, and reads as
"that daemon is not running". It is running; it is simply lazy-spawned by
`serve` and therefore in no group at all. The router's own
`stop|spawn?port=3028` is the answer, and `?service=<id>` there is rejected in
turn with `no proxy route on :0` even though `/state` prints that very id.

Two addressing schemes and two rejection messages, neither of which says "you
are asking the wrong component". Cheap fix: have each refusal name the other —
*"not in this group; :3028 is served by the router, try `:3997/control`"*.

**FIXED, 2026-08-24.** The router's side accepts `?service=<id>` (it had to:
broker mode created daemons with no port to address) and its 404 names what it
found — nothing at all, versus brokered, versus a 421 redirect to another host —
instead of saying `no proxy route` to every one of them.

The group's side is `Bosun.Supervisor.addressService` +
`Bosun.Report.renderAddressMiss`, shared by `supervise` and `docker` because
both had the same one-sentence refusal. It splits **four** mistakes that were
sharing it — the fourth and fifth were nobody's suspicion until the ADT made
them ask:

| asked | verdict | the refusal says |
|---|---|---|
| `?service=8790` | `LooksLikePort` | it is a port, this group has none to match it against, and `POST :3997/control/stop?port=8790` is the command wanted |
| `?service=` (missing) | `Unnamed` | nothing was named; ids come from `GET /state` |
| `?service=ticker:worker` on a group holding `ticker` | `NearMiss` | the id it does hold, and that this surface will not guess |
| `?service=polyglot` on a group holding `polyglot:api` + `polyglot:site` | `Ambiguous` | both candidates, and that a control verb does not pick |
| `?service=itajara` | `NotInGroup` | not here under any spelling, **and** that lazy-spawned services live in no group — go to the router |

A `NearMiss` is reported, never acted on: restarting `itajara:worker` because
someone typed `itajara` would be a control surface signalling something other
than what it was asked for, which is the habit these refusals exist to prevent.

What the group deliberately does NOT do is ask the router whether it holds the
name. A synchronous HTTP call to another daemon on a refusal path buys a
maybe-answer for a new failure mode (the router being down makes this refusal
slow, or fail), and the router's own half is symmetrically local. The remedy is
structural instead — name the other addressing scheme and where it lives, which
is true whether or not the router happens to hold this particular id.

## 5. A performance daemon should not be lazy-spawned

Itajara sat in `serve` because that is where a dev service goes. But
lazy-spawn has no keep-alive: if it dies during a set, nothing restarts it and
**the first symptom is silence**. For a rig that is played rather than
developed against, that is the wrong default, and no amount of probing fixes it
— the probe is not the problem, the absence of a supervisor is.

`supervise --held` is the shape that fits: resident, restarted when it crashes,
and booted *down* so it is raised deliberately. The `--held` part matters more
here than elsewhere, because **Itajara holds the Audio4c exclusively**. Which
raises the question this rig will keep asking:

**A probe cannot currently distinguish "running" from "running and holding the
converter".** A daemon that lost its device stays `running` and makes no sound —
the exact case `audioAlive` was added to Itajara's own snapshot for, after it
cost an afternoon. Supervision has no equivalent. An exclusive-device service
wants a readiness check that asks the service whether it has the thing, not
whether it has a pid.

That generalises past this rig: es9-daemon, continuo and SuperDirt all hold
audio devices, and all three would report `running` after losing one.
