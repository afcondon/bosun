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
