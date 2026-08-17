-- | The resident-mode seam (docs/EXECUTORS.md) — shared by every executor that
-- | mounts a deployment behind the HANDOFF-CHAIR `/state` + `/control` HTTP
-- | contract and runs a periodic tick. It is the load-bearing invariant that
-- | keeps the Chair **executor-agnostic**: a process group (`Bosun.CLI.Supervise`)
-- | and a Docker group (`Bosun.CLI.Docker`) both fill exactly this record, so the
-- | Chair drives either unchanged.
-- |
-- | What varies per substrate is *only* the three callbacks — and the variation
-- | is precisely the EXECUTORS.md "who owns keep-alive" distinction:
-- |
-- |   · process (supervise) — Bosun owns keep-alive: `tick` observes AND enacts
-- |     (restart what crashed).
-- |   · docker — Docker owns keep-alive: `tick` only observes; `control` relays
-- |     deploy/teardown verbs to `docker compose`.
-- |
-- | This `Resident` record IS the "Executor interface" of EXECUTORS.md. It is
-- | named `Resident` (not `Executor`) to avoid clashing with the per-service IR
-- | tag `Bosun.Executor` (Process/Container/…): that classifies one service;
-- | this classifies a whole resident *mode*. Two real instances (process, docker)
-- | now exist, which is the point at which the doc says the shared shape is safe
-- | to name — so it is named here, once, and reused.
module Bosun.CLI.Resident
  ( Resident
  , ControlResult
  , accepted
  , refused
  , runResident
  , nowMs
  ) where

import Prelude

import Effect (Effect)
import Effect.Uncurried (EffectFn1, EffectFn2, runEffectFn1)

-- | What a `/control/<verb>` POST did. `ok` is the SUBSTRATE'S OWN verdict, not
-- | "the callback returned without throwing" — a verb it does not know, a
-- | service it cannot find, a reload it rejected are all refusals, and the shim
-- | answers 4xx for them.
-- |
-- | It used to be a bare `String`, and the shim wrapped every non-throwing
-- | return as `200 {ok:true}`. So `"unknown control verb: xyz"` and
-- | `"reload: rejected — …"` reached the caller as successes — and chair-server
-- | reads exactly this `ok` to decide whether a registration was routed, so the
-- | daemon's own "no" was being converted into a "yes" one layer up.
type ControlResult = { ok :: Boolean, message :: String }

-- | The verb was understood and enacted.
accepted :: String -> Effect ControlResult
accepted message = pure { ok: true, message }

-- | The verb was understood and NOT enacted (or not understood at all). The
-- | message is the reason, and it reaches the caller instead of being logged
-- | where only the daemon can see it.
refused :: String -> Effect ControlResult
refused message = pure { ok: false, message }

-- | A resident substrate adapter. `tick` runs every `intervalMs`; `stateBody`
-- | renders the current `/state` JSON; `control` handles a
-- | `/control/<verb>?service=<arg>` POST and reports what it did. Bringing
-- | the deployment to its initial state (process: bring-up; docker: first
-- | observe) is the substrate's own job, done before `runResident` is called.
type Resident =
  { statusPort :: Int
  , intervalMs :: Int
  , tick :: Effect Unit
  , stateBody :: Effect String
  , control :: EffectFn2 String String ControlResult
  }

foreign import residentImpl :: EffectFn1 Resident Unit

-- | Wall-clock milliseconds at the seam. Lives in the shim (not the pure core),
-- | so the decision tier stays deterministic and conformance-byte-identical;
-- | a substrate only ever *receives* time, never reads it.
foreign import nowMs :: Effect Number

-- | Mount a substrate on its status port and run forever (resident).
runResident :: Resident -> Effect Unit
runResident = runEffectFn1 residentImpl
