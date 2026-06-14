-- | The execution edge (BUILD-PLAN Phase 6C) — `apply`'s os-exec.
-- |
-- | `execLine` runs one already-rendered shell line synchronously and reports
-- | success/exit-code/output. This is the *only* mutating effect Bosun
-- | performs; everything upstream (`plan`, `applyScript`) is pure, so the
-- | effectful shell is trivial — it just runs the strings the pure core
-- | produced. Synchronous by design (the no-Aff seam); a launch command must
-- | be non-blocking on its own (a backgrounded server, `docker compose up -d`),
-- | exactly as in a real deploy.
module Bosun.CLI.Exec
  ( ExecResult
  , execLine
  ) where

import Effect (Effect)
import Effect.Uncurried (EffectFn1, runEffectFn1)

type ExecResult = { ok :: Boolean, code :: Int, message :: String }

foreign import execLineImpl :: EffectFn1 String ExecResult

execLine :: String -> Effect ExecResult
execLine = runEffectFn1 execLineImpl
