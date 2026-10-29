{-# LANGUAGE OverloadedStrings #-}

-- | @api.session.status()@, @api.session.quit()@ and the unavailable-state guard @state(...)@ / @api.state(...)@
-- (LFE-26; D-70, D-72, D-76, P-73 sections 4 and 5), bound over the narrow session endpoints the coordinator
-- (LFE-13) injects. This module adds no coordinator, no store and no queue: it checks what a script asked,
-- calls an endpoint, and shapes the answer.
--
-- = @status@: one capture for each presentation segment
--
-- A presentation facade is told whenever an instance's hook begins or resumes ('captureStatus', wired by
-- 'Hetoimasia.LuaEngine.Facade.facadeInstanceConfig' beside the clock's sample). It reads the session's
-- status once, in one transaction, and stores that value for the segment. A call to @status@ never reads the
-- coordinator: it answers a fresh Lua copy of the stored capture, so every read of a segment describes the
-- same capture however the session changes meanwhile, a script that edits a result changes nothing but its
-- own table, and a stopping session is not seen until a later segment. A long segment may keep an old
-- capture, an event-driven instance with no scheduled hook is not woken by a change, and nothing here waits
-- for a request, a readiness or a retirement. The gameplay VM has no status: its call is an ordinary error.
--
-- = @quit@: a returning request
--
-- @quit@ calls the coordinator's idempotent normal-stop endpoint directly and returns no value. It takes no
-- request slot and has no busy answer; the endpoint closes new work and future logical tick grants before it
-- returns. The statements after it still run until the hook returns or yields.
--
-- = @state@: the terminal boundary
--
-- The guard takes any arguments and inspects none. Its first act is to latch the whole session's failure and
-- orderly stop through the coordinator; only the call that latched it writes the fixed diagnostic, and only
-- after the latch, so a sink that fails cannot lose the terminal authority. It then returns, and the Lua
-- closure raises the fixed error. It is reachable from a module's top level, from every hook, after a quit and
-- through any captured facade, and no role, phase or arity check stands in front of it.
module Hetoimasia.LuaEngine.Facade.Session
  ( sessionBindings
  , statusSchema
  , statusValue
  , failureValue
  , captureStatus
  , forgetStatus
  ) where

import Control.Concurrent.STM (STM, atomically, modifyTVar', readTVar)
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Facade.Bindings
import Hetoimasia.LuaEngine.Facade.Caller
  ( Calling (InInstance, InModule, Nowhere)
  , Caller (..)
  , Stage (..)
  , recordByNumber
  )
import Hetoimasia.LuaEngine.Facade.Output (writeAuthored)
import Hetoimasia.LuaEngine.Facade.Types
import Hetoimasia.LuaEngine.Manifest (Role (..))
import Hetoimasia.Scripting.Lua.Instance (InstanceId (instanceLocal))
import Hetoimasia.Scripting.Lua.Registration
  ( Binding
  , asynchronousNativeRequestIn
  , recoverableRefusals
  , withPrecondition
  )
import Hetoimasia.Scripting.Lua.Value (Schema (SBoolean, SOptional, SRecord, SText), Value (VBoolean, VRecord, VText))

-- | The three bindings of the hidden namespace: @session_status@, @session_quit@ and @state_unavailable@.
-- The initial chunk wraps each in the facade's own closure.
sessionBindings ∷ Facade → [Binding]
sessionBindings facade =
  [ withPrecondition (instanceCheck facade (requireRole Presentation "status is available to the presentation role only")) $
      recoverableRefusals (asynchronousNativeRequestIn "session_status" [] [statusSchema] status)
  , withPrecondition (instanceCheck facade (const Nothing)) $
      recoverableRefusals (asynchronousNativeRequestIn "session_quit" [] [] quit)
  , -- The guard is not an ordinary validation refusal: no precondition and no argument check stand in front
    -- of it, it takes no argument at all (the closure drops whatever the script passed, unread), and its
    -- action never refuses.
    asynchronousNativeRequestIn "state_unavailable" [] [] unavailable
  ]
  where
    status context _ = do
      calling ← callingIn facade context
      case calling of
        InInstance caller → do
          captured ← atomically (Map.lookup (callerNumber caller) <$> readTVar (statusSamples (fcStatus facade)))
          case captured of
            Just sample → pure [statusValue sample]
            Nothing → failEngine facade "a presentation hook began without the facade being told: no capture of its segment's status"
        _ → failEngine facade "the status was read with no instance running"

    quit context _ = do
      calling ← callingIn facade context
      case calling of
        InInstance _ → [] <$ endpointQuit (fcSession facade)
        _ → failEngine facade "quit was called with no instance running"

    -- First the latch, which cannot be lost to anything that follows it; then, for the call that latched it,
    -- the one diagnostic. A sink that fails is the output's failure (the owner ends, nothing is retried), and
    -- the latch and the stop are already committed.
    unavailable context _ = do
      calling ← callingIn facade context
      first ← endpointTerminal (fcSession facade) (terminalOf facade calling)
      when first (writeAuthored (fcOutput facade) Stderr [stateUnavailableMessage])
      pure []

-- | What a guard call says about where it ran.
terminalOf ∷ Facade → Calling → TerminalContext
terminalOf facade = \case
  InInstance caller →
    let record = callerRecord caller
     in TerminalContext
          { terminalRole = recordRole record
          , terminalStage = case callerStage caller of
              StageInitializing → TerminalInit
              StageServing → TerminalUpdate
              StageEnding → TerminalShutdown
          , terminalContent = Just (recordContent record)
          , terminalInstance = Just (recordId record)
          }
  InModule _ → TerminalContext (fcRole facade) TerminalModule (soleRoot facade) Nothing
  -- A segment that is no instance's hook: the executing role's own serving code, with no instance to name.
  Nowhere → TerminalContext (fcRole facade) TerminalUpdate (soleRoot facade) Nothing

-- | The content the VM serves when it serves exactly one (in M1 it always does).
soleRoot ∷ Facade → Maybe Text
soleRoot facade = case fcRoots facade of
  [root] → Just root
  _ → Nothing

-- Capturing --------------------------------------------------------------------------------------------------

-- | A hook of this instance is about to begin or resume: a presentation facade reads the session's status
-- once and stores it as the segment's. A gameplay facade stores nothing. An instance this facade was not
-- declared to is not remembered. The read and the store are one transaction.
captureStatus ∷ Facade → InstanceId → IO ()
captureStatus facade instanceId = case fcRole facade of
  Gameplay → pure ()
  Presentation → atomically $ do
    known ← recordByNumber (fcRegistry facade) (instanceLocal instanceId)
    case known of
      Nothing → pure ()
      Just _ → do
        sample ← endpointStatus (fcSession facade)
        modifyTVar' (statusSamples (fcStatus facade)) (Map.insert (instanceLocal instanceId) sample)

-- | Forget an instance's capture.
forgetStatus ∷ Facade → Word64 → IO ()
forgetStatus facade number = atomically (modifyTVar' (statusSamples (fcStatus facade)) (Map.delete number) ∷ STM ())

-- Marshalling ------------------------------------------------------------------------------------------------

-- | The accepted status record: @stopping@ and, for each role, @{present=false}@ or the present record. The
-- failure's optional fields are absent when unknown.
statusSchema ∷ Schema
statusSchema = SRecord [("stopping", SBoolean), ("gameplay", roleSchema), ("presentation", roleSchema)]
  where
    roleSchema =
      SRecord
        [ ("present", SBoolean)
        , ("initialized", SOptional SBoolean)
        , ("phase", SOptional SText)
        , ("failed", SOptional SBoolean)
        , ("failure", SOptional failureSchema)
        ]
    failureSchema =
      SRecord
        [ ("code", SText)
        , ("message", SText)
        , ("role", SText)
        , ("stage", SText)
        , ("content_id", SOptional SText)
        , ("instance_id", SOptional SText)
        , ("path", SOptional SText)
        , ("traceback", SOptional SText)
        ]

-- | A capture as a fresh record: exactly the accepted fields, an unknown one absent.
statusValue ∷ StatusSample → Value
statusValue sample =
  VRecord
    [ ("stopping", VBoolean (sampleStopping sample))
    , ("gameplay", roleValue (sampleGameplay sample))
    , ("presentation", roleValue (samplePresentation sample))
    ]
  where
    roleValue = \case
      Nothing → VRecord [("present", VBoolean False)]
      Just role →
        VRecord $
          [ ("present", VBoolean True)
          , ("initialized", VBoolean (sampleInitialized role))
          , ("phase", VText (samplePhase role))
          , ("failed", VBoolean (sampleFailure role /= Nothing))
          ]
            <> [("failure", failureValue failure) | Just failure ← [sampleFailure role]]

-- | A failure as a fresh record: the four required fields, then each known optional one.
failureValue ∷ FailureSample → Value
failureValue failure =
  VRecord $
    [ ("code", VText (sfCode failure))
    , ("message", VText (sfMessage failure))
    , ("role", VText (sfRole failure))
    , ("stage", VText (sfStage failure))
    ]
      <> catMaybes
        [ ("content_id",) . VText <$> sfContentId failure
        , ("instance_id",) . VText <$> sfInstanceId failure
        , ("path",) . VText <$> sfPath failure
        , ("traceback",) . VText <$> sfTraceback failure
        ]
