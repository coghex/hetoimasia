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
  , OpenOptions (..)
  , defaultOpenOptions
  , openArenaWithOptions
  , attachArenaWith
  , cellWith
  , columnWith
  , surfaceWith
  , removeWith
  , knowledgeWith
  , regionsWith
  , growWith
  , retryWith

    -- * Cancelling and retiring
  , cancel
  , retire
  , retireSTM
  , takeSTM
  , TakeOutcome (..)
  , releaseArenaLeaseSTM
  ) where

import Control.Concurrent.STM
import Control.Monad (void)
import Data.Text (Text)
import Hetoimasia.Terrain.Cell (Column, ZRange)
import Hetoimasia.Terrain.Coordinate (RegionCoord, TileCoord)
import Hetoimasia.Terrain.Runtime.Internal.Core
import Hetoimasia.Terrain.Runtime.Internal.Types
import Hetoimasia.Terrain.Source (SourceSpec, mkSource)
import qualified Data.Text as Text
import Hetoimasia.Terrain.Runtime.Store.Internal.State (StoreConfig, StoreSpec (..), mkStoreConfig)

-- | The ordinary endpoint: always eligible, and settled into a box the caller
-- waits on. A second settlement is ignored.
arrivalEndpoint ∷ IO (Endpoint, TMVar Settlement)
arrivalEndpoint = do
  box <- newEmptyTMVarIO
  pure (Endpoint (pure ()) (pure True) (void . tryPutTMVar box), box)

-- | Create a named arena with the service's own allowance ('configStore'): the request settles with the creator's lease. It is
-- 'openArenaWithOptions' with 'defaultOpenOptions'.
openArenaWith ∷ Service → Endpoint → Client → Text → SourceSpec → IO (Either Refused Request)
openArenaWith svc ep client name spec = openArenaWithOptions svc ep client name spec defaultOpenOptions

-- | Create a named arena with what the options name. An allowance the options name is validated by the rules of the service's
-- own ('mkStoreConfig': at least 64 MiB, a whole number of MiB, within the configured offset limit, with room for the protected
-- reserve beside the configured overhead), with the service's other store figures; one that can never be granted is refused
-- here, before admission ('RefusedInvalid'), so no request, name claim, credit or reservation exists. A valid one is the arena's
-- allowance from its reservation on, exactly as the service's own would be.
openArenaWithOptions ∷ Service → Endpoint → Client → Text → SourceSpec → OpenOptions → IO (Either Refused Request)
openArenaWithOptions svc ep client name spec options = case openStoreConfig svc options of
  Left why → pure (Left (RefusedInvalid why))
  Right store →
    atomically . admit svc ep $
      case mkSource (configSourceLimits (serviceConfig svc)) spec of
        Left err → SubOpenInvalid client err
        Right source → SubOpen client name source store

-- | The store configuration an open's options give its arena: the service's own when they name no allowance.
openStoreConfig ∷ Service → OpenOptions → Either Text StoreConfig
openStoreConfig svc options = case openAllowanceBytes options of
  Nothing → Right (serviceStoreConfig svc)
  Just bytes → case mkStoreConfig (configStore (serviceConfig svc)) {specAllowanceBytes = bytes} of
    Left err → Left (Text.pack ("an allowance that can never be granted: " <> show err))
    Right store → Right store

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

-- | What is known of a cell (#661's known solid and known void), read from the arena's store at one
-- committed version and settled like any read: current while its content and knowledge revisions hold.
knowledgeWith ∷ Service → Endpoint → ArenaLease → TileCoord → IO (Either Refused Request)
knowledgeWith svc ep lease tile = atomically (admit svc ep (SubKnowledge lease tile))

-- | A regional terrain-and-knowledge snapshot of some regions (#690), built from one committed version
-- and settled labelled with its identities. Its borrow is the service's until the host takes it
-- ('retire' or 'retireSTM', which take it in the transaction that retires the result), then the host's
-- until it releases it ('Hetoimasia.Terrain.Runtime.releaseRegionBorrow').
regionsWith ∷ Service → Endpoint → ArenaLease → [RegionCoord] → IO (Either Refused Request)
regionsWith svc ep lease regions = atomically (admit svc ep (SubRegions lease regions))

-- | The creator's growth of an arena's allowance to a size in bytes (requirement 9): equal is an
-- idempotent success, smaller settles @storage_size_not_increased@, larger becomes spendable only
-- when the storage backend has obtained it and the decision commits the cap with the result. A
-- size that can never be granted is refused before admission; an attached lease has no authority.
growWith ∷ Service → Endpoint → ArenaLease → Integer → IO (Either Refused Request)
growWith svc ep lease bytes = atomically (admit svc ep (SubGrow lease bytes))

-- | The creator's explicit retry of a paused arena: a bounded revalidation that clears only the
-- cause it verified gone, and never repeats a failed edit. On a ready arena it succeeds idempotently.
retryWith ∷ Service → Endpoint → ArenaLease → IO (Either Refused Request)
retryWith svc ep lease = atomically (admit svc ep (SubRetry lease))

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

-- | Retire a settled request's accepted result and take what it hands over, in one transaction: a
-- regional snapshot's borrow ('Hetoimasia.Terrain.Runtime.requestRegionSnapshot') becomes the host's,
-- charged until the host releases it ('Hetoimasia.Terrain.Runtime.releaseRegionBorrow'), but only while
-- the request still owns it: a borrow released before the take (the request retired, its lease or client
-- ended, its arena or the service closed) is never handed over, and the take answers 'TakeReleased'. A host
-- uses a regional answer only on 'Taken', in the transaction that took it. Plain 'retireSTM' releases a
-- borrow nobody took instead. For any other settled result the two are the same and the take answers
-- 'Taken'.
takeSTM ∷ Service → Request → STM TakeOutcome
takeSTM = takeRequest

-- | 'Hetoimasia.Terrain.Runtime.releaseLease' as a transaction, for a host that gives a lease back from inside one (the Lua host does, for a
-- lease the service made for an open it then settled instead of publishing): the lease is released in that transaction and never left
-- queued for a later call. The same release, idempotent, and a lease of another service is refused.
releaseArenaLeaseSTM ∷ Service → ArenaLease → STM (Either Refused ())
releaseArenaLeaseSTM svc (ArenaLease tag lid)
  | tag /= serviceTag svc = pure (Left RefusedAuthority)
  | otherwise = Right <$> releaseLeaseSTM svc lid
