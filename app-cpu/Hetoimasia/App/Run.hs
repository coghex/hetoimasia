-- | What the default and CPU builds say about the @run@ command: that it does not exist. The console command set
-- of these builds is the one it always had; @run@ is an unknown argument (usage, 2), and the help text names no
-- such command. This is build selection, not a runtime fallback. The full-product build has the module of this
-- name in @app-full/@.
module Hetoimasia.App.Run
  ( runCommand
  , usageAlternative
  , helpEntry
  ) where

import Data.Text (Text)
import Hetoimasia.Foundation.Log (LogFilter)

-- | The command, when this build has it.
runCommand ∷ Maybe (LogFilter → [String] → IO ())
runCommand = Nothing

-- | What the top-level usage line adds for the command.
usageAlternative ∷ Text
usageAlternative = ""

-- | The command's lines in the top-level help text.
helpEntry ∷ [Text]
helpEntry = []
