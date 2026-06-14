-- | BUILD-PLAN Phase 7 spike — is a backend-go lazy CAF thunk thread-safe?
-- |
-- | This is the gating unknown for `bosun serve` (the SDI-style concurrent
-- | router): a resident router serves requests in goroutines, which will force
-- | shared top-level CAF thunks *concurrently* — something single-threaded
-- | `apply` never does. backend-go's `_force` mutates the thunk's `done/forcing/
-- | val` with no synchronization (and panics on `forcing && !done`), so the
-- | hypothesis is: concurrent forcing breaks (data race or a spurious
-- | "cyclic strict initialization" panic).
-- |
-- | `shared` is an expensive lazily-initialized CAF. `main` forces it from N
-- | goroutines at once (via the foreign) and reports whether they agree.
module Bosun.Conformance.RaceSpike where

import Prelude

import Effect (Effect)
import Effect.Console (log)
import Effect.Uncurried (EffectFn2, runEffectFn2)

-- An expensive, lazily-initialized top-level CAF — a `_lazy(...)` thunk in
-- backend-go, forced on first use. The loop widens the race window.
shared :: Int
shared = loop 0 0
  where
  loop :: Int -> Int -> Int
  loop acc i = if i >= 2000000 then acc else loop (acc + i) (i + 1)

-- forceConcurrentlyImpl n thunkFn: call `thunkFn unit` from n goroutines, each
-- forcing the SAME `shared` CAF concurrently; returns each goroutine's result.
foreign import forceConcurrentlyImpl :: EffectFn2 Int (Unit -> Int) (Array Int)

main :: Effect Unit
main = do
  results <- runEffectFn2 forceConcurrentlyImpl 16 (\_ -> shared)
  log ("forced `shared` from 16 goroutines")
  log ("results: " <> show results)
