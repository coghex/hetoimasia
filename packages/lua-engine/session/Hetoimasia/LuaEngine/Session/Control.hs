{-# LANGUAGE OverloadedStrings #-}

-- | What the coordinator hands a facade (LFE-26): the conversions between the session's own records and the
-- facade's plain samples, and nothing else. Pure; it imports no endpoint and runs nothing, so a record the
-- running Lua may never get to read (a fatal one, a module-only one, a final phase) is converted and checked
-- on its own.
--
-- The coordinator's answers are copied word for word. Nothing is added, summarized or rebuilt here: every
-- text the failure holds was bounded when the state took it in (message 2 KiB, traceback 8 KiB, the whole
-- record 16 KiB, an instance identity 128 bytes), and a field that was not known stays absent.
module Hetoimasia.LuaEngine.Session.Control
  ( statusSample
  , roleSample
  , failureSample
  , phaseWord
  , terminalFailure
  ) where

import Hetoimasia.LuaEngine.Facade
  ( FailureSample (..)
  , RoleSample (..)
  , StatusSample (..)
  , TerminalContext (..)
  , TerminalStage (..)
  , stateUnavailableMessage
  )
import Hetoimasia.LuaEngine.Session.Failure
import Hetoimasia.LuaEngine.Session.State
import Data.Text (Text)

-- | The status the coordinator publishes, as the plain sample a script is shown. Whole-session @stopping@
-- is the coordinator's; a role absent from the session is absent here.
statusSample ∷ SessionStatus → StatusSample
statusSample status =
  StatusSample
    { sampleStopping = statusStopping status
    , sampleGameplay = roleSample <$> statusGameplay status
    , samplePresentation = roleSample <$> statusPresentation status
    }

-- | One present role. A role is failed exactly when it carries a failure.
roleSample ∷ RoleStatus → RoleSample
roleSample found =
  RoleSample
    { sampleInitialized = roleInitialized found
    , samplePhase = phaseWord (rolePhase found)
    , sampleFailure = failureSample <$> roleFailure found
    }

-- | A latched failure, spelled as the schema spells it.
failureSample ∷ RoleFailure → FailureSample
failureSample failure =
  FailureSample
    { sfCode = codeWord (rfCode failure)
    , sfMessage = rfMessage failure
    , sfRole = roleWord (rfRole failure)
    , sfStage = stageWord (rfStage failure)
    , sfContentId = rfContent failure
    , sfInstanceId = rfInstance failure
    , sfPath = rfPath failure
    , sfTraceback = rfTraceback failure
    }

-- | The phase as the schema spells it.
phaseWord ∷ Phase → Text
phaseWord = \case
  Starting → "starting"
  Ready → "ready"
  Running → "running"
  Stopping → "stopping"
  Retired → "retired"

-- | The failure the unavailable-state guard latches, from where the guard ran: code @state_unavailable@, the
-- fixed message, the executing role and stage, the content and instance when an instance was running, and the
-- content and path of the module whose top level was running when one was. A module-only call names no instance,
-- and no traceback is captured.
terminalFailure ∷ TerminalContext → RoleFailure
terminalFailure context =
  (newRoleFailure StateUnavailable stage (terminalRole context) stateUnavailableMessage)
    { rfContent = terminalContent context
    , rfInstance = terminalInstance context
    , rfPath = terminalPath context
    }
  where
    stage = case terminalStage context of
      TerminalModule → OnModule
      TerminalInit → OnInit
      TerminalUpdate → OnUpdate
      TerminalShutdown → OnShutdown
