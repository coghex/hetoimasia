{-# LANGUAGE OverloadedStrings #-}

-- | What a facade is made of. Hidden: "Hetoimasia.LuaEngine.Facade" is the public view. Nothing here
-- runs Lua; the modules beside it hold the bindings, the Lua source and the resolver.
--
-- = Who owns what
--
-- One 'Facade' belongs to one VM, made before its owner (the owner's configuration is built from it)
-- and living inside the session's scopes that own what it borrows: the pool, the inventory, the
-- coordinator and the 'Output'. Its mutable state is two variables, each changed only in a
-- transaction that checks and changes it together:
--
-- * 'fcRegistry': the instances declared to it and the host instance each is bound to. Written by
--   the application's thread ('declareInstance', 'forgetInstance') and by the owner's thread (the
--   builder's one call to bind), read by every binding a hook calls.
-- * 'fcTime': the presentation clock's origin and each instance's sample of the current segment.
--   Written on the owner's thread at the start of a segment, read by the owner's thread.
--
-- Nothing here is a registry of services: every endpoint a binding reaches is a field of the one
-- facade its closure was built over, and a facade is not reachable from Lua.
module Hetoimasia.LuaEngine.Facade.Types
  ( -- * Services injected from outside
    AdmissionState (..)
  , EngineFailure (..)
  , FacadeEndpoints (..)
  , SessionEndpoints (..)
  , StatusSample (..)
  , RoleSample (..)
  , FailureSample (..)
  , TerminalStage (..)
  , TerminalContext (..)
  , stateUnavailableMessage
  , OutputSink (..)
  , Output (..)
  , OutputState (..)
  , Stream (..)
    -- * The facade
  , Facade (..)
  , InstanceIds (..)
  , InstanceRecord (..)
  , Registry (..)
  , TimeState (..)
  , StatusState (..)
  , FacadeLimits (..)
    -- * Injected graphics
  , TextureImageKind (..)
  , TextureOptions (..)
  , defaultTextureOptions
  , textureNormalEncodingNames
  , GraphicsStart (..)
  , GraphicsVm (..)
  , GraphicsInjection (..)
  , GraphicsServices (..)
  , graphicsTextureType
  , graphicsWindowType
  , graphicsTextureRequestType
  , graphicsWindowRequestType
  , graphicsTextureValueSchema
  , graphicsWindowValueSchema
    -- * Injected terrain
  , TerrainVm (..)
  , TerrainInjection (..)
  , TerrainServices (..)
  , TerrainStart (..)
  , TerrainCell (..)
  , TerrainColumnAsk (..)
  , TerrainDefinition (..)
  , TerrainLayer (..)
  , TerrainPatch (..)
  , TerrainPatchValue (..)
  , terrainArenaType
  , terrainPickType
  , terrainArenaRequestType
  , terrainCellRequestType
  , terrainColumnRequestType
  , terrainSurfaceRequestType
  , terrainRemoveRequestType
  , terrainArenaValueSchema
  , terrainCellValueSchema
  , terrainColumnValueSchema
  , terrainSurfaceValueSchema
  , terrainRemoveValueSchema
  , terrainNameLimit
  , terrainMaterialBytesLimit
  , terrainCellLow
  , terrainCellHigh
  , terrainEndpointHigh
    -- * Injected input
  , graphicsInputResetType
  , InputServices (..)
  , InputPoll (..)
  , InputAck (..)
  , InputPacket (..)
  , InputDisposition (..)
  , InputEventRecord (..)
  , InputBody (..)
  , InputKeyAction (..)
  , InputButtonAction (..)
  , InputModifiers (..)
  , InputResetInfo (..)
  , InputResetReason (..)
  , InputObservation (..)
  , engineNamespaceName
  , engineBuilderName
    -- * Failures
  , FacadeDefect (..)
  ) where

import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM (STM, TVar)
import Control.Exception (Exception, SomeException)
import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Unique (Unique)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word64)
import Numeric.Natural (Natural)
import Hetoimasia.Content.Identity (ContentKey)
import Hetoimasia.Content.Inventory (Inventory)
import Hetoimasia.Foundation.Time (Duration, Instant, MonotonicSource)
import Hetoimasia.LuaEngine.Data (DataService)
import Hetoimasia.LuaEngine.Manifest (Role)
import Hetoimasia.LuaEngine.Modules (Coordinator)
import Hetoimasia.LuaEngine.Profile (Profile)
import Hetoimasia.LuaEngine.Request (M1Requests, M1Start)
import Hetoimasia.Scripting.Lua.Lease (Leases)
import Hetoimasia.Scripting.Lua.Lending (Lending)
import Hetoimasia.Scripting.Lua.Owner (ModulePhase)
import Hetoimasia.Scripting.Lua.Provider (RequestEndpoint)
import Hetoimasia.Scripting.Lua.Registration (ArgumentCheck, Binding, CapabilityType, RequestContext)
import Hetoimasia.Scripting.Lua.Value (Schema (SBoolean, SCapability, SInteger, SList, SOptional, SRecord, SText))

-- Services injected from outside -------------------------------------------------------------------

-- | Whether the session takes new work, as the facade reads it before a request starts. The session
-- coordinator (LFE-13) owns the real answer; the facade only asks.
data AdmissionState
  = -- | New work is taken.
    AdmissionOpen
  | -- | A stop has been asked: nothing new starts.
    AdmissionStopping
  | -- | Admission is closed for good.
    AdmissionClosed
  deriving (Eq, Show)

-- | An engine failure: not a mistake of a script but a fact the engine cannot go on from (a tick
-- that no Lua integer holds, a clock that cannot be read, an inconsistent registry). It is reported
-- through the injected failure boundary and raised from the binding that met it, so it ends the owner
-- as a failure of the host whatever Lua did with the stand-in error.
newtype EngineFailure = EngineFailure Text
  deriving (Eq, Show)

instance Exception EngineFailure

-- | The narrow endpoints a facade is injected with. None of them is a service locator: each is one
-- fact a binding needs, supplied by the assembly that owns it.
data FacadeEndpoints = FacadeEndpoints
  { endpointAdmission ∷ IO AdmissionState
  -- ^ Read before a content request starts. A stopping or closed session is an ordinary Lua error
  -- before any action, never busy.
  , endpointFailure ∷ EngineFailure → IO ()
  -- ^ The failure boundary: told, on the owner's thread, of an engine failure, just before the
  -- binding raises it. It must not run Lua and must not itself write through the authored output.
  , endpointClock ∷ MonotonicSource
  -- ^ The monotonic clock a presentation VM samples and an elapsed wait is placed on. It is the
  -- clock the owner was configured with, so that a deadline is checked against the clock that places it.
  , endpointTick ∷ IO Word64
  -- ^ The logical tick a gameplay VM is at, read live. Used by a gameplay facade only.
  }

-- | The narrow session-control endpoints a facade is injected with (LFE-26): the three facts and the two
-- operations the status, quit and unavailable-state bindings need, and nothing else. The session
-- coordinator (LFE-13) owns every answer; the facade only asks, copies and marshals. None is a service
-- locator and none gives a script a handle: each is reached through a closure built over one facade.
data SessionEndpoints = SessionEndpoints
  { endpointStatus ∷ STM StatusSample
  -- ^ One coherent, bounded, nonblocking read of the session's status. Read once at the entry of every
  -- presentation hook and resumed segment, in the same transaction that stores it, and never when a
  -- script calls @status@.
  , endpointQuit ∷ IO ()
  -- ^ Ask for a normal whole-session stop: idempotent, no slot, no result, closes new work and future
  -- logical tick grants before it returns, and waits for nothing.
  , endpointTerminal ∷ TerminalContext → IO Bool
  -- ^ Latch the unavailable-state guard's terminal failure and end the whole session. Answers whether
  -- this was the first such latch, which is when the diagnostic is claimed; the failure record is the
  -- coordinator's to build and bound.
  }

-- | The session's status as a script may be shown it: the coordinator's facts, as plain data.
data StatusSample = StatusSample
  { sampleStopping ∷ !Bool
  -- ^ Whole-session stop, not merely a failed logical role.
  , sampleGameplay ∷ !(Maybe RoleSample)
  -- ^ 'Nothing' for a role the session does not have.
  , samplePresentation ∷ !(Maybe RoleSample)
  }
  deriving (Eq, Show)

-- | One present role. A role is failed exactly when it has a failure.
data RoleSample = RoleSample
  { sampleInitialized ∷ !Bool
  -- ^ Its own @init@ succeeded; historical.
  , samplePhase ∷ !Text
  -- ^ @starting@, @ready@, @running@, @stopping@ or @retired@.
  , sampleFailure ∷ !(Maybe FailureSample)
  }
  deriving (Eq, Show)

-- | A role's latched failure, every text already bounded by the coordinator. An unknown optional field
-- is 'Nothing' and absent from what a script sees.
data FailureSample = FailureSample
  { sfCode ∷ !Text
  , sfMessage ∷ !Text
  , sfRole ∷ !Text
  , sfStage ∷ !Text
  , sfContentId ∷ !(Maybe Text)
  , sfInstanceId ∷ !(Maybe Text)
  , sfPath ∷ !(Maybe Text)
  , sfTraceback ∷ !(Maybe Text)
  }
  deriving (Eq, Show)

-- | Where the unavailable-state guard was called from: the context that was executing.
data TerminalStage
  = -- | An authored module's top level, including evaluation resumed from an import chain.
    TerminalModule
  | TerminalInit
  | TerminalUpdate
  | TerminalShutdown
  deriving (Eq, Show)

-- | What the facade knows of a guard call, and all it says: the executing role and stage and, when an
-- instance was running, the content and the instance; when an authored module's top level was running, the
-- module's content and path, as the loader's canonical identity names them. A module-only call invents no
-- instance, and a hook names no path (the failure of a hook has none).
data TerminalContext = TerminalContext
  { terminalRole ∷ !Role
  , terminalStage ∷ !TerminalStage
  , terminalContent ∷ !(Maybe Text)
  , terminalInstance ∷ !(Maybe Text)
  , terminalPath ∷ !(Maybe Text)
  }
  deriving (Eq, Show)

-- | The one fixed phrase of the unavailable-state guard: the failure's message, the line written to
-- stderr when the guard is first claimed, and the text of the Lua error it raises. The same for either VM
-- and either spelling.
stateUnavailableMessage ∷ Text
stateUnavailableMessage = "state service not available in this milestone"

-- | One line sink of a stream, with the flush that follows each authored call. A sink that raises
-- ends the owner; nothing retries it and nothing is reported through it.
data OutputSink = OutputSink
  { sinkLine ∷ Text → IO ()
  , sinkFlush ∷ IO ()
  }

-- | The two streams authored output reaches.
data Stream = Stdout | Stderr
  deriving (Eq, Show)

-- The facade ---------------------------------------------------------------------------------------

-- | The numbers a facade works to, read once from its profile.
data FacadeLimits = FacadeLimits
  { limitInstanceIdBytes ∷ !Int
  , limitInstances ∷ !Int
  , limitPrintBytes ∷ !Int
  , limitIntegerMaximum ∷ !Word64
  , limitMessageBytes ∷ !Int
  }
  deriving (Eq, Show)

-- | The session's source of instance identities, shared by every VM's facade so that an identity is
-- unique in the session and never reused.
newtype InstanceIds = InstanceIds (TVar Word64)

-- | One instance declared to a facade.
data InstanceRecord = InstanceRecord
  { recordId ∷ !Text
  -- ^ The opaque identity the script sees as @instance_id@.
  , recordRole ∷ !Role
  , recordContent ∷ !Text
  -- ^ The content identifier the instance requests by default.
  , recordNumber ∷ !(Maybe Word64)
  -- ^ The host's local number of the instance it is bound to, once the builder has bound it.
  }
  deriving (Eq, Show)

-- | The instances declared to one facade, by identity and by the host instance each is bound to.
data Registry = Registry
  { registryRecords ∷ !(TVar (Map Text InstanceRecord))
  , registryNumbers ∷ !(TVar (Map Word64 Text))
  }

-- | The presentation clock: the one origin, set when the VM starts its first instance's
-- initialization, and each instance's sample of the segment it is running.
data TimeState = TimeState
  { timeOrigin ∷ !(TVar (Maybe Instant))
  , timeSamples ∷ !(TVar (Map Word64 Duration))
  }

-- | Each presentation instance's capture of the session's status for the segment it is running, keyed by
-- the host's local number of the instance. Written on the owner's thread at a segment's entry, read by
-- the owner's thread; one entry per declared instance, removed with it. A capture is immutable data, so
-- every read of a segment is the same value, and a script is only ever handed a fresh copy.
newtype StatusState = StatusState
  { statusSamples ∷ TVar (Map Word64 StatusSample)
  }

-- | One VM's facade.
data Facade = Facade
  { fcRole ∷ !Role
  , fcProfile ∷ !Profile
  , fcLimits ∷ !FacadeLimits
  , fcRequests ∷ !M1Requests
  , fcCoordinator ∷ !Coordinator
  , fcData ∷ !DataService
  , fcInventory ∷ !Inventory
  , fcOutput ∷ !Output
  , fcEndpoints ∷ !FacadeEndpoints
  , fcPhase ∷ !ModulePhase
  , fcRoots ∷ ![Text]
  , fcIds ∷ !InstanceIds
  , fcTickDuration ∷ !(Maybe Duration)
  , fcRegistry ∷ !Registry
  , fcTime ∷ !TimeState
  , fcSession ∷ !SessionEndpoints
  , fcStatus ∷ !StatusState
  , fcGraphics ∷ !(Maybe GraphicsServices)
  -- ^ The graphics operations of this VM, when the composition injected any. 'Nothing' keeps every call of the
  -- facade as it was and adds none.
  , fcTerrain ∷ !(Maybe TerrainServices)
  -- ^ The terrain operations of this VM, when the composition injected any. 'Nothing' keeps every call, field,
  -- handle type and request kind of the facade as it was: no @api.terrain@, no terrain operation of @api.request@.
  }

-- Injected graphics ---------------------------------------------------------------------------------

-- | The name of the capability type of a texture lease's handle. The graphics adapter's own spelling is
-- checked equal to this by its tests; the CPU facade names it here because it imports neither the texture
-- pipeline nor the window provider.
graphicsTextureType ∷ Text
graphicsTextureType = "texture"

-- | The name of the capability type of a window lease's handle.
graphicsWindowType ∷ Text
graphicsWindowType = "window"

-- | The request handle types of a texture request and of a window request.
graphicsTextureRequestType, graphicsWindowRequestType ∷ Text
graphicsTextureRequestType = "texture_request"
graphicsWindowRequestType = "window_request"

-- | What @take@ hands as the success value of a texture request: @{texture = HANDLE, width = INTEGER, height = INTEGER}@.
graphicsTextureValueSchema ∷ Schema
graphicsTextureValueSchema = SRecord [("texture", SCapability graphicsTextureType), ("width", SInteger), ("height", SInteger)]

-- | What @take@ hands as the success value of a window request: the window handle itself.
graphicsWindowValueSchema ∷ Schema
graphicsWindowValueSchema = SCapability graphicsWindowType

-- | The image kind a texture request asks for: @kind = "colour"@ (the default) or @kind = "data"@.
data TextureImageKind
  = ImageColour
  | ImageData
  deriving (Eq, Show)

-- | What @api.content.texture(path, options)@ asked beyond the root and the optional flag, as the facade
-- parsed and checked it before any provider is asked. The facade validates the spelling and the one
-- incompatible combination (a normal encoding on a colour image); what the options mean to the load is the
-- injected service's.
data TextureOptions = TextureOptions
  { optionKind ∷ !TextureImageKind
  , optionBinaryCoverage ∷ !Bool
    -- ^ @coverage = "binary"@.
  , optionNormalEncoding ∷ !(Maybe Text)
    -- ^ The checked name of @normal_encoding@, one of 'textureNormalEncodingNames'. Only with data.
  }
  deriving (Eq, Show)

-- | The options of a request that gave none: premultiplied sRGB colour, no coverage, no encoding.
defaultTextureOptions ∷ TextureOptions
defaultTextureOptions = TextureOptions ImageColour False Nothing

-- | The normal encodings @normal_encoding@ names: exactly these spellings, case-sensitive.
textureNormalEncodingNames ∷ [Text]
textureNormalEncodingNames = ["unit-normal-rgb-v1"]

-- | What a request-producing graphics service answered once the facade's checks passed.
data GraphicsStart
  = -- | The host's answer: the request, or busy with nothing reserved.
    GraphicsStarted !M1Start
  | -- | A permanent refusal that reached the admission after the check passed (an owner that ended, a stopping
    -- provider): nothing was reserved. The facade raises it as the ordinary error it is.
    GraphicsRefused !Text
  deriving (Eq, Show)

-- | What the composition is told of the VM it makes graphics services for.
data GraphicsVm = GraphicsVm
  { gvRole ∷ !Role
  -- ^ The VM's role. A logical VM is given the same layout; every graphics call it makes is refused.
  , gvRequests ∷ !M1Requests
  -- ^ The VM's request policy, already gated on the session's admission: the one the services admit with.
  , gvTakesWork ∷ !(STM Bool)
  -- ^ Whether the session still takes new work for this role, as a transaction: the authority a publication reads in the
  -- very transaction that commits it, so that a stop that wins between the check and the commit refuses the whole scene.
  , gvSharedCapacity ∷ !Int
  -- ^ The leases per instance that the VM's other services (terrain, when injected) hold in the same scope: the scope this
  -- injection makes must have room for them beside its own, since a VM has exactly one lending and one lease scope. Zero when
  -- graphics is the VM's only leasing service.
  }

-- | How a composition injects graphics: a function from one VM to its services. The session coordinator holds it
-- as an abstract value and calls it once for each role's VM; it reaches no global and no registry.
newtype GraphicsInjection = GraphicsInjection {injectGraphics ∷ GraphicsVm → IO GraphicsServices}

-- | The narrow graphics operations of one VM, supplied by a composition. The CPU facade validates the
-- caller, role, phase, session admission, arity and every argument's shape and decides which Lua error a
-- refusal is; these do what only the providers can: check the provider's own facts, start the request and
-- release. Every operation names the calling instance by the identity the facade issued it.
data GraphicsServices = GraphicsServices
  { gsLending ∷ !Lending
  -- ^ The VM's lending, which its owner is configured with.
  , gsLeases ∷ !Leases
  -- ^ The VM's lease scope, which its owner is configured with: capacity above every texture and window the
  -- instance's reservations let coexist.
  , gsLeaseCapacity ∷ !Int
  -- ^ The capacity 'gsLeases' was made with, for one instance. The owner's collection must be able to hold every live
  -- instance at it, so the session sizes the owner's member limit from this number.
  , gsTypes ∷ ![CapabilityType]
  -- ^ The lease handle types (@texture@, @window@) over 'gsLeases'.
  , gsEndpoints ∷ ![RequestEndpoint]
  -- ^ The texture and window endpoints of the owner's request grant.
  , gsDeclare ∷ Text → IO ()
  -- ^ An instance was declared: make its owners.
  , gsForget ∷ Text → IO ()
  -- ^ An instance was forgotten, once its settlement was observed: end its owners.
  , gsTextureCheck ∷ Text → ContentKey → Bool → TextureOptions → ArgumentCheck
  , gsTextureStart ∷ Text → ContentKey → Bool → TextureOptions → RequestContext → IO GraphicsStart
  , gsWindowCheck ∷ Text → ByteString → Int64 → Int64 → ArgumentCheck
  , gsWindowStart ∷ Text → ByteString → Int64 → Int64 → RequestContext → IO GraphicsStart
  , gsPublish ∷ Text → ArgumentCheck → Binding
  -- ^ The scene publication binding of this name, given the facade's precondition.
  , gsIssued ∷ Text → Word64 → IO ()
  -- ^ A texture handle was taken by this instance, recorded before the script is handed it: the issuing instance of a
  -- handle outlives the lease's slot, which is deleted when the texture has retired.
  , gsReleaseCheck ∷ Text → Word64 → IO (Maybe Text)
  -- ^ Whether this instance may release this texture handle: refused, as the text of an ordinary error and before any
  -- provider is asked, for a handle another instance was issued (alive, retiring or completely retired) and a lease of
  -- another kind. A lease of the calling instance that has already ended is not refused: releasing it again is the
  -- special release path's to answer.
  , gsRelease ∷ Word64 → IO Text
  -- ^ Release a texture lease by key through the host's special release path: @done@, @retiring@ or @already_released@.
  , gsInput ∷ !(Maybe InputServices)
  -- ^ The presentation-input operations (TRA-6), when the composition opted in. 'Nothing' keeps the facade exactly as it
  -- was: no @api.input@ field, no handle type. Input is a part of the graphics services because a window exists only
  -- through them, so input without a window provider cannot be composed.
  }

-- Injected terrain -----------------------------------------------------------------------------------

-- | The handle type of an arena lease (the success value of @api.terrain.open@ and @api.terrain.attach@).
terrainArenaType ∷ Text
terrainArenaType = "terrain_arena"

-- | The handle type of an opaque displayed-view authority (the optional third argument of @api.terrain.remove@). TRA-10
-- supplies the real issuer; this facade only names the type and has the injected service check it.
terrainPickType ∷ Text
terrainPickType = "terrain_pick"

-- | The request handle types, one for each kind of terrain result, so that @api.request@ dispatches by kind.
terrainArenaRequestType, terrainCellRequestType, terrainColumnRequestType, terrainSurfaceRequestType, terrainRemoveRequestType ∷ Text
terrainArenaRequestType = "terrain_arena_request"
terrainCellRequestType = "terrain_cell_request"
terrainColumnRequestType = "terrain_column_request"
terrainSurfaceRequestType = "terrain_surface_request"
terrainRemoveRequestType = "terrain_remove_request"

-- | What @take@ hands as the success value of an open or an attach: the arena handle itself.
terrainArenaValueSchema ∷ Schema
terrainArenaValueSchema = SCapability terrainArenaType

-- | A cell: the content revision it was read at, and air or an authored material with its shape.
-- @{revision = INTEGER, air = BOOLEAN, material = TEXT?, shape = INTEGER?}@; the material and shape are present exactly when
-- @air@ is false.
terrainCellValueSchema ∷ Schema
terrainCellValueSchema = SRecord [("revision", SInteger), ("air", SBoolean), ("material", SOptional SText), ("shape", SOptional SInteger)]

-- | A column: the revision and the complete coalesced runs of the half-open range, air included, in ascending order.
-- @{revision = INTEGER, runs = LIST of {z_min = INTEGER, z_max = INTEGER, air = BOOLEAN, material = TEXT?, shape = INTEGER?}}@.
terrainColumnValueSchema ∷ Schema
terrainColumnValueSchema =
  SRecord
    [ ("revision", SInteger)
    , ("runs", SList (SRecord [("z_min", SInteger), ("z_max", SInteger), ("air", SBoolean), ("material", SOptional SText), ("shape", SOptional SInteger)]))
    ]

-- | A surface: the revision, and the highest occupied cell, explicitly absent for an empty column.
-- @{revision = INTEGER, occupied = BOOLEAN, z = INTEGER?, material = TEXT?, shape = INTEGER?}@.
terrainSurfaceValueSchema ∷ Schema
terrainSurfaceValueSchema = SRecord [("revision", SInteger), ("occupied", SBoolean), ("z", SOptional SInteger), ("material", SOptional SText), ("shape", SOptional SInteger)]

-- | A removal: whether anything changed and the committed content revision. @{changed = BOOLEAN, revision = INTEGER}@.
terrainRemoveValueSchema ∷ Schema
terrainRemoveValueSchema = SRecord [("changed", SBoolean), ("revision", SInteger)]

-- | The longest arena name, in characters. The terrain service accepts 256; the adapter prefixes the content root, which is at
-- most 64 characters, and the namespace's separator, so a name is bounded below what is left of that.
terrainNameLimit ∷ Int
terrainNameLimit = 128

-- | The longest material identifier, in UTF-8 bytes (the terrain validator's limit).
terrainMaterialBytesLimit ∷ Int
terrainMaterialBytesLimit = 64

-- | The lowest and highest supported cell coordinate, and the highest exclusive interval endpoint (one past the highest cell).
terrainCellLow, terrainCellHigh, terrainEndpointHigh ∷ Int64
terrainCellLow = negate (2 ^ (62 ∷ Int))
terrainCellHigh = 2 ^ (62 ∷ Int) - 1
terrainEndpointHigh = 2 ^ (62 ∷ Int)

-- | A cell coordinate, as the facade read it: three checked Lua integers within @[-2^62, 2^62 - 1]@.
data TerrainCell = TerrainCell !Int64 !Int64 !Int64
  deriving (Eq, Show)

-- | A column request: the column and the half-open range of levels @[z_min, z_max)@, the range checked to be a valid interval
-- and the corners within the supported bounds. The range's length is the service's to bound (8,192 levels).
data TerrainColumnAsk = TerrainColumnAsk !Int64 !Int64 !Int64 !Int64
  deriving (Eq, Show)

-- | What a copied definition is, after the facade's decode checks: nothing about overlap, order or whether a material is
-- declared (those are the terrain validator's, and its refusal is the expected @definition@ failure).
data TerrainDefinition = TerrainDefinition
  { tdMaterials ∷ ![Text]
  , tdLayers ∷ ![TerrainLayer]
  , tdPatches ∷ ![TerrainPatch]
  }
  deriving (Eq, Show)

-- | A base layer: the half-open interval, an omitted end meaning the supported extreme, and the material and shape.
data TerrainLayer = TerrainLayer
  { tlMin ∷ !(Maybe Int64)
  , tlMax ∷ !(Maybe Int64)
  , tlMaterial ∷ !Text
  , tlShape ∷ !Int64
  }
  deriving (Eq, Show)

-- | A bounded per-column override of the base.
data TerrainPatch = TerrainPatch
  { tpX ∷ !Int64
  , tpY ∷ !Int64
  , tpMin ∷ !Int64
  , tpMax ∷ !Int64
  , tpValue ∷ !TerrainPatchValue
  }
  deriving (Eq, Show)

-- | What a patch overrides with: air, or a material and its shape.
data TerrainPatchValue
  = PatchAir
  | PatchSolid !Text !Int64
  deriving (Eq, Show)

-- | What a request-producing terrain service answered once the facade's checks passed.
data TerrainStart
  = -- | The host's answer: the request, or busy with nothing reserved.
    TerrainStarted !M1Start
  | -- | A permanent refusal that reached the admission after the check passed (an ended owner, a stopping service): nothing was
    -- reserved. The facade raises it as the ordinary error it is.
    TerrainRefused !Text
  deriving (Eq, Show)

-- | What the composition is told of the VM it makes terrain services for.
data TerrainVm = TerrainVm
  { tvRole ∷ !Role
  -- ^ The VM's role. Either role's instances may create, attach, query and remove.
  , tvRequests ∷ !M1Requests
  -- ^ The VM's request policy, already gated on the session's admission: the one the services admit with.
  , tvTakesWork ∷ !(STM Bool)
  -- ^ Whether the session still takes new work for this role, as a transaction.
  , tvLending ∷ !Lending
  -- ^ The VM's one lending, shared with every other service of the VM that leases resources (graphics, when injected).
  , tvLeases ∷ !Leases
  -- ^ The VM's one lease scope, shared likewise: the terrain leases are charged in the same scope as the VM's other leases.
  , tvSession ∷ !Unique
  -- ^ The identity of the session this VM belongs to, the same for both roles of one session and for no other session: the
  -- terrain namespace is the session's and the instance's content root.
  }

-- | How a composition injects terrain: the lease capacity its services need, per instance, in the VM's one shared scope, and
-- a function from one VM to its services. The session holds it as an abstract value and calls it once for each role's VM; it
-- reaches no global and no registry.
data TerrainInjection = TerrainInjection
  { tiLeaseCapacity ∷ !(Profile → Int)
  -- ^ The most leases one instance of a VM can hold at once through these services (pending, live and retiring), for the
  -- profile: what the VM's shared lease scope must add for them.
  , injectTerrain ∷ TerrainVm → IO TerrainServices
  }

-- | The narrow terrain operations of one VM, supplied by a composition. The CPU facade validates the caller, role, phase,
-- session admission, arity and every argument's shape, and decides which Lua error a refusal is; these do what only the
-- terrain service can: check that a handle is the calling instance's own live arena lease, check the provider's own facts,
-- start the request and release. Every operation names the calling instance by the identity the facade issued it and its
-- content root.
data TerrainServices = TerrainServices
  { tsTypes ∷ ![CapabilityType]
  -- ^ The handle types over the VM's shared leases: the arena lease ('terrainArenaType') and the pick authority ('terrainPickType').
  , tsEndpoints ∷ ![RequestEndpoint]
  -- ^ The terrain endpoints of the owner's request grant.
  , tsDeclare ∷ Text → Text → IO ()
  -- ^ An instance was declared, with its content root: make its client.
  , tsForget ∷ Text → IO ()
  -- ^ An instance was forgotten, once its settlement was observed: end its client.
  , tsOpenCheck ∷ Text → Text → Text → TerrainDefinition → ArgumentCheck
  -- ^ Instance, root, name, definition: whether the open is refused for good (an ended owner), as an ordinary error.
  , tsOpenStart ∷ Text → Text → Text → TerrainDefinition → RequestContext → IO TerrainStart
  , tsAttachCheck ∷ Text → Text → Text → ArgumentCheck
  , tsAttachStart ∷ Text → Text → Text → RequestContext → IO TerrainStart
  , tsCellCheck ∷ Text → Word64 → TerrainCell → ArgumentCheck
  -- ^ Instance, arena handle key, cell: whether the handle is refused (another instance's, of another kind, forged, or the
  -- caller's own already released): the text of an ordinary error, before any provider is asked. A lease whose arena was
  -- closed by someone else is not refused: its request settles @arena_closed@.
  , tsCellStart ∷ Text → Word64 → TerrainCell → RequestContext → IO TerrainStart
  , tsColumnCheck ∷ Text → Word64 → TerrainColumnAsk → ArgumentCheck
  , tsColumnStart ∷ Text → Word64 → TerrainColumnAsk → RequestContext → IO TerrainStart
  , tsSurfaceCheck ∷ Text → Word64 → Int64 → Int64 → ArgumentCheck
  , tsSurfaceStart ∷ Text → Word64 → Int64 → Int64 → RequestContext → IO TerrainStart
  , tsRemoveCheck ∷ Text → Word64 → TerrainCell → Maybe Word64 → ArgumentCheck
  -- ^ Instance, arena handle key, cell, the optional pick authority's key.
  , tsRemoveStart ∷ Text → Word64 → TerrainCell → Maybe Word64 → RequestContext → IO TerrainStart
  , tsReleaseCheck ∷ Text → Word64 → IO (Maybe Text)
  -- ^ Whether this instance may release this arena handle: refused before any provider is asked for a handle another instance
  -- was issued (alive, retiring or completely retired) and a lease of another kind. A lease of the calling instance that has
  -- already ended is not refused: releasing it again answers the existing disposition.
  , tsRelease ∷ Word64 → IO Text
  -- ^ Release an arena lease by key through the host's release path: @done@, @retiring@ or @already_released@.
  , tsIssued ∷ Text → Word64 → IO ()
  -- ^ An arena handle was taken by this instance, recorded before the script is handed it: the issuing instance of a handle
  -- outlives the lease's slot.
  , tsDrain ∷ IO ()
  -- ^ Give the service back what the requests whose results were taken or discarded held, now: called after a terrain request
  -- is taken or cancelled, never blocking. Whatever is not drained here is drained by the next terrain call and when the
  -- instance is forgotten.
  , tsExtraBindings ∷ ![Binding]
  -- ^ Bindings a test fixture adds to the hidden namespace (a host-created pick-token fixture). Empty in production.
  }

-- Injected input -------------------------------------------------------------------------------------

-- | The name of the capability type of a reset-acknowledgement token.
graphicsInputResetType ∷ Text
graphicsInputResetType = "input_reset"

-- | The narrow presentation-input operations of one VM, supplied by a composition that opted in. The CPU facade validates
-- the caller, role, phase, session admission, arity, every argument's shape and the result capacity, and decides which
-- Lua error a refusal is; these do what only the window integration can: check that the window handle is the calling
-- instance's own live window, read a bounded prefix of its ordered input atomically with the feed's disposition and the
-- window's observation, and acknowledge a reset. Every operation names the calling instance by the identity the facade
-- issued it and the window by its lease key. Nothing here waits, blocks or runs Lua.
data InputServices = InputServices
  { isTypes ∷ ![CapabilityType]
  -- ^ The capability type of a reset token ('graphicsInputResetType'), with its liveness check.
  , isCheckPoll ∷ Text → Word64 → IO (Maybe Text)
  -- ^ Whether this instance may poll this window handle: a refusal is the text of an ordinary error, and nothing is read.
  , isPoll ∷ Text → Word64 → Int → IO InputPoll
  -- ^ Read at most this many events from the window's feed, with its disposition and observation, in one atomic step.
  , isCheckAcknowledge ∷ Text → Word64 → Word64 → IO (Maybe Text)
  -- ^ Whether this instance may acknowledge with this token (a reset-token key) for this window handle.
  , isAcknowledge ∷ Text → Word64 → Word64 → IO InputAck
  -- ^ Acknowledge the reset the token names, on the window's reader, nonblocking.
  }

-- | What a poll came to.
data InputPoll
  = -- | A lifecycle change that landed after the check (an ending instance, a stopped session, a retired window): nothing
    -- was read. The facade raises it as the ordinary error it is.
    PollRefused !Text
  | Polled !InputPacket

-- | What an acknowledgement came to.
data InputAck
  = -- | A lifecycle change that landed after the check, or a token that is not this window's: nothing was acknowledged.
    AckRefused !Text
  | -- | The pending reset is now acknowledged.
    AckAcknowledged
  | -- | This reset was already acknowledged, or has resumed.
    AckAlready
  | -- | The token is not the feed's newest reset: nothing changed.
    AckStale
  | -- | The feed has closed.
    AckClosed
  deriving (Eq, Show)

-- | Where the feed stood when a poll stopped reading.
data InputDisposition
  = DispositionRunning
  | DispositionResetRequired
  | DispositionPaused
  | DispositionClosed
  deriving (Eq, Show)

-- | One bounded poll: an ordered prefix of events, the disposition the read stopped on, and the window's observation read
-- in the same step.
data InputPacket = InputPacket
  { packetDisposition ∷ !InputDisposition
  , packetEpoch ∷ !Natural
  -- ^ The epoch of the running generation, or of the last one that ran.
  , packetEvents ∷ ![InputEventRecord]
  , packetExhausted ∷ !Bool
  -- ^ True only when the read observed the end of the feed: an empty running feed, or any other disposition. A poll that
  -- stopped at its bound says false, because it did not look.
  , packetReset ∷ !(Maybe InputResetInfo)
  , packetObservation ∷ !InputObservation
  }
  deriving (Eq, Show)

-- | An event as the feed delivered it: its epoch and its payload.
data InputEventRecord = InputEventRecord
  { eventEpoch ∷ !Natural
  , eventBody ∷ !InputBody
  }
  deriving (Eq, Show)

data InputBody
  = -- | A key transition: key code, platform scancode, action, modifiers.
    BodyKey !Int !Int !InputKeyAction !InputModifiers
  | -- | One character, by its exact code point (a surrogate included).
    BodyText !Int
  | -- | A button transition: number, action, the cursor position captured for it, modifiers.
    BodyButton !Int !InputButtonAction !(Maybe (Double, Double)) !InputModifiers
  | -- | Both scroll offsets; no modifiers, because the source captured none.
    BodyScroll !Double !Double
  | BodyFocus !Bool
  deriving (Eq, Show)

data InputKeyAction = KeyActionPress | KeyActionRepeat | KeyActionRelease
  deriving (Eq, Show)

data InputButtonAction = ButtonActionPress | ButtonActionRelease
  deriving (Eq, Show)

-- | The six modifier flags of the source, under its own names.
data InputModifiers = InputModifiers
  { modShift ∷ !Bool
  , modControl ∷ !Bool
  , modAlt ∷ !Bool
  , modSuper ∷ !Bool
  , modCapsLock ∷ !Bool
  , modNumLock ∷ !Bool
  }
  deriving (Eq, Show)

data InputResetReason = ResetReasonOverflow | ResetReasonSuspension
  deriving (Eq, Show)

-- | The reset the feed is in: why, the epoch it reserved and, only while it is pending, the key of its token.
data InputResetInfo = InputResetInfo
  { resetReason ∷ !InputResetReason
  , resetEpoch ∷ !Natural
  , resetTokenKey ∷ !(Maybe Word64)
  }
  deriving (Eq, Show)

-- | The window's latest observation, each attribute the platform could not provide left 'Nothing'.
data InputObservation = InputObservation
  { observationRevision ∷ !Natural
  , observationFocused ∷ !(Maybe Bool)
  , observationCursor ∷ !(Maybe (Double, Double))
  , observationCursorInside ∷ !(Maybe Bool)
  , observationLogical ∷ !(Maybe (Int, Int))
  , observationFramebuffer ∷ !(Maybe (Int, Int))
  , observationScale ∷ !(Maybe (Double, Double))
  }
  deriving (Eq, Show)

-- | The session's authored output: both streams, the lock one whole call is written under, and the
-- state of the output (open and counting calls, failed, or closed). Made and used by
-- "Hetoimasia.LuaEngine.Facade.Output"; defined here so that a facade can hold it.
data Output = Output
  { outStdout ∷ !OutputSink
  , outStderr ∷ !OutputSink
  , outLock ∷ !(MVar ())
  , outState ∷ !(TVar OutputState)
  }

data OutputState = OutputState
  { stateOpen ∷ !Bool
  , stateInFlight ∷ !Int
  , stateFailure ∷ !(Maybe SomeException)
  }

-- | The hidden namespace of the facade's bindings. The initial chunk reads it once and removes it.
engineNamespaceName ∷ Text
engineNamespaceName = "hetoimasia_engine"

-- | The global the initial chunk leaves for the builder's export module to take, once, and which
-- takes itself away.
engineBuilderName ∷ Text
engineBuilderName = "hetoimasia_engine_builder"

-- Failures -----------------------------------------------------------------------------------------

-- | The facade's own bookkeeping disagreed with itself or with a collaborator: an engine defect, never
-- a mistake of a script. It fails the owner.
newtype FacadeDefect = FacadeDefect Text
  deriving (Eq, Show)

instance Exception FacadeDefect
