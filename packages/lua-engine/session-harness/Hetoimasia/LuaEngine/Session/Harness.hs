-- | The harness's seams of the session coordinator: what a test composes to place a stop or a failure in
-- an exact window, to ask for the second instance of a role the design keeps for qualifying reusable
-- bindings, and to start the tick counter near the Lua integer ceiling.
--
-- This module is in a private sublibrary of the package. No public library exposes it and no public type
-- exports a constructor or a field of it: "Hetoimasia.LuaEngine.Session" shows 'Harness' as an abstract
-- type and 'noHarness', so a composition outside the package can pass the one and cannot build another. It
-- is reachable from the package's own test suite alone. None of it is reachable from a manifest or from
-- Lua.
--
-- A probe is told, on the thread that reaches the point, at each named point of the session's life and may
-- block (to hold a window open until a test has acted) or raise (to inject a failure at that step); it is
-- never called with a lock held that a stop needs.
module Hetoimasia.LuaEngine.Session.Harness
  ( Harness (..)
  , noHarness
  , Point (..)
  , BuildStep (..)
  , InstanceKey (..)
  ) where

import Data.Word (Word64)
import Hetoimasia.LuaEngine.Manifest (Role)

-- | One instance of the session: its role and its slot in that role's VM. Slot 0 is the root every
-- role has; slot 1 is the harness's second instance, where a composition asks for one.
data InstanceKey = InstanceKey
  { ikRole ∷ !Role
  , ikSlot ∷ !Int
  }
  deriving (Eq, Ord, Show)

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
  | -- | An instance is constructed and validated and is about to be held until every instance is, on its
    -- owner's thread.
    Validating !InstanceKey
  | -- | The dispatch gate opened for an instance, it was released, and its @init@ is about to begin: the
    -- owner's thread is here, and holding it holds the @init@ in flight without running a line of Lua.
    Dispatched !InstanceKey
  | -- | A tick is about to be granted, the check made and nothing issued.
    GrantIntent !Word64
  | -- | A tick was granted.
    GrantIssued !Word64
  | -- | A role's owner has ended and is about to be finalized.
    OwnerEnded !Role
  | -- | An event has been committed, in one transaction, and the effects it owes have not been run: holding the
    -- thread here, or raising from it, leaves every one of them owed.
    Committed !String
  | -- | A role's owner is about to be asked to stop, by whoever is discharging the stop the session owes it.
    StopHandoff !Role
  | -- | A role's owner has ended and been accounted, and its coordinator is about to be waited for until it has
    -- drained: every read it started has returned. Holding the thread here holds the role unretired.
    Draining !Role
  | -- | The driver released a held instance and has not yet looked at anything else: holding it here is how an
    -- example keeps the driver from seeing an instance run.
    Resumed !InstanceKey
  deriving (Eq, Show)
