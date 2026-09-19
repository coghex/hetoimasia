-- | The protocol model's fixture.
--
-- Scopes, limits, and the two combinators every example in this group is
-- written with. Nothing here touches a VM, the bridge, or the filesystem: the
-- model is pure, and so is everything needed to drive it.
module Test.Lua.Protocol.Support
  ( -- * Scopes
    gameplay
  , interfaceSide
  , otherMod
  , otherSession
  , laterEpoch

    -- * Sessions
  , sampleLimits
  , roomyLimits
  , openSession
  , openSessionWith
  , openSessionAt

    -- * Admission
  , admission
  , observingAdmission
  , admitted
  , runningTask

    -- * Driving operations
  , ok
  , rejected

    -- * Values
  , cursor
  , message
  ) where

import Control.Exception (throwIO)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( BehaviorId (BehaviorId)
  , ExecutionDomain (GameplayDomain, InterfaceDomain)
  , ModId (ModId)
  , Owner (Owner)
  , SessionId (SessionId)
  , SessionKey (SessionKey, keyEpoch)
  , TaskId
  , firstEpoch
  , nextEpoch
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Limits
  ( Limits (Limits, limitQuanta, maxActiveTasks, maxOutstandingRequests, maxPayloadBytes, maxQueuedAdmissions, maxRetainedResults, maxSubscriptionQueue, maxSubscriptions)
  , Quanta (Quanta, backgroundQuantum, controlQuantum, ordinaryQuantum)
  , Quantum (Quantum)
  , ServiceClass (OrdinaryClass)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( AdmissionRequest (AdmissionRequest, admitAuthority, admitBehavior, admitCursor, admitReadiness, admitService)
  , Authority (Mutating, Observing)
  , Session
  , SessionRejection
  , activateNext
  , newSession
  , requestAdmission
  , startSegment
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Value (Payload (Payload, payloadBytes, payloadValue))
import Test.Hspec (expectationFailure)

-- | The gameplay owner these examples work in.
gameplay ∷ SessionKey
gameplay = SessionKey (Owner (ModId "mod.alpha") GameplayDomain) (SessionId 1) firstEpoch

-- | The same mod's interface domain: a different owner entirely.
interfaceSide ∷ SessionKey
interfaceSide = SessionKey (Owner (ModId "mod.alpha") InterfaceDomain) (SessionId 1) firstEpoch

-- | A different mod, in the same domain and with the same session number.
otherMod ∷ SessionKey
otherMod = SessionKey (Owner (ModId "mod.beta") GameplayDomain) (SessionId 1) firstEpoch

-- | The same owner's next session.
otherSession ∷ SessionKey
otherSession = SessionKey (Owner (ModId "mod.alpha") GameplayDomain) (SessionId 2) firstEpoch

-- | A scope one epoch on from another.
laterEpoch ∷ SessionKey → SessionKey
laterEpoch key = key {keyEpoch = nextEpoch (keyEpoch key)}

-- | Small caps, so every one of them can be reached in an example.
sampleLimits ∷ Limits
sampleLimits =
  Limits
    { maxActiveTasks = 3
    , maxQueuedAdmissions = 2
    , maxSubscriptions = 2
    , maxSubscriptionQueue = 2
    , maxOutstandingRequests = 2
    , maxPayloadBytes = 64
    , maxRetainedResults = 4
    , limitQuanta =
        Quanta
          { controlQuantum = Quantum 2
          , ordinaryQuantum = Quantum 4
          , backgroundQuantum = Quantum 1
          }
    }

-- | Caps wide enough to be out of the way, for the examples whose subject is
-- not a cap.
roomyLimits ∷ Limits
roomyLimits =
  sampleLimits
    { maxActiveTasks = 8
    , maxQueuedAdmissions = 4
    , maxSubscriptions = 4
    , maxOutstandingRequests = 4
    , maxRetainedResults = 12
    }

-- | A gameplay session over 'sampleLimits'.
openSession ∷ HasCallStack ⇒ IO (Session Text)
openSession = openSessionWith sampleLimits

-- | A gameplay session over the given limits.
openSessionWith ∷ HasCallStack ⇒ Limits → IO (Session Text)
openSessionWith = openSessionAt gameplay

-- | A session in the given scope.
openSessionAt ∷ HasCallStack ⇒ SessionKey → Limits → IO (Session Text)
openSessionAt key limits = case newSession key limits of
  Right session → pure session
  Left violations → do
    expectationFailure ("limits refused: " <> show violations)
    throwIO (userError "unreachable")

-- | A mutating admission carrying a distinguishable cursor.
--
-- The number is the cursor's, not the task's: the session issues task names,
-- so an example never picks one.
admission ∷ Word64 → AdmissionRequest Text
admission number =
  AdmissionRequest
    { admitBehavior = BehaviorId "behaviour"
    , admitService = OrdinaryClass
    , admitAuthority = Mutating
    , admitCursor = cursor number
    , admitReadiness = Nothing
    }

-- | An observing admission.
observingAdmission ∷ Word64 → AdmissionRequest Text
observingAdmission number = (admission number) {admitAuthority = Observing}

-- | Admit and activate one task.
admitted ∷ HasCallStack ⇒ Word64 → Session Text → IO (Session Text, TaskId)
admitted number session = do
  (queued, identity) ← ok (requestAdmission (admission number) session)
  (active, _) ← ok (activateNext queued)
  pure (active, identity)

-- | Admit, activate, and start a segment for one task.
runningTask ∷ HasCallStack ⇒ Word64 → Session Text → IO (Session Text, TaskId)
runningTask number session = do
  (active, identity) ← admitted number session
  (started, ()) ← ok (startSegment identity active)
  pure (started, identity)

-- | Require an operation to have succeeded.
ok
  ∷ (HasCallStack, Show a)
  ⇒ (Session v, Either SessionRejection a)
  → IO (Session v, a)
ok (session, Right value) = pure (session, value)
ok (_, Left rejection) = do
  expectationFailure ("unexpected rejection: " <> show rejection)
  throwIO (userError "unreachable")

-- | Require an operation to have been refused, answering the reason.
rejected
  ∷ (HasCallStack, Show a)
  ⇒ (Session v, Either SessionRejection a)
  → IO (Session v, SessionRejection)
rejected (session, Left rejection) = pure (session, rejection)
rejected (_, Right value) = do
  expectationFailure ("unexpectedly accepted: " <> show value)
  throwIO (userError "unreachable")

-- | A distinguishable application cursor.
cursor ∷ Word64 → Text
cursor number = "cursor-" <> Text.pack (show number)

-- | A payload of a declared size, carrying a distinguishable value.
message ∷ Int → Text → Payload Text
message declared value = Payload {payloadBytes = declared, payloadValue = value}
