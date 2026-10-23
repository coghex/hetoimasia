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
  , FacadeLimits (..)
  , engineNamespaceName
  , engineBuilderName
    -- * Failures
  , FacadeDefect (..)
  ) where

import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM (TVar)
import Control.Exception (Exception, SomeException)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Content.Inventory (Inventory)
import Hetoimasia.Foundation.Time (Duration, Instant, MonotonicSource)
import Hetoimasia.LuaEngine.Data (DataService)
import Hetoimasia.LuaEngine.Manifest (Role)
import Hetoimasia.LuaEngine.Modules (Coordinator)
import Hetoimasia.LuaEngine.Profile (Profile)
import Hetoimasia.LuaEngine.Request (M1Requests)
import Hetoimasia.Scripting.Lua.Owner (ModulePhase)

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
