-- | What the run uses to know that the owner is running nothing.
--
-- The runner produces an instance's events, and takes the tables, only at moments the owner's thread is
-- provably not running Lua, so that which events are produced, in what order and to whom does not depend
-- on when the runner's own thread resumes. The engine offers the runner two things to know that:
--
-- * the application's observer, run on the owner's thread before every segment, which the runner uses as a
--   /gate/ it can hold: while the gate is held the owner parks there, before the segment, in one place the
--   runner can read ('gateParked'); and a /permit/ lets the owner through for one segment;
-- * the instances' own state, read in one transaction ('inspectInstances'): an instance is /busy/ when it
--   has work the owner has yet to do for it, and the owner is /quiet/ when no instance is.
--
-- An owner parked at the gate is frozen: the segment it is about to run, and everything after it, waits.
-- An owner that is quiet is idle, and stays idle until something the runner does (an admission, a grant,
-- a delivery) wakes it, on a tick VM, where nothing else can: no timer of the owner's own is armed. On an
-- elapsed VM a timer can wake the owner at any time, which is that clock's own wall-clock semantics.
module Hetoimasia.Scripting.Lua.Runner.Gate
  ( Gate
  , newGate
  , gateHook
  , gateWait
  , holdGate
  , freeGate
  , permitOne
  , gateParked
  , busy
  , quiet
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (finally)
import Control.Monad (when)
import Hetoimasia.Scripting.Lua.Instance
  ( Execution (ExecIdle, ExecReady, ExecRunning, ExecWaiting)
  , InstanceKind (RunOnce)
  , InstancePhase (Active, Initializing, Paused, Stopping)
  , InstanceSnapshot (..)
  , isTerminal
  )
import Hetoimasia.Scripting.Lua.Scheduled (SegmentContext)

-- | The gate's state: whether it is held, how many segments the runner has let through, and whether the
-- owner is parked at it.
data GateState = GateState
  { gateHeld ∷ !Bool
  , gatePermits ∷ !Int
  , gateIsParked ∷ !Bool
  }

newtype Gate = Gate (TVar GateState)

-- | A gate that is not held.
newGate ∷ IO Gate
newGate = Gate <$> newTVarIO (GateState False 0 False)

-- | The application's observer, for the owner's thread: before each segment, park while the gate is held
-- and no permit is left, and take a permit when one is. A cancellation or a stop reaches the park, which
-- is a wait in STM, and clears it.
gateHook ∷ Gate → SegmentContext → IO ()
gateHook gate _ = gateWait gate

-- | What the owner does before each segment: nothing while the gate is not held, and otherwise wait for a
-- permit or for the gate to be opened, parked where the runner can see it.
gateWait ∷ Gate → IO ()
gateWait (Gate var) = do
  parked ← atomically $ do
    state ← readTVar var
    if not (gateHeld state)
      then pure False
      else
        if gatePermits state > 0
          then writeTVar var state {gatePermits = gatePermits state - 1} >> pure False
          else writeTVar var state {gateIsParked = True} >> pure True
  when parked $
    atomically
      ( do
          state ← readTVar var
          if not (gateHeld state)
            then writeTVar var state {gateIsParked = False}
            else
              if gatePermits state > 0
                then writeTVar var state {gatePermits = gatePermits state - 1, gateIsParked = False}
                else retry
      )
      `finally` atomically (modifyTVar' var (\state → state {gateIsParked = False}))

-- | Hold the gate: the owner parks before its next segment, until it is opened or a permit is given.
holdGate ∷ Gate → STM ()
holdGate (Gate var) = modifyTVar' var (\state → state {gateHeld = True, gatePermits = 0})

-- | Open the gate for good: the owner is let through, and parks no more. Idempotent.
freeGate ∷ Gate → STM ()
freeGate (Gate var) = modifyTVar' var (\state → state {gateHeld = False, gatePermits = 0})

-- | Let the owner through for one segment: a segment the runner is not waiting to see the start of. Answers
-- whether it did: a permit already given and not yet taken is not given twice, so one call lets one segment
-- through however often it is asked while the owner is on its way.
permitOne ∷ Gate → STM Bool
permitOne (Gate var) = do
  state ← readTVar var
  if gatePermits state > 0
    then pure False
    else writeTVar var state {gatePermits = 1} >> pure True

-- | Whether the owner is parked at a held gate, before a segment.
gateParked ∷ Gate → STM Bool
gateParked (Gate var) = gateIsParked <$> readTVar var

-- | Whether an instance has work the owner can do for it now: it is initializing or ending; or it is serving
-- and has an invocation ready or running, or, with none in progress, an event queued, (on logical time) an
-- update owed, or (a one-shot) its @run@ owed or just done and not yet settled. A paused instance does
-- nothing, whatever it holds; a finished one has nothing. An instance whose invocation is suspended on a
-- wait has nothing the owner can do however much is queued behind it: the invocations of one instance are
-- served one after another, so what waits behind the suspended one waits for its wake, which is a tick or a
-- time the runner does not hold the next grant for.
--
-- On elapsed time an update falls due by the wall clock whenever it does, so a looped instance owing one is
-- not work the owner could be waited for: the run's coordination there is of the instances' own work, and the
-- first argument says whether updates owed count.
busy ∷ Bool → InstanceSnapshot → Bool
busy updatesOwed snapshot = case snapshotPhase snapshot of
  Initializing → True
  Stopping → True
  Paused → False
  Active → case snapshotExecution snapshot of
    ExecReady → True
    ExecRunning → True
    ExecWaiting → False
    ExecIdle →
      snapshotQueued snapshot > 0
        || (updatesOwed && snapshotUpdateOwed snapshot)
        || snapshotKind snapshot == RunOnce
  phase → not (isTerminal phase)

-- | Whether no instance is busy: the owner has nothing it must do before it idles.
quiet ∷ Bool → [InstanceSnapshot] → Bool
quiet updatesOwed = not . any (busy updatesOwed)
