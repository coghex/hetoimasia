{-# LANGUAGE OverloadedStrings #-}

-- | What a session is made from and what it hands back. Hidden: "Hetoimasia.LuaEngine.Session" is the
-- public view, and "Hetoimasia.LuaEngine.Session.Harness" the harness-only one.
--
-- = Who owns what
--
-- * The 'SessionSpec' is data: the services a composition injects. The coordinator reaches no global,
--   no environment record and no registry; each service is a field here and is passed on, narrowed,
--   to what needs it.
-- * The 'Session' handle is made first, before any VM, and lives for the call that made it. Its one
--   state variable holds the pure state of "Hetoimasia.LuaEngine.Session.State"; its other variable
--   holds the actions that stop each role's owner, registered by the thread that started the owner and
--   run by whichever thread applies a transition that reports a role to be stopped. Both variables are
--   written only by transactions that check and change them together.
module Hetoimasia.LuaEngine.Session.Types
  ( -- * The composition
    SessionSpec (..)

    -- * The harness's seams
  , Harness (..)
  , noHarness
  , Point (..)
  , BuildStep (..)

    -- * The handle
  , Session (..)

    -- * Failures of the coordinator itself
  , SessionAborted (..)
  , SessionRefused (..)
  ) where

import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM (TVar)
import Control.Exception (Exception)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word64)
import Hetoimasia.Content.Inventory (Inventory)
import Hetoimasia.Content.ReadPool (ReadPool)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Time (MonotonicSource)
import Hetoimasia.LuaEngine.Boot (Checkpoint)
import Hetoimasia.LuaEngine.Facade (Output)
import Hetoimasia.LuaEngine.Manifest (Role)
import Hetoimasia.LuaEngine.Profile (Profile)
import Hetoimasia.LuaEngine.Session.State (InstanceKey, SessionState)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend)

-- | Everything a session is composed from. Each service is injected; none is looked up.
data SessionSpec = SessionSpec
  { sxProfile ∷ !Profile
  -- ^ The validated profile every bound is read from.
  , sxCheckpoint ∷ !Checkpoint
  -- ^ The manifest and the entry each selected role loads, from the boot checkpoint: validated against
  -- the content scan before any Lua.
  , sxInventory ∷ !Inventory
  -- ^ The anchored content the checkpoint was made over.
  , sxPool ∷ !ReadPool
  -- ^ The session's pool of verified reads, which outlives every role's owner.
  , sxLogger ∷ !Logger
  -- ^ Where the coordinator's diagnostics and a module nobody waits for are reported.
  , sxOutput ∷ !Output
  -- ^ The authored output: the caller's scope, which outlives the session.
  , sxClock ∷ !MonotonicSource
  -- ^ The monotonic clock the owners, the facades and the pacing share.
  , sxTimer ∷ !TimerBackend
  -- ^ What sleeps: the threaded runtime's timer manager in production.
  , sxRuntime ∷ !LuaRuntime
  -- ^ The Lua runtime the owners are started on.
  , sxControl ∷ !RuntimeControl
  -- ^ The supervision control of the thread that drives the session.
  , sxHarness ∷ !Harness
  -- ^ The harness's seams: 'noHarness' for a real composition.
  }

-- | Where a harness may look, and what it may add. None of it is reachable from a manifest or from
-- Lua, and a real composition passes 'noHarness'.
data Harness = Harness
  { harnessSecond ∷ ![Role]
  -- ^ The roles that get a second instance of their selected behavior on the same VM, the slot the
  -- design keeps for qualifying reusable bindings. Never public spawning.
  , harnessTickBase ∷ !Word64
  -- ^ The tick number the composition counts from: zero in production. A test of the Lua integer ceiling
  -- starts near it, because reaching 2^63 - 1 by granting ticks is infeasible.
  , harnessProbe ∷ Point → IO ()
  -- ^ Told at each named point, on the thread that reaches it. A probe may block (to hold a window
  -- open) or raise (to inject a failure); it is never called with a lock held that a stop needs.
  }

-- | A harness with nothing in it.
noHarness ∷ Harness
noHarness = Harness [] 0 (const (pure ()))

-- | The steps a role's VM is made in, and released in the opposite order.
data BuildStep = BuildCoordinator | BuildData | BuildFacade | BuildOwner
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A named point of the session's life.
data Point
  = -- | A step of a role's construction has completed.
    Built !Role !BuildStep
  | -- | A step of a role's construction has been released.
    Released !Role !BuildStep
  | -- | An instance's admission has been intended and not yet issued.
    Intended !InstanceKey
  | -- | An instance's admission was accepted and not yet tracked.
    Issued !InstanceKey
  | -- | An instance is tracked.
    Tracking !InstanceKey
  | -- | An instance is constructed and validated and its @init@ is about to be dispatched, on its
    -- owner's thread.
    Validating !InstanceKey
  | -- | The dispatch gate opened for an instance and its @init@ is about to begin: the owner's thread is
    -- here, and holding it holds the @init@ in flight without running a line of Lua.
    Dispatched !InstanceKey
  | -- | A tick is about to be granted, the check made and nothing issued.
    GrantIntent !Word64
  | -- | A tick was granted.
    GrantIssued !Word64
  | -- | A role's owner has ended and is about to be finalized.
    OwnerEnded !Role
  deriving (Eq, Show)

-- | The handle to a session, made before any VM exists.
data Session = Session
  { sessionState ∷ !(TVar SessionState)
  , sessionStoppers ∷ !(TVar (Map Role (IO ())))
  -- ^ What stops each role's owner: registered once the owner exists, run by whoever applies the
  -- transition that reports the role to be stopped.
  , sessionLogger ∷ !Logger
  -- ^ The coordinator's diagnostics: lifecycle at info, a failure once at error.
  , sessionGrantLock ∷ !(MVar ())
  -- ^ Held by the driver around the issuing of a tick grant, and passed through by a stop of the
  -- logical role before it asks the owner to stop: a grant is either issued before the stop or not at all.
  }

-- | Raised in an owner's thread, from the hook that gates a root's @init@, when the gate is aborted: the
-- @init@ does not run, and the owner ends. Recognized by the owners' policy, so it is not a failure.
data SessionAborted = SessionAborted
  deriving (Eq, Show)

instance Exception SessionAborted

-- | The composition could not be made: a bound below what the engine needs, a service that was
-- refused. A failure of the host's, with its reason; nothing of the script's.
newtype SessionRefused = SessionRefused Text
  deriving (Eq, Show)

instance Exception SessionRefused
