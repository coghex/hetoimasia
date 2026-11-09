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
  , terrainLeaseCapacity
  , TerrainCompositionRefused (..)
  , terrainCodes
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

import Control.Concurrent.STM
import Control.Exception (Exception, finally, mask, mask_, onException, throwIO)
import Control.Monad (filterM, forM_, unless, void, when)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Unique (Unique, hashUnique, newUnique)
import Data.Word (Word64)
import Hetoimasia.Foundation.Resource (acquirePart, releaseRank)
import Hetoimasia.LuaEngine.Facade
  ( TerrainCell (..)
  , TerrainColumnAsk (..)
  , TerrainDefinition (..)
  , TerrainInjection (..)
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
  , terrainRemoveValueSchema
  , terrainSurfaceValueSchema
  )
import Hetoimasia.LuaEngine.Profile (Count (Count), CountLimit (RequestsPerInstance), Profile, countLimit)
import Hetoimasia.LuaEngine.Request
  ( M1Ask (..)
  , M1Start (M1Busy)
  , m1Ask
  , m1ArgumentCheck
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
  , SubmissionDeclined (..)
  )
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, Binding, RequestContext, capabilityType)
import Hetoimasia.Scripting.Lua.Value (Schema (SNil), Value (..), capability)
import Hetoimasia.Terrain.Cell (Cell (..), Column, IntervalError, MaterialId, ZRange, materialIdString, maxMaterialIdBytes, mkColumn, mkZRange, zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Coordinate (TileCoord, axisValue, tileCoord)
import Hetoimasia.Terrain.Query (Occupied (..), QueryLimits (..), Run (..))
import Hetoimasia.Terrain.Residency (Revision (..))
import Hetoimasia.Terrain.Runtime
  ( Answer (..)
  , ArenaLease
  , CellAnswer (..)
  , Client
  , ColumnAnswer (..)
  , Config (configMaxLeases, configQueryLimits)
  , Failure (..)
  , Precondition (..)
  , RemoveAnswer (..)
  , Refused (..)
  , Request
  , Service
  , Settlement (..)
  , SurfaceAnswer (..)
  , endClient
  , registerClient
  )
import qualified Hetoimasia.Terrain.Runtime as Terrain
import Hetoimasia.Terrain.Runtime.Settlement
  ( Endpoint (..)
  , attachArenaWith
  , cancel
  , cellWith
  , columnWith
  , openArenaWith
  , removeWith
  , retire
  , surfaceWith
  )
import Hetoimasia.Terrain.Shape (shapeIdValue)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))

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
  , tfOffered ∷ !(TVar (Map Text (Set Unique)))
  -- ^ The names whose open the service committed and the host has not yet adopted or let go, each with the opens (by incarnation:
  -- every open request has its own identity) that hold it back: shared by every VM of the service, so that an attach, whichever VM
  -- makes it, is not eligible while the arena it would find is not yet the open's settled result. An open lets go only of its own
  -- entry, so a late cleanup of an earlier open of the name never shows a later open's arena before it has settled.
  }

-- | An open the service holds a name for: whether the host has settled it without telling the service, and the telling.
data Claim = Claim
  { clStale ∷ STM Bool
  -- ^ The host has settled the request without the service's telling (it was cancelled, or its requester ended) and the service
  -- still holds the claim: whether the offered lease was adopted does not matter, an adopted open is the arena's own claim.
  , clDone ∷ STM Bool
  -- ^ The request reached its end for the adapter: the service answered it (or was told) and no offered lease waits to be adopted.
  , clCancel ∷ IO ()
  }

-- | An open's name is held back from attach, from the service's commit of the open until the host has adopted or let go of its lease.
holdBack ∷ TerrainFacade → Text → Link → STM ()
holdBack facade name link = modifyTVar' (tfOffered facade) (Map.insertWith Set.union name (Set.singleton (lkId link)))

-- | Let go of this open's own hold on a name, and of nothing another open of the name holds.
letGo ∷ TerrainFacade → Text → Link → STM ()
letGo facade name link =
  modifyTVar' (tfOffered facade) (Map.update (\held → let rest = Set.delete (lkId link) held in if Set.null rest then Nothing else Just rest) name)

-- | Whether some open still holds a name back from attach.
heldBack ∷ TerrainFacade → Text → STM Bool
heldBack facade name = Map.member name <$> readTVar (tfOffered facade)

-- | A composition over a service, with no pick authority issued, no hooks and no extra bindings.
newTerrainFacade ∷ Profile → Service → Config → IO TerrainFacade
newTerrainFacade profile svc config = do
  picks ← newTerrainPicks
  claims ← newTVarIO Map.empty
  offered ← newTVarIO Map.empty
  pure (TerrainFacade profile svc config picks noTerrainHooks [] claims offered)

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
  , hookSubmitting ∷ IO ()
  -- ^ The host admitted a request (its places are reserved) and the hand-off is about to ask the service, masked: the window between a
  -- permanent precheck and the service's own admission, in which the service can close.
  , hookRevoked ∷ IO ()
  -- ^ The service has released the lease of an open (the script's release of its arena, or a cancelled open's revocation) and the open
  -- has not yet let go of its hold on the name (the name is free for the service's next open): the window in which a later open of the
  -- same name can already be offered.
  }

noTerrainHooks ∷ TerrainHooks
noTerrainHooks = TerrainHooks (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (pure ()) (pure ())

-- | Why a VM's terrain could not be composed: a failure of the composition, never a script's.
newtype TerrainCompositionRefused = TerrainCompositionRefused Text
  deriving (Eq, Show)

instance Exception TerrainCompositionRefused

-- | Raised inside the service's committing transaction when the host rejects the reply that settles it: the transaction is abandoned
-- with nothing of the change written, and the service treats it as the provider defect it is.
newtype SettlementRejected = SettlementRejected Text
  deriving (Eq, Show)

instance Exception SettlementRejected

-- | The expected failure codes the terrain requests supply (D-19 and the manager's two authorizations): the only codes a
-- terrain reply may carry. Any other outcome of the service is a defect of the host.
terrainCodes ∷ [Text]
terrainCodes = ["not_found", "arena_closed", "stale_view", "definition", "source_failure", "too_large", "name_in_use"]

-- | The lease capacity one instance needs in the VM's shared scope for terrain: every lease the service can hold at once (its
-- cap is service-wide, so one instance may hold them all, pending, live and retiring), the places its requests can reserve a
-- lease for before the service has admitted them, and one of headroom, as graphics does. Derived, not chosen: it follows the
-- service's cap and the profile's, and changes neither.
terrainLeaseCapacity ∷ Profile → Config → Int
terrainLeaseCapacity profile config = configMaxLeases config + fromIntegral perInstance + 1
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
newtype TerrainResource = TerrainResource {resourceLease ∷ Maybe ArenaLease}

-- | A request's offered lease: offered by the commit, adopted by the host, or disposed of by this adapter when the host
-- withdrew its interest first. One transition out of offered, decided in one transaction.
data LeaseCell
  = NoLease
  | Offered !ArenaLease
  | -- | The host's interest ended and the lease is being revoked: the service's release has not completed, so the arena is still the
    -- open's and its name still held back, until whoever revokes it has finished.
    Revoking !ArenaLease
  | Adopted
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
  , lkId ∷ !Unique
  -- ^ The identity of this request's incarnation of the name it opens: what it holds in 'tfOffered', and all it ever lets go of.
  }

-- The per-VM state ----------------------------------------------------------------------------------------

-- | One typed request, held between the binding's start and the service's hand-off.
data Ask
  = AskOpen !Client !Text !SourceSpec
  | AskAttach !Client !Text
  | AskCell !ArenaLease !TileCoord
  | AskColumn !ArenaLease !Column !ZRange
  | AskSurface !ArenaLease !Column
  | AskRemove !ArenaLease !TileCoord !(Maybe Precondition)

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
  }

data Env = Env
  { envFacade ∷ !TerrainFacade
  , envVm ∷ !TerrainVm
  , envSession ∷ !Int
  , envClients ∷ !(TVar (Map Text Clients))
  , envAsks ∷ !(TVar (Word64, Map Word64 Pending))
  , envRetire ∷ !(TVar [Request])
  , envIssued ∷ !(TVar (Map Text (Set Word64)))
  -- ^ The arena handles each live instance was issued: ownership is positive, so another instance's handle is refused for as long
  -- as the caller lives, whether or not the issuing instance does. The memory is the handles the instance issued, ended with it.
  , envDropped ∷ !(TVar [ArenaLease])
  -- ^ Leases the service made for a request the host settled instead of publishing them: released at the next drain.
  }

service ∷ Env → Service
service = tfService . envFacade

hooks ∷ Env → TerrainHooks
hooks = tfHooks . envFacade

-- | The injection a session is composed with: for each role's VM, its own client table over the shared service, in the VM's own
-- lending and lease scope.
terrainInjection ∷ TerrainFacade → TerrainInjection
terrainInjection config =
  TerrainInjection
    { tiLeaseCapacity = \profile → terrainLeaseCapacity profile (tfConfig config)
    , injectTerrain = \vm → do
        clients ← newTVarIO Map.empty
        asks ← newTVarIO (1, Map.empty)
        retiring ← newTVarIO []
        issued ← newTVarIO Map.empty
        dropped ← newTVarIO []
        let env = Env config vm (hashUnique (tvSession vm)) clients asks retiring issued dropped
        pure (services env)
    }

services ∷ Env → TerrainServices
services env =
  TerrainServices
    { tsTypes = [leaseCapabilityType leases terrainArenaType, capabilityType terrainPickType pickLive]
    , tsEndpoints = endpoints
    , tsDeclare = declare env
    , tsForget = forget env
    , tsOpenCheck = \_ _ _ _ owner values → permanent env (const openAsk) owner values
    , tsOpenStart = \identity root name definition context → do
        client ← clientOf env identity
        start env context openName openAsk (AskOpen client (nameKey env root name) (sourceSpec definition))
    , tsAttachCheck = \_ _ _ owner values → permanent env (const attachAsk) owner values
    , tsAttachStart = \identity root name context → do
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
    , tsCellCheck = \identity key _ owner values → leaseCheck env identity key readAsk owner values
    , tsCellStart = \_ key cell context → withArena env key $ \lease →
        startOr cell (\tile → start env context cellName readAsk (AskCell lease tile))
    , tsColumnCheck = \identity key _ owner values → leaseCheck env identity key readAsk owner values
    , tsColumnStart = \_ key ask context → withArena env key $ \lease →
        case columnOf ask of
          Left why → pure (TerrainRefused why)
          Right (column, range) → start env context columnName readAsk (AskColumn lease column range)
    , tsSurfaceCheck = \identity key _ _ owner values → leaseCheck env identity key readAsk owner values
    , tsSurfaceStart = \_ key x y context → withArena env key $ \lease →
        case mkColumn (toInteger x) (toInteger y) of
          Left _ → pure (TerrainRefused "the column is outside the supported range")
          Right column → start env context surfaceName readAsk (AskSurface lease column)
    , tsRemoveCheck = \identity key _ pick owner values → do
        refused ← pickCheck env identity pick
        case refused of
          Just why → pure (Just why)
          Nothing → leaseCheck env identity key readAsk owner values
    , tsRemoveStart = \identity key cell pick context → withArena env key $ \lease → do
        precondition ← pickPrecondition env identity pick
        case precondition of
          Left why → pure (TerrainRefused why)
          Right found → startOr cell (\tile → start env context removeName readAsk (AskRemove lease tile found))
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
      , endpoint env cellName terrainCellValueSchema
      , endpoint env columnName terrainColumnValueSchema
      , endpoint env surfaceName terrainSurfaceValueSchema
      , endpoint env removeName terrainRemoveValueSchema
      ]
    releaseWord = \case
      Released → "done"
      Retiring → "retiring"
      AlreadyReleased → "already_released"

-- | The endpoint names of the requests.
openName, attachName, cellName, columnName, surfaceName, removeName ∷ Text
openName = "terrain_open"
attachName = "terrain_attach"
cellName = "terrain_cell"
columnName = "terrain_column"
surfaceName = "terrain_surface"
removeName = "terrain_remove"

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

-- | The name the service holds for an instance's name: in the session's and the instance's content root's namespace.
nameKey ∷ Env → Text → Text → Text
nameKey env root name = "s" <> Text.pack (show (envSession env)) <> "/" <> root <> "/" <> name

-- | The retire queue's drain: every request whose host record has been taken or discarded and whose work is over gives the
-- service back the result it held, in IO, on whichever thread drains it. Never blocks.
drainRetired ∷ Env → IO ()
drainRetired env = do
  requests ← atomically (swapTVar (envRetire env) [])
  forM_ (reverse requests) (retire (service env))
  atomically (pruneClaims (envFacade env))
  dropped ← atomically (swapTVar (envDropped env) [])
  forM_ (reverse dropped) (Terrain.releaseLease (service env))

-- The asks ------------------------------------------------------------------------------------------------------

openAsk, attachAsk, readAsk ∷ M1Ask
openAsk = leaseAsk "terrain open"
attachAsk = leaseAsk "terrain attach"
readAsk = (m1Ask OptionalRequest "terrain read") {askCodes = terrainCodes}

leaseAsk ∷ Text → M1Ask
leaseAsk source =
  (m1Ask OptionalRequest source)
    { askCodes = terrainCodes
    , askLease = Just (InstanceOwned, \_ key → VCapability (capability terrainArenaType key))
    }

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
  where
    expected code message = ProviderExpected (ExpectedFailure code message Nothing Nothing)

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
  AAttached _ → ProviderFailure "terrain: a lease answer reached the value conversion"
  where
    withRevision revision build = case revisionOf ceiling' revision of
      Just found → ProviderResult (build found)
      Nothing → ProviderFailure "terrain: a content revision is not a Lua integer"

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
  link ←
    Link
      (case pdAsk found of AskAttach _ name → Just name; _ → Nothing)
      (case pdAsk found of AskOpen _ name _ → Just name; _ → Nothing)
      settling
      <$> newTVarIO NoLease
      <*> newTVarIO False
      <*> newUnique
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
            AskOpen {} → pure True
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
          }
  -- A name whose open the host settled as cancelled (and the service was not yet told) is free: let that claim go before asking.
  case pdAsk found of
    AskOpen _ name _ → releaseStale env name
    _ → pure ()
  hookSubmitting (hooks env)
  admitted ← case pdAsk found of
    AskOpen client name spec → openArenaWith (service env) ep client name spec
    AskAttach client name → attachArenaWith (service env) ep client name
    AskCell lease tile → cellWith (service env) ep lease tile
    AskColumn lease column range → columnWith (service env) ep lease column range
    AskSurface lease column → surfaceWith (service env) ep lease column
    AskRemove lease tile precondition → removeWith (service env) ep lease tile precondition
  case admitted of
    Left refused → throwIO (declination refused)
    Right request → do
      atomically (writeTVar (pdRequest found) (Just request) >> note)
      case pdAsk found of
        AskOpen _ name _ → do
          let claim = Claim (stale link (submissionSettled submission)) (done link) (tellCancelled env link request)
          atomically $ do
            pruneClaims (envFacade env)
            over ← clDone claim
            -- A request that has already ended needs no claim: only what is still open can be found stale.
            unless over (modifyTVar' (tfClaims (envFacade env)) (Map.insertWith (<>) name [claim]))
        _ → pure ()
      hookSubmitted (hooks env)
      pure
        ProviderWork
          { workCancel = cancelWork env link request
          , workRetirement = retirement link
          }

-- | The largest answer a read or a removal can have, as the reply the host judges: a revision at the greatest integer, every field
-- present, and for a column as many runs as the range has levels and the service will return (more is @too_large@, a failure that
-- carries no answer). Nothing for a request whose result is a lease or a failure.
worstReply ∷ Env → Ask → Maybe ProviderReply
worstReply env = \case
  AskCell {} → Just (ProviderResult (VRecord (("revision", greatest) : solid)))
  AskColumn _ _ range →
    let levels = max 1 (toInteger (zRangeHi range) - toInteger (zRangeLo range))
        runs = fromInteger (min (toInteger (limitReturnedRuns (configQueryLimits (tfConfig (envFacade env))))) levels)
     in Just (ProviderResult (VRecord [("revision", greatest), ("runs", VList (replicate runs (VRecord ([("z_min", greatest), ("z_max", greatest)] <> solid))))]))
  AskSurface {} → Just (ProviderResult (VRecord [("revision", greatest), ("occupied", VBoolean True), ("z", greatest), ("material", longest), ("shape", greatest)]))
  AskRemove {} → Just (ProviderResult (VRecord [("changed", VBoolean True), ("revision", greatest)]))
  _ → Nothing
  where
    greatest = VInteger maxBound
    longest = VText (Text.replicate maxMaterialIdBytes "m")
    solid = [("air", VBoolean False), ("material", longest), ("shape", greatest)]

-- | Let go of the claims on a name whose request the host has already settled without the service being told: the service is told
-- now, which frees the name, before another open asks for it.
releaseStale ∷ Env → Text → IO ()
releaseStale env name = do
  tells ← atomically $ do
    pruneClaims (envFacade env)
    held ← Map.findWithDefault [] name <$> readTVar (tfClaims (envFacade env))
    flags ← mapM clStale held
    pure [clCancel claim | (claim, True) ← zip held flags]
  sequence_ tells

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
  pure (answered && case cell of Offered _ → False; Revoking _ → False; _ → True)

-- | Forget the claims of requests that have ended, so the registry holds only what is still open: bounded by the opens in flight,
-- whatever came and went, and empty once every instance has been forgotten.
pruneClaims ∷ TerrainFacade → STM ()
pruneClaims facade = do
  held ← readTVar (tfClaims facade)
  kept ← traverse (filterM (fmap not . clDone)) held
  writeTVar (tfClaims facade) (Map.filter (not . null) kept)

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
      Terrain.BusyRetainedEdits → "retained edits"
      Terrain.BusyArenas → "arenas"
      Terrain.BusyLeases → "leases"
      Terrain.BusyViews → "views"
      Terrain.BusyClients → "clients"
      Terrain.BusyRetained → "retained results"

-- | The service's terminal outcome of a request, in the very transaction that decides it: the host's seam is read and written
-- in it, and nothing else is.
settleInto ∷ Env → Link → Settlement → STM ()
settleInto env link = \case
  Cancelled → settlingCancel (lkSettling link) >> writeTVar (lkTerminal link) True
  Failed failure → do
    _ ← settlingSettle (lkSettling link) (failureReply failure)
    writeTVar (lkTerminal link) True
  Succeeded answer → case answer of
    AOpened lease → offer lease
    AAttached lease → do
      -- An attach is decided against the names that have settled for the service, and an open the host has not yet published is not one
      -- for the host: it answers not_found without waiting, and the service's lease for it is let go at the next drain.
      pending ← maybe (pure False) (heldBack (envFacade env)) (lkAttach link)
      if pending
        then do
          modifyTVar' (envDropped env) (lease :)
          _ ← settlingSettle (lkSettling link) (failureReply NotFound)
          writeTVar (lkTerminal link) True
        else offer lease
    other → do
      settled ← settlingSettle (lkSettling link) (answerReply (tvIntegerCeiling (envVm env)) other)
      -- A reply the host rejects abandons the very transaction that is committing a change: nothing of it is written. The prechecks
      -- ('worstReply', the revision's eligibility) make that unreachable, so it is a defect of this adapter. A read commits nothing: the
      -- host has recorded its rejection as the defect it is, which the owner raises, and that record is kept.
      when (isRemoved other && settled `elem` [ReplyDefective, ReplyRefusedValue]) (throwSTM (SettlementRejected (Text.pack (show settled))))
      writeTVar (lkTerminal link) True
  where
    isRemoved = \case
      ARemoved _ → True
      _ → False
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
              Offered lease → TerrainResource (Just lease) <$ writeTVar (lkLease link) Adopted
              _ → pure (TerrainResource Nothing)
          hookAdopted (hooks env)
          pure built
      )
      releaseResource
  where
    -- The service's lease is released through its non-waiting release: the creator's final owner lease closes the arena, an
    -- attachment ends its client's interest only. It waits for no borrower and for nothing of the owner.
    releaseResource resource = forM_ (resourceLease resource) $ \lease → do
      hookReleasing (hooks env)
      released ← Terrain.releaseLease (service env) lease
      hookRevoked (hooks env)
      -- Only once the service has revoked the lease is the name no longer held back from attach.
      atomically (forM_ (lkName link) (\name → letGo (envFacade env) name link))
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

-- | The provider's own reading of where its work has got to, after interest was withdrawn: over when the service has reached
-- its terminal outcome for the request and no offered lease is waiting for a release.
retirement ∷ Link → STM RetirementState
retirement link = do
  terminal ← readTVar (lkTerminal link)
  held ← readTVar (lkLease link)
  pure (if terminal && not (isOffered held) then ProviderComplete else ProviderPending)
  where
    isOffered = \case
      Offered _ → True
      Revoking _ → True
      _ → False

-- The start ------------------------------------------------------------------------------------------------------

-- | Start a terrain request: the typed ask is held under a ticket while the host admits it, and the service is handed the
-- request after that. The credit returns the service's result to it when the host's record has been taken or discarded and
-- its work is over.
start ∷ Env → RequestContext → Text → M1Ask → Ask → IO TerrainStart
start env context endpointName ask typed = mask $ \restore → do
  drainRetired env
  requestVar ← newTVarIO Nothing
  ticket ← atomically $ do
    (next, held) ← readTVar (envAsks env)
    writeTVar (envAsks env) (next + 1, Map.insert next (Pending typed requestVar) held)
    pure next
  let credit =
        Credit
          { creditName = "terrain request"
          , creditReserve = pure True
          , creditRelease = \case
              CreditUnused → pure ()
              CreditSettled → readTVar requestVar >>= mapM_ (\request → modifyTVar' (envRetire env) (request :))
          , creditTransfers = False
          }
      withCredit = ask {askCredits = askCredits ask <> [credit]}
  started ←
    restore (startM1 (tvRequests (envVm env)) withCredit context endpointName [VInteger (fromIntegral ticket)] (pure ()))
      `finally` discard ticket
  pure (TerrainStarted started)
  where
    discard ticket = atomically (modifyTVar' (envAsks env) (\(next, held) → (next, Map.delete ticket held)))
