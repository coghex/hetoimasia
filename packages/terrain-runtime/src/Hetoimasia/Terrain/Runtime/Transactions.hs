-- | The terrain runtime as an issuer of ownership transactions (#714): the concrete operations a terrain view composes
-- into its own commits, and the view's sealed requests.
--
-- Each operation here is one of the service's own, over its existing state, embedded through the issuer bridge
-- ("Hetoimasia.Foundation.OwnerTx.Issuer"). Each reads only the service's own cells and the parent session's
-- read-only token, validates before it writes, answers a refusal as data, and finishes without waiting or raising: a
-- view composes it with its own operations in one 'Hetoimasia.Foundation.OwnerTx.commit', and no caller code runs
-- inside it.
--
-- __View requests.__ A view never supplies an 'Hetoimasia.Terrain.Runtime.Settlement.Endpoint'. 'requestViewRegions'
-- and 'requestViewSurface' build the request's endpoint here: ready is a no-op, eligibility is always granted, and
-- settlement is a non-waiting put into the request's own result box, inside the service's arbitrating transaction.
-- The view observes that box ('viewRequestSettled', a waiting read outside any commit) and then commits a decision
-- by the request handle alone: 'takeViewRequestTx' hands a regional borrow over, while the request still owns it;
-- 'retireViewRequestTx' releases one nobody took. Hosts of TRA-5 keep the endpoint seam of
-- "Hetoimasia.Terrain.Runtime.Settlement" as it was.
--
-- __State.__ The module owns none: a 'ViewRequest' holds the service's request and its result box, written only by
-- that request's settlement.
module Hetoimasia.Terrain.Runtime.Transactions
  ( -- * Demand and borrows
    setViewDemandTx
  , releaseRegionBorrowTx
  , inspectArenaTx
  , authorityEpochTx

    -- * View requests
  , ViewRequest
  , requestViewRegions
  , requestViewSurface
  , viewRequestSettled
  , takeViewRequestTx
  , retireViewRequestTx
  , cancelViewRequest
  ) where

import Control.Concurrent.STM (STM, TMVar, atomically, newEmptyTMVarIO, tryPutTMVar, tryReadTMVar)
import Control.Monad (void)
import Data.Word (Word64)
import Hetoimasia.Foundation.OwnerTx (OwnerTx)
import Hetoimasia.Foundation.OwnerTx.Issuer (fromIssuerSTM)
import Hetoimasia.Terrain.Cell (Column)
import Hetoimasia.Terrain.Coordinate (RegionCoord)
import Hetoimasia.Terrain.Residency (RegionDemand)
import Hetoimasia.Terrain.Runtime (ArenaView, DemandReceipt, authorityEpochSTM, inspectArenaSTM)
import Hetoimasia.Terrain.Runtime.Internal.Core (TakeOutcome, cancelRequest, releaseRegionBorrowSTM, retireRequest, setViewDemandSTM, takeRequest)
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Runtime.Settlement (regionsWith, surfaceWith)

-- | Install, replace or clear (an empty list) a view's demand ('Hetoimasia.Terrain.Runtime.setViewDemand'), checking
-- the parent session's token in the same commit: a closed session refuses it and changes nothing.
setViewDemandTx ∷ Service → View → ArenaLease → [RegionDemand] → OwnerTx (Either Refused DemandReceipt)
setViewDemandTx svc view lease demands = fromIssuerSTM (setViewDemandSTM svc view lease demands)

-- | Give back a regional borrow the holder took ('Hetoimasia.Terrain.Runtime.releaseRegionBorrow'). Idempotent.
releaseRegionBorrowTx ∷ Service → RegionBorrow → OwnerTx ()
releaseRegionBorrowTx svc borrow = fromIssuerSTM (releaseRegionBorrowSTM svc borrow)

-- | The arena a live lease names, as it stands in this commit ('Hetoimasia.Terrain.Runtime.inspectArena').
inspectArenaTx ∷ Service → ArenaLease → OwnerTx (Maybe ArenaView)
inspectArenaTx svc lease = fromIssuerSTM (inspectArenaSTM svc lease)

-- | The service's authority epoch, as it stands in this commit.
authorityEpochTx ∷ Service → OwnerTx Word64
authorityEpochTx svc = fromIssuerSTM (authorityEpochSTM svc)

-- | A view's request: the service's request and the result box its own endpoint settles into.
data ViewRequest = ViewRequest !Request !(TMVar Settlement)

instance Eq ViewRequest where
  ViewRequest left _ == ViewRequest right _ = left == right

-- | Ask for a regional snapshot of these regions for a view ('Hetoimasia.Terrain.Runtime.requestRegionSnapshot'),
-- with the service's own endpoint.
requestViewRegions ∷ Service → ArenaLease → [RegionCoord] → IO (Either Refused ViewRequest)
requestViewRegions svc lease regions = sealed (\endpoint → regionsWith svc endpoint lease regions)

-- | Ask for a column's surface for a view ('Hetoimasia.Terrain.Runtime.surfaceAt'), with the service's own endpoint.
requestViewSurface ∷ Service → ArenaLease → Column → IO (Either Refused ViewRequest)
requestViewSurface svc lease column = sealed (\endpoint → surfaceWith svc endpoint lease column)

sealed ∷ (Endpoint → IO (Either Refused Request)) → IO (Either Refused ViewRequest)
sealed submit = do
  box ← newEmptyTMVarIO
  -- ready is a no-op, eligibility is always granted, and settlement is a non-waiting put into the box
  fmap (`ViewRequest` box) <$> submit (Endpoint (pure ()) (pure True) (void . tryPutTMVar box) Nothing)

-- | The request's settlement once it has one: a read of its box, for a watcher to wait on outside any commit.
viewRequestSettled ∷ ViewRequest → STM (Maybe Settlement)
viewRequestSettled (ViewRequest _ box) = tryReadTMVar box

-- | Retire a settled request and take what it hands over, in this commit
-- ('Hetoimasia.Terrain.Runtime.Settlement.takeSTM'): a regional borrow becomes the view's, charged until it releases
-- it, while the request still owns it; one released first (the lease, client, arena or service ended) answers
-- 'TakeReleased' and is never handed over.
takeViewRequestTx ∷ Service → ViewRequest → OwnerTx TakeOutcome
takeViewRequestTx svc (ViewRequest request _) = fromIssuerSTM (takeRequest svc request)

-- | Retire a settled request, releasing any borrow nobody took ('Hetoimasia.Terrain.Runtime.Settlement.retireSTM').
retireViewRequestTx ∷ Service → ViewRequest → OwnerTx ()
retireViewRequestTx svc (ViewRequest request _) = fromIssuerSTM (retireRequest svc request)

-- | Cancel a request ('Hetoimasia.Terrain.Runtime.Settlement.cancel'): it wins unless the request already settled.
cancelViewRequest ∷ Service → ViewRequest → IO CancelResult
cancelViewRequest svc (ViewRequest request _) = atomically (cancelRequest svc request)
