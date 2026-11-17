module Bosun.Version where

-- | The single source of truth for the Bosun version string. Lives in
-- | the pure core so every column (node, the BEAM) and the CLI
-- | agree on it without an Effect.
version :: String
version = "0.0.0"
