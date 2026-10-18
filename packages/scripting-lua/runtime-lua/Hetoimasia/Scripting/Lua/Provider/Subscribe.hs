-- | What a script's @api.subscribe@ and @api.unsubscribe@ do on the owner's side (LUA-26).
--
-- A script subscribes a function to an event endpoint its instance was granted, and the engine
-- keeps the subscription as a record of the instance, beside its connections. A producer
-- delivers to it from any thread, through the 'EventFeed' it was handed, and never calls Lua:
-- the delivery places a reference in the instance's queue, and the owner looks up the callback
-- when it services it.
--
-- Every call into provider code goes through the one guard ('guarded'), as a request's does, and
-- is fully evaluated inside it: handing a subscription over, withdrawing interest and reading
-- its retirement are the owner's, with the same claim-then-tell, and a delivery is checked on the
-- producer's thread inside it too.
--
-- = What a failure is
--
-- * Provider code raising when it is handed a subscription is a failure of application code: a
--   failure of the host under the owner's policy, unconverted, and the subscription is taken
--   back as though it had never been admitted.
-- * A provider told that interest was withdrawn that raises is the same, raised with the others
--   kept whole as evidence ('raiseAmong').
-- * A provider's retirement that fails is a cleanup failure, retained on the work, never
--   retried, fatal under every policy.
module Hetoimasia.Scripting.Lua.Provider.Subscribe
  ( subscribeTo
  , unsubscribeFrom
  , serviceFromContext
  ) where

import Control.Concurrent.STM (atomically)
import Control.Exception (mask, mask_, rethrowIO, throwIO)
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Instance.Types (InstanceId (InstanceId))
import Hetoimasia.Scripting.Lua.Internal.Fault (CallRefusal (CallRefusal))
import Hetoimasia.Scripting.Lua.Provider.Events
  ( AdmittedSub (..)
  , admitSubscription
  , checkEvent
  , commitSubscribed
  , deliverChecked
  , failDelivery
  , unsubscribeOf
  , withdrawSubscription
  )
import Hetoimasia.Scripting.Lua.Provider.Serve (guarded, raiseAmong, tellProviders)
import Hetoimasia.Scripting.Lua.Provider.State (Caller (CallerInstance), callerOf)
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Registration (RequestContext, fromRequestContext)
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)

-- | The service of the owner whose script called, read from the engine's own context. A context
-- that is not an owner's request service is the application's misuse of the library.
serviceFromContext ∷ HasCallStack ⇒ RequestContext → IO ProviderState
serviceFromContext context = case fromRequestContext context of
  Just service → pure service
  Nothing → throwFailure runtimeComponent (operation "request-context") [] (userError "the request context is not a request service")

-- | Refuse the call, as the engine: a fault of the call and not a failure of the application's
-- code.
refuse ∷ SubscribeRefusal → IO a
refuse = throwIO . CallRefusal . renderSubscribeRefusal

-- | The instance whose code is calling, or the refusal that none is. Only an instance
-- subscribes, and only for itself: the slot a script's call names is checked against the
-- instance the owner is running.
subscriberIn ∷ ProviderState → Word64 → IO Word64
subscriberIn service slot = do
  caller ← atomically (callerOf service)
  case caller of
    CallerInstance number | number == slot → pure number
    _ → refuse NoSubscriber

-- | Subscribe the calling instance to an endpoint and answer the subscription's number.
--
-- The place is reserved, and the owner's checks are made, before the provider is asked
-- anything; the provider is then handed the subscription and the feed it delivers through.
-- Refused, as a fault of the call, when no instance's code is running, when the owner or the
-- instance is no longer taking subscriptions, when the endpoint is not one the instance was
-- granted, and when every place is held; the provider is asked nothing of a refused one. A
-- provider that raises when it is handed the subscription is a failure of the host.
subscribeTo ∷ HasCallStack ⇒ RequestContext → Word64 → Text → IO Word64
subscribeTo context slot name = do
  service ← serviceFromContext context
  instanceNumber ← subscriberIn service slot
  mask $ \restore → do
    admitted ← atomically (admitSubscription service instanceNumber name)
    (AdmittedSub number identity, endpoint) ← either refuse pure admitted
    let feed =
          EventFeed
            { feedDeliver = \slotOf value → do
                checked ← checkEvent (psLimits service) endpoint value
                atomically (deliverChecked service identity slotOf checked)
            , feedFail = \reason → atomically (failDelivery service identity reason)
            }
        info =
          SubscriptionInfo
            { subscriptionOwner = psOwner service
            , subscriptionInstance = InstanceId (psOwner service) instanceNumber
            , subscriptionEndpoint = name
            , subscriptionNumber = number
            }
    handed ← guarded (restore (eventSubscribe endpoint (EventSubscription feed info)))
    case handed of
      Left failure → do
        atomically (withdrawSubscription service identity)
        rethrowIO failure
      Right provided → do
        atomically (commitSubscribed service identity provided)
        -- A subscription ended while the provider was being handed it has interest to withdraw
        -- now that there is a provider to tell.
        raiseAmong "lua subscription cancel" =<< tellProviders service
        pure number

-- | End the calling instance's subscription of this number. Answers whether it ended a live one;
-- a number that names none is not an error. Interest in the provider's work is withdrawn and the
-- provider told, once; a provider that raises when told is a failure of the host.
unsubscribeFrom ∷ HasCallStack ⇒ RequestContext → Word64 → Word64 → IO Bool
unsubscribeFrom context slot number = do
  service ← serviceFromContext context
  instanceNumber ← subscriberIn service slot
  ended ← atomically (unsubscribeOf service instanceNumber number)
  -- The claim and the raising of what the provider raised are one masked step.
  mask_ (raiseAmong "lua subscription cancel" =<< tellProviders service)
  pure ended
