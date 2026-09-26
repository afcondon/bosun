# A restart that answered `ok` and restarted nothing

Found 2026-09-25 on the Atlantis group (`bosun supervise`, control on :3994),
while shipping a server change to `friends-of-itajara` (:3029). Written up for
whoever fixes it, with the evidence, a way to reproduce it, and what "fixed"
should mean. Same family as `FINDINGS-supervision-blind-spots.md`: **the
signal the supervisor publishes is not measuring the thing that matters**, so
the failure shows up as silence rather than as an error.

## What happened

1. Changed `friends-of-itajara/server.mjs`, then ran
   `POST :3994/control/restart?service=friends-of-itajara`. The answer was
   `{"ok":true,"message":"restart: raised — restart: friends-of-itajara"}`.
2. `/state` then showed `friends-of-itajara: running`, with supervision
   `{restarts: 7, fails: 0, gaveUp: false}`.
3. The server kept behaving like the old code. A new route returned
   `{"error":"no such route"}`. A second restart gave the same `ok` and
   nothing changed.
4. The process holding :3029 was:

   ```
   PID 94743  STARTED Sun Sep 20 11:34:15 2026  node server.mjs
   cwd /Users/afc/work/afc-work/music/friends-of-itajara
   ```

   It had been running for **five days**, across at least two "restarts" that
   day. Nothing had replaced it.
5. `kill 94743`. Within about a second Bosun spawned its registered command
   (PID 77054, `STARTED Fri Sep 25 18:55:32`), and the new code answered. A
   later restart of *that* process worked normally.

**What it cost:** an earlier change the same day (Quadrat writing a take's
tempo when it is kept) had been "restarted" into service and was never live.
Nothing indicated that. It was found only because a brand-new route 404'd,
which a behaviour change inside an existing route would not have done.

## Why, as far as I could tell without reading the supervisor

The process on :3029 was an **orphan**: started outside this supervise
instance (by hand, or by an earlier incarnation of the group), so Bosun had
no child handle on it. This has been seen before on this group:

- **2026-09-08:** processes hand-started in one batch read `running` with
  teardown verdict `no-record`. `/control/down` returned `ok:true` and killed
  nothing.
- **2026-09-22:** `/control/down` and `/control/restart` were re-confirmed to
  do nothing to orphans.

The likely mechanism: restart acts on the child Bosun owns. Having none, it
kills nothing. Its spawn then finds the port busy (or the endpoint probe finds
it answering) and settles as "running". The `ok` means "request accepted and
desired state set", not "the process was replaced", but the caller can't tell
those apart. The `restarts` counter also looks like health.

The probe cannot see the difference. `running` means "something answers on
the port", and the stale process answers perfectly.

## How to reproduce

1. Start the service by hand from its registered cwd and command, so it binds
   the port before the group owns it (or leave one running across a
   supervisor restart).
2. `POST /control/restart?service=<id>`.
3. Compare `ps -o pid=,lstart= -p $(lsof -t -iTCP:<port> -sTCP:LISTEN)` before
   and after. Same pid, same start time, and an `ok` answer: that's the bug.

## What "fixed" should mean (the fixer's call how)

The requirement is only that **the answer tells the truth about what
happened to the process**. Some shapes it could take:

- The restart response reports the **pid and start time before and after**,
  and says plainly when they are the same: "nothing restarted: the process
  on :3029 (pid 94743, since 09-20) is not mine".
- `/state` separates **owned** from **observed**. A service answering on its
  port with no child handle is `orphan`, not `running`, as the `no-record`
  teardown verdict already hints.
- An explicit way to **adopt or replace an orphan**. It should be safe only
  when the port holder's command and cwd match the registered ones (they did
  here), because killing whatever holds a port is exactly the wrong reflex in
  general.
- `ok:false` (or a distinct status) when a restart provably changed nothing.

Acceptance, in the terms this failure was found in:

1. With an orphan on the port, `restart` must not return a bare `ok`. The
   answer must say the process was not replaced, or actually replace it.
2. After a restart that reports success, the pid on the port must be new and
   started after the request.
3. `/state` must not show an orphan the same way as an owned, healthy
   process.

## Workaround in use until then

After any restart, check the port holder's start time. If it is older than
the restart, kill that pid by hand; Bosun then spawns the registered command,
and that one responds to later restarts.

---

# Resolution (2026-09-25, branch `restart-truth`)

## What changed

**`Bosun.Holding`** (core, pure; lowers to Go) answers *whose process is on the
port*. One evidence script collects every TCP listener on the services' ports,
in both address families. For each listener it gets the pid, process group,
start time, command and working directory, plus each service's recorded pgid
and the **physical** form of its registered directory. `judgeHolding` then
returns one of:

- `ours`: every listener is in the group this supervisor recorded
- `stranger`: something this group did not start holds the port, with our own
  listeners (if any) kept beside it, which covers the IPv4/IPv6 split bind
- `none`, `no-port`, or `unobservable` (a remote host, or `lsof` did not
  complete; never read as `none`)

A stranger is **claimable** only if it runs from the service's own registered
directory, compared physically, since `lsof` reports `/private/tmp/x` for a
`/tmp/x` launch.

**`/state`** gains an additive `holders` map. `services` keeps its words, so
every existing decoder is unaffected (criterion 3).

**`restart`** reads the holding just before the machine decides:

- a **claimable stranger** is stopped first (TERM on its group, wait up to 5s,
  then KILL), and then the service is launched. The answer names what was
  replaced: `replaced pid 94743 (node server.mjs, since …, in …), which this
  group had not started`. If the stranger would not stop, nothing is launched
  and the answer is `ok:false`. A stranger in the supervisor's own process group
  is signalled by pid alone, and pgids 0 and 1 are never signalled.
- a **foreign stranger** is refused by the machine, through the new
  `port-held-by-foreigner` fact and `held-by-foreigner` refusal in
  `machines/supervise-group.json`. The answer is `ok:false`, naming the process
  and saying it was not touched (criterion 1).
- **our own process**: as before, but the answer names the pid it replaced
  (criterion 2 is then true by construction: the old pid is gone before the
  launch).

The keep-alive tick does **not** act on strangers. Only an operator's restart
does.

## Verified

- 270 unit tests (new `HoldingSpec`: parsing, every verdict, the split bind,
  physical paths, reap tokens, JSON escaping).
- `go-conformance.sh`: the node and Go columns are byte-identical over a new
  Holding section.
- Live, on `fixtures/hello` with control ports :3899 (node) and :3898 (Gnomon).
  - A hand-started orphan in the service's directory was replaced with a pid
    started at the moment of the request.
  - A foreign process on `echoer`'s port was refused with `ok:false` and left
    running.

## The root cause underneath: macOS deletes the pidfiles

The orphan on :3029 was not started by hand. **macOS deleted its pidfile.**
`com.apple.tmp_cleaner` runs `/usr/libexec/tmp_cleaner` every day at 00:00. It
removes anything in `/tmp` whose access, modification *and* change times are all
more than 3 days old. A pidfile is written once, at launch, and this filesystem
does not keep refreshing access times on read, so the supervisor reading it
every tick does not save it. **Any service that runs for more than three days
without a relaunch loses its pidfile at the next midnight, and becomes an orphan
of its own supervisor.**

Evidence from the MBP on 2026-09-25, 13 days after boot: every router-group
pidfile (`chair-server`, `bosun-serve`, the sub-supervisors) is gone, and
`chair-server` (running since 09-12) reads `stranger` in `holders`. The only
pidfiles left are Atlantis services relaunched in the last three days.
`friends-of-itajara` had run for five days.

This is also a likely cause of blind-spots finding 2 (link-spike et al.
relaunched thousands of times against their own orphans). For a `probe:
process` service, a missing pidfile reads as `Down`, so the supervisor
relaunches into the port or socket its own untracked process still holds.

**Fixed with a lease, not a move (same branch, next commit).** The first
instinct was to move pidfiles to a state directory under `$HOME`. That would
have been worse: `/tmp` is cleared at boot, which is exactly the right lifetime
for a pgid. A persistent directory would keep a pre-reboot pgid and one day
signal whatever unrelated group inherited the number. What was missing was an
owner saying the record is still in use. `Substrate.pidLease` runs `touch -c`
on the pidfile of every group still alive, on the supervisor's first
observation and every 10 minutes after. `touch -c` refreshes all three
timestamps the sweep tests and never creates a file, so a service that has gone
keeps no lease. There is no path change and no migration.

Verified in isolation: supervisor A launched `hello`, then A was stopped and the
pidfiles backdated to Sep 20. Supervisor B was started `--held`, so it launched
nothing. On its first observation both pidfiles were renewed, with the same
listener pids, and `find -atime +3 -mtime +3 -ctime +3` no longer matched them.

A pidfile the sweep already took is not recovered by this. Such a service shows
as a claimable `stranger` in `holders`, and one `restart` puts it back under
ownership.

## `down` too (2026-09-26)

`down`, and the partial stop a reload does, now look at the ports after
stopping the recorded groups (`Holding.settleTeardown`):

- A **claimable stranger** is stopped, and the service's verdict becomes
  `reaped`. The 09-08 case (`no-record`, orphan still serving) is now a real
  stop.
- If the stranger would not stop, the verdict is `refused` or `survived`.
- A **foreign stranger** is left alone and named in the reply. Its service's
  own verdict is unchanged, so `no-record` with a foreigner on the port stays
  unsettled.

`down` is never refused for one port, because it is group-wide: it stops what
it may and says what it did not.

Verified live on `fixtures/hello`. With two hand-started orphans and no
records, `down` stopped both (`teardown: reaped`, ports free); before, it
answered `ok` and killed nothing. With a foreign process on `echoer`'s port,
`down` named it, left it running, and still stopped `greeter`.
