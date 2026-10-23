-- | The M1 request adapter (LFE-7): the fixed profile's policy and the exact common result
-- schema, over the host's opt-in admission ("Hetoimasia.Scripting.Lua.Admission").
--
-- The host supplies the mechanism: one transaction that reserves a request's places, result lease and
-- provider credits together or returns busy, the timing assignment, the required-failure latch, the
-- one-shot settlement and the cancellation race. This module supplies what is M1's: the limits read
-- from a validated 'Profile' (16 accepted, unretired requests per instance, 64 per VM, the
-- copied-value ceilings, the 2 KiB message, the 2^63 - 1 numeric ceiling), the busy answer, the
-- records @take@ answers, and the bindings an engine facade assembles under @api.request@. No
-- service is implemented here: a texture, data, module or window service builds its own
-- request-producing binding from 'startM1' and gives its own endpoint, expected failure codes,
-- credits and lease. Nothing of a game, a window or a native resource is imported.
--
-- = What a script sees
--
-- A request-producing binding, written by a service, is called with a dot and answers two values:
-- @request, nil@ when the request was accepted, or @nil, {code = "busy", message = TEXT}@ when
-- a temporary bank had no room (never an error, never the instance's failure; a later call
-- may succeed; nothing retries). 'm1StartResults' makes them and 'm1StartSchemas' declares them.
--
-- The request is an opaque handle owned by the instance that made it. The four operations on it:
--
-- +------------------+---------------------------------------------------------------------+
-- | @ready(r)@       | a Boolean; consumes nothing                                         |
-- | @take(r)@        | @{status="pending"}@ without consuming; otherwise exactly one fresh |
-- |                  | record and the handle is spent: @{status="success", value=V}@,      |
-- |                  | @{status="failure", error={code, message, root, path}}@ (root and   |
-- |                  | path only for content) or @{status="cancelled"}@                    |
-- | @cancel(r)@      | @"cancelled"@ when this call won, @"already_settled"@ otherwise     |
-- | @wait(r)@        | no results; suspends without blocking the VM thread; consumes       |
-- |                  | nothing; refused in @init@ and @shutdown@                           |
-- +------------------+---------------------------------------------------------------------+
--
-- Only the fields of the variant are present. Wrong arity, type, kind, instance, a spent handle and
-- a wrong phase are ordinary Lua errors ("Hetoimasia.Scripting.Lua.Registration"'s recoverable
-- refusals), raised before any provider action; catching one never clears a required failure.
--
-- = What is not here
--
-- Which role may ask, which phase, which codes a service supplies and what its value is are the
-- service's. A provider reply that breaks the service's declaration (a result over the
-- ceilings or of another shape, a failure with no code the service supplies) is a provider
-- defect and fails the owner; it is never given an @error.code@.
module Hetoimasia.LuaEngine.Request
  ( -- * The service
    M1Requests
  , M1RequestsRefused (..)
  , m1Requests
  , m1Profile
  , m1Handles

    -- * What is asked
  , M1Ask (..)
  , m1Ask
  , offsetFromLua
  , m1Admission

    -- * Asking
  , M1Start (..)
  , startM1
  , m1ArgumentCheck
  , m1StartResults
  , m1StartSchemas
  , busyCode
  , refusedCode
  , busyMessage

    -- * The common result adapter
  , M1Service (..)
  , m1HandleType
  , m1RequestBindings
  , m1TakeSchema
  , m1ErrorSchema
  , m1SuccessFrame
  , m1FailureFrame
  , terminalRecord
  ) where

import qualified Data.ByteString as ByteString
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Encoding
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.LuaEngine.Profile
  ( Bytes (Bytes)
  , ByteLimit (CopiedValueBytes, MessageBytes, PathBytes)
  , Count (Count)
  , CountLimit (CopiedValueDepth, CopiedValueElements, LuaIntegerMaximum, RequestsPerInstance, RequestsPerVm)
  , Profile
  , bytesLimit
  , countLimit
  )
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Lease (Ownership)
import Hetoimasia.Scripting.Lua.Registration
  ( ArgumentCheck
  , Binding
  , CapabilityType
  , OwnerContexts (contextRequests)
  , RequestContext
  , WaitKind (WaitSettlement)
  , asynchronousNativeRequestIn
  , recoverableRefusals
  , waitOperation
  , withPrecondition
  )
import Hetoimasia.Scripting.Lua.Request (RequestHandle, requestHandleValue)
import Hetoimasia.Scripting.Lua.Value
  ( LimitsRefusal
  , Schema (SBoolean, SCapability, SOptional, SRecord, SText)
  , Value (VBoolean, VCapability, VNil, VRecord, VText)
  , ValueLimits
  , capabilityKey
  , valueLimits
  )

-- The service ------------------------------------------------------------------------------

-- | The M1 request policy over one validated profile: the limits, read once, and the registry
-- the owner answers handle liveness through.
data M1Requests = M1Requests
  { m1Profile ∷ !Profile
  , m1Handles ∷ !RequestHandles
  , m1PerInstance ∷ !Int
  , m1PerVm ∷ !Int
  , m1Ceiling ∷ !Word64
  , m1ReplyLimits ∷ !ValueLimits
  , m1MessageBytes ∷ !Int
  , m1PathBytes ∷ !Int
  }

-- | Why the profile could not be turned into the limits of requests.
data M1RequestsRefused
  = -- | A profile value that does not fit the machine integer it is held in, or the value limits
    -- the host accepts: which one.
    LimitNotRepresentable !Text
  | LimitsRefused !LimitsRefusal
  deriving (Eq, Show)

-- | The policy of a validated profile. Every smaller profile a test injects went through
-- 'Hetoimasia.LuaEngine.Profile.validateProfile', so the 64-per-VM cap can be reached with
-- an instance cap below it.
m1Requests ∷ Profile → RequestHandles → Either M1RequestsRefused M1Requests
m1Requests profile handles = do
  perInstance ← machine "RequestsPerInstance" (count RequestsPerInstance)
  perVm ← machine "RequestsPerVm" (count RequestsPerVm)
  bytes ← machine "CopiedValueBytes" (bytes' CopiedValueBytes)
  depth ← machine "CopiedValueDepth" (count CopiedValueDepth)
  elements ← machine "CopiedValueElements" (count CopiedValueElements)
  message ← machine "MessageBytes" (bytes' MessageBytes)
  path ← machine "PathBytes" (bytes' PathBytes)
  limits ← either (Left . LimitsRefused) Right (valueLimits bytes depth elements)
  Right
    M1Requests
      { m1Profile = profile
      , m1Handles = handles
      , m1PerInstance = perInstance
      , m1PerVm = perVm
      , m1Ceiling = count LuaIntegerMaximum
      , m1ReplyLimits = limits
      , m1MessageBytes = message
      , m1PathBytes = path
      }
  where
    count limit = let Count value = countLimit profile limit in value
    bytes' limit = let Bytes value = bytesLimit profile limit in value
    machine name value
      | value <= fromIntegral (maxBound ∷ Int) = Right (fromIntegral value)
      | otherwise = Left (LimitNotRepresentable name)

-- What is asked ----------------------------------------------------------------------------

-- | What a service asks of one request, beside the endpoint and the arguments.
data M1Ask = M1Ask
  { askNecessity ∷ !Necessity
    -- ^ Whether its expected failure fails the instance.
  , askSource ∷ !Text
    -- ^ The attributable source context: what is asked for, recorded with the request.
  , askOffset ∷ !(Maybe Word64)
    -- ^ A logical request's tick offset, positive; 'Nothing' is the default of one. Use
    -- 'offsetFromLua' for the integer a script gave. An owner on arrival takes none.
  , askCodes ∷ ![Text]
    -- ^ The failure codes the service supplies.
  , askCredits ∷ ![Credit]
    -- ^ The provider's credits, reserved with the request.
  , askLease ∷ !(Maybe (Ownership, Value → Word64 → Value))
    -- ^ A result lease to reserve, and how the success value holds the adopted lease's handle (the
    -- service's own shape: a record carrying it, or the handle itself).
  }

-- | A request that asks for nothing beside its requirement and source.
m1Ask ∷ Necessity → Text → M1Ask
m1Ask requirement source = M1Ask requirement source Nothing [] [] Nothing

-- | The offset a script's integer asks for. A zero or negative one is carried as zero, which the
-- admission refuses as not positive; a positive one is carried exactly.
offsetFromLua ∷ Int64 → Word64
offsetFromLua given
  | given <= 0 = 0
  | otherwise = fromIntegral given

-- | The host's admission for a request of this ask under this policy.
m1Admission ∷ M1Requests → M1Ask → Admission
m1Admission m1 ask =
  (admission (askNecessity ask) (askSource ask) (m1ReplyLimits m1) (m1Ceiling m1) (m1PerInstance m1) (m1PerVm m1))
    { admitOffset = askOffset ask
    , admitExpectedCodes = askCodes ask
    , admitMessageBytes = m1MessageBytes m1
    , admitPathBytes = m1PathBytes m1
    , admitCredits = askCredits ask
    , admitLease = fst <$> askLease ask
    , admitCombine = snd <$> askLease ask
    , admitSuccessFrame = m1SuccessFrame
    , admitFailureFrame = m1FailureFrame
    }

-- | The record a script is handed for a success: @{status = "success", value = VALUE}@.
m1SuccessFrame ∷ Value → [(Text, Value)]
m1SuccessFrame value = [("status", VText "success"), ("value", value)]

-- | The record a script is handed for an expected failure: @{status = "failure", error = {code,
-- message, root, path}}@, the root and path only when the failure has them.
m1FailureFrame ∷ ExpectedFailure → [(Text, Value)]
m1FailureFrame found =
  [ ("status", VText "failure")
  , ( "error"
    , VRecord
        ( [("code", VText (expectedCode found)), ("message", VText (expectedMessage found))]
            <> [("root", VText root) | Just root ← [expectedRoot found]]
            <> [("path", VText path) | Just path ← [expectedPath found]]
        )
    )
  ]

-- Asking -----------------------------------------------------------------------------------

-- | What asking came to.
data M1Start
  = -- | Accepted: the request, to be returned to the script.
    M1Accepted !RequestHandle
  | -- | A temporary bank had no room: the bounded message of the busy answer. Nothing was
    -- accepted.
    M1Busy !Text
  | -- | A credit of the endpoint said it can never be had: the bounded reason. Final, unlike busy.
    -- Nothing was accepted.
    M1Refused !Text
  deriving (Eq, Show)

-- | Start a request of this endpoint, atomically: accepted, or busy with nothing reserved.
-- Permanent refusals are the argument check's ('m1ArgumentCheck'), and a call that skipped it
-- meets them here as a fault of the call.
startM1 ∷ HasCallStack ⇒ M1Requests → M1Ask → RequestContext → Text → [Value] → IO () → IO M1Start
startM1 m1 ask context endpoint arguments afterCompletion = do
  started ← startAdmitted context (m1Admission m1 ask) endpoint arguments afterCompletion
  pure $ case started of
    Started handle → M1Accepted handle
    Unavailable bank → M1Busy (busyMessage m1 bank)
    Refused why → M1Refused (clipBytes (m1MessageBytes m1) why)

-- | The bounded message of a busy answer for a bank.
busyMessage ∷ M1Requests → Bank → Text
busyMessage m1 bank = clipBytes (m1MessageBytes m1) ("request capacity is not available: " <> renderBank bank)

-- | The code of a busy answer.
busyCode ∷ Text
busyCode = "busy"

-- | The code of a permanent refusal answer: nothing was accepted and asking again cannot change that.
refusedCode ∷ Text
refusedCode = "refused"

-- | The check a service's request-producing binding makes of its copied arguments, before the action:
-- every permanent fact the admission would refuse (the role's phase, an instance that is ending, an
-- offset that is not positive or passes the ceiling with the tick, request numbers that are
-- exhausted, a lease scope that is not there) as an ordinary Lua error, with no handle and no work.
-- A bank that is merely full is not here: that is busy.
--
-- The service says how the ask is read from the values.
m1ArgumentCheck ∷ M1Requests → ([Value] → M1Ask) → ArgumentCheck
m1ArgumentCheck m1 askOf owner values = case contextRequests owner of
  Nothing → pure Nothing
  Just context → preflightAdmission context (m1Admission m1 (askOf values))

-- | The two values a request-producing binding answers.
m1StartResults ∷ Text → M1Start → [Value]
m1StartResults handleType = \case
  M1Accepted handle → [requestHandleValue handleType handle, VNil]
  M1Busy message → [VNil, VRecord [("code", VText busyCode), ("message", VText message)]]
  M1Refused message → [VNil, VRecord [("code", VText refusedCode), ("message", VText message)]]

-- | The result schemas of a request-producing binding.
m1StartSchemas ∷ Text → [Schema]
m1StartSchemas handleType =
  [SOptional (SCapability handleType), SOptional (SRecord [("code", SText), ("message", SText)])]

-- The common result adapter -------------------------------------------------------------------

-- | What a service says of its requests for the common operations.
data M1Service = M1Service
  { serviceHandleType ∷ !Text
    -- ^ The name of the request handle capability type the registration declares with
    -- 'm1HandleType'.
  , serviceValue ∷ !Schema
    -- ^ What @take@ hands as the success value: after any lease handle is composed in.
  }

-- | The capability type of the request handles: live for the instance that holds the request.
m1HandleType ∷ M1Requests → Text → CapabilityType
m1HandleType m1 = admittedHandleType (m1Handles m1)

-- | The record @take@ answers.
m1TakeSchema ∷ Schema → Schema
m1TakeSchema value = SRecord [("status", SText), ("value", SOptional value), ("error", SOptional m1ErrorSchema)]

-- | The record of a failure.
m1ErrorSchema ∷ Schema
m1ErrorSchema = SRecord [("code", SText), ("message", SText), ("root", SOptional SText), ("path", SOptional SText)]

-- | A terminal result as the fresh record a script is handed.
terminalRecord ∷ Terminal → Value
terminalRecord = \case
  TerminalSuccess value → VRecord (m1SuccessFrame value)
  TerminalFailure found → VRecord (m1FailureFrame found)
  TerminalCancelled → VRecord [("status", VText "cancelled")]

-- | The four operations on a request, to be assembled under @api.request@ by the facade:
-- @ready@, @take@, @cancel@ and @wait@. Each refuses what is wrong with the call before any
-- provider action, as an ordinary Lua error. @wait@ is for an instance that is serving, and refuses
-- in @init@ and @shutdown@ before it waits.
m1RequestBindings ∷ M1Service → [Binding]
m1RequestBindings service =
  [ recoverableRefusals (asynchronousNativeRequestIn "ready" [handle] [SBoolean] ready)
  , recoverableRefusals (asynchronousNativeRequestIn "take" [handle] [m1TakeSchema (serviceValue service)] taken)
  , recoverableRefusals (asynchronousNativeRequestIn "cancel" [handle] [SText] cancelled)
  , withPrecondition serving (waitOperation "wait" WaitSettlement [handle])
  ]
  where
    handle = SCapability (serviceHandleType service)
    ready context = \case
      [VCapability found] → (\settled → [VBoolean settled]) <$> readyAdmitted context (capabilityKey found)
      _ → pure []
    taken context = \case
      [VCapability found] →
        takeAdmitted context (capabilityKey found) >>= \case
          TakenPending → pure [VRecord [("status", VText "pending")]]
          Taken terminal → pure [terminalRecord terminal]
      _ → pure []
    cancelled context = \case
      [VCapability found] →
        cancelAdmitted context (capabilityKey found) >>= \case
          CancelWon → pure [VText "cancelled"]
          CancelAlreadySettled → pure [VText "already_settled"]
      _ → pure []
    serving owner = case contextRequests owner of
      Nothing → pure Nothing
      Just context →
        callerPhase context >>= \case
          Just CallerServing → pure Nothing
          Just CallerInitializing → pure (Just "wait is not available in init")
          Just CallerEnding → pure (Just "wait is not available in shutdown")
          Nothing → pure (Just "wait is made by an instance")

-- Text ---------------------------------------------------------------------------------------

-- | Text cut to at most this many UTF-8 bytes, at a character, with a visible mark when cut.
clipBytes ∷ Int → Text → Text
clipBytes bound text
  | ByteString.length (Encoding.encodeUtf8 text) <= bound = text
  | bound < 3 = Text.empty
  | otherwise = go (bound - 3) text <> "..."
  where
    go room remaining = case Text.uncons remaining of
      Just (character, rest)
        | width character <= room → Text.cons character (go (room - width character) rest)
      _ → Text.empty
    width = ByteString.length . Encoding.encodeUtf8 . Text.singleton
