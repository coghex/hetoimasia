-- | The window provider's endpoints on the real session coordinator (LFE-18 over LFE-13).
--
-- The provider ("Hetoimasia.LuaEngine.Graphics.Window.Provider") is configured with two plain actions so that its
-- examples can count them. In a composition they are the session's own:
--
-- * a genuine native close is the session's idempotent, slot-free normal stop ('requestStop' with 'StopQuit'),
--   which closes admission for the whole session in one transaction and cannot be refused for want of request
--   capacity;
-- * a fatal fault is the session's terminal failure ('latchTerminalFailure'): a failure of retirement is a
--   @cleanup_failure@, anything else a @host_failure@, both attributed to the presentation role at the engine
--   stage. The session applies its own precedence (a failure outranks an interruption, an interruption a normal
--   quit) and its own protected teardown; this module decides neither.
module Hetoimasia.LuaEngine.Graphics.Window.Session
  ( sessionWindowConfig
  ) where

import Control.Monad (void)
import Hetoimasia.LuaEngine.Graphics.Window.Port (Fatal (..), fatalText)
import Hetoimasia.LuaEngine.Graphics.Window.Provider (WindowConfig (..))
import Hetoimasia.LuaEngine.Manifest (Role (Presentation))
import Hetoimasia.LuaEngine.Session
  ( FailureCode (CleanupFailure, HostFailure)
  , FailureStage (OnEngine)
  , Session
  , StopKind (StopQuit)
  , latchTerminalFailure
  , newRoleFailure
  , requestStop
  )

-- | A provider configuration whose stop and fatal endpoints are this session's, over this many work records.
sessionWindowConfig ∷ Session → Int → WindowConfig
sessionWindowConfig session records =
  WindowConfig
    { windowRecords = records
    , windowStop = requestStop session StopQuit
    , windowFatal = \found →
        void . latchTerminalFailure session $
          newRoleFailure (codeOf found) OnEngine Presentation (fatalText found)
    }
  where
    codeOf = \case
      CleanupFatal _ → CleanupFailure
      Fatal _ → HostFailure
