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
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word64)
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
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SInteger, SRecord))

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
  -- instance's M1 reservations let coexist.
  , gsTypes ∷ ![CapabilityType]
  -- ^ The lease handle types (@texture@, @window@) over 'gsLeases'.
  , gsEndpoints ∷ ![RequestEndpoint]
  -- ^ The texture and window endpoints of the owner's request grant.
  , gsDeclare ∷ Text → IO ()
  -- ^ An instance was declared: make its owners.
  , gsForget ∷ Text → IO ()
  -- ^ An instance was forgotten, once its settlement was observed: end its owners.
  , gsTextureCheck ∷ Text → ContentKey → Bool → ArgumentCheck
  , gsTextureStart ∷ Text → ContentKey → Bool → RequestContext → IO GraphicsStart
  , gsWindowCheck ∷ Text → ByteString → Int64 → Int64 → ArgumentCheck
  , gsWindowStart ∷ Text → ByteString → Int64 → Int64 → RequestContext → IO GraphicsStart
  , gsPublish ∷ Text → ArgumentCheck → Binding
  -- ^ The scene publication binding of this name, given the facade's precondition.
  , gsRelease ∷ Word64 → IO Text
  -- ^ Release a texture lease by key through the host's special release path: @done@, @retiring@ or @already_released@.
  }

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
