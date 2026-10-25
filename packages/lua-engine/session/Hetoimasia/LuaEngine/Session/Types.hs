{-# LANGUAGE OverloadedStrings #-}

-- | What a session is made from and what it hands back. Hidden: "Hetoimasia.LuaEngine.Session" is the
-- public view. The harness's seams are in a private sublibrary, "Hetoimasia.LuaEngine.Session.Harness".
--
-- = Who owns what
--
-- * The 'SessionSpec' is data: the services a composition injects. The coordinator reaches no global,
--   no environment record and no registry; each service is a field here and is passed on, narrowed,
--   to what needs it.
-- * The 'Session' handle is the session's lifecycle record. It is made first, before any VM, is fresh for
--   each session and is never reset, and it outlives every role's scope: a reader holding the handle sees
--   a coherent snapshot after the driver has returned or thrown. Its state variable holds the pure state of
--   "Hetoimasia.LuaEngine.Session.State". Its registry holds, for each role, what the session needs to
--   stop and to prove retired what was acquired: the finite stop of the owner and of the coordinator that
--   serves it, the raw completion of the owner, the proof that the coordinator has drained, and the finite
--   releases of the acquired components. Both variables are written only by transactions that check and
--   change them together (a registration is committed with the fact that the component was acquired), by the
--   thread that acquired the component; the stop pass, the retirement protocol and the status readers read
--   them, on whichever thread runs them.
module Hetoimasia.LuaEngine.Session.Types
  ( -- * The composition
    SessionSpec (..)

    -- * The handle
  , Session (..)
  , Registry (..)
  , emptyRegistry
  , Registered (..)
  , RoleRelease (..)

    -- * Failures of the coordinator itself
  , SessionRefused (..)
  ) where

import Control.Concurrent.STM (STM, TVar)
import Control.Exception (Exception)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import Hetoimasia.Content.Inventory (Inventory)
import Hetoimasia.Content.ReadPool (ReadPool)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Time (MonotonicSource)
import Hetoimasia.Foundation.Worker (Completion)
import Hetoimasia.LuaEngine.Boot (Checkpoint)
import Hetoimasia.LuaEngine.Facade (Output)
import Hetoimasia.LuaEngine.Manifest (Role)
import Hetoimasia.LuaEngine.Profile (Profile)
import Hetoimasia.LuaEngine.Session.Harness (Harness, InstanceKey, Point, Protection, Release)
import Hetoimasia.LuaEngine.Session.State (SessionState)
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

-- | The handle to a session, made before any VM exists.
data Session = Session
  { sessionState ∷ !(TVar SessionState)
  , sessionRegistry ∷ !(TVar Registry)
  -- ^ What the session acquired, role by role, and how each is stopped, proven drained and released.
  , sessionLogger ∷ !Logger
  -- ^ The coordinator's diagnostics: lifecycle at info, a failure once at error. Written only by the session's writer
  -- thread (D-87), never by the driver, an owner callback, a stop pass or a recovery commit. It is borrowed: an abandoned
  -- writer may still be using it until 'sessionWriterEnd' says it has ended.
  , sessionWriterEnd ∷ !(STM Bool)
  -- ^ Whether the diagnostics writer, and the helper that cancels it, have ended (or were never started). The call never
  -- waits for it; whoever owns the logger joins it before releasing the logger.
  , sessionProbe ∷ Point → IO ()
  -- ^ The harness's probe, told at the points of the session's life ('noHarness' tells nothing).
  , sessionRelease ∷ Release → IO ()
  -- ^ The harness's finite release, run with each registered release ('noHarness' runs nothing).
  , sessionRemoved ∷ ![Protection]
  -- ^ The protections a negative control removed ('noHarness' removes none).
  , sessionHidden ∷ InstanceKey → Bool
  -- ^ The settlements a test injected the loss of ('noHarness' hides none).
  }

-- | What the session holds for each role and for itself. Registered by the thread that acquired a component,
-- in the transaction that records the acquisition, so a stop or a failure that follows finds it.
data Registry = Registry
  { regRoles ∷ !(Map Role Registered)
  , regSession ∷ ![RoleRelease]
  -- ^ The session-level finite releases still to run (the pacing timer, the outermost scope), the first to run first.
  }

emptyRegistry ∷ Registry
emptyRegistry = Registry Map.empty []

-- | One role's acquired components.
data Registered = Registered
  { regStop ∷ !(IO ())
  -- ^ The finite, non-waiting stop: the owner's request to stop if it exists, and the close of the coordinator's
  -- admission with the withdrawal of the reads no worker took. Idempotent.
  , regCompletion ∷ !(Maybe (STM (Maybe (Completion ()))))
  -- ^ The owner's raw completion, once it has one; 'Nothing' for a role whose owner was never started.
  , regDrained ∷ !(Maybe (STM Bool))
  -- ^ Whether the coordinator has given back every slot and byte, when there is one.
  , regReleases ∷ ![RoleRelease]
  -- ^ The role's finite releases, the last acquired first.
  }

-- | A finite release the session registered with the acquisition it undoes. It runs once, uninterruptibly, after
-- the owners and providers that borrowed what it releases have finished, and never waits.
data RoleRelease = RoleRelease
  { rrWhich ∷ !Release
  , rrAction ∷ !(IO ())
  }

-- | The composition could not be made: a bound below what the engine needs, a service that was
-- refused. A failure of the host's, with its reason; nothing of the script's.
newtype SessionRefused = SessionRefused Text
  deriving (Eq, Show)

instance Exception SessionRefused
