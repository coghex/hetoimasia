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
-- never called with a lock held that a stop needs, and never between the first and the last of the stops of
-- the all-owner barrier or inside a commit or a release.
--
-- A /release/ is different from a probe: it is the finite release of one component the session registered when it
-- acquired it, run by the session's own retirement protocol under the repository's uninterruptible discipline, so
-- it may raise (that is how a test injects a failure of a release) and must not block.
module Hetoimasia.LuaEngine.Session.Harness
  ( Harness (..)
  , noHarness
  , Point (..)
  , BuildStep (..)
  , Release (..)
  , Protection (..)
  , OwnerHandles (..)
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
  , harnessRelease ∷ Release → IO ()
  -- ^ Run as part of the finite release of the component the session registered, once, after the owners and
  -- providers that borrowed it have actually finished: it may raise (a failed release) and must not block.
  , harnessOwner ∷ Role → OwnerHandles → IO ()
  -- ^ Told, on the thread that registered an owner, once it is registered: what a test needs to stop or cancel that
  -- owner from outside the session, as another party would. It runs no Lua and must not block.
  , harnessStartChunk ∷ ![(Role, String)]
  -- ^ Lua a role's VM runs in its initialization, before its owner is ready: a test holds it in the authored output
  -- to hold the start of that owner in its readiness wait.
  , harnessHideSettlement ∷ InstanceKey → Bool
  -- ^ Injects a fault of the host's contract: the instance's settlement is treated as missing when its owner has ended.
  , harnessRemoved ∷ ![Protection]
  -- ^ The protections a negative control removes, to show that the proof of one detects its absence. Empty in
  -- every real composition; only this package's own tests can name one, and nothing reaches it from a manifest or
  -- from Lua.
  }

-- | A harness with nothing in it.
noHarness ∷ Harness
noHarness = Harness [] 0 (const (pure ())) (const (pure ())) (\_ _ → pure ()) [] (const False) []

-- | What a party outside the session can do to an owner it did not make.
data OwnerHandles = OwnerHandles
  { ownerStop ∷ IO ()
  -- ^ Ask the owner to stop, as its supervisor would.
  , ownerCancel ∷ IO ()
  -- ^ Cancel the owner's worker.
  }

-- | A protection of the teardown protocol that a negative control can remove, one production site each.
data Protection
  = -- | Every constructed owner is asked to stop, by one pass, before any owner is waited for. Removed, each scope
    -- stops and waits for its own role alone.
    ProtectBarrier
  | -- | An owner's end, the evidence it carries and the facts its settlements prove are one commit. Removed, the
    -- claim is committed first and the evidence and facts after it.
    ProtectBundle
  | -- | A recovery path only commits. Removed, the diagnostics still pending are written first.
    ProtectRecovery
  | -- | The cleanup failures a cancellation carries are accounted. Removed, they are left in the exception.
    ProtectCancellationEvidence
  | -- | A started owner is registered in the step that starts it, before any probe. Removed, a probe comes first and
    -- an owner that outlives its failure is never found.
    ProtectRegistration
  | -- | An owner's raw completion is the evidence of how it ended. Removed, it is not read.
    ProtectRawCompletion
  | -- | Every registered release is attempted whatever the others do. Removed, the first that raises ends the attempts.
    ProtectReleases
  | -- | An exception a release itself raised is a failure of that cleanup, whatever its type. Removed, one of an
    -- asynchronous type is taken for a cancellation.
    ProtectReleaseSource
  | -- | Every wait of the protocol is interruptible. Removed, the wait for an owner is uninterruptibly masked.
    ProtectInterruptibleWait
  | -- | The registered peers are handed their stops from inside an abandoned start, before the starter waits for its
    -- worker. Removed, they are handed them after the start has raised.
    ProtectStartAbandon
  | -- | The check that the logical role takes ticks and the scheduler's acceptance of the grant are one transaction.
    -- Removed, they are two, with the point 'GrantChecked' between them, so a closure can commit between the two.
    ProtectGrantAtomic
  deriving (Eq, Show)

-- | The steps a role's VM is made in, and released in the opposite order.
data BuildStep = BuildCoordinator | BuildData | BuildFacade | BuildOwner
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A component the session registered a finite release for.
data Release
  = -- | One step of a role's construction.
    ReleaseBuild !Role !BuildStep
  | -- | The driver's pacing timer.
    ReleaseTimer
  | -- | The outermost scope of the composition, the last to be released.
    ReleaseComposition
  deriving (Eq, Ord, Show)

-- | A named point of the session's life.
data Point
  = -- | A step of a role's construction is about to be acquired, and nothing of it exists yet.
    Acquiring !Role !BuildStep
  | -- | A role's start is abandoned, on the starter's thread: the session is closed and every registered peer has been
    -- handed its stop, and the starter has not yet begun to wait for its worker to end.
    StartAbandoned !Role
  | -- | A step of a role's construction has completed, and what it made is registered with the session's
    -- lifecycle record: from here a failure or a stop finds it.
    Built !Role !BuildStep
  | -- | The finite release of a registered component ran (the harness's recorder notes it; the thread that
    -- reaches it is the one releasing and holding it is refused).
    Released !Release
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
  | -- | A tick is about to be granted: nothing checked and nothing issued. The check and the grant are one
    -- transaction, so there is no point between them.
    GrantIntent !Word64
  | -- | Only with 'ProtectGrantAtomic' removed: the check was made in one transaction and the grant is about to be
    -- issued in another.
    GrantChecked !Word64
  | -- | A tick was granted.
    GrantIssued !Word64
  | -- | The session is closed and its stops are owed, and the all-owner barrier is about to run: this is the point
    -- to hold to see both stop receipts come before any wait. The barrier itself has no point inside it.
    Unwinding
  | -- | Every constructed owner has been asked to stop and the role's owner is about to be waited for until it
    -- has ended, on a wait that stays interruptible.
    Awaiting !Role
  | -- | A role's owner has ended and is about to be finalized.
    OwnerEnded !Role
  | -- | An event has been committed, in one transaction, and the effects it owes have not been run: holding the
    -- thread here, or raising from it, leaves every one of them owed.
    Committed !String
  | -- | A role's owner has ended and been accounted, and its coordinator is about to be waited for until it has
    -- drained: every read it started has returned. Holding the thread here holds the role unretired.
    Draining !Role
  | -- | The driver released a held instance and has not yet looked at anything else: holding it here is how an
    -- example keeps the driver from seeing an instance run.
    Resumed !InstanceKey
  deriving (Eq, Show)
