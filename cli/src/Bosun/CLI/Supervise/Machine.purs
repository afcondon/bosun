-- | Bosun.CLI.Supervise.Machine
-- |
-- | The seam between `bosun supervise` and the Glassbox artifact that describes
-- | its group lifecycle. Everything here is pure; the effects it names live in
-- | `Bosun.CLI.Supervise`, where the closures that can carry them out are.
-- |
-- | ### What moved, and what did not
-- |
-- | The group's whole lifecycle used to be a `Ref Boolean` called `desiredUp`,
-- | read in two places, with its transitions spread across the arms of a
-- | `case verb`. It is now `machines/supervise-group.json`, and this module is
-- | what lets the daemon obey it: the artifact decides, the daemon acts.
-- |
-- | The transitions are NOT here. They are in the artifact, singular, and this
-- | file could not contradict them if it tried — it names states, events and
-- | commands and says nothing about which leads to which.
-- |
-- | ### Why the alphabet is checked at boot
-- |
-- | `Bosun.Machine.SuperviseGroup` is generated from the same file, so it can go
-- | stale the moment somebody edits the artifact without regenerating. What
-- | makes that safe is not the regeneration but `complaints` below: the daemon
-- | compares the two at startup and refuses to run on a machine whose vocabulary
-- | it does not implement. A stale module is a loud startup failure rather than
-- | a command that silently does nothing at 3am.
-- |
-- | This is the same shape as `Host.reportClock`, and the same lesson: find out
-- | at load, by refusal, rather than at the first transition that goes the wrong
-- | way.
module Bosun.CLI.Supervise.Machine
  ( complaints
  , desiredFromPhase
  , phaseTag
  , evUp
  , evDown
  , evRestart
  , evReload
  , evDone
  , evReloaded
  , evRejected
  , evTick
  ) where

import Prelude

import Bosun.Machine.SuperviseGroup as SG
import Data.Array (null)
import Data.Maybe (Maybe(..))
import Data.String (joinWith)
import Data.Variant (Variant)
import Data.Variant as V
import Glassbox.Host (event, reify, reportCommands, reportEvents, reportRefusals, reportStates)
import Glassbox.Spec (EventId, Spec, StateId(..))

-- | Every event this host can deliver, named through the generated row so a
-- | typo is a compile error rather than an event the machine never hears.
evUp :: EventId
evUp = event @"up" SG.events

evDown :: EventId
evDown = event @"down" SG.events

evRestart :: EventId
evRestart = event @"restart" SG.events

evReload :: EventId
evReload = event @"reload" SG.events

evDone :: EventId
evDone = event @"done" SG.events

evReloaded :: EventId
evReloaded = event @"reloaded" SG.events

evRejected :: EventId
evRejected = event @"rejected" SG.events

evTick :: EventId
evTick = event @"tick" SG.events

-- | Is the group meant to be running, in this phase?
-- |
-- | The old `/state` field `desired: up|down` is kept, and derived from the
-- | phase rather than stored beside it, because a stored copy is a second
-- | description that can disagree — which is the whole complaint the artifact
-- | answers. The Chair on `:3020` reads `desired`, so it keeps working
-- | untouched while `phase` is added beside it.
-- |
-- | Exhaustive over the machine's states by construction: the annotation is the
-- | generated `Cases` row, so adding a state to the artifact and regenerating
-- | makes this fail to compile at the missing label rather than fall through to
-- | a default. That is the reason a wildcard is not used here.
desiredFromPhase :: StateId -> Boolean
desiredFromPhase sid = case tagOf sid of
  Nothing -> false
  Just v -> V.match
    ( { "held": \_ -> false
      -- Lowering is on its way down and its teardown has already run, so a
      -- keep-alive that read it as up would relaunch what was just stopped.
      , "lowering": \_ -> false
      , "raising": \_ -> true
      , "raised": \_ -> true
      , "restarting": \_ -> true
      , "reloading": \_ -> true
      , "adopting": \_ -> true
      } :: Record (SG.Cases Boolean)
    ) v

-- | The phase as the plain identifier, for `/state`.
phaseTag :: StateId -> String
phaseTag = case _ of
  StateId s -> s

-- | The artifact's state reified into the generated row, or `Nothing` for a
-- | state this host has never heard of. `complaints` is what makes `Nothing`
-- | unreachable in a daemon that actually started.
tagOf :: StateId -> Maybe (Variant SG.Phase)
tagOf = reify

-- | What this host cannot honour about a given artifact.
-- |
-- | Empty means the daemon may run it. Anything else is printed and the daemon
-- | stops, because a supervisor that cannot carry out one of its own commands
-- | is worse than one that will not start: it starts, looks healthy, and drops
-- | that command on the floor.
-- |
-- | Only `missing` is fatal. `unused` — a name this host implements that the
-- | artifact never mentions — is not: that is what an artifact being simplified
-- | looks like, and refusing it would make the machine harder to edit rather
-- | than safer.
complaints :: Spec -> Array String
complaints spec =
  say "state" (reportStates SG.phases spec)
    <> say "event" (reportEvents SG.events spec)
    <> say "command" (reportCommands SG.commands spec)
    <> say "refusal" (reportRefusals SG.refusals spec)
  where
  say what r
    | null r.missing = []
    | otherwise =
        [ what <> "s the artifact names and this daemon does not implement: "
            <> joinWith ", " r.missing
        ]
