-- | What the full-product build says about the @run@ command: it is dispatched to the private @run@ library
-- ("Hetoimasia.Run"), which composes the engine's services, and the top-level usage and help name it. The
-- default and CPU builds have the module of this name in @app-cpu/@, which has no such command.
module Hetoimasia.App.Run
  ( runCommand
  , usageAlternative
  , helpEntry
  ) where

import Data.Text (Text)
import Hetoimasia.Foundation.Log (LogFilter)
import Hetoimasia.Run (runHelpEntry, runRun)

-- | The command, when this build has it.
runCommand ∷ Maybe (LogFilter → [String] → IO ())
runCommand = Just runRun

-- | What the top-level usage line adds for the command.
usageAlternative ∷ Text
usageAlternative = " | run [--] GAME_ROOT"

-- | The command's lines in the top-level help text.
helpEntry ∷ [Text]
helpEntry = runHelpEntry
