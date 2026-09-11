-- | Minimal application orchestration. The caller supplies the implementation.
module Hetoimasia.Runtime (runApplication) where

import Data.Text (Text)
import Hetoimasia.Foundation.Log (Component, Logger, logInfo, unsafeComponent)

-- | The component every entry from this module uses.
runtimeComponent ∷ Component
runtimeComponent = unsafeComponent "runtime"

-- | Log entry and successful completion, preserving the action's result.
-- Exceptions propagate; failure must not produce a successful completion entry.
-- This function currently acquires no resources and starts no worker threads.
runApplication ∷ Logger → Text → IO a → IO a
runApplication logger name action = do
  logInfo logger runtimeComponent ("Starting " <> name) []
  result ← action
  logInfo logger runtimeComponent ("Completed " <> name) []
  pure result
