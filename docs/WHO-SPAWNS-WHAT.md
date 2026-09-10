# Who spawns what

**Status:** adopted 2026-09-10. Supersedes the informal split ("Bosun does
lazy-spawn, DeepStar does the rig"), which was drawn by TOOL and is here
redrawn by PROPERTY.

---

## 1. The question

Two things on this machine start long-running processes:

- **Bosun** — `bosun serve` (a lazy-spawn router) and `bosun supervise` (a
  keep-alive daemon, one per group).
- **DeepStar** — `deepstar up/down/restart`, the rig launcher it kept after
  supervision was ceded to Bosun in 2026-07.

The working assumption was that Bosun owns the web-app tier and DeepStar owns
the rig, on the grounds that Atlantis is a constellation you would not always
run in full, and that a released Atlantis must be startable by someone who has
none of our infrastructure.

The instinct about release is right and is kept below. The split itself was
wrong, because **it is drawn where no process can see it.** Nothing in a
compose file, a registry row or a probe encodes "this one is Bosun's". So the
line was not enforced anywhere, and both tools reached for the same daemons.

## 2. What that cost, measured

Read off the live Atlantis group on 2026-09-10, after seven days resident:

| service | restarts | fails | state |
|---|---|---|---|
| fh2-daemon | **2,912** | 2,587 | in-backoff |
| es9-daemon | **1,335** | 1,335 | in-backoff |
| the other ten | 0–11 | 0 | running |

Two distinct faults, one shared cause.

**fh2-daemon: hardware absence retried for ever.** The FH-2 was switched off.
`run-daemon.mjs` prints `✗ FH-2 MIDI port not found` and exits — with status
**zero**, which is worth dwelling on: no exit-code-based restart policy in the
world would have caught this. Bosun had no vocabulary for a bounded retry
anyway; the compose adapter hardcoded retry-forever for every service and never
read a restart key at all. Meanwhile `fh2-drumkit`, which depends on it, showed
**running** — it is a `RemainAfterExit`-style `exec sleep`, so it reported a
green light over a SysEx config applied to a module that was not there.

**es9-daemon: a supervisor fighting a healthy daemon.** The real one had held
`udp:57130` on pid 1596 for eight hours. Bosun could not see it, because
`probe: process` means *"is the process group **I** recorded alive"*. So it read
Down, spawned a copy, the copy lost the bind and died, every tick. Separately,
`bosun serve` had **rejected** that service's registry row, and a hand-start had
put it there in the first place: three claimants, no owner.

And the two faults compound. On 2026-08-31 the MBP was unplugged from the ES-9
overnight; es9/fh2/link failed for ten hours, `fails` reached ~8,200, and the
backoff exponent overflowed the stack. The tick then never completed, group
state never converged, and every reconcile relaunched all eleven services:
**6,309 SuperCollider boots and ~1 GB of orphaned scsynth.** That is where the
SuperDirt "flapping" came from. It was never a SuperDirt bug.

`deepstar verify` describes the same estate from the other side, and its verdict
is the diagnosis in one word — es9-daemon, link-spike, purerl-tidal and both
calypso halves all reported as `unknown_sibling`:

```
⚠ es9-daemon  unknown_sibling: pid=1596 bound to udp:57130 outside state.json
```

**Each tool regards the other's children as strays.**

## 3. The property that actually divides them

Not "app versus rig", and not "lazy versus eager". It is:

> **Does the service hold an exclusive claim on hardware?**

Everything follows.

### Tier 1 — Software. Bosun supervises, restart `unless-stopped`.

`calypso-server`, `calypso-frontend`, `amphora`, `triggerfish-frontend`,
`friends-of-itajara`, `deepstar serve`. Nothing exclusive; a restart is always
the right answer to a crash. Zero restarts in seven days. This tier was never
the problem and needed no change.

Note **why** it was never the problem: these are TCP services, and a TCP probe
is adoption-capable by construction — it asks "is something listening", never
"did I start it". That is not luck, it is the whole distinction, and it is why
the fix for tier 2 is the one below rather than more supervision.

### Tier 2 — Instruments. One owner, a probe that sees reality, a bounded retry.

`es9-daemon`, `link-spike`, `fh2-daemon`, `superdirt`, `continuo`, and
`itajara`. Each opens a CoreAudio device, a CoreMIDI port, a USB SysEx link or a
UDP socket that admits exactly one holder. Three rules:

1. **Probe the endpoint, never the process group.** `x-bosun.probe: exec` with
   an `x-bosun.check` that tests the address declared a few lines below it. A
   check that names its own service's port cannot drift; a check naming another
   file's service id can.
2. **Bound the retries.** Hardware absence is a *state to report*, not a failure
   to retry. 10 tries 30 s apart for the audio daemons, 5 for the two whose
   modules are routinely powered off.
3. **Giving up must be visible and reversible.** `/state` carries `retryCap` and
   `gaveUp`, because `in-backoff` otherwise covers both "wait, it is coming
   back" and "it has stopped trying". `POST /control/restart?service=…` clears
   the fail count and hands back the full budget — the operator pressing it is
   asserting the cause is fixed.

`superdirt` is the sharpest case and was mis-probed in *both* directions.
sclang binds `:57120` and runs in **its own process group** — deliberately;
that is how `boot-superdirt.sh` drains it — so the process probe was reading the
bash *wrapper*. sclang segfaults rather than draining when memory is tight, and
a segfaulted sclang under a live wrapper read as **Running over complete
silence**. `lsof -t -iUDP:57120` reads the thing that actually receives
`/dirt/play`.

### Tier 3 — On demand. The `bosun serve` broker.

`itajara`, summoned by a page opening. Right in concept. Its bookkeeping is not
yet right — see §6.

## 4. So what is DeepStar for?

Three things, none of them "a second supervisor".

**The adjudicator.** `deepstar claims <service>` answers the one question
neither tool can answer alone — *is this endpoint held, by anybody?* — in its
exit code (`0` held, `1` free, `3` no such service). Endpoint occupancy does not
care who the parent was. Endpoint-bind rather than argv matching, because exec
chains (`erl→beam.smp`, `spago→node`, `npx→npm exec`) mutate the cmdline out
from under any string match.

**The metrologist.** `verify`, `doctor`, `tune`, `sweep`, `latency`, and
`deepstar serve` on `:3027` — now an Atlantis member, because Quadrat's pitch
calibration calls it. Its rig lock ("a control voltage is a physical resource")
is the tier-2 idea already implemented in the right place.

**The zero-infrastructure launcher.** `deepstar up` needs nothing but the
binary and a `services.toml`. This is the answer to the release question: a
stranger cloning Atlantis has no Marginalia, no `fleet.json`, and no NATO
callsigns like `alpha-victor-echo-kilo:worker`. They need a launcher that ships
in the box, and DeepStar is it.

Worth recording that **DeepStar already had the pre-flight Bosun lacked**: `up`
refuses to spawn onto an occupied port — *"port %s bound by foreign pid %d;
refusing to adopt"* (SPEC §3.3/§11, no adoption-by-port in v2, written after v1
adopted `loginwindow` twice). The launcher without that check is the one that
ran up 4,247 failed spawns.

So the rule is not "Bosun for apps, DeepStar for the rig". It is:

> **Bosun schedules. DeepStar adjudicates and measures. `deepstar up` is the
> fallback launcher for an Atlantis with no Bosun in the house.**

## 5. A reservation is not a violation

Related, and the same failure of reporting. `bosun serve` listed 16 rows as not
routable; **thirteen were deliberate** — a NULL `startCommand` is the documented
convention for "another launcher owns this; reserve the port but do not bind
it". They were reported as SDI contract violations, which also misdescribes a
row that has no start command at all.

Deliberate states must not be filed under the same heading as mistakes. They now
read `Reserved`, and the three genuine violations that were hidden behind them
are visible: `minard:api` :3000, `psd3-arid-keystone:api` :3010,
`shavian:api` :3300.

## 6. Known-open

- **`itajara` runs three times.** `bosun serve` brokered pid 74644; pid 74638
  holds `:23028`; a third hand-start (80313) bound nothing and ran blind. The
  broker's pid bookkeeping is wrong for a process it launched itself, and the
  broker path has no claim pre-flight. Tier-2 rules should apply to it.
- **Two service inventories.** `fixtures/atlantis/compose.yml` has thirteen
  services; `~/.deepstar/services.toml` has six, is untracked personal config,
  and dates from 2026-05. For the release story DeepStar's inventory must cover
  the constellation. The compose file is the better source of truth (it is the
  lingua franca and the maintained one); generating the TOML from it would end
  the drift.
- **Exit status is not observed.** `OnFailure` and `Always` resolve identically,
  because the observation edge reads a process group's existence, not an exit
  code. Documented rather than pretended. It would not have helped the case that
  prompted all this — fh2-daemon exits 0 — but a service that exits non-zero
  deserves to be told apart from one that finished.
- **`fh2-daemon` should exit non-zero** when the FH-2 is absent. One line, in
  `fh2-config`.
- **The three real SDI violations** in §5, each in an unrelated project.
