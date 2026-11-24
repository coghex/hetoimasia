{-# LANGUAGE OverloadedStrings #-}

-- | The terrain operations of the M1 Lua facade (TRA-5), composed over the real terrain service (TRA-4, @hetoimasia-terrain-runtime@).
--
-- = What this is
--
-- The CPU facade ("Hetoimasia.LuaEngine.Facade") owns every Lua-visible rule of @api.terrain@: who may call, in which role and
-- phase, with what arguments, and what an ordinary error is. It imports no terrain module and is handed 'TerrainServices',
-- abstract operations. This module is the concrete composition of those operations over a terrain 'Service' and nothing else:
-- 'terrainInjection' is the value a session is composed with ('Hetoimasia.LuaEngine.Session.sxTerrain'), and the session calls
-- it once for each role's VM. Neither terrain library imports Lua, and the generic Lua host imports no terrain module.
--
-- = Who owns what
--
-- * The terrain 'Service', its owner thread and everything under it are the /assembly's/: borrowed here, made before the session
--   and closed after it. A session never closes it.
-- * A VM's /lending and lease scope/ are the session's (one for the VM, shared with graphics when it is injected); the terrain
--   leases are charged in it, with a capacity derived from the service's lease cap ('terrainLeaseCapacity').
-- * An instance's /terrain client/ is registered when the facade declares the instance and ended when the facade forgets it.
--   The table that holds them is written by the declaring thread and read by the instance's owner thread, in STM.
-- * A /name/ is local to its session and content root: the adapter prefixes the service's one name table with the session and
--   the instance's root, so a name opened under another root or session is not found, and the miss reveals nothing.
--
-- = Requests, settlement and cancellation
--
-- Every terrain request is admitted by the host's opt-in admission first (request places, the result lease where one is
-- reserved, the session's gate), and the service is handed the request after it, in the one masked hand-off. When the service
-- refuses it as busy the hand-off declines ('DeclinedBusy'), and the host takes the whole admission back (no handle, no lease,
-- no credit left); a permanent refusal that arrived since the argument check is declined the same way and read by the script
-- as an ordinary error. The service's own admission is atomic: a refused request creates no request, work, name claim or edit.
--
-- The service's settlement seam is attached to the host's: the service reads the request's eligibility ('settlingEligible') and
-- delivers its terminal outcome ('settlingSettle') in the one transaction that commits an edit and decides cancellation, the
-- parent session's admission and the arena's closure, so exactly one of a script's cancel and the commit wins. Nothing here runs
-- Lua or terrain IO inside the host's STM, waits for the terrain owner on a Lua thread, or calls another VM.
--
-- = The lease
--
-- A successful open or attach offers the service's lease to the request; the host builds it into the lease the request reserved
-- (the adoption), on the owner's thread, and only then settles the result. A request cancelled or ended between the offer and the
-- adoption leaves the offered lease with this adapter, which releases it when the host withdraws its interest, so no arena, name
-- or lease is left to Lua's collection, a finalizer or a successful @take@. Releasing a lease reaches the service's non-waiting
-- release: the creator's final owner lease closes the arena and cancels its requests; an attachment ends only its client's interest.
module Hetoimasia.LuaEngine.Terrain
  ( -- * Composing
    TerrainFacade (..)
  , newTerrainFacade
  , TerrainHooks (..)
  , noTerrainHooks
  , terrainInjection
  , terrainInjectionWithArena
  , terrainLeaseCapacity
  , TerrainCompositionRefused (..)
  , terrainCodes
  , terrainCodesFor
  , terrainFailureReply
    -- * Pick authorities (the seam TRA-10 fills)
  , TerrainPicks
  , newTerrainPicks
  , issuePick
  , pickValue
    -- * The leased resource
  , TerrainResource
  , resourceLease
  ) where

import Control.Concurrent.MVar (MVar, newMVar)
import Control.Concurrent.STM
import Control.Exception (Exception, finally, mask, mask_, onException, throwIO)
import Control.Applicative ((<|>))
import Control.Monad (forM_, unless, void, when)
import Data.Functor ((<&>))
import Data.Int (Int64)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Unique (Unique, hashUnique, newUnique)
import Data.Word (Word64)
import Hetoimasia.Content.Identity (RootKey, rootKeyBytes)
import Hetoimasia.Foundation.Resource (acquirePart, releaseRank)
import Hetoimasia.LuaEngine.Facade
  ( TerrainCell (..)
  , TerrainColumnAsk (..)
  , TerrainDefinition (..)
  , TerrainInjection (..)
  , TerrainRegion (..)
  , TerrainLayer (..)
  , TerrainPatch (..)
  , TerrainPatchValue (..)
  , TerrainServices (..)
  , TerrainStart (..)
  , TerrainVm (..)
  , terrainArenaType
  , terrainCellValueSchema
  , terrainColumnValueSchema
  , terrainPickType
  , terrainRegionCells
  , terrainRegionValueSchema
  , terrainRemoveValueSchema
  , terrainRetryValueSchema
  , terrainGrowValueSchema
  , terrainStatusValueSchema
  , terrainStorageMinimum
  , terrainHostAttachEndpoint
  , terrainHostAttachName
  , terrainStorageUnit
  , terrainSurfaceValueSchema
  )
import Hetoimasia.LuaEngine.Profile (Count (Count), CountLimit (RequestsPerInstance), Profile, countLimit)
import Hetoimasia.LuaEngine.Request
  ( M1Ask (..)
  , M1Start (M1Busy)
  , m1Ask
  , m1ArgumentCheck
  , m1ReplyCheck
  , startM1
  )
import Hetoimasia.Scripting.Lua.Admission (Credit (..), CreditEnd (..), ExpectedFailure (..), Necessity (OptionalRequest))
import Hetoimasia.Scripting.Lua.Lease
  ( Ownership (InstanceOwned)
  , ReleaseAnswer (..)
  , leaseCapabilityType
  , releaseLease
  , withLeaseOr
  )
import Hetoimasia.Scripting.Lua.Provider
  ( Adoption (..)
  , ProviderReply (..)
  , ProviderWork (..)
  , ReplyAnswer (..)
  , RequestEndpoint (..)
  , RetirementState (..)
  , Settling (..)
  , Submission (..)
  , settlePrepared
  , SubmissionDeclined (..)
  )
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, Binding, RequestContext, capabilityType)
import Hetoimasia.Scripting.Lua.Value (Schema (SNil), Value (..), capability)
import Hetoimasia.Terrain.Cell (Cell (..), Column, IntervalError, MaterialId, ZRange, materialIdString, maxMaterialIdBytes, mkColumn, mkZRange, zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), changesFromIntervals)
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), TileCoord, axisValue, composeTile, decomposeTile, localX, localY, localZ, mkLocalCoord, regionLevels, tileCoord)
import Hetoimasia.Terrain.Discovery (CellKnowledge (..), SolidKnowledge (..), VoidKnowledge (..), regionKnowledgeAt)
import Hetoimasia.Terrain.Query (Occupied (..), QueryLimits (..), Run (..), cellAt, defaultQueryLimits)
import Hetoimasia.Terrain.Residency (Revision (..), limitExtent, limitHoldRegions, limitQueryRegions)
import Hetoimasia.LuaEngine.Terrain.Internal.Arbitration
  ( ArbitrationHooks (..)
  , Claim (..)
  , OpenNames (..)
  , arbitrateOpen
  , holdFailedUntil
  , pruneClaims
  , pruneFailedOpens
  , registerClaim
  )
import Hetoimasia.Terrain.Runtime
  ( Answer (..)
  , ArenaLease
  , ArenaStatus (..)
  , Condition (..)
  , DiscoveryState (..)
  , GrowAnswer (..)
  , OpenOptions (..)
  , RetryAnswer (..)
  , StorageState (..)
  , CellAnswer (..)
  , Client
  , ColumnAnswer (..)
  , Config (configLimits, configMaxLeases, configQueryLimits, configSourceLimits, configStore)
  , Failure (..)
  , Precondition (..)
  , RemoveAnswer (..)
  , Refused (..)
  , RegionBorrow
  , RegionPart (..)
  , RegionSnapshot
  , Request
  , Service
  , Settlement (..)
  , SurfaceAnswer (..)
  , endClient
  , inspectConfig
  , regionBorrowSnapshot
  , regionKnowledge
  , regionSnapshotContentRevision
  , regionSnapshotKnowledgeRevision
  , regionSnapshotRegions
  , regionSnapshotSource
  , regionTerrain
  , registerClient
  , releaseRegionBorrowSTM
  )
import qualified Hetoimasia.Terrain.Runtime as Terrain
import Hetoimasia.Terrain.Runtime.Settlement
  ( Endpoint (..)
  , PreparedSettlement (..)
  , TakeOutcome (..)
  , attachArenaFromWith
  , attachArenaWith
  , cancel
  , cellWith
  , columnWith
  , growWith
  , openArenaWithOptions
  , removeWith
  , retryWith
  , borrowHeldSTM
  , releaseArenaLeaseSTM
  , regionsWith
  , retireSTM
  , surfaceWith
  , takeSTM
  )
import Hetoimasia.Terrain.Shape (shapeIdValue)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceLimits (..), SourceSpec (..), defaultSourceLimits)
import Hetoimasia.Terrain.Runtime.Store (StoreSpec (..), allowanceUnitBytes, minAllowanceBytes, mkStoreConfig)

-- The composition -------------------------------------------------------------------------------------

-- | The session's terrain service this composition borrows.
data TerrainFacade = TerrainFacade
  { tfProfile ∷ !Profile
  -- ^ The validated profile every VM's request policy is read from.
  , tfService ∷ !Service
  -- ^ The assembly's terrain service.
  , tfConfig ∷ !Config
  -- ^ The configuration the service was made with: its lease cap derives the lease capacity.
  , tfPicks ∷ !TerrainPicks
  -- ^ The pick authorities the composition honours. Empty until a view adapter (TRA-10) or a test fixture issues one.
  , tfHooks ∷ !TerrainHooks
  -- ^ The test seams: 'noTerrainHooks' in production.
  , tfExtraBindings ∷ ![Binding]
  -- ^ Bindings a test fixture adds to the facade's hidden namespace (a host-created pick token). Empty in production.
  , tfClaims ∷ !(TVar (Map Text [Claim]))
  -- ^ The opens in flight, by the service's name: how an open finds, before it asks the service, a claim whose request the host has
  -- already settled as cancelled (the service has not been told yet) and lets it go, so that a name is free from the host's terminal
  -- settlement and not from the later notification.
  , tfFailedOpens ∷ !(TVar (Map Text [STM Bool]))
  -- ^ The names of opens the service failed (an invalid definition) whose settlement the host has not made yet (on logical time it is held
  -- for the request's assigned tick), each with whether it is still pending. The service holds no claim for such an open, so the adapter
  -- holds it, shared by every VM of the service: another open of the name before the host's settlement is @name_in_use@, as it is while a
  -- successful open stands, and the name is free from the settlement.
  , tfOpenLock ∷ !(MVar ())
  -- ^ The facade's opens, one at a time from the consultation of 'tfFailedOpens' through the service's admission: the arbitration of a name.
  , tfOffered ∷ !(TVar (Map Text (Set Unique)))
  -- ^ The names whose open the service committed and the host has not yet adopted or let go, each with the opens (by incarnation:
  -- every open request has its own identity) that hold it back: shared by every VM of the service, so that an attach, whichever VM
  -- makes it, is not eligible while the arena it would find is not yet the open's settled result. An open lets go only of its own
  -- entry, so a late cleanup of an earlier open of the name never shows a later open's arena before it has settled.
  }

-- | The host's publication of one arena: the content root it is published to and the host's creator lease, which the injection borrows and
-- never owns. The host keeps the lease and releases it with its own scope; closing the last creator lease closes the arena, whatever
-- is attached to it. Written once, at composition, and read by every VM of the session: no state, no reset.
data Published = Published !RootKey !ArenaLease

-- | An open's name is held back from attach, from the service's commit of the open until the host has adopted or let go of its lease.
holdBack ∷ TerrainFacade → Text → Link → STM ()
holdBack facade name link = modifyTVar' (tfOffered facade) (Map.insertWith Set.union name (Set.singleton (lkId link)))

-- | Let go of this open's own hold on a name, and of nothing another open of the name holds.
letGo ∷ TerrainFacade → Text → Link → STM ()
letGo facade name link =
  modifyTVar' (tfOffered facade) (Map.update (\held → let rest = Set.delete (lkId link) held in if Set.null rest then Nothing else Just rest) name)

-- | An open the service failed holds its name until the host has settled it. Every entry is gone at its settlement (or its owner's end): the
-- registry is swept whole at each insertion, at every drain and at every forgetting of an instance, and an open the host has settled already
-- is not entered at all, so what it holds is bounded by the failed opens still waiting for their tick, whatever names they used.
holdFailed ∷ TerrainFacade → Text → Link → STM ()
holdFailed facade name link = holdFailedUntil (names facade) name (lkSettled link)

-- | The state the arbitration of an open's name decides over.
names ∷ TerrainFacade → OpenNames
names facade = OpenNames (tfClaims facade) (tfFailedOpens facade) (tfOpenLock facade)

-- | The moments of an open's arbitration the facade's hooks mark.
arbitrationHooks ∷ TerrainFacade → ArbitrationHooks
arbitrationHooks facade = ArbitrationHooks (hookArriving (tfHooks facade)) (hookChecked (tfHooks facade)) (hookSubmitting (tfHooks facade))

-- | Whether some open still holds a name back from attach.
heldBack ∷ TerrainFacade → Text → STM Bool
heldBack facade name = Map.member name <$> readTVar (tfOffered facade)

-- | The caps the Lua contract fixes for what a script sends and is answered, and that the service's own configuration must not exceed: a
-- column answer of at most 1,024 runs (a longer one is the failure @too_large@) over a range of at most 8,192 levels, and a definition of
-- at most 256 KiB and 8,192 authored runs (a larger one is the failure @definition@). Their values are the service's approved defaults
-- ('defaultQueryLimits', 'defaultSourceLimits'), read from there so that there is one place they are written.
--
-- The rule, one for every cap: **a service configured above them is refused at composition** ('TerrainCompositionRefused', by
-- 'newTerrainFacade', before any VM or request exists), and a service configured below them is allowed and enforces its own, tighter value
-- (the service decides the failure, as it does for the default). The alternative, applying @min cap configured@ at the adapter's boundary,
-- would make the adapter re-decide what the service decides (the definition's conservative byte accounting, the run count of an answer) and
-- leave two places that can disagree; a refused composition is one explicit decision, taken where the assembly can read the reason. The caps
-- that are not a service limit are constants of the facade and the validator, which no configuration reaches: the arena name's 128
-- characters and the column range's 8,192 levels are checked by the facade before the service is asked, and the 4,095 materials are the
-- validator's constant ('maxAuthoredMaterials').
incompatibleLimits ∷ Config → [Text]
incompatibleLimits config =
  [ field <> " is " <> Text.pack (show configured) <> ", over the " <> Text.pack (show cap) <> " a script is promised"
  | (field, configured, cap) ←
      [ ("limitReturnedRuns", limitReturnedRuns (configQueryLimits config), limitReturnedRuns defaultQueryLimits)
      , ("limitRangeLevels", limitRangeLevels (configQueryLimits config), limitRangeLevels defaultQueryLimits)
      , ("limitDefinitionBytes", limitDefinitionBytes (configSourceLimits config), limitDefinitionBytes defaultSourceLimits)
      , ("limitAuthoredRuns", limitAuthoredRuns (configSourceLimits config), limitAuthoredRuns defaultSourceLimits)
      ]
  , configured > cap
  ]

-- | A composition over a service, with no pick authority issued, no hooks and no extra bindings. Every limit the adapter reads is the
-- configuration the service itself reports ('inspectConfig'), never one a caller holds: a caller cannot hand the adapter a configuration
-- that differs from the one the service enforces. A service configured with a limit above what Lua is promised ('incompatibleLimits') is
-- refused, with 'TerrainCompositionRefused'.
newTerrainFacade ∷ Profile → Service → IO TerrainFacade
newTerrainFacade profile svc = do
  let config = inspectConfig svc
  case incompatibleLimits config of
    [] → pure ()
    over → throwIO (TerrainCompositionRefused ("the terrain service's configuration exceeds the limits Lua is promised: " <> Text.intercalate "; " over))
  -- the allowance rules a script is promised are the service's own: its smallest allowance and its unit
  unless (toInteger minAllowanceBytes == toInteger terrainStorageMinimum && toInteger allowanceUnitBytes == toInteger terrainStorageUnit) $
    throwIO (TerrainCompositionRefused "the terrain service's allowance rules are not the 64 MiB minimum and the 1 MiB unit Lua is promised")
  picks ← newTerrainPicks
  claims ← newTVarIO Map.empty
  offered ← newTVarIO Map.empty
  failed ← newTVarIO Map.empty
  lock ← newMVar ()
  pure (TerrainFacade profile svc config picks noTerrainHooks [] claims failed lock offered)

-- | The windows a test may hold or fail: told, never consulted for an answer.
data TerrainHooks = TerrainHooks
  { hookAdopting ∷ IO ()
  -- ^ The host is about to build an offered lease into its reserved lease, on the owner's thread.
  , hookAdopted ∷ IO ()
  -- ^ The host has built the offered lease into its reserved lease and has not yet settled the request: the window in which the arena
  -- can close before the settlement.
  , hookReleasing ∷ IO ()
  -- ^ A lease's release is about to reach the service.
  , hookSubmitted ∷ IO ()
  -- ^ The service accepted a request and the hand-off is about to return, masked.
  , hookCancelling ∷ IO ()
  -- ^ The host settled a request as cancelled (a script's cancel won) and the adapter is about to ask the service to cancel it: the
  -- window in which the service's own commit and the host's settlement are arbitrated by the request's eligibility alone.
  , hookArriving ∷ IO ()
  -- ^ An open is about to take the critical section that arbitrates its name: before it can be held back by another open's.
  , hookChecked ∷ IO ()
  -- ^ An open has consulted the failed opens and is about to be admitted by the service: inside the critical section that arbitrates the name,
  -- where no other open of this facade can be admitted.
  , hookSubmitting ∷ IO ()
  -- ^ The host admitted a request (its places are reserved) and the hand-off is about to ask the service, masked: the window between a
  -- permanent precheck and the service's own admission, in which the service can close.
  , hookAdmitted ∷ IO ()
  -- ^ The service admitted a request and the host has not yet recorded it: the window in which the service can already act on the request
  -- (its arena can close) while the host cannot yet ask about it.
  , hookRevoked ∷ IO ()
  -- ^ The service has released the lease of an open (the script's release of its arena, or a cancelled open's revocation) and the open
  -- has not yet let go of its hold on the name (the name is free for the service's next open): the window in which a later open of the
  -- same name can already be offered.
  }

noTerrainHooks ∷ TerrainHooks
noTerrainHooks = TerrainHooks (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (pure ())

-- | Why a VM's terrain could not be composed: a failure of the composition, never a script's.
newtype TerrainCompositionRefused = TerrainCompositionRefused Text
  deriving (Eq, Show)

instance Exception TerrainCompositionRefused

-- | Raised inside the service's committing transaction when the host rejects the reply that settles it: the transaction is abandoned
-- with nothing of the change written, and the service treats it as the provider defect it is.
newtype SettlementRejected = SettlementRejected Text
  deriving (Eq, Show)

instance Exception SettlementRejected

-- | The expected failure codes the terrain requests supply (D-19, the manager's two authorizations, and TRA-23's seven storage
-- codes): the only codes a terrain reply may carry. Any other outcome of the service is a defect of the host. Each endpoint declares
-- the subset it can settle with ('terrainCodesFor').
terrainCodes ∷ [Text]
terrainCodes =
  [ "not_found"
  , "arena_closed"
  , "stale_view"
  , "definition"
  , "source_failure"
  , "too_large"
  , "name_in_use"
  , "source_complexity"
  , "storage_unsupported"
  , "reservation_failed"
  , "storage_full"
  , "storage_io"
  , "storage_integrity"
  , "storage_size_not_increased"
  ]

-- | The expected codes of one terrain endpoint (by its name): the seven of TRA-5 for the calls that had them, and the storage codes
-- the service's own classification ("Hetoimasia.Terrain.Runtime.Backed.Backend") can settle that command with. An open meets a
-- complex source, an unsupported or unreservable file and an I/O failure of its open; a read meets the I/O and integrity failures of
-- the pages it reads; a removal meets every pause (and settles at once with it while the arena holds); a growth meets its
-- reservation's refusals, an I/O failure (its allocation, or the release of an earlier extra) and a smaller size; a retry meets the
-- I/O failure of an extra's release (its probes' failures are recorded as pauses, never its settlement). An attach meets none, and a
-- status, which the adapter settles itself, only its arena's closure, and a regional read the same. A storage code an endpoint does not declare is a defect there.
terrainCodesFor ∷ Text → [Text]
terrainCodesFor name
  | name == openName = base <> ["source_complexity", "storage_unsupported", "reservation_failed", "storage_io"]
  | name `elem` [attachName, attachHostName] = base
  | name == removeName = base <> ["storage_full", "storage_io", "storage_integrity"]
  | name `elem` [cellName, columnName, surfaceName] = base <> ["storage_io", "storage_integrity"]
  | name == statusName = ["arena_closed"]
  | name == growName = ["arena_closed", "storage_unsupported", "reservation_failed", "storage_io", "storage_size_not_increased"]
  | name == retryName = ["arena_closed", "storage_io"]
  -- A regional read has one expected failure. A page that fails or reads back invalid during the build is not a failure of the request: it
  -- settles with the affected part unavailable, so no storage code is declared.
  | name == regionName = ["arena_closed"]
  | otherwise = []
  where
    base = take 7 terrainCodes

-- | The lease capacity one instance needs in the VM's shared scope for terrain: every lease the service can hold at once (its
-- cap is service-wide, so one instance may hold them all, pending, live and retiring), the places its requests can reserve a
-- lease for before the service has admitted them, and one of headroom, as graphics does. Derived, not chosen: it follows the
-- service's cap and the profile's, and changes neither.
terrainLeaseCapacity ∷ Profile → Service → Int
terrainLeaseCapacity profile svc = configMaxLeases (inspectConfig svc) + fromIntegral perInstance + 1
  where
    Count perInstance = countLimit profile RequestsPerInstance

-- The pick authorities -----------------------------------------------------------------------------------

-- | The pick authorities issued so far: opaque tokens naming the instance they were issued to and the incarnation and
-- content revision a displayed view was built from. The real issuer is the view adapter (TRA-10); a test fixture issues them
-- from the host side. Lua has no constructor.
newtype TerrainPicks = TerrainPicks (TVar (Word64, Map Word64 (Text, Precondition)))

newTerrainPicks ∷ IO TerrainPicks
newTerrainPicks = TerrainPicks <$> newTVarIO (1, Map.empty)

-- | Issue an authority to this instance (by the identity the facade issued it) for this precondition. The key is the
-- capability's.
issuePick ∷ TerrainPicks → Text → Precondition → IO Word64
issuePick (TerrainPicks var) identity precondition = atomically $ do
  (next, held) ← readTVar var
  writeTVar var (next + 1, Map.insert next (identity, precondition) held)
  pure next

-- | The value a host fixture hands a script for an issued authority.
pickValue ∷ Word64 → Value
pickValue key = VCapability (capability terrainPickType key)

-- The leased resource ---------------------------------------------------------------------------------------

-- | What the host's lease holds: the service's own lease, or nothing when the request that was to own it ended between the
-- offer and the build (its offered lease was already released by this adapter).
data TerrainResource = TerrainResource
  { resourceLease ∷ !(Maybe ArenaLease)
  , resourceCreator ∷ !Bool
  -- ^ Whether the lease is the arena's creator lease (built for an open), the only one with authority over its storage.
  }

-- | A request's offered lease: offered by the commit, built by the host (adopting) and published by the successful settlement
-- (adopted), or disposed of by this adapter when the host withdrew its interest first. Cancellation authority is kept through every
-- state before publication ('Offered', 'Adopting', 'Revoking'); each transition is decided in one transaction.
data LeaseCell
  = NoLease
  | Offered !ArenaLease
  | -- | The host's interest ended and the lease is being revoked: the service's release has not completed, so the arena is still the
    -- open's and its name still held back, until whoever revokes it has finished.
    Revoking !ArenaLease
  | -- | The host has built the lease and has not yet published it by settling the request successfully (its last look, in the
    -- settling transaction, does that): until then the host's interest can still end, and the lease stays revocable.
    Adopting !ArenaLease
  | -- | Published: the request settled successfully and the lease is the instance's.
    Adopted
  | Disposed
  deriving (Eq)

-- | What this adapter holds of one request while it is the service's: the host's seam, where the offered lease is, and
-- whether the service has reached its terminal outcome.
data Link = Link
  { lkAttach ∷ !(Maybe Text)
  -- ^ The service's name of the arena an attach looks for.
  , lkName ∷ !(Maybe Text)
  -- ^ The service's name of the arena an open creates: held in 'tfOffered' from the commit until the host adopts or lets go of the lease.
  , lkSettling ∷ !Settling
  , lkLease ∷ !(TVar LeaseCell)
  , lkTerminal ∷ !(TVar Bool)
  , lkSettled ∷ !(STM Bool)
  -- ^ The host has settled this request: its terminal settlement was made, not only delivered to the host's seam.
  , lkDropped ∷ !(TVar [ArenaLease])
  -- ^ The leases the service made for this request and the host did not publish (an attach that found its open still unpublished): given back in
  -- the transaction that gives the request's credit back, when the service has recorded them.
  , lkId ∷ !Unique
  -- ^ The identity of this request's incarnation of the name it opens: what it holds in 'tfOffered', and all it ever lets go of.
  , lkArena ∷ !(Maybe ArenaLease)
  -- ^ The creator lease a growth or a retry names: its success reports the arena's storage state as its commit left it, read in the
  -- transaction that settles it.
  , lkRequest ∷ !(TVar (Maybe Request))
  -- ^ The service's request, once the hand-off has recorded it: a regional read takes its borrow in the transaction that settles it, which
  -- needs the request, so such a request is not eligible before this is known.
  , lkRegional ∷ !Bool
  -- ^ Whether this is a regional read, whose native borrow can outlive its request ('workHeld').
  }

-- The per-VM state ----------------------------------------------------------------------------------------

-- | One typed request, held between the binding's start and the service's hand-off.
data Ask
  = AskOpen !Client !Text !SourceSpec !OpenOptions
  | AskAttach !Client !Text
  | -- | An attachment to the arena the host published, through the host's creator lease and as this client; nothing when no arena is
    -- published to the instance's root, which settles at the hand-off like a status, with no work of the service's.
    AskAttachHost !(Maybe (Client, ArenaLease))
  | AskCell !ArenaLease !TileCoord
  | AskColumn !ArenaLease !Column !ZRange
  | AskSurface !ArenaLease !Column
  | AskRemove !ArenaLease !TileCoord !(Maybe Precondition)
  | -- | A status: no work of the service, a coherent read of its own state, settled at the hand-off.
    AskStatus !ArenaLease
  | AskGrow !ArenaLease !Integer
  | AskRetry !ArenaLease
  | -- | One whole region's terrain and knowledge, copied from the one version the service's build pinned.
    AskRegion !ArenaLease !RegionCoord

-- | An instance's two terrain clients. The service makes the lease of an attach by the arena's own creator an /owner/ lease, but
-- an attach always yields a nonowner attachment (the lease of the open is the arena's only owner lease, and releasing it closes
-- the arena whatever the creator attached to): so an instance opens as its owner client and attaches as another client, made the
-- first time it attaches. Both end with the instance.
data Clients = Clients
  { clOwner ∷ !Client
  , clAttach ∷ !(Maybe Client)
  }

data Pending = Pending
  { pdAsk ∷ !Ask
  , pdRequest ∷ !(TVar (Maybe Request))
  , pdDropped ∷ !(TVar [ArenaLease])
  }

data Env = Env
  { envFacade ∷ !TerrainFacade
  , envVm ∷ !TerrainVm
  , envSession ∷ !Int
  , envClients ∷ !(TVar (Map Text Clients))
  , envAsks ∷ !(TVar (Word64, Map Word64 Pending))
  , envIssued ∷ !(TVar (Map Text (Set Word64)))
  -- ^ The arena handles each live instance was issued: ownership is positive, so another instance's handle is refused for as long
  -- as the caller lives, whether or not the issuing instance does. The memory is the handles the instance issued, ended with it.
  , envPublished ∷ !(Maybe Published)
  -- ^ The arena the host published to one content root of the session ('terrainInjectionWithArena'): what @api.terrain.attach_host()@ of an
  -- instance of that root is issued an attachment to. Nothing in the injection of 'terrainInjection'. Fixed at composition, never written.
  }

service ∷ Env → Service
service = tfService . envFacade

hooks ∷ Env → TerrainHooks
hooks = tfHooks . envFacade

-- | The injection a session is composed with, publishing one arena of the host's to one content root: the 'terrainInjection' of the same
-- facade, whose instances of that root can also take @api.terrain.attach_host()@, an attachment of their own to the arena the lease
-- opened, whatever name it was opened under.
--
-- The lease must be, now, a live creator (owner) lease of a live arena of the facade's service: one that is another service's, an
-- attachment, or already released or closed is refused ('RefusedAuthority'), as is a closed service ('RefusedClosed'). The injection
-- BORROWS it: it acquires no lease, never releases the host's and keeps no arena alive. The host's lease stays the host's, with its
-- native view; it is released with the host's scope, and releasing the arena's last creator lease closes the arena with Lua attached.
-- A lease that ends later is not an error of the injection: an attachment that would be issued from it settles @not_found@. The facade
-- and every injection made from it before keep their behavior and their tables; the root that matches no root of the session is not
-- refused either, since every instance of the session is then in an unpublished root.
terrainInjectionWithArena ∷ TerrainFacade → RootKey → ArenaLease → IO (Either Refused TerrainInjection)
terrainInjectionWithArena facade root lease =
  atomically (Terrain.creatorLeaseSTM (tfService facade) lease) <&> \case
    Left refused → Left refused
    Right () → Right (injectionOver (Just (Published root lease)) facade)

-- | The injection a session is composed with: for each role's VM, its own client table over the shared service, in the VM's own
-- lending and lease scope.
terrainInjection ∷ TerrainFacade → TerrainInjection
terrainInjection = injectionOver Nothing

-- | The injection over a facade, with the arena the host published, if any: what every VM's environment is made with.
injectionOver ∷ Maybe Published → TerrainFacade → TerrainInjection
injectionOver publication config =
  TerrainInjection
    { tiLeaseCapacity = \profile → terrainLeaseCapacity profile (tfService config)
    , injectTerrain = \vm → do
        clients ← newTVarIO Map.empty
        asks ← newTVarIO (1, Map.empty)
        issued ← newTVarIO Map.empty
        let env = Env config vm (hashUnique (tvSession vm)) clients asks issued publication
        pure (services env)
    }

services ∷ Env → TerrainServices
services env =
  TerrainServices
    { tsTypes = [leaseCapabilityType leases terrainArenaType, capabilityType terrainPickType pickLive]
    , tsEndpoints = endpoints
    , tsDeclare = declare env
    , tsForget = forget env
    , tsOpenCheck = \_ _ _ _ bytes owner values →
        firstRefusal
          [ pure (bytes >>= openAllowanceRefusal env)
          , permanent env (const openAsk) owner values
          ]
    , tsOpenStart = \identity root name definition bytes context → do
        client ← clientOf env identity
        start env context openName openAsk (AskOpen client (nameKey env root name) (sourceSpec definition) (OpenOptions (toInteger <$> bytes)))
    , tsAttachCheck = \_ _ _ owner values → permanent env (const attachAsk) owner values
    , tsAttachStart = \identity root name context →
        if name == terrainHostAttachName
          then -- the name no script can pass asks for the arena the host published to this instance's root
            case published env root of
              -- no arena is published to this instance's root: the request settles not_found at its hand-off, with no client made
              Nothing → start env context attachHostName attachHostAsk (AskAttachHost Nothing)
              -- the instance's own client: the service issues the attachment as a nonowner lease whichever client asks, so it needs no
              -- client of its own to keep the creator-owner rule apart, and one the instance holds already cannot be refused as the bank
              -- filling
              Just source → do
                client ← clientOf env identity
                start env context attachHostName attachHostAsk (AskAttachHost (Just (client, source)))
          else
            attachClientOf env identity >>= \case
              Left refusal → pure refusal
              Right (client, fresh) → do
                -- A client made for this attach is the attach's to give back when it is not accepted: nothing stays charged for a request
                -- that was refused (busy in the host's banks or the service's), and an exception leaves none behind either.
                let giveBack = when fresh $ do
                      atomically (modifyTVar' (envClients env) (Map.adjust (\clients → clients {clAttach = Nothing}) identity))
                      endClient (service env) client
                started ← start env context attachName attachAsk (AskAttach client (nameKey env root name)) `onException` giveBack
                case started of
                  TerrainStarted (M1Busy _) → giveBack
                  TerrainRefused _ → giveBack
                  _ → pure ()
                pure started
    , tsCellCheck = \identity key cell owner values →
        firstRefusal
          [ leaseCheck env identity key readAsk owner values
          , answerCheck env terrainCellValueSchema LargestCell owner values
          , pure (either Just (extentRefusal env . cellPlaces) (tileOf cell))
          ]
    , tsCellStart = \_ key cell context → withArena env key $ \lease →
        startOr cell (\tile → start env context cellName readAsk (AskCell lease tile))
    , tsColumnCheck = \identity key ask owner values →
        firstRefusal
          [ leaseCheck env identity key readAsk owner values
          , answerCheck env terrainColumnValueSchema (LargestColumn (levelsOf ask)) owner values
          , pure (either Just (const (rangeRefusal env ask <|> extentRefusal env (columnPlaces ask))) (columnOf ask))
          ]
    , tsColumnStart = \_ key ask context → withArena env key $ \lease →
        case columnOf ask of
          Left why → pure (TerrainRefused why)
          Right (column, range) → start env context columnName readAsk (AskColumn lease column range)
    , tsSurfaceCheck = \identity key _ _ owner values →
        firstRefusal
          [ leaseCheck env identity key readAsk owner values
          , answerCheck env terrainSurfaceValueSchema LargestSurface owner values
          ]
    , tsSurfaceStart = \_ key x y context → withArena env key $ \lease →
        case mkColumn (toInteger x) (toInteger y) of
          Left _ → pure (TerrainRefused "the column is outside the supported range")
          Right column → start env context surfaceName readAsk (AskSurface lease column)
    , tsRemoveCheck = \identity key cell pick owner values →
        firstRefusal
          [ pickCheck env identity pick
          , leaseCheck env identity key removeAsk owner values
          , answerCheck env terrainRemoveValueSchema LargestRemove owner values
          , pure (either Just (extentRefusal env . cellPlaces) (tileOf cell))
          ]
    , tsRemoveStart = \identity key cell pick context → withArena env key $ \lease → do
        precondition ← pickPrecondition env identity pick
        case precondition of
          Left why → pure (TerrainRefused why)
          Right found → startOr cell (\tile → start env context removeName removeAsk (AskRemove lease tile found))
    , tsStatusCheck = \identity key owner values →
        firstRefusal
          [ leaseCheck env identity key statusAsk owner values
          , statusFigureRefusal env key
          , m1ReplyCheck (tvRequests (envVm env)) statusAsk terrainStatusValueSchema (largestReply env LargestStatus) owner values
          ]
    , tsStatusStart = \_ key context → withArena env key $ \lease → start env context statusName statusAsk (AskStatus lease)
    , tsGrowCheck = \identity key bytes owner values →
        firstRefusal
          [ creatorCheck env identity key growAsk "grow its storage" owner values
          , pure (growAllowanceRefusal env bytes)
          , m1ReplyCheck (tvRequests (envVm env)) growAsk terrainGrowValueSchema (largestReply env LargestGrow) owner values
          ]
    , tsGrowStart = \_ key bytes context → withArena env key $ \lease → start env context growName growAsk (AskGrow lease (toInteger bytes))
    , tsRetryCheck = \identity key owner values →
        firstRefusal
          [ creatorCheck env identity key retryAsk "retry its storage" owner values
          , m1ReplyCheck (tvRequests (envVm env)) retryAsk terrainRetryValueSchema (largestReply env LargestRetry) owner values
          ]
    , tsRetryStart = \_ key context → withArena env key $ \lease → start env context retryName retryAsk (AskRetry lease)
    , tsRegionCheck = \identity key _ owner values →
        firstRefusal
          [ leaseCheck env identity key regionAsk owner values
          , pure (regionRefusal env)
          , m1ReplyCheck (tvRequests (envVm env)) regionAsk terrainRegionValueSchema (largestReply env LargestRegion) owner values
          ]
    , tsRegionStart = \_ key (TerrainRegion x y z) context → withArena env key $ \lease →
        let region = RegionCoord x y z
         in if wholeRegionSupported region
              then start env context regionName regionAsk (AskRegion lease region)
              else pure (TerrainRefused "the region is outside the supported range")
    , tsReleaseCheck = releaseCheck env
    , tsRelease = \key → releaseWord <$> releaseLease leases key
    , tsIssued = \identity key → atomically (modifyTVar' (envIssued env) (Map.insertWith Set.union identity (Set.singleton key)))
    , tsDrain = drainRetired env
    , tsExtraBindings = tfExtraBindings (envFacade env)
    }
  where
    leases = tvLeases (envVm env)
    -- A pick authority is live while the registry that issued it holds it: its liveness is not a lease's.
    pickLive key = let TerrainPicks var = tfPicks (envFacade env) in Map.member key . snd <$> readTVarIO var
    startOr cell run = case tileOf cell of
      Left why → pure (TerrainRefused why)
      Right tile → run tile
    endpoints =
      [ endpoint env openName SNil
      , endpoint env attachName SNil
      , -- the opt-in of host attachment: the facade asks this provider for the published arena, and not for a name nothing holds
        endpoint env attachHostName SNil
      , endpoint env cellName terrainCellValueSchema
      , endpoint env columnName terrainColumnValueSchema
      , endpoint env surfaceName terrainSurfaceValueSchema
      , endpoint env removeName terrainRemoveValueSchema
      , endpoint env statusName terrainStatusValueSchema
      , endpoint env growName terrainGrowValueSchema
      , endpoint env retryName terrainRetryValueSchema
      , endpoint env regionName terrainRegionValueSchema
      ]
    releaseWord = \case
      Released → "done"
      Retiring → "retiring"
      AlreadyReleased → "already_released"

-- | The endpoint names of the requests.
openName, attachName, attachHostName, cellName, columnName, surfaceName, removeName, statusName, growName, retryName, regionName ∷ Text
openName = "terrain_open"
attachName = "terrain_attach"
attachHostName = terrainHostAttachEndpoint
cellName = "terrain_cell"
columnName = "terrain_column"
surfaceName = "terrain_surface"
removeName = "terrain_remove"
statusName = "terrain_status"
growName = "terrain_grow_storage"
retryName = "terrain_retry_storage"
regionName = "terrain_region"

-- Declaring ---------------------------------------------------------------------------------------------------

declare ∷ Env → Text → Text → IO ()
declare env identity _root =
  registerClient (service env) >>= \case
    Left refused → throwIO (TerrainCompositionRefused ("an instance's terrain client was refused: " <> Text.pack (show refused)))
    Right client → atomically (modifyTVar' (envClients env) (Map.insert identity (Clients client Nothing)))

forget ∷ Env → Text → IO ()
forget env identity = do
  found ← atomically $ do
    held ← Map.lookup identity <$> readTVar (envClients env)
    modifyTVar' (envClients env) (Map.delete identity)
    pure held
  forM_ found $ \clients → do
    forM_ (clAttach clients) (endClient (service env))
    endClient (service env) (clOwner clients)
  -- What an instance was issued is remembered as long as the instance lives, so another instance holding its handle is refused
  -- however many handles have been issued since; the entries end with the instance, whose holdings are gone.
  atomically (modifyTVar' (envIssued env) (Map.delete identity))
  drainRetired env

clientOf ∷ Env → Text → IO Client
clientOf env identity = clOwner <$> clientsOf env identity

clientsOf ∷ Env → Text → IO Clients
clientsOf env identity =
  Map.lookup identity <$> readTVarIO (envClients env) >>= \case
    Just found → pure found
    Nothing → throwIO (TerrainCompositionRefused "no terrain client was declared for the instance")

-- | The client an instance attaches as, made on first use.
attachClientOf ∷ Env → Text → IO (Either TerrainStart (Client, Bool))
attachClientOf env identity = do
  clients ← clientsOf env identity
  case clAttach clients of
    Just found → pure (Right (found, False))
    Nothing →
      registerClient (service env) >>= \case
        -- The service's client bank is full: temporary pressure, answered as busy before anything is reserved.
        Left (RefusedBusy _) → pure (Left (TerrainStarted (M1Busy "request capacity is not available: the terrain service has all of its clients")))
        -- The service is stopping, or an identity of it is spent: the same ordinary refusals every other call gets from the service.
        Left RefusedClosed → pure (Left (TerrainRefused "the terrain service is closed"))
        Left RefusedExhausted → pure (Left (TerrainRefused "an identity of the terrain service is exhausted"))
        Left refused → throwIO (TerrainCompositionRefused ("an instance's attach client was refused: " <> Text.pack (show refused)))
        Right made → do
          atomically (modifyTVar' (envClients env) (Map.insert identity clients {clAttach = Just made}))
          pure (Right (made, True))

-- | The creator lease the host published to the content root of an instance, if any: the root's text is the one the facade issued the
-- instance, and the published root is its UTF-8 encoding exactly (the rule the content facade applies to a root).
published ∷ Env → Text → Maybe ArenaLease
published env root = case envPublished env of
  Just (Published key lease) | rootKeyBytes key == Text.encodeUtf8 root → Just lease
  _ → Nothing

-- | The name the service holds for an instance's name: in the session's and the instance's content root's namespace. It cannot exceed
-- the 256 characters the service holds: a session's identity is at most 19 digits, a content root at most 64 characters
-- ('validRootId') and a script's name at most 128, and the two separators and the prefix add three, so at most 214.
nameKey ∷ Env → Text → Text → Text
nameKey env root name = "s" <> Text.pack (show (envSession env)) <> "/" <> root <> "/" <> name

-- | What an operation of an instance sweeps: the claims of opens that have ended and the failed opens the host has settled. Never blocks. (A
-- request's result and a lease the host did not publish are given back to the service in the transaction that settles or takes them, not
-- here: nothing is queued for a later call.)
drainRetired ∷ Env → IO ()
drainRetired env = atomically (pruneClaims (names (envFacade env)) >> pruneFailedOpens (names (envFacade env)))

-- The asks ------------------------------------------------------------------------------------------------------

-- | Each request's ask, declaring exactly the expected codes its endpoint can settle with ('terrainCodesFor').
openAsk, attachAsk, attachHostAsk, readAsk, removeAsk, statusAsk, growAsk, retryAsk, regionAsk ∷ M1Ask
openAsk = leaseAsk "terrain open" (terrainCodesFor openName)
attachAsk = leaseAsk "terrain attach" (terrainCodesFor attachName)
attachHostAsk = leaseAsk "terrain host attach" (terrainCodesFor attachHostName)
readAsk = (m1Ask OptionalRequest "terrain read") {askCodes = terrainCodesFor cellName}
removeAsk = (m1Ask OptionalRequest "terrain removal") {askCodes = terrainCodesFor removeName}
statusAsk = (m1Ask OptionalRequest "terrain status") {askCodes = terrainCodesFor statusName}
growAsk = (m1Ask OptionalRequest "terrain storage growth") {askCodes = terrainCodesFor growName}
retryAsk = (m1Ask OptionalRequest "terrain storage retry") {askCodes = terrainCodesFor retryName}
regionAsk = (m1Ask OptionalRequest "terrain region read") {askCodes = terrainCodesFor regionName}

leaseAsk ∷ Text → [Text] → M1Ask
leaseAsk source codes =
  (m1Ask OptionalRequest source)
    { askCodes = codes
    , askLease = Just (InstanceOwned, \_ key → VCapability (capability terrainArenaType key))
    }

-- | The first refusal of these checks, in order: each is a permanent fact decided before any bank is asked, and none reserves anything.
firstRefusal ∷ [IO (Maybe Text)] → IO (Maybe Text)
firstRefusal = \case
  [] → pure Nothing
  decide : more → decide >>= maybe (firstRefusal more) (pure . Just)

-- | The shape of the largest answer a call can have.
data Largest = LargestCell | LargestColumn !Int | LargestSurface | LargestRemove | LargestStatus | LargestGrow | LargestRetry | LargestRegion

-- | The levels a column ask spans.
levelsOf ∷ TerrainColumnAsk → Int
levelsOf (TerrainColumnAsk _ _ lo hi) = fromIntegral (toInteger hi - toInteger lo)

-- | A call whose largest answer the VM's copied-value limits could never carry is refused here, before the host's banks, as an ordinary
-- error (see 'm1ReplyCheck'): a permanent fact of the call and the profile, never busy because a bank is full.
answerCheck ∷ Env → Schema → Largest → ArgumentCheck
answerCheck env schema largest = m1ReplyCheck (tvRequests (envVm env)) readAsk schema (largestReply env largest)

-- | The service's extent is the columns, rows and levels of a region that may ever be loaded: a cell, or a range of a column, that
-- names a level of a region beyond it is refused by the service's own admission, permanently. It is decided here from the same extent
-- and the same decomposition of a cell, before any bank, so that it is never busy. (The default extent is a whole region and refuses
-- nothing; a service configured with a smaller one does.) A surface's answer depends on the arena's content and is the service's alone.
extentRefusal ∷ Env → [(Int, Int, Int)] → Maybe Text
extentRefusal env places
  | all inside places = Nothing
  | otherwise = Just "the cell is outside the extent of the regions this service loads"
  where
    (ex, ey, ez) = limitExtent (configLimits (tfConfig (envFacade env)))
    inside (lx, ly, hiZ) = lx < ex && ly < ey && hiZ <= ez

-- | The service's own limits on a column's range, from its configuration: the most levels one range may name, and the most regions one
-- request may demand (a request that names more is refused by the service, permanently).
rangeRefusal ∷ Env → TerrainColumnAsk → Maybe Text
rangeRefusal env ask
  | levelsOf ask > limitRangeLevels (configQueryLimits config) = Just "the range spans more levels than this service returns"
  | toInteger (length (columnPlaces ask)) > toInteger (limitQueryRegions (configLimits config)) = Just "the range spans more regions than this service reads at once"
  | otherwise = Nothing
  where
    config = tfConfig (envFacade env)

-- | The service's own permanent refusals of a regional set, decided from its configuration before any bank is asked, as 'extentRefusal'
-- and 'rangeRefusal' decide theirs (so neither can read as busy behind a full bank): a copy covers whole regions, so a service whose
-- extent is not a whole region refuses every one, and a service whose hold admits no region refuses every set.
regionRefusal ∷ Env → Maybe Text
regionRefusal env
  | limitExtent limits /= (16, 16, 32) = Just "the service's extent is not a whole region: it copies none"
  | limitHoldRegions limits < 1 = Just "the service's hold admits no region: it copies none"
  | otherwise = Nothing
  where
    limits = configLimits (tfConfig (envFacade env))

-- | Whether every cell of the region is a supported coordinate (the facade decoded the same indices; the service's admission decides it
-- again).
wholeRegionSupported ∷ RegionCoord → Bool
wholeRegionSupported region = case (mkLocalCoord 0 0 0, mkLocalCoord 15 15 31) of
  (Right low, Right high) → either (const False) (const True) (composeTile region low) && either (const False) (const True) (composeTile region high)
  _ → False

-- | What a cell asks of its region: its column's place and the levels it needs.
cellPlaces ∷ TileCoord → [(Int, Int, Int)]
cellPlaces tile = [(fromIntegral (localX local), fromIntegral (localY local), fromIntegral (localZ local) + 1)]
  where
    (_, local) = decomposeTile tile

-- | What a range of a column asks of each region it spans: the column's place and the levels of the range inside that region.
columnPlaces ∷ TerrainColumnAsk → [(Int, Int, Int)]
columnPlaces (TerrainColumnAsk x y lo' hi') = [(lx, ly, piece rz) | rz ← [first .. final]]
  where
    lo = toInteger lo'
    hi = toInteger hi'
    levels = toInteger regionLevels
    first = lo `div` levels
    final = (hi - 1) `div` levels
    piece rz = fromInteger (min hi ((rz + 1) * levels) - rz * levels)
    (lx, ly) = case tileCoord (toInteger x) (toInteger y) 0 of
      Right tile → let (_, local) = decomposeTile tile in (fromIntegral (localX local), fromIntegral (localY local))
      Left _ → (0, 0)

-- | The host's permanent facts for an ask, decided before any action and reserving nothing: the service is still admitting work (a
-- closed service is a permanent refusal, never the busy a full bank of the host's would answer first), and the host's own facts. It is
-- a precheck: the service decides its admission again, atomically with the admission, and a service that closed since refuses the
-- hand-off the same way ('declination'), leaving nothing reserved.
permanent ∷ Env → ([Value] → M1Ask) → ArgumentCheck
permanent env askOf owner values = do
  admitting ← atomically (Terrain.serviceAdmitting (service env))
  if admitting
    then m1ArgumentCheck (tvRequests (envVm env)) askOf owner values
    else pure (Just "the terrain service is closed")

-- | A lease handle's check: another instance's handle (alive, retiring or ended) and a handle of another kind are refused as
-- ordinary errors; the host's own permanent facts follow. A lease whose arena was closed by someone else is not refused here:
-- its request settles @arena_closed@.
leaseCheck ∷ Env → Text → Word64 → M1Ask → ArgumentCheck
leaseCheck env identity key ask owner values = do
  mine ← ownedBy env identity key
  if not mine
    then pure (Just "the arena belongs to another instance")
    else
      withLeaseOr
        (tvLeases (envVm env))
        key
        (\why → pure (Just why))
        (\(_ ∷ TerrainResource) → permanent env (const ask) owner values)

-- | A creator command's check: the handle is the caller's own, it is the arena's creator lease (an attachment, the creator's own
-- included, has no authority over the arena's storage), and the host's own permanent facts follow. Decided before any bank, so a
-- full request bank never hides it.
creatorCheck ∷ Env → Text → Word64 → M1Ask → Text → ArgumentCheck
creatorCheck env identity key ask what owner values = do
  mine ← ownedBy env identity key
  if not mine
    then pure (Just "the arena belongs to another instance")
    else
      withLeaseOr
        (tvLeases (envVm env))
        key
        (\why → pure (Just why))
        ( \resource →
            if resourceCreator resource
              then permanent env (const ask) owner values
              else pure (Just ("only the arena's creator lease may " <> what))
        )

-- | The largest allowance a script may name: the service's offset domain and the VM's integer ceiling, whichever is smaller,
-- rounded down to a whole number of MiB. A larger one could never be granted or reported, so it is refused before any work.
largestAllowance ∷ Env → Integer
largestAllowance env = (bound `div` unit) * unit
  where
    unit = toInteger terrainStorageUnit
    bound = minimum [specOffsetLimit (configStore (tfConfig (envFacade env))), toInteger (tvIntegerCeiling (envVm env)), toInteger (maxBound ∷ Int64)]

-- | Whether an open's allowance is refused: past the largest a script may name, or refused by the service's own rule for an
-- arena's store with its other figures ('mkStoreConfig', the rule the service applies at the open). Never busy.
openAllowanceRefusal ∷ Env → Int64 → Maybe Text
openAllowanceRefusal env bytes
  | toInteger bytes > largestAllowance env = Just ("storage_bytes is above the largest allowance this service can grant (" <> Text.pack (show (largestAllowance env)) <> ")")
  | otherwise = case mkStoreConfig (configStore (tfConfig (envFacade env))) {specAllowanceBytes = toInteger bytes} of
      Left err → Just (Text.take 200 ("storage_bytes can never be granted: " <> Text.pack (show err)))
      Right _ → Nothing

-- | Whether a status is refused because its byte figures are predictably not Lua integers for this VM: the arena's allowance and a
-- pending extra bound every byte figure, and above the VM's integer ceiling they could never be handed to the script. Decided before
-- any bank. (A revision or a count above the ceiling is not predictable: it is a host defect, as for every terrain answer.)
statusFigureRefusal ∷ Env → Word64 → IO (Maybe Text)
statusFigureRefusal env key =
  withLeaseOr (tvLeases (envVm env)) key (\_ → pure Nothing) $ \resource → case resourceLease resource of
    Nothing → pure Nothing
    Just lease →
      Terrain.arenaStatus (service env) lease <&> \case
        Right status
          | toInteger (statusReservedBytes status) + toInteger (statusPendingReservedBytes status) > toInteger (tvIntegerCeiling (envVm env)) →
              Just "the arena's allowance is above the largest integer this VM hands a script"
        _ → Nothing

-- | Whether a growth's allowance is refused: past the largest a script may name. Whether it is larger than the arena's current
-- allowance is decided by the service when the growth executes (@storage_size_not_increased@), never here.
growAllowanceRefusal ∷ Env → Int64 → Maybe Text
growAllowanceRefusal env bytes
  | toInteger bytes > largestAllowance env = Just ("new_bytes is above the largest allowance this service can grant (" <> Text.pack (show (largestAllowance env)) <> ")")
  | otherwise = Nothing

-- | Whether this instance was issued this handle.
ownedBy ∷ Env → Text → Word64 → IO Bool
ownedBy env identity key = maybe False (Set.member key) . Map.lookup identity <$> readTVarIO (envIssued env)

-- | Borrow the service's lease from the host's, for a start. A lease that has ended since the check (it cannot, on the one
-- thread that runs the instance, but the answer is data) is a refusal.
withArena ∷ Env → Word64 → (ArenaLease → IO TerrainStart) → IO TerrainStart
withArena env key use =
  withLeaseOr (tvLeases (envVm env)) key (\why → pure (TerrainRefused why)) $ \resource →
    case resourceLease resource of
      Nothing → pure (TerrainRefused "the lease has ended")
      Just lease → use lease

releaseCheck ∷ Env → Text → Word64 → IO (Maybe Text)
releaseCheck env identity key = do
  mine ← ownedBy env identity key
  -- Another instance's handle is refused whether its lease is live, retiring or completely retired (its slot is gone by then):
  -- ownership is the caller's own record, not the lease's.
  if not mine
    then pure (Just "the arena belongs to another instance")
    else
      withLeaseOr
        (tvLeases (envVm env))
        key
        (\why → pure (if Text.isInfixOf "another" why then Just why else Nothing))
        (\(_ ∷ TerrainResource) → pure Nothing)

-- The pick -----------------------------------------------------------------------------------------------------

-- | Whether the authority is the calling instance's own live one.
pickCheck ∷ Env → Text → Maybe Word64 → IO (Maybe Text)
pickCheck env identity = \case
  Nothing → pure Nothing
  Just key → do
    let TerrainPicks var = tfPicks (envFacade env)
    (_, held) ← readTVarIO var
    pure $ case Map.lookup key held of
      Just (owner, _) | owner == identity → Nothing
      Just _ → Just "the pick authority belongs to another instance"
      Nothing → Just "the pick is not a live pick authority"

pickPrecondition ∷ Env → Text → Maybe Word64 → IO (Either Text (Maybe Precondition))
pickPrecondition env identity = \case
  Nothing → pure (Right Nothing)
  Just key → do
    let TerrainPicks var = tfPicks (envFacade env)
    (_, held) ← readTVarIO var
    pure $ case Map.lookup key held of
      Just (owner, precondition) | owner == identity → Right (Just precondition)
      _ → Left "the pick is not a live pick authority of this instance"

-- Conversions ----------------------------------------------------------------------------------------------------

sourceSpec ∷ TerrainDefinition → SourceSpec
sourceSpec definition =
  SourceSpec
    { specMaterials = map Text.unpack (tdMaterials definition)
    , specLayers = map layer (tdLayers definition)
    , specPatches = map patch (tdPatches definition)
    }
  where
    layer l = LayerSpec (toInteger <$> tlMin l) (toInteger <$> tlMax l) (Text.unpack (tlMaterial l)) (fromIntegral (tlShape l))
    patch p = PatchSpec (toInteger (tpX p)) (toInteger (tpY p)) (toInteger (tpMin p)) (toInteger (tpMax p)) (value (tpValue p))
    value = \case
      PatchAir → SpecAir
      PatchSolid material shape → SpecSolid (Text.unpack material) (fromIntegral shape)

tileOf ∷ TerrainCell → Either Text TileCoord
tileOf (TerrainCell x y z) = either (const (Left "the cell is outside the supported range")) Right (tileCoord (toInteger x) (toInteger y) (toInteger z))

columnOf ∷ TerrainColumnAsk → Either Text (Column, ZRange)
columnOf (TerrainColumnAsk x y lo hi) = do
  column ← either (const (Left "the column is outside the supported range")) Right (mkColumn (toInteger x) (toInteger y))
  range ← either (\(_ ∷ IntervalError) → Left "the range is not a valid interval of supported levels") Right (mkZRange (toInteger lo) (toInteger hi))
  Right (column, range)

-- | A terrain failure as the reply the host judges, for the examples that name every failure the service can settle.
terrainFailureReply ∷ Failure → ProviderReply
terrainFailureReply = failureReply

-- | A terrain failure as the reply the host judges: the declared code with a fixed, bounded message, or a reply that is a
-- provider defect (no code), for what the service never declared.
failureReply ∷ Failure → ProviderReply
failureReply = \case
  NotFound → expected "not_found" "no arena of this name is open in this content root"
  ArenaClosed → ProviderExpected closedFailure
  StaleView → expected "stale_view" "the displayed snapshot is no longer the arena's content"
  Definition err → expected "definition" ("the definition was refused: " <> Text.pack (take 400 (show err)))
  TooLarge _ → expected "too_large" "the complete answer has more than 1024 runs: narrow the range"
  SourceFailure why → expected "source_failure" (Text.take 400 why)
  NameInUse → expected "name_in_use" "an arena of this name is open or being opened in this content root"
  Superseded why → ProviderFailure ("terrain: a request was overtaken and cannot be admitted again: " <> Text.take 200 why)
  HostFailure why → ProviderFailure ("terrain: " <> Text.take 200 why)
  -- The typed storage outcomes (TRA-23): each is its service's stable code with a fixed message. The fault's own detail (pages,
  -- offsets, operations, figures) is the service's diagnostics and never reaches a script; a code the contract does not declare
  -- is a defect, as for any other outcome.
  StorageFailed fault → case Terrain.faultCode fault of
    code
      | code `elem` terrainCodes → expected code (storageMessage code)
      | otherwise → ProviderFailure ("terrain: an undeclared storage outcome: " <> Text.take 100 code)
  where
    expected code message = ProviderExpected (ExpectedFailure code message Nothing Nothing)

-- | The fixed message of each storage code.
storageMessage ∷ Text → Text
storageMessage = \case
  "source_complexity" → "the definition is valid but too complex to prepare within the arena's bounds"
  "storage_unsupported" → "the arena's storage is not supported where the engine keeps it"
  "reservation_failed" → "the arena's storage could not be reserved"
  "storage_full" → "the arena's allowance cannot take this change: the arena is paused until it grows or a retry finds room"
  "storage_io" → "the arena's storage failed to read or write: the arena is paused until a retry succeeds"
  "storage_integrity" → "the arena's stored history did not read back intact: the arena is paused until a retry succeeds"
  "storage_size_not_increased" → "the allowance asked for is smaller than the one committed; storage never shrinks"
  _ → "the arena's storage refused the request"

-- | The code of a pause condition.
conditionCode ∷ Condition → Text
conditionCode = \case
  CondIntegrity → "storage_integrity"
  CondIo → "storage_io"
  CondCapacity → "storage_full"

-- | Conditions in the order of their severity, the most severe first: integrity, then I/O, then capacity. A status's @reason@ is
-- the first; a retry's lists are in this order.
bySeverity ∷ [Condition] → [Condition]
bySeverity = sortOn rank
  where
    rank = \case
      CondIntegrity → 0 ∷ Int
      CondIo → 1
      CondCapacity → 2

-- | The @state@ and, while paused, the @reason@ of an arena's storage.
storageFields ∷ StorageState → Maybe [(Text, Value)]
storageFields = \case
  StorageReady → Just [("state", VText "ready")]
  StoragePaused conds → case bySeverity conds of
    worst : _ → Just [("state", VText "paused"), ("reason", VText (conditionCode worst))]
    [] → Nothing

discoveryText ∷ DiscoveryState → Text
discoveryText = \case
  DiscoveryIdle → "idle"
  DiscoveryPending → "pending"
  DiscoveryPaused → "paused"

-- | A figure as a Lua integer, when it is one: within the VM's profile ceiling and Int64.
figureOf ∷ Word64 → Word64 → Maybe Value
figureOf ceiling' w
  | w <= min ceiling' (fromIntegral (maxBound ∷ Int64)) = Just (VInteger (fromIntegral w))
  | otherwise = Nothing

-- | A status as the reply the host takes: a fresh record of copied integers and text, or a defect when one of its figures is not a
-- Lua integer (composition bounds every byte figure by an allowance at most the VM's ceiling, so that is impossible after a valid
-- admission).
statusReply ∷ Word64 → ArenaStatus → ProviderReply
statusReply ceiling' status = maybe (ProviderFailure "terrain: a status figure is not a Lua integer") ProviderResult $ do
  storage ← storageFields (statusStorage status)
  bytes ←
    traverse
      (\(field, w) → (,) field <$> figureOf ceiling' w)
      [ ("reserved_bytes", statusReservedBytes status)
      , ("used_bytes", statusUsedBytes status)
      , ("pending_reclaim_bytes", statusPendingReclaimBytes status)
      , ("pending_reserved_bytes", statusPendingReservedBytes status)
      ]
  items ← figureOf ceiling' (statusPendingItems status)
  content ← revisionValue (statusContentRevision status)
  knowledge ← revisionValue (statusKnowledgeRevision status)
  Just
    ( VRecord
        [ ("storage", VRecord (storage <> bytes))
        , ("discovery", VRecord [("state", VText (discoveryText (statusDiscovery status))), ("pending_items", items)])
        , ("content_revision", content)
        , ("knowledge_revision", knowledge)
        ]
    )
  where
    revisionValue (Revision w) = figureOf ceiling' w

-- | A growth's success: whether it changed the allowance, the allowance committed now, and the storage state its commit left.
growReply ∷ Word64 → GrowAnswer → ArenaStatus → ProviderReply
growReply ceiling' grown status = maybe (ProviderFailure "terrain: a growth's figures are not Lua integers") ProviderResult $ do
  storage ← storageFields (statusStorage status)
  reserved ← figureOf ceiling' (grownAllowance grown)
  Just (VRecord [("changed", VBoolean (grownChanged grown)), ("reserved_bytes", reserved), ("storage", VRecord storage)])

-- | A retry's success: what it cleared, what remains and what no retry can clear, and the states its commit left.
retryReply ∷ Word64 → RetryAnswer → ArenaStatus → ProviderReply
retryReply _ retried status = maybe (ProviderFailure "terrain: a retry's storage state is not one Lua is promised") ProviderResult $ do
  storage ← storageFields (statusStorage status)
  Just
    ( VRecord
        [ ("changed", VBoolean (not (null (retriedCleared retried))))
        , ("cleared", codes (retriedCleared retried))
        , ("remaining", codes (retriedRemaining retried))
        , ("until_closed", codes (retriedUntilClosed retried))
        , ("storage", VRecord storage)
        , ("discovery", VRecord [("state", VText (discoveryText (statusDiscovery status)))])
        ]
    )
  where
    codes = VList . map (VText . conditionCode) . bySeverity

-- | The expected failure of a lease whose arena has closed.
closedFailure ∷ ExpectedFailure
closedFailure = ExpectedFailure "arena_closed" "the arena has closed" Nothing Nothing

-- | A revision as a Lua integer, when it is one.
revisionOf ∷ Word64 → Revision → Maybe Int64
revisionOf ceiling' (Revision w)
  | w <= min ceiling' (fromIntegral (maxBound ∷ Int64)) = Just (fromIntegral w)
  | otherwise = Nothing

cellFields ∷ Cell → [(Text, Value)]
cellFields = \case
  Air → [("air", VBoolean True)]
  Solid material shape → [("air", VBoolean False), ("material", VText (materialText material)), ("shape", VInteger (fromIntegral (shapeIdValue shape)))]

materialText ∷ MaterialId → Text
materialText = Text.pack . materialIdString

-- | The reply for an answer that is not a lease, or a defect for one that cannot be handed to Lua.
answerReply ∷ Word64 → Answer → ProviderReply
answerReply ceiling' = \case
  ACell answer → withRevision (cellRevision answer) $ \revision → VRecord (("revision", VInteger revision) : cellFields (cellValue answer))
  AColumn answer → withRevision (columnRevision answer) $ \revision →
    VRecord
      [ ("revision", VInteger revision)
      , ("runs", VList [VRecord ([("z_min", VInteger (fromIntegral (zRangeLo range))), ("z_max", VInteger (fromIntegral (zRangeHi range)))] <> cellFields cell) | Run range cell ← columnAnswerRuns answer])
      ]
  ASurface answer → withRevision (surfaceRevision answer) $ \revision → case surfaceTop answer of
    Nothing → VRecord [("revision", VInteger revision), ("occupied", VBoolean False)]
    Just (Occupied level material shape) →
      VRecord
        [ ("revision", VInteger revision)
        , ("occupied", VBoolean True)
        , ("z", VInteger (axisValue level))
        , ("material", VText (materialText material))
        , ("shape", VInteger (fromIntegral (shapeIdValue shape)))
        ]
  ARemoved answer → withRevision (removeRevision answer) $ \revision → VRecord [("changed", VBoolean (removeChangedFlag answer)), ("revision", VInteger revision)]
  AOpened _ → ProviderFailure "terrain: a lease answer reached the value conversion"
  AGrown _ → ProviderFailure "terrain: a growth answer reached the value conversion without its arena's status"
  ARetried _ → ProviderFailure "terrain: a retry answer reached the value conversion without its arena's status"
  AKnowledge _ → ProviderFailure "terrain: a knowledge answer reached the value conversion (no Lua schema in this slice)"
  ARegions borrow → regionReply ceiling' (regionBorrowSnapshot borrow)
  AAttached _ → ProviderFailure "terrain: a lease answer reached the value conversion"
  where
    withRevision revision build = case revisionOf ceiling' revision of
      Just found → ProviderResult (build found)
      Nothing → ProviderFailure "terrain: a content revision is not a Lua integer"

-- | A regional snapshot as the reply the host takes: a fresh record of the two revisions it was labelled with and its two parts, each
-- ready with the dense cells of the region in the order @1 + x + 16 * y + 256 * z@, or unavailable. Nothing in it names the snapshot: every
-- value is an integer, a boolean or a text made here. A revision that is not a Lua integer, or a snapshot that does not hold exactly one
-- region, is a defect of the host, as for every other terrain answer.
regionReply ∷ Word64 → RegionSnapshot → ProviderReply
regionReply ceiling' snapshot = maybe (ProviderFailure "terrain: a regional snapshot is not one a script can be handed") ProviderResult $ do
  region ← case regionSnapshotRegions snapshot of
    [only] → Just only
    _ → Nothing
  content ← revisionOf ceiling' (regionSnapshotContentRevision snapshot)
  knowledge ← revisionOf ceiling' (regionSnapshotKnowledgeRevision snapshot)
  tiles ← traverse (\(x, y, z) → either (const Nothing) Just (mkLocalCoord x y z >>= composeTile region)) locals
  terrain ← case regionTerrain snapshot region of
    PartReady intervals → do
      changes ← either (const Nothing) Just (changesFromIntervals (ChangeLimits maxBound) intervals)
      Just (readyPart [VRecord (cellFields (cellAt (regionSnapshotSource snapshot) changes tile)) | tile ← tiles])
    PartUnavailable → Just unavailablePart
    PartNotHeld → Nothing
  known ← case regionKnowledge snapshot region of
    PartReady regional → case traverse (regionKnowledgeAt regional) tiles of
      Just cells → Just (readyPart [VRecord [("solid", VText (solidText (cellSolid cell))), ("void", VText (voidText (cellVoid cell)))] | cell ← cells])
      -- a cell the knowledge does not describe is never delivered in part: the part is as if it could not be read
      Nothing → Just unavailablePart
    PartUnavailable → Just unavailablePart
    PartNotHeld → Nothing
  Just (VRecord [("content_revision", VInteger content), ("knowledge_revision", VInteger knowledge), ("terrain", terrain), ("knowledge", known)])
  where
    -- the zero-based local coordinates in the order of the Lua index: x fastest, then y, then z
    locals = [(x, y, z) | z ← [0 .. toInteger regionLevels - 1], y ← [0 .. 15], x ← [0 .. 15]]
    readyPart cells = VRecord [("state", VText "ready"), ("cells", VList cells)]
    unavailablePart = VRecord [("state", VText "unavailable")]
    solidText = \case
      NoSolid → "none"
      SolidKnown → "known"
      SolidUnknown → "unknown"
    voidText = \case
      NoVoidHere → "none"
      VoidKnown → "known"
      VoidUnknown → "unknown"

-- | The settlement of a regional read, in the one transaction that commits it: the request's borrow is taken (it is still the request's
-- here, and the copy was made under it), the reply the copy made is settled, and the borrow is released, so nothing of the snapshot is
-- charged once the request is settled, whether or not the script ever takes the result. A borrow the service released before this take
-- ('TakeReleased') is never read: the request settles as its arena's closure, once. The take needs the service's request; the request is
-- not eligible before the hand-off has recorded it.
settleRegion ∷ Env → Link → RegionBorrow → STM ReplyAnswer → STM ()
settleRegion env link borrow settle = do
  taken ← readTVar (lkRequest link) >>= maybe (pure TakeReleased) (takeSTM (service env))
  case taken of
    Taken → void settle >> releaseRegionBorrowSTM (service env) borrow
    TakeReleased → void (settlingSettle (lkSettling link) (ProviderExpected closedFailure))
  writeTVar (lkTerminal link) True

-- The service's endpoint ------------------------------------------------------------------------------------------

endpoint ∷ Env → Text → Schema → RequestEndpoint
endpoint env name schema = RequestEndpoint {endpointName = name, endpointResult = schema, endpointSubmit = submit env}

-- | Hand a request to the service: one masked step from taking the typed ask to returning the work, so nothing separates an
-- admitted request from the record that cancels it.
submit ∷ Env → Submission → IO ProviderWork
submit env submission = mask_ $ do
  ticket ← case submissionArguments submission of
    [VInteger found] → pure (fromIntegral found)
    _ → throwIO (TerrainCompositionRefused "a terrain request was handed with no ticket")
  pending ← atomically $ do
    (next, held) ← readTVar (envAsks env)
    writeTVar (envAsks env) (next, Map.delete ticket held)
    pure (Map.lookup ticket held)
  found ← maybe (throwIO (TerrainCompositionRefused "a terrain request's ask was lost")) pure pending
  settling ← maybe (throwIO (TerrainCompositionRefused "a terrain request was handed with no settlement seam")) pure (submissionSettling submission)
  -- The largest reply this ask can have must be one the host takes, or the request is refused here, before the service is handed it:
  -- a settlement the host rejects at the commit abandons the transaction and takes the whole service down with the host's defect
  -- unrecorded. The refusal is an ordinary error naming the range, decided by the host's own judgement of the reply.
  forM_ (worstReply env (pdAsk found)) $ \reply →
    unless (settlingJudge settling reply) $
      throwIO (DeclinedRefused "the VM's copied-value limits cannot carry the answer of this call: narrow the range")
  case pdAsk found of
    AskStatus lease → submitStatus env settling lease
    AskAttachHost Nothing → submitNotFound env settling
    _ → submitToService env submission found settling

-- | A status is no work of the service's: one coherent read of the arena's own state, in one transaction, settled at the hand-off
-- (on logical time the host holds it for the request's position, as it holds any answer). It reserves nothing of the service, does
-- not discover terrain and clears no pause. A lease whose arena has closed since the check settles @arena_closed@.
submitStatus ∷ Env → Settling → ArenaLease → IO ProviderWork
submitStatus env settling lease = do
  atomically $ do
    reply ←
      Terrain.inspectArenaSTM (service env) lease >>= \case
        Nothing → pure (ProviderExpected closedFailure)
        Just _ →
          Terrain.arenaStatusSTM (service env) lease <&> \case
            Right status → statusReply (tvIntegerCeiling (envVm env)) status
            -- the lease is this adapter's own, so its only refusal is that its arena has ended
            Left RefusedAuthority → ProviderExpected closedFailure
            Left other → ProviderFailure ("terrain: a status was refused: " <> Text.take 200 (Text.pack (show other)))
    void (settlingSettle settling reply)
  pure ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete}

-- | A request with no arena to reach: settled at the hand-off, @not_found@, and nothing of the service's is touched, reserved or held. The
-- service's admission is still decided at the hand-off, in the very transaction that settles it: a service that closed since the host's
-- precheck is the permanent closed-service refusal every other request gets ('declination'), with the host's reservations taken back.
submitNotFound ∷ Env → Settling → IO ProviderWork
submitNotFound env settling = do
  hookSubmitting (hooks env)
  admitting ← atomically $ do
    open ← Terrain.serviceAdmitting (service env)
    when open (void (settlingSettle settling (failureReply NotFound)))
    pure open
  unless admitting (throwIO (declination RefusedClosed))
  pure ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete}

-- | Hand a request that is the service's work to it.
submitToService ∷ Env → Submission → Pending → Settling → IO ProviderWork
submitToService env submission found settling = do
  link ←
    Link
      (case pdAsk found of AskAttach _ name → Just name; _ → Nothing)
      (case pdAsk found of AskOpen _ name _ _ → Just name; _ → Nothing)
      settling
      <$> newTVarIO NoLease
      <*> newTVarIO False
      <*> pure (submissionSettled submission)
      <*> pure (pdDropped found)
      <*> newUnique
      <*> pure (case pdAsk found of AskGrow lease _ → Just lease; AskRetry lease → Just lease; _ → Nothing)
      <*> pure (pdRequest found)
      <*> pure (case pdAsk found of AskRegion {} → True; _ → False)
  noted ← newTVarIO False
  let -- What decides a commit, read in the transaction that makes it: the session still takes new work, the request is still
      -- waiting (and its tick granted, on logical time), and a read or removal does not need a revision no Lua integer holds.
      eligible = do
        takes ← tvTakesWork (envVm env)
        waiting ← settlingEligible settling
        if not (takes && waiting)
          then pure False
          else case pdAsk found of
            AskAttach {} → pure True
            AskAttachHost {} → pure True
            AskOpen {} → pure True
            -- a growth or a retry hands no revision to Lua
            AskGrow {} → pure True
            AskRetry {} → pure True
            -- a regional read takes its borrow when it settles, and needs the service's request for it: the owner waits (it reads this
            -- cell) until the hand-off has recorded it
            -- (its revisions are the pinned snapshot's, judged in its reply ('regionReply'), never the live arena's: an arena that has
            -- moved on since the copy was staged must not keep the staged copy from settling)
            AskRegion {} → isJust <$> readTVar (pdRequest found)
            _ → fromMaybe False <$> representableNow
      -- Whether the revision this request will hand to Lua is one a Lua integer holds, from the arena as the service has it. A read hands
      -- the arena's revision; a removal hands the next one when it changes content and the same one when it removes air, which only the
      -- service's staging knows ('Terrain.stagedRemovalChanges'): Nothing until it has staged the removal, when there is nothing to decide.
      representableNow ∷ STM (Maybe Bool)
      representableNow = do
        needs ← case pdAsk found of
          AskCell lease _ → pure (Just (lease, 0))
          AskColumn lease _ _ → pure (Just (lease, 0))
          AskSurface lease _ → pure (Just (lease, 0))
          AskRemove lease _ _ →
            readTVar (pdRequest found) >>= \case
              Nothing → pure Nothing
              Just request → fmap (\changes → (lease, if changes then 1 else 0)) <$> Terrain.stagedRemovalChanges (service env) request
          _ → pure Nothing
        case needs of
          Nothing → pure Nothing
          Just (lease, advance) →
            Terrain.inspectArenaSTM (service env) lease >>= \case
              Just view → pure (Just (not (Terrain.viewRevision view `exceeds` advance)))
              Nothing → pure (Just True)
      exceeds (Revision w) advance = w > min (tvIntegerCeiling (envVm env)) (fromIntegral (maxBound ∷ Int64)) - advance
      -- A revision that cannot be handed to Lua is the host's defect, and it is recorded where it is first known: when the service stages
      -- the request (its readiness, a transaction that commits, which the owner's choosing of work is not), or, for a request staged before
      -- the hand-off returned, when it returns. The request is not eligible, so the service commits nothing. It cannot be left to the
      -- commit: a settlement the host rejects there abandons the transaction (nothing committed) but the service takes it for a provider
      -- defect and fails as a whole, and the host's request is never told. Recorded once.
      note = do
        recorded ← readTVar noted
        unless recorded $
          representableNow >>= \case
            Just False → do
              writeTVar noted True
              void (settlingSettle settling (ProviderFailure "terrain: a content revision is not a Lua integer"))
            _ → pure ()
      ep =
        Endpoint
          { endpointReady = note
          , endpointEligible = eligible
          , endpointSettle = settleInto env link
          , endpointPrepare = Just (prepareInto env link)
          }
  let admitAsk = case pdAsk found of
        AskOpen client name spec options → openArenaWithOptions (service env) ep client name spec options
        AskAttach client name → attachArenaWith (service env) ep client name
        AskAttachHost (Just (client, source)) → attachArenaFromWith (service env) ep client source
        AskAttachHost Nothing → throwIO (TerrainCompositionRefused "an attachment with no published arena reached the service's admission")
        AskCell lease tile → cellWith (service env) ep lease tile
        AskColumn lease column range → columnWith (service env) ep lease column range
        AskSurface lease column → surfaceWith (service env) ep lease column
        AskRemove lease tile precondition → removeWith (service env) ep lease tile precondition
        AskGrow lease bytes → growWith (service env) ep lease bytes
        AskRetry lease → retryWith (service env) ep lease
        AskRegion lease region → regionsWith (service env) ep lease [region]
        -- settled at the hand-off ('submitStatus'), never the service's
        AskStatus _ → throwIO (TerrainCompositionRefused "a status reached the service's admission")
      -- What follows the service's admission of a request: the host's record of it, and for an open the claim of its name, which is found
      -- stale if the host settles the open as cancelled before the service is told.
      afterAdmission request = do
        atomically (writeTVar (pdRequest found) (Just request) >> note)
        case pdAsk found of
          AskOpen _ name _ _ →
            atomically (registerClaim (names (envFacade env)) name (Claim (stale link (submissionSettled submission)) (done link) (tellCancelled env link request)))
          _ → pure ()
        hookSubmitted (hooks env)
      admitted = do
        found' ← admitAsk
        -- the window between the service's admission and the host's record of the request
        forM_ (either (const Nothing) Just found') (\_ → hookAdmitted (hooks env))
        forM_ (either (const Nothing) Just found') afterAdmission
        pure found'
  -- An open's name is arbitrated by 'arbitrateOpen': the release of the stale claims, the consultation of the failed opens, the admission and
  -- the registration of the open's claim are one critical section of the facade's opens, so no open is admitted between another's
  -- consultation and its registration, whatever the VM. (A non-Lua client opening names on the same service directly is outside it.)
  outcome ← case pdAsk found of
    AskOpen _ name _ _ → arbitrateOpen (names (envFacade env)) (arbitrationHooks (envFacade env)) name admitted
    _ → do
      hookSubmitting (hooks env)
      Just <$> admitted
  case outcome of
    Nothing → do
      -- An open the service failed still holds its name until the host settles it: this one is a duplicate of it, answered here and never
      -- handed to the service, which has no claim to find.
      atomically (settlingSettle settling (failureReply NameInUse) >> writeTVar (lkTerminal link) True)
      pure ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete}
    Just (Left refused) → throwIO (declination refused)
    Just (Right request) →
      pure
        ProviderWork
          { workCancel = cancelWork env link request
          , workRetirement = retirement env link
          }

-- | The largest answer a read or a removal can have, as the reply the host judges: a revision at the greatest integer, every field
-- present, and for a column as many runs as the range has levels and the service returns (more is @too_large@, a failure that
-- carries no answer).
largestReply ∷ Env → Largest → ProviderReply
largestReply env = \case
  LargestCell → ProviderResult (VRecord (("revision", greatest) : solid))
  LargestColumn levels →
    let runs = max 1 (min (limitReturnedRuns (configQueryLimits (tfConfig (envFacade env)))) levels)
     in ProviderResult (VRecord [("revision", greatest), ("runs", VList (replicate runs (VRecord ([("z_min", greatest), ("z_max", greatest)] <> solid))))])
  LargestSurface → ProviderResult (VRecord [("revision", greatest), ("occupied", VBoolean True), ("z", greatest), ("material", longest), ("shape", greatest)])
  LargestRemove → ProviderResult (VRecord [("changed", VBoolean True), ("revision", greatest)])
  LargestStatus →
    ProviderResult
      ( VRecord
          [ ("storage", VRecord (pausedFields <> [(field, greatest) | field ← ["reserved_bytes", "used_bytes", "pending_reclaim_bytes", "pending_reserved_bytes"]]))
          , ("discovery", VRecord [("state", VText "pending"), ("pending_items", greatest)])
          , ("content_revision", greatest)
          , ("knowledge_revision", greatest)
          ]
      )
  LargestGrow → ProviderResult (VRecord [("changed", VBoolean True), ("reserved_bytes", greatest), ("storage", VRecord pausedFields)])
  LargestRegion → largestRegionReply
  LargestRetry →
    ProviderResult
      ( VRecord
          [ ("changed", VBoolean True)
          , ("cleared", every)
          , ("remaining", every)
          , ("until_closed", every)
          , ("storage", VRecord pausedFields)
          , ("discovery", VRecord [("state", VText "pending")])
          ]
      )
  where
    pausedFields = [("state", VText "paused"), ("reason", VText "storage_integrity")]
    every = VList [VText (conditionCode c) | c ← [minBound .. maxBound]]
    greatest = VInteger maxBound
    longest = VText (Text.replicate maxMaterialIdBytes "m")
    solid = [("air", VBoolean False), ("material", longest), ("shape", greatest)]

-- | The largest regional read: every cell of both parts present at its widest (a solid of the longest material and the greatest shape,
-- a known solid over an unknown void), and both revisions at the greatest integer. It depends on no configuration, so it is built once.
largestRegionReply ∷ ProviderReply
largestRegionReply =
  ProviderResult
    ( VRecord
        [ ("content_revision", VInteger maxBound)
        , ("knowledge_revision", VInteger maxBound)
        , ("terrain", readyPart (VRecord [("air", VBoolean False), ("material", VText (Text.replicate maxMaterialIdBytes "m")), ("shape", VInteger maxBound)]))
        , ("knowledge", readyPart (VRecord [("solid", VText "unknown"), ("void", VText "unknown")]))
        ]
    )
  where
    readyPart cell = VRecord [("state", VText "ready"), ("cells", VList (replicate terrainRegionCells cell))]

-- | The largest answer of a request the host was handed, for the hand-off's own judgement (the check before the banks decided the same
-- thing already; this is the belt to that brace).
worstReply ∷ Env → Ask → Maybe ProviderReply
worstReply env = \case
  AskCell {} → Just (largestReply env LargestCell)
  AskColumn _ _ range → Just (largestReply env (LargestColumn (fromIntegral (toInteger (zRangeHi range) - toInteger (zRangeLo range)))))
  AskSurface {} → Just (largestReply env LargestSurface)
  AskRemove {} → Just (largestReply env LargestRemove)
  AskStatus {} → Just (largestReply env LargestStatus)
  AskGrow {} → Just (largestReply env LargestGrow)
  AskRetry {} → Just (largestReply env LargestRetry)
  AskRegion {} → Just (largestReply env LargestRegion)
  _ → Nothing

-- | The host has settled the request without the service's telling, and the offered lease (if any) was not adopted.
stale ∷ Link → STM Bool → STM Bool
stale link settled = do
  ended ← settled
  cell ← readTVar (lkLease link)
  pure (ended && case cell of Adopted → False; Disposed → False; _ → True)

-- | The request reached its end: the service has answered it and no offered lease is waiting for the host.
done ∷ Link → STM Bool
done link = do
  answered ← readTVar (lkTerminal link)
  cell ← readTVar (lkLease link)
  pure (answered && case cell of Offered _ → False; Adopting _ → False; Revoking _ → False; _ → True)

-- | What the service's refusal of an admitted request is to the script: busy for a bank with no room, an ordinary error for
-- anything permanent.
declination ∷ Refused → SubmissionDeclined
declination = \case
  RefusedBusy why → DeclinedBusy (Text.pack ("terrain " <> bankName why))
  RefusedAuthority → DeclinedRefused "the arena handle is not this service's authority"
  RefusedInvalid why → DeclinedRefused (Text.take 200 why)
  RefusedExhausted → DeclinedRefused "an identity of the terrain service is exhausted"
  RefusedClosed → DeclinedRefused "the terrain service is closed"
  where
    bankName = \case
      Terrain.BusyModel _ → "bank"
      Terrain.BusyArenas → "arenas"
      Terrain.BusyLeases → "leases"
      Terrain.BusyViews → "views"
      Terrain.BusyClients → "clients"
      Terrain.BusyRetained → "retained results"

-- | THE SUCCESS OF A READ IS PREPARED OUTSIDE ANY TRANSACTION: the service evaluates this before it stages the answer, so the
-- conversion of the answer into its Lua value and the host's judgement of that reply ('settlingPrepare') are done once, and the
-- arbitration's transaction only settles the judged reply ('settleInto' decides the same, unprepared). Both read only the answer
-- and what the request's admission fixed (the VM's integer ceiling, the owner's limits, the schema). Every other answer (a lease,
-- a growth's or a retry's, which read the arena's status at their commit) prepares nothing and is settled as 'settleInto' settles it.
prepareInto ∷ Env → Link → Answer → PreparedSettlement
prepareInto env link answer = case answer of
  ACell _ → prepared
  AColumn _ → prepared
  ASurface _ → prepared
  -- THE COPY OF A REGION IS MADE HERE, outside every transaction and on the thread of the service's owner that stages the answer (never a
  -- Lua thread, and no pool of its own): the request still owns the borrow, which the snapshot is charged under until the transaction that
  -- settles it takes it and releases it ('settleRegion'), so the copy is complete before the borrow ends and nothing of it names the
  -- snapshot.
  ARegions borrow → PreparedSettlement (settlingPrepare (lkSettling link) (regionReply (tvIntegerCeiling (envVm env)) (regionBorrowSnapshot borrow))) $ \reply →
    settleRegion env link borrow (settlePrepared reply)
  _ → PreparedSettlement () (\() → settleInto env link (Succeeded answer))
  where
    prepared = PreparedSettlement (settlingPrepare (lkSettling link) (answerReply (tvIntegerCeiling (envVm env)) answer)) $ \reply →
      settlePrepared reply >> writeTVar (lkTerminal link) True

-- | The service's terminal outcome of a request, in the very transaction that decides it: the host's seam is read and written
-- in it, and nothing else is.
settleInto ∷ Env → Link → Settlement → STM ()
settleInto env link = \case
  Cancelled → settlingCancel (lkSettling link) >> writeTVar (lkTerminal link) True
  Failed failure → do
    -- The service may still hold what it borrowed for the request: the preparation that was running when it was failed (an arena closed,
    -- the service closed) keeps the request as a ghost, which the withdrawal that precedes this settlement has just made. Its work is not
    -- over because it has answered: the settlement does not prove it so, and the retirement obligation stays ('retirement'). Without a ghost
    -- the settlement proves the work over, as every other does.
    ghosts ← workHeld env link
    _ ← (if ghosts then settlingSettleKeeping else settlingSettle) (lkSettling link) (failureReply failure)
    -- An open the service failed holds no claim of its own: the adapter holds its name until the host has settled it.
    case failure of
      NameInUse → pure ()
      _ → forM_ (lkName link) (\name → holdFailed (envFacade env) name link)
    writeTVar (lkTerminal link) True
  Succeeded answer → case answer of
    AOpened lease → offer lease
    AAttached lease → do
      -- An attach is decided against the names that have settled for the service, and an open the host has not yet published is not one
      -- for the host: it answers not_found without waiting, and the service's lease for it is let go at the next drain.
      pending ← maybe (pure False) (heldBack (envFacade env)) (lkAttach link)
      if pending
        then do
          -- the lease the service made is the request's to give back with its credit: the service records it only after this callback
          modifyTVar' (lkDropped link) (lease :)
          _ ← settlingSettle (lkSettling link) (failureReply NotFound)
          writeTVar (lkTerminal link) True
        else offer lease
    ARegions borrow → settleRegion env link borrow (settlingSettle (lkSettling link) (regionReply ceiling' (regionBorrowSnapshot borrow)))
    AGrown grown → creatorSettled (\status → growReply ceiling' grown status)
    ARetried retried → creatorSettled (\status → retryReply ceiling' retried status)
    other → do
      settled ← settlingSettle (lkSettling link) (answerReply (tvIntegerCeiling (envVm env)) other)
      -- A reply the host rejects abandons the very transaction that is committing a change: nothing of it is written. The prechecks
      -- ('worstReply', the revision's eligibility) make that unreachable, so it is a defect of this adapter. A read commits nothing: the
      -- host has recorded its rejection as the defect it is, which the owner raises, and that record is kept.
      when (isRemoved other && settled `elem` [ReplyDefective, ReplyRefusedValue]) (throwSTM (SettlementRejected (Text.pack (show settled))))
      writeTVar (lkTerminal link) True
  where
    ceiling' = tvIntegerCeiling (envVm env)
    isRemoved = \case
      ARemoved _ → True
      _ → False
    -- A growth's or a retry's success, with the arena's storage state as its commit left it: the service settles it last in the
    -- transaction that commits it, so the status read here is the committed one. A reply the host rejects would abandon that commit:
    -- the prechecks ('worstReply') make it unreachable, so it is this adapter's defect, as for a removal.
    creatorSettled build = do
      found ← maybe (pure Nothing) (fmap (either (const Nothing) Just) . Terrain.arenaStatusSTM (service env)) (lkArena link)
      settled ← settlingSettle (lkSettling link) (maybe (ProviderFailure "terrain: a creator command's arena has no status at its commit") build found)
      when (settled `elem` [ReplyDefective, ReplyRefusedValue]) (throwSTM (SettlementRejected (Text.pack (show settled))))
      writeTVar (lkTerminal link) True
    -- The service's lease is offered to the request, and the host is told it is a resource reply: it builds the lease at its next
    -- boundary and settles then. Whatever the host answers, the lease stays offered until it is adopted or disposed of.
    offer lease = do
      writeTVar (lkLease link) (Offered lease)
      forM_ (lkName link) (\name → holdBack (envFacade env) name link)
      settled ← settlingSettleFinal (lkSettling link) (publishable lease) (ProviderResource VNil (adoptionFor env link))
      when (settled `elem` [ReplyDefective, ReplyRefusedValue]) (throwSTM (SettlementRejected (Text.pack (show settled))))
      writeTVar (lkTerminal link) True
    -- The last look at the settlement, taken in the very transaction that publishes the result once the host has built the resource:
    -- the arena is still there, or the request settles arena_closed instead. Either way the open's name stops being held back from
    -- attach in the same step, so what is visible and what has settled are one.
    publishable lease = do
      forM_ (lkName link) (\name → letGo (envFacade env) name link)
      view ← Terrain.inspectArenaSTM (service env) lease
      -- The success is published here, in the settling transaction: only now does the lease stop being revocable by the host's
      -- withdrawal of interest.
      when (isJust view) $
        readTVar (lkLease link) >>= \case
          Adopting _ → writeTVar (lkLease link) Adopted
          _ → pure ()
      pure (maybe (Just closedFailure) (const Nothing) view)

-- | The recipe the host runs, on the owner's thread, to build the offered lease into the lease the request reserved. A request
-- that ended between the offer and the build has had its offered lease released by 'cancelWork': the resource is then built over
-- nothing, and the host, whose interest ended, releases it at once.
adoptionFor ∷ Env → Link → Adoption
adoptionFor env link =
  Adoption $ \_ →
    acquirePart
      "terrain arena"
      (releaseRank 0)
      ( do
          hookAdopting (hooks env)
          built ← atomically $
            readTVar (lkLease link) >>= \case
              Offered lease → TerrainResource (Just lease) creator <$ writeTVar (lkLease link) (Adopting lease)
              _ → pure (TerrainResource Nothing creator)
          hookAdopted (hooks env)
          pure built
      )
      releaseResource
  where
    creator = isJust (lkName link)
    -- The service's lease is released through its non-waiting release: the creator's final owner lease closes the arena, an
    -- attachment ends its client's interest only. It waits for no borrower and for nothing of the owner.
    releaseResource resource = forM_ (resourceLease resource) $ \lease → do
      hookReleasing (hooks env)
      released ← Terrain.releaseLease (service env) lease
      hookRevoked (hooks env)
      -- Only once the service has revoked the lease is the name no longer held back from attach.
      atomically $ do
        forM_ (lkName link) (\name → letGo (envFacade env) name link)
        -- A lease the host built and then released without publishing it (the request ended, the arena closed) is disposed of.
        readTVar (lkLease link) >>= \case
          Adopting _ → writeTVar (lkLease link) Disposed
          _ → pure ()
      either (throwIO . TerrainCompositionRefused . ("a lease's release was refused: " <>) . Text.pack . show) pure released

-- | Withdraw interest in a request: ask the service to cancel it, and give back an offered lease nobody adopted.
cancelWork ∷ Env → Link → Request → IO ()
cancelWork env link request = mask_ (hookCancelling (hooks env) >> tellCancelled env link request)

-- | Tell the service a request the host settled as cancelled is over, and let go of what it holds: its claim on a name and any lease
-- offered for it. Whoever finds the settlement first tells it (the host's cancel, or an open that finds the name still claimed); the
-- telling is idempotent.
tellCancelled ∷ Env → Link → Request → IO ()
tellCancelled env link request = mask_ $ do
  _ ← cancel (service env) request
  atomically (writeTVar (lkTerminal link) True)
  -- The lease is revoked before anything else is published about it: until the service has released it the arena is still the open's,
  -- its name still held back from attach and its claim still standing. Whoever finds the lease offered takes the revocation; one that
  -- finds it being revoked (another opener, while the first is held at its release) finishes it, and the release is idempotent.
  claimed ← atomically $
    readTVar (lkLease link) >>= \case
      Offered lease → Just (lease, True) <$ writeTVar (lkLease link) (Revoking lease)
      -- built by the host and not yet published: the cancellation won, and the name is free from now, not from the owner's next boundary
      Adopting lease → Just (lease, True) <$ writeTVar (lkLease link) (Revoking lease)
      Revoking lease → pure (Just (lease, False))
      _ → pure Nothing
  forM_ claimed $ \(lease, first) → do
    when first (hookReleasing (hooks env))
    void (Terrain.releaseLease (service env) lease)
    when first (hookRevoked (hooks env))
    atomically $
      readTVar (lkLease link) >>= \case
        Revoking _ → do
          writeTVar (lkLease link) Disposed
          forM_ (lkName link) (\name → letGo (envFacade env) name link)
        _ → pure ()

-- | The provider's own reading of where its work has got to, after interest was withdrawn: over when the service has reached its
-- terminal outcome for the request, no lease of it is waiting for a release, and the service has finished with what the request
-- borrowed. A request cancelled while the owner prepares its answer is withdrawn at once but retained, as a ghost, with its borrowed
-- data and credits until the owner's safe point: only then is the work over, whatever the terminal notification said. The census
-- does not say which request a ghost is, so any ghost holds every retirement back: conservative, never early, and a ghost lasts
-- no longer than the preparation that was running.
retirement ∷ Env → Link → STM RetirementState
retirement env link = do
  terminal ← readTVar (lkTerminal link)
  held ← readTVar (lkLease link)
  retained ← workHeld env link
  pure (if terminal && not (isOffered held) && not retained then ProviderComplete else ProviderPending)
  where
    isOffered = \case
      Offered _ → True
      Adopting _ → True
      Revoking _ → True
      _ → False

-- | Whether the service still holds something this request borrowed: a ghost (the census does not say which request one is, so any ghost
-- holds every request back), or this request's regional borrow, which a request that ended while its build or its delivery ran leaves with
-- the service until the owner's safe point ('Terrain.borrowHeldSTM'). The request's work is not over, and its places are not returned,
-- before both are gone.
workHeld ∷ Env → Link → STM Bool
workHeld env link = do
  ghosts ← any Terrain.censusGhost . Terrain.censusRequests <$> Terrain.inspectCensusSTM (service env)
  -- A regional request the hand-off has not yet recorded (the service admitted it and the arena closed before the record was made) cannot
  -- be asked about its borrow, which the service may still hold for a gather in flight: until it is recorded, the borrow is presumed held.
  borrowed ← readTVar (lkRequest link) >>= maybe (pure (lkRegional link)) (borrowHeldSTM (service env))
  pure (ghosts || borrowed)

-- The start ------------------------------------------------------------------------------------------------------

-- | Start a terrain request: the typed ask is held under a ticket while the host admits it, and the service is handed the
-- request after that. The credit returns the service's result to it when the host's record has been taken or discarded and
-- its work is over.
start ∷ Env → RequestContext → Text → M1Ask → Ask → IO TerrainStart
start env context endpointName ask typed = mask $ \restore → do
  drainRetired env
  requestVar ← newTVarIO Nothing
  droppedVar ← newTVarIO []
  ticket ← atomically $ do
    (next, held) ← readTVar (envAsks env)
    writeTVar (envAsks env) (next + 1, Map.insert next (Pending typed requestVar droppedVar) held)
    pure next
  let credit =
        Credit
          { creditName = "terrain request"
          , creditReserve = pure True
          , creditRelease = \case
              CreditUnused → pure ()
              -- The result the service held for the request is given back in the very transaction that gives the credit back, on the thread
              -- that does: the taking script's, or the owner's accounting of the work, whichever comes last. Nothing is queued, so no VM's
              -- later call is needed to retire what an idle VM took.
              CreditSettled → do
                readTVar requestVar >>= mapM_ (retireSTM (service env))
                -- and the lease the service made for an attach the host answered without publishing it, which it records by now
                readTVar droppedVar >>= mapM_ (releaseArenaLeaseSTM (service env))
          , creditTransfers = False
          }
      withCredit = ask {askCredits = askCredits ask <> [credit]}
  started ←
    restore (startM1 (tvRequests (envVm env)) withCredit context endpointName [VInteger (fromIntegral ticket)] (pure ()))
      `finally` discard ticket
  pure (TerrainStarted started)
  where
    discard ticket = atomically (modifyTVar' (envAsks env) (\(next, held) → (next, Map.delete ticket held)))
