-- | The arbitration of an open's name (TRA-5), the part of the terrain adapter that decides which open of a name is admitted.
--
-- It is an implementation module of the adapter ("Hetoimasia.LuaEngine.Terrain"), in a private sub-library the adapter and the package's
-- own suite depend on and nothing else can: the suite decides the windows of the arbitration with threads of its own, over the real
-- service, which a Lua script cannot do on every runtime. Nothing here knows a VM, a request or a lease; the adapter hands it the state
-- it arbitrates over ('OpenNames') and the three moments its hooks mark ('ArbitrationHooks').
--
-- The state, its owner, its lifetime: the three components of 'OpenNames' are made once by the facade and shared by every VM of the
-- service; they are read and written by the VM threads that open (under the lock), by the owner's drain and by the forgetting of an
-- instance (the sweeps); they live as long as the facade; the registries hold only what is still open, and are empty once every
-- instance has been forgotten.
module Hetoimasia.LuaEngine.Terrain.Internal.Arbitration
  ( -- * The state
    Claim (..)
  , OpenNames (..)
  , newOpenNames
  , ArbitrationHooks (..)
  , noArbitrationHooks

    -- * The arbitration
  , arbitrateOpen
  , releaseStale
  , registerClaim
  , holdFailedUntil

    -- * Sweeps
  , pruneClaims
  , pruneFailedOpens
  , failedOpenPending
  ) where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
import Control.Monad (filterM, unless)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

-- | An open the service holds a name for: whether the host has settled it without telling the service, and the telling.
data Claim = Claim
  { clStale ∷ STM Bool
  -- ^ The host has settled the request without the service's telling (it was cancelled, or its requester ended) and the service
  -- still holds the claim: whether the offered lease was adopted does not matter, an adopted open is the arena's own claim.
  , clDone ∷ STM Bool
  -- ^ The request reached its end for the adapter: the service answered it (or was told) and no offered lease waits to be adopted.
  , clCancel ∷ IO ()
  }

-- | What the arbitration decides over, shared by every VM of the service.
data OpenNames = OpenNames
  { onClaims ∷ !(TVar (Map Text [Claim]))
  -- ^ The opens in flight, by the service's name: how an open finds, before it asks the service, a claim whose request the host has
  -- already settled as cancelled (the service has not been told yet) and lets it go, so that a name is free from the host's terminal
  -- settlement and not from the later notification.
  , onFailed ∷ !(TVar (Map Text [STM Bool]))
  -- ^ The names of opens the service failed (an invalid definition) whose settlement the host has not made yet (on logical time it is held
  -- for the request's assigned tick), each with whether it is still pending. The service holds no claim for such an open, so the adapter
  -- holds it: another open of the name before the host's settlement is @name_in_use@, as it is while a successful open stands, and the
  -- name is free from the settlement.
  , onLock ∷ !(MVar ())
  -- ^ The facade's opens, one at a time from the release of the stale claims through the service's admission and the registration of the
  -- open's claim: the arbitration of a name.
  }

newOpenNames ∷ IO OpenNames
newOpenNames = OpenNames <$> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newMVar ()

-- | The three moments of an open's arbitration an example may hold at: before the critical section, in it once the open has been found
-- not to be a duplicate, and in it just before the admission. Nothing in production.
data ArbitrationHooks = ArbitrationHooks
  { ahArriving ∷ IO ()
  , ahChecked ∷ IO ()
  , ahSubmitting ∷ IO ()
  }

noArbitrationHooks ∷ ArbitrationHooks
noArbitrationHooks = ArbitrationHooks (pure ()) (pure ()) (pure ())

-- | The arbitration of an open's name: one critical section ('onLock'), in this order: the release of every claim the host has settled as
-- cancelled without the service's being told, the consultation of the opens the service failed, and the admission this action makes (the
-- service's, with the registration of the open's own claim). Answers 'Nothing' for an open that is a duplicate of one the service failed
-- and the host has not yet settled, which is never admitted. Everything under the lock is non-waiting: the service's cancel is a plain
-- transaction that never retries, so no owner and no other VM is waited for inside it.
arbitrateOpen ∷ OpenNames → ArbitrationHooks → Text → IO a → IO (Maybe a)
arbitrateOpen names hooks name admit = do
  ahArriving hooks
  withMVar (onLock names) $ \_ → do
    releaseStale names name
    duplicate ← atomically (failedOpenPending names name)
    if duplicate
      then pure Nothing
      else do
        ahChecked hooks
        ahSubmitting hooks
        Just <$> admit

-- | Let go of the claims on a name whose request the host has already settled without the service being told: the service is told
-- now, which frees the name, before another open asks for it.
releaseStale ∷ OpenNames → Text → IO ()
releaseStale names name = do
  tells ← atomically $ do
    pruneClaims names
    held ← Map.findWithDefault [] name <$> readTVar (onClaims names)
    flags ← mapM clStale held
    pure [clCancel claim | (claim, True) ← zip held flags]
  sequence_ tells

-- | The claim of an open the service admitted: found stale if the host settles the open as cancelled before the service is told. A request
-- that has already ended needs none.
registerClaim ∷ OpenNames → Text → Claim → STM ()
registerClaim names name claim = do
  pruneClaims names
  over ← clDone claim
  unless over (modifyTVar' (onClaims names) (Map.insertWith (<>) name [claim]))

-- | An open the service failed holds its name until the host has settled it. Every entry is gone at its settlement (or its owner's end): the
-- registry is swept whole at each insertion, at every drain and at every forgetting of an instance, and an open the host has settled already
-- is not entered at all, so what it holds is bounded by the failed opens still waiting for their tick, whatever names they used.
holdFailedUntil ∷ OpenNames → Text → STM Bool → STM ()
holdFailedUntil names name hostSettled = do
  pruneFailedOpens names
  settled ← hostSettled
  unless settled (modifyTVar' (onFailed names) (Map.insertWith (<>) name [not <$> hostSettled]))

-- | Forget the claims of requests that have ended, so the registry holds only what is still open: bounded by the opens in flight,
-- whatever came and went, and empty once every instance has been forgotten.
pruneClaims ∷ OpenNames → STM ()
pruneClaims names = do
  held ← readTVar (onClaims names)
  kept ← traverse (filterM (fmap not . clDone)) held
  writeTVar (onClaims names) (Map.filter (not . null) kept)

-- | Forget every failed open the host has settled, of every name.
pruneFailedOpens ∷ OpenNames → STM ()
pruneFailedOpens names = do
  held ← readTVar (onFailed names)
  kept ← traverse (filterM id) held
  writeTVar (onFailed names) (Map.filter (not . null) kept)

-- | Whether an open the service failed is still waiting for the host's settlement of the name.
failedOpenPending ∷ OpenNames → Text → STM Bool
failedOpenPending names name = do
  pruneFailedOpens names
  Map.member name <$> readTVar (onFailed names)
