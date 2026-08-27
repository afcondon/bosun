# Glassbox machines

State machines Bosun runs — or, for now, describes — as **data artifacts**
rather than as code. See `purescript-hylograph-libs/purescript-glassbox`.

`supervise-group.json` is the lifecycle of one `bosun supervise` group. It is
**not wired in**: it is written, linted and rendered, and the code it describes
still lives in `Bosun.CLI.Supervise.superviseResident`. Writing it was the test
of whether the format can say what a real supervisor does, and the answer is
worth recording before anything is ported.

Regenerate the renderings from the glassbox workspace:

```sh
spago run -p glassbox-cli -- lint       <bosun>/machines
spago run -p glassbox-cli -- render-all <bosun>/machines <bosun>/machines/rendered
```

## What the format said that the code does not

**`held` and `raised` are states.** Today the whole of the group's lifecycle is
`desiredUp :: Ref Boolean`, read in exactly two places — the keep-alive tick and
`/state`. A Boolean has no room for the five transient states below, so they do
not exist and the Chair cannot show them.

**A moment that runs a command has to be a state,** because commands hang off
state entry. `raising`, `lowering`, `restarting`, `reloading` and `adopting` are
the format forcing into existence the in-flight moments the code runs
synchronously inside a control handler. That is the same thing the follow
button's two pending states were. It buys something concrete: a control verb
arriving mid-transition can be refused as `busy` here, and cannot be there.

**`tick` in `raised` is a Move to the state it is already in** — the statechart
external self-transition, which exits and re-enters, and re-entering runs
`reconcile`. The keep-alive loop, in one word.

## The bug it found

`restart` and `reload` are not gated on `desiredUp` at all. Nothing was decided
wrongly; the cell was simply never written down, which is what totality is for.

Demonstrated on `fixtures/hello` (two `python3 -m http.server`), on a spare
port so the live Atlantis group on `:3994` was untouched:

```
$ bosun supervise --held --port 3899 fixtures/hello/{compose.yml,registry.json}
supervise: resident, held down (desired=down) — no initial bring-up

$ curl :3899/state
{ "desired": "down", "services": { "hello:echoer": "down", "hello:greeter": "down" } }

$ curl -X POST ':3899/control/restart?service=hello:greeter'
{"ok":true,"message":"restart: hello:greeter"}

$ curl :3899/state
{ "desired": "down", "services": { "hello:echoer": "running", "hello:greeter": "running" } }
```

Two things there, and the second is worse than the first. A held group launched
on a `restart` — and it launched **both** services, not the named one, because
`enactPlan` runs the whole plan and every other service reads `Down`. Meanwhile
`/state` still says `desired: down`, so the Chair shows a held group with
everything running.

The artifact says `held × restart -> refuse not-raised`, and `held × reload`
likewise: reloading a group with nothing running has nothing to stop.

## What the format could NOT say

**Reload cannot return whence it came.** A machine has no memory beyond the
state it is in, so `reloading` cannot know whether it was entered from `held` or
`raised`. This is the third independent sighting of the same limitation — the
looper's pause/resume and the elevator's floor number were the first two. Here
it is not a compromise: refusing `reload` while held is the better behaviour
anyway. It will not always be.

**No deadlines, which was a surprise.** A supervisor is full of timing, but the
*group's* lifecycle has none: the tick is a recurring heartbeat the host owns,
and a heartbeat is not a deadline. Boot-grace and backoff are real millisecond
deadlines, but they belong to the per-service machine — and that one is
currently `Bosun.Supervisor.decide`, a **classifier** rather than a state
machine: it reads observations and counters and never consults `s.status` at
all. Describing it as a state machine would be changing it, not describing it,
and that is a separate decision from this one.
