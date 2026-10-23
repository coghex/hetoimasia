-- | What a binding's action needs to reach the owner's request service: the service its context
-- names, who is calling, the refusal that is a fault of the call, a request's handle, and the
-- handle registry an application gives its owner so that a handle's liveness is answered for the
-- instance that holds it.
--
-- This is a hidden module of the adapter: "Hetoimasia.Scripting.Lua.Request" is a binding
-- author's view of the generic requests and "Hetoimasia.Scripting.Lua.Admission" of the opt-in ones;
-- both are built from here.
module Hetoimasia.Scripting.Lua.Provider.Call
  ( -- * The handle
    RequestHandle (..)
  , handleNumber

    -- * Reaching the service
  , serviceOf
  , requesterIn
  , refuse
  , refuseOrdinarily
  , infoFor

    -- * Handle liveness
  , RequestHandles
  , RequestHandlesRefused (..)
  , newRequestHandles
  , bindRequestHandles
  , handleLive
  ) where

import Control.Concurrent.STM (atomically, readTVar)
import Control.Exception (Exception, throwIO)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (operation, throwFailure)
import Hetoimasia.Scripting.Lua.Instance.Types (InstanceId (InstanceId))
import Hetoimasia.Scripting.Lua.Internal.Fault (CallRefusal (CallRefusal), OrdinaryCallRefusal (OrdinaryCallRefusal))
import Hetoimasia.Scripting.Lua.Provider.State
import Hetoimasia.Scripting.Lua.Provider.Types
import Hetoimasia.Scripting.Lua.Registration (RequestContext, fromRequestContext)
import Hetoimasia.Scripting.Lua.Runtime.Shared (runtimeComponent)

-- | A request's handle: its number, which is unique to its owner and never reissued.
newtype RequestHandle = RequestHandle Word64
  deriving (Eq, Ord, Show)

-- | The request's number.
handleNumber ∷ RequestHandle → Word64
handleNumber (RequestHandle number) = number

-- | The service of the owner whose script called, read from the engine's own context. A
-- context that is not an owner's request service is the application's misuse of the library.
serviceOf ∷ HasCallStack ⇒ RequestContext → IO ProviderState
serviceOf context = case fromRequestContext context of
  Just service → pure service
  Nothing → throwFailure runtimeComponent (operation "request-context") [] (userError "the request context is not a request service")

-- | Refuse the call, as the engine: a fault of the call and not a failure of the
-- application's code.
refuse ∷ RequestRefusal → IO a
refuse = throwIO . CallRefusal . renderRequestRefusal

-- | Refuse the call, as the engine, with a refusal that is final and not a fault: for a binding opted in
-- to ordinary refusals Lua sees an ordinary error it may catch and go on from, for any other binding it
-- is the fault of the call 'refuse' raises.
refuseOrdinarily ∷ RequestRefusal → IO a
refuseOrdinarily = throwIO . OrdinaryCallRefusal . renderRequestRefusal

-- | Who is calling, or the refusal that nobody is.
requesterIn ∷ ProviderState → IO Requester
requesterIn service = do
  caller ← atomically (callerOf service)
  maybe (refuse NoRequester) pure (requesterOf caller)

-- | What a request is, for the application's assignment and for the provider.
infoFor ∷ ProviderState → Requester → Text → Word64 → RequestInfo
infoFor service requester name number =
  RequestInfo
    { infoOwner = psOwner service
    , infoInstance = case requester of
        RequesterInstance local → Just (InstanceId (psOwner service) local)
        RequesterTask _ → Nothing
    , infoEndpoint = name
    , infoNumber = number
    , infoNecessity = Nothing
    , infoSource = Nothing
    , infoOffset = Nothing
    , infoDue = Nothing
    }

-- | What an application gives an owner so that a request handle's liveness is answered for the
-- instance that holds it: made before the owner, closed over by the handle type its registration
-- declares, and bound by the owner when it is created, as the leases are. A handle serves one
-- owner.
newtype RequestHandles = RequestHandles (IORef (Maybe ProviderState))

-- | A request handle registry was refused when its owner was created, and nothing was made.
newtype RequestHandlesRefused = RequestHandlesRefused Text
  deriving (Eq, Show)

instance Exception RequestHandlesRefused

-- | A registry no owner has taken. Until one has, every handle is dead.
newRequestHandles ∷ IO RequestHandles
newRequestHandles = RequestHandles <$> newIORef Nothing

-- | The owner takes the registry. Answers whether it was free: a registry serves one owner.
bindRequestHandles ∷ RequestHandles → ProviderState → IO Bool
bindRequestHandles (RequestHandles var) service =
  -- One atomic step: of any number of owners that claim the registry together exactly one wins.
  atomicModifyIORef' var $ \held → case held of
    Just _ → (held, False)
    Nothing → (Just service, True)

-- | Whether a handle names a request the running instance holds: it exists (its settlement has
-- not been taken, its requester has not ended) and it is the caller's. A handle that is another
-- instance's, was consumed, was never issued or is used where no instance runs is not live.
handleLive ∷ RequestHandles → Word64 → IO Bool
handleLive (RequestHandles var) key =
  readIORef var >>= \case
    Nothing → pure False
    Just service → atomically $ do
      caller ← callerOf service
      case requesterOf caller of
        Nothing → pure False
        Just requester → do
          st ← readTVar (psVar service)
          pure $ case Map.lookup key (pByNumber st) >>= \identity → Map.lookup identity (pRecs st) of
            Just record → recRequester record == requester
            Nothing → False
