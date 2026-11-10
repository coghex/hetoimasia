-- | The adapter seam: how a host takes part in the service's arbitration.
--
-- A host (the Lua request endpoint of TRA-5, a test fixture) supplies an
-- 'Endpoint' with each request. The service stages work, tells the endpoint it
-- is ready, waits for the endpoint to be eligible, and then commits the content
-- change and the terminal 'Settlement' in one transaction that also decides
-- cancellation, the parent session's admission and the arena's closure. There
-- is one winner: after a commit, 'cancel' answers 'AlreadySettled'; after a
-- cancellation, nothing was committed.
--
-- The three endpoint operations are distinct. 'endpointReady' announces staged
-- work, 'endpointEligible' is the host's grant, and 'endpointSettle' is the
-- terminal delivery, run inside the arbitrating transaction so it is atomic
-- with the commit. Do not run an ordinary IO completion after a commit and call
-- that atomic.
module Hetoimasia.Terrain.Runtime.Settlement
  ( -- * The seam
    Endpoint (..)
  , Settlement (..)
  , CancelResult (..)
  , arrivalEndpoint

    -- * Admitting with an endpoint
  , openArenaWith
  , attachArenaWith
  , cellWith
  , columnWith
  , surfaceWith
  , removeWith

    -- * Cancelling and retiring
  , cancel
  , retire
  , retireSTM
  , releaseArenaLeaseSTM
  ) where

import Control.Concurrent.STM
import Control.Monad (void)
import Data.Text (Text)
import Hetoimasia.Terrain.Cell (Column, ZRange)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Source (SourceSpec, mkSource)

-- | The ordinary endpoint: always eligible, and settled into a box the caller
-- waits on. A second settlement is ignored.
arrivalEndpoint ∷ IO (Endpoint, TMVar Settlement)
arrivalEndpoint = do
  box <- newEmptyTMVarIO
  pure (Endpoint (pure ()) (pure True) (void . tryPutTMVar box), box)

-- | Create a named arena: the request settles with the creator's lease.
openArenaWith ∷ Service → Endpoint → Client → Text → SourceSpec → IO (Either Refused Request)
openArenaWith svc ep client name spec =
  atomically . admit svc ep $
    case mkSource (configSourceLimits (serviceConfig svc)) spec of
      Left err → SubOpenInvalid client err
      Right source → SubOpen client name source

-- | Obtain a lease on an existing arena of the same service, by name.
attachArenaWith ∷ Service → Endpoint → Client → Text → IO (Either Refused Request)
attachArenaWith svc ep client name = atomically (admit svc ep (SubAttach client name))

cellWith ∷ Service → Endpoint → ArenaLease → TileCoord → IO (Either Refused Request)
cellWith svc ep lease tile = atomically (admit svc ep (SubCell lease tile))

columnWith ∷ Service → Endpoint → ArenaLease → Column → ZRange → IO (Either Refused Request)
columnWith svc ep lease column range = atomically (admit svc ep (SubColumn lease column range))

surfaceWith ∷ Service → Endpoint → ArenaLease → Column → IO (Either Refused Request)
surfaceWith svc ep lease column = atomically (admit svc ep (SubSurface lease column))

removeWith ∷ Service → Endpoint → ArenaLease → TileCoord → Maybe Precondition → IO (Either Refused Request)
removeWith svc ep lease tile precondition = atomically (admit svc ep (SubRemove lease tile precondition))

-- | Cancel a request. If it has not settled, cancellation wins and nothing is
-- committed; if its commit won, this answers 'AlreadySettled' and cannot undo it.
cancel ∷ Service → Request → IO CancelResult
cancel svc request = atomically (cancelRequest svc request)

-- | Retire a settled request's accepted result, returning the credits it holds.
-- The ordinary 'Hetoimasia.Terrain.Runtime.await' does this itself.
retire ∷ Service → Request → IO ()
retire svc request = atomically (retireRequest svc request)

-- | 'retire' as a transaction, for a host whose own release of the request's result is made in one (the Lua host gives a request's credit back
-- in the transaction that takes the result or accounts its work, on whichever thread does): the retirement is then part of that release, never
-- left queued for a later call. The same function, writing the same state; it does nothing for a request that is not settled.
retireSTM ∷ Service → Request → STM ()
retireSTM = retireRequest

-- | 'Hetoimasia.Terrain.Runtime.releaseLease' as a transaction, for a host that gives a lease back from inside one (the Lua host does, for a
-- lease the service made for an open it then settled instead of publishing): the lease is released in that transaction and never left
-- queued for a later call. The same release, idempotent, and a lease of another service is refused.
releaseArenaLeaseSTM ∷ Service → ArenaLease → STM (Either Refused ())
releaseArenaLeaseSTM svc (ArenaLease tag lid)
  | tag /= serviceTag svc = pure (Left RefusedAuthority)
  | otherwise = Right <$> releaseLeaseSTM svc lid
