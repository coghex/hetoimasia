{-# LANGUAGE OverloadedStrings #-}

-- | What a session is made from and what it hands back. Hidden: "Hetoimasia.LuaEngine.Session" is the
-- public view. The harness's seams are in a private sublibrary, "Hetoimasia.LuaEngine.Session.Harness".
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

    -- * The handle
  , Session (..)

    -- * Failures of the coordinator itself
  , SessionRefused (..)
  ) where

import Control.Concurrent.MVar (MVar)
import Control.Concurrent.STM (TVar)
import Control.Exception (Exception)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Hetoimasia.Content.Inventory (Inventory)
import Hetoimasia.Content.ReadPool (ReadPool)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.Foundation.Time (MonotonicSource)
import Hetoimasia.LuaEngine.Boot (Checkpoint)
import Hetoimasia.LuaEngine.Facade (Output)
import Hetoimasia.LuaEngine.Manifest (Role)
import Hetoimasia.LuaEngine.Profile (Profile)
import Hetoimasia.LuaEngine.Session.Harness (Harness, Point)
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
  , sessionStoppers ∷ !(TVar (Map Role (IO ())))
  -- ^ What stops each role's owner: registered once the owner exists, run by whoever applies the
  -- transition that reports the role to be stopped.
  , sessionLogger ∷ !Logger
  -- ^ The coordinator's diagnostics: lifecycle at info, a failure once at error.
  , sessionProbe ∷ Point → IO ()
  -- ^ The harness's probe, told at the points of the session's life ('noHarness' tells nothing).
  , sessionGrantLock ∷ !(MVar ())
  -- ^ Held by the driver around the issuing of a tick grant, and passed through by a stop of the
  -- logical role before it asks the owner to stop: a grant is either issued before the stop or not at all.
  }

-- | The composition could not be made: a bound below what the engine needs, a service that was
-- refused. A failure of the host's, with its reason; nothing of the script's.
newtype SessionRefused = SessionRefused Text
  deriving (Eq, Show)

instance Exception SessionRefused
