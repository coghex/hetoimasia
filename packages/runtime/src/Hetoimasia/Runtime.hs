-- | Minimal application orchestration. The caller supplies the implementation.
module Hetoimasia.Runtime (runApplication) where

import Data.Text (Text)
import Hetoimasia.Foundation.Log (Logger, LogLevel (Info), logMessage)

-- | Log entry and successful completion, preserving the action's result.
-- Exceptions propagate; failure must not produce a successful completion entry.
-- This function currently acquires no resources and starts no worker threads.
runApplication ∷ Logger → Text → IO a → IO a
runApplication logger name action = do
  logMessage logger Info "runtime" ("Starting " <> name)
  result ← action
  logMessage logger Info "runtime" ("Completed " <> name)
  pure result
