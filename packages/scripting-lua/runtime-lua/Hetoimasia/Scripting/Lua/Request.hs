-- | Asynchronous requests, as a binding's author uses them (LUA-7).
--
-- A script asks for something an engine operation will answer later, without blocking its
-- owner and without a provider's thread ever entering Lua. The binding that asks is the
-- application's own ('startRequest'); the operations a script uses on what it was handed are
-- supplied here ('requestBindings'), and a script can wait for its request without blocking
-- ('wait'). "Hetoimasia.Scripting.Lua.Provider" says how the owner is granted the service,
-- what a provider implements, and what the application controls.
--
-- = What a script sees
--
-- @startRequest@ gives the binding a 'RequestHandle', which the binding returns as a
-- capability of the type it declared ('requestHandleValue'). A handle carries no authority: it
-- names a request of the instance, or task, that made it, and nothing else. The calls are:
--
-- * @ready(h)@, a boolean, without blocking: whether the request has settled;
-- * @take(h)@, once, a record @{status, value, reason}@: @status@ is @"pending"@ when it has
--   not settled (nothing was taken), and otherwise @"result"@ with the @value@, @"failure"@
--   with the provider's @reason@, or @"cancelled"@ with the cause; taking a settlement retires
--   the handle;
-- * @cancel(h)@, @"cancelled"@, or @"settled"@ when the request settled first and keeps its
--   settlement;
-- * @wait(h)@, which gives control back until the request has settled, cooperatively; it
--   returns once the settlement is there to take.
--
-- A handle that is another requester's, or whose settlement was taken, or whose requester
-- ended, is refused as a fault of the call, never run: this is how a stale handle is told. The
-- capability type's own check cannot say it (a registration is shared by owners with different
-- services and cannot know whose a handle is), so each of these calls does.
--
-- = Admission and refusal
--
-- @startRequest@ never blocks. It is allowed in any invocation of an instance that is taking
-- requests, @init@ included, and from a task's segment. It reserves the request's place before
-- the provider is asked anything, and is refused, as a fault of the call and never a failure of
-- the host, when no instance or task is running to receive the answer, when the owner or the
-- instance is no longer taking requests (it is stopping: a @shutdown@ hook and a coroutine's
-- closing handlers are past that), when the application assigned the request no place or one
-- that has begun or is taken, and when every place is held. The provider is asked nothing of a
-- request that is refused.
--
-- = Whose a request is
--
-- An instance owns its requests, not the invocation that made them: they survive that
-- invocation's end until their settlement is taken, they are cancelled, or the instance ends.
-- A task of the owner that is no instance's invocation owns its own until it ends. Ending
-- revokes them, each settling once, and the providers are told; a provider's work is
-- accounted until it proves it over, and the instance's settlement waits for that.
module Hetoimasia.Scripting.Lua.Request
  ( -- * Starting a request
    RequestHandle
  , handleNumber
  , startRequest
  , requestHandleValue
  , requestHandleType

    -- * What a script calls
  , requestBindings
  , requestNamespace

    -- * For the owner
  , requestContextOf
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask, mask_, rethrowIO)
import Control.Monad (unless, void)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Provider.Call (RequestHandle (RequestHandle), handleNumber, infoFor, refuse, requesterIn, serviceOf)
import Hetoimasia.Scripting.Lua.Provider.Serve (guarded, raiseAmong, tellProviders)
import Hetoimasia.Scripting.Lua.Provider.State
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Registration
  ( Binding
  , CapabilityType
  , Namespace
  , RequestContext
  , WaitKind (WaitSettlement)
  , asynchronousNativeRequestIn
  , capabilityType
  , namespace
  , requestContext
  , waitOperation
  )
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)
import Hetoimasia.Scripting.Lua.Value (Schema (..), Value (..), capability, capabilityKey)

-- | The capability a script is handed for a request, of the declared type.
requestHandleValue ∷ Text → RequestHandle → Value
requestHandleValue typeName (RequestHandle number) = VCapability (capability typeName number)

-- | A capability type for request handles, named.
--
-- It says every handle is live: a registration is shared by owners with different request
-- services, and cannot know whose a handle is. The calls that take a handle refuse one that
-- is stale, or another requester's, themselves.
requestHandleType ∷ Text → CapabilityType
requestHandleType name = capabilityType name (const (pure True))

-- | What the owner's configuration carries so that its asynchronous requests are delivered.
requestContextOf ∷ ProviderState → RequestContext
requestContextOf = requestContext

-- | Start a request of this endpoint and give the binding its handle.
--
-- The place is reserved, and the owner's checks are made, before the provider is asked
-- anything; the provider is then handed the arguments, which the binding has already
-- checked, and a 'Completion'. @afterCompletion@ is what the request's work needs, disposed of
-- once the provider has proved the work over, on the owner's thread and uninterruptibly, and
-- never if the provider's retirement failed: a borrowed dependency stays alive until then,
-- whatever became of the script's interest.
--
-- Refused as a fault of the call for every reason in the module header. An endpoint the
-- grant does not name is the application's own mistake and a failure of the host. A provider
-- that raises when it is handed the request is a failure of the host, unconverted, and the
-- request is taken back as though it had never been admitted.
startRequest ∷ HasCallStack ⇒ RequestContext → Text → [Value] → IO () → IO RequestHandle
startRequest context name arguments afterCompletion = do
  service ← serviceOf context
  endpoint ← case Map.lookup name (psEndpoints service) of
    Just found → pure found
    Nothing → throwFailure runtimeComponent (operation "start-request") [("endpoint", name)] (userError "the grant names no such endpoint")
  requester ← requesterIn service
  -- A request refused as closed asks nobody anything: not the application's assignment either.
  taking ← atomically (admissible service requester)
  unless taking (refuse RequestsClosed)
  placement ← placementFor service requester name
  mask $ \restore → do
    admitted ← atomically (admit service requester endpoint placement)
    found ← either refuse pure admitted
    let info = infoFor service requester name (admittedNumber found)
        completion = Completion $ \reply → do
          checked ← checkReply (psLimits service) (endpointResult endpoint) reply
          atomically (replyTo service (admittedIdentity found) checked)
    handed ← guarded (restore (endpointSubmit endpoint (Submission arguments completion info (settledNumber service (admittedNumber found)))))
    case handed of
      Left failure → do
        void (atomically (withdrawAdmission service (admittedIdentity found)))
        rethrowIO failure
      Right provided → do
        atomically (commitSubmitted service (admittedIdentity found) provided [afterCompletion])
        -- A request revoked while the provider was being handed it has interest to withdraw
        -- now that there is a provider to tell.
        raiseAmong "lua request cancel" =<< tellProviders service
        pure (RequestHandle (admittedNumber found))

-- | Where the application places the request, for an owner that settles at assigned ticks: its
-- assignment, run here on the caller's thread before the request is admitted, inside the one
-- guard and evaluated; what it raises is a failure of the host.
placementFor ∷ ProviderState → Requester → Text → IO Placement
placementFor service requester name = case psTiming service of
  SettleOnArrival → pure PlaceByDefault
  SettleAtAssignedTick Nothing → pure PlaceByDefault
  SettleAtAssignedTick (Just assign) → do
    number ← atomically (peekNumber service)
    placed ← guarded (assign (infoFor service requester name number) >>= \answer → maybe (pure answer) (\slot → slot `seq` pure answer) answer)
    either rethrowIO (pure . maybe PlaceDeclined PlaceAt) placed

-- What a script calls ----------------------------------------------------------------------

-- | The namespace of 'requestBindings', named by the application.
requestNamespace ∷ Text → Text → Schema → Namespace
requestNamespace name handleType result = namespace name (requestBindings handleType result)

-- | The bindings a script uses on a request: @ready@, @take@, @cancel@ and @wait@, for
-- handles of this capability type, @take@ answering a result of this schema.
--
-- The schema is what the endpoints that answer these requests declare their results to be:
-- they are checked against it before they are retained, so a result a script takes always
-- conforms. All of them are asynchronous requests in the registration's sense, so none can be
-- eligible for a finalizer, and an owner with no request service answers all of them as not yet
-- supported.
requestBindings ∷ Text → Schema → [Binding]
requestBindings handleType result =
  [ asynchronousNativeRequestIn "ready" [SCapability handleType] [SBoolean] ready
  , asynchronousNativeRequestIn "take" [SCapability handleType] [takenSchema] taken
  , asynchronousNativeRequestIn "cancel" [SCapability handleType] [SText] cancelled
  , waitOperation "wait" WaitSettlement [SCapability handleType]
  ]
  where
    takenSchema = SRecord [("status", SText), ("value", SOptional result), ("reason", SOptional SText)]

    ready context = \case
      [VCapability handle] → do
        service ← serviceOf context
        requester ← requesterIn service
        answer ← atomically (readyOf service requester (capabilityKey handle))
        either refuse (\settled → pure [VBoolean settled]) answer
      _ → refuse RequestEnded

    taken context = \case
      [VCapability handle] → do
        service ← serviceOf context
        requester ← requesterIn service
        answer ← atomically (takeOf service requester (capabilityKey handle))
        case answer of
          TakeRefused why → refuse why
          TakePending → pure [VRecord [("status", VText "pending")]]
          TakeSettled settlement → pure [VRecord (deliverable (psLimits service) result settlement)]
      _ → refuse RequestEnded

    cancelled context = \case
      [VCapability handle] → do
        service ← serviceOf context
        requester ← requesterIn service
        answer ← atomically (cancelOf service requester (capabilityKey handle))
        -- A provider that raises when told is a failure of application code, raised from the
        -- action as any other is.
        case answer of
          CancelRefused why → refuse why
          CancelTooLate → pure [VText "settled"]
          Cancelled → do
            -- The claim and the raising of what the provider raised are one masked step.
            mask_ (raiseAmong "lua request cancel" =<< tellProviders service)
            pure [VText "cancelled"]
      _ → refuse RequestEnded
