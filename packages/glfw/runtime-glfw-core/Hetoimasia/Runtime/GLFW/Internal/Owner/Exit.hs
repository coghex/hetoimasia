-- | The after-drain half of the protected exit: awaiting verified whole-owner
-- destruction while servicing bounded native housekeeping, then joining the
-- owner and reporting everything it found exactly once.
--
-- Main thread, in the protected boundary's after-drain step, after every
-- attachment's own terminal evidence has been validated. It reads the owner's
-- terminal record, its latch, its delivery record and its retained failures,
-- and writes none of them. It returns for destruction evidence and nothing
-- else, and joins only after that evidence exists; the independent evidence
-- that can end a retained wait is published through this module too.
module Hetoimasia.Runtime.GLFW.Internal.Owner.Exit
  ( finishOwnerExit
  , publishOwnerRetirement
  , publishOwnerDestruction
  , OwnerDestructionUnverified (..)
  ) where

import Control.Concurrent.STM (STM, atomically, check, readTVar, readTVarIO, registerDelay)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , evaluate
  , throwIO
  , tryWithContext
  )
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Logger, logWarning)
import Hetoimasia.Foundation.Worker
  ( Completion (completionExit, completionResult)
  , GroupReport (..)
  , Requested (CancelWasRequested)
  , Result (..)
  , RunExit (RunExited)
  , WorkerGroup
  , closeWorkerGroup
  )
import Hetoimasia.Runtime.GLFW.Internal
  ( RetirementEnvironment (..)
  , WindowHost
  , retirementEnvironmentOf
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Config (graphicsOwnerComponent)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Drain (raiseRetainingOwner)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Evidence (HasEvidence (..), OwnerDestroyed, OwnerRetired)
import Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff
  ( OwnerTerminal (..)
  , ownerTerminal
  , recordOwnerDestroyed
  , recordOwnerRetired
  )
import Hetoimasia.Runtime.GLFW.Internal.Owner.Latch (isAsynchronous)
import Hetoimasia.Runtime.GLFW.Internal.Owner.State (GraphicsOwner (..), LatchSource (..), Latched (..))
import Hetoimasia.Runtime.GLFW.Internal.Owner.Wake (wakeGraphicsHost)

-- | The owner's run ended without the injected whole-owner destruction
-- returning evidence.
--
-- It retains that fact and authorizes nothing. It is never permission to
-- dispose the owner's shared state, and never permission to run the work that
-- failed again.
data OwnerDestructionUnverified = OwnerDestructionUnverified
  { unverifiedRetired ∷ !Bool
    -- ^ Whether whole-owner /retirement/ did return evidence, which
    -- destruction then did not follow.
  , unverifiedTargets ∷ !Int
    -- ^ How many targets the owner still held whose own retirement produced no
    -- evidence either.
  }
  deriving (Eq, Show)

instance Exception OwnerDestructionUnverified

-- | Await verified whole-owner destruction while servicing bounded
-- housekeeping, then join.
--
-- The attachment drain has already returned, which means every attachment's
-- own terminal evidence was validated — never the owner's completion. What is
-- still owed is the owner's own: its shared state was acquired before any
-- target existed and outlives the last one, so an empty target set proves
-- nothing here, and neither does the worker ending.
--
-- @observed@ is the private examples' seam, 'afterDestructionSnapshot'; see
-- 'awaitOwnerDestruction'.
finishOwnerExit ∷ IO () → (∀ a. IO a → IO a) → Logger → WindowHost → GraphicsOwner scene → IO ()
finishOwnerExit observed restore logger host owner = do
  awaited ← awaitOwnerDestruction observed restore logger host owner
  -- The join, after verified destruction and before the host releases a single
  -- window. It is reached only once the evidence exists, so it can never be
  -- what lets an unverified owner's parents go — and it absorbs cancellation,
  -- because escaping it would let the host unwind with the owner still live,
  -- which is the very thing the wait above refused to do.
  (report, interrupted) ← joinAbsorbing (ownerGroup owner) []
  -- Everything this exit found, in the order it found it: what the wait
  -- absorbed, what the owner survived, what its own run and drain failed
  -- with, and last the cancellations the join absorbed. Each is raised only
  -- now, after the join.
  kept ← readTVarIO (ownerRetained owner)
  -- The latch itself is deliberately absent. It is notification — what the
  -- supervision sentinel waits on — and every failure it can hold is already
  -- in exactly one of the stores beside it, so raising it here as well would
  -- report a single failed operation twice.
  --
  -- That is only half of it, because the sentinel raises the latch at the
  -- application's own checkpoint, where it becomes the composition's primary
  -- failure. Once it has, the store entry that is that same failure has
  -- already been reported and this exit must leave it out — while still
  -- reporting every failure the sentinel did not raise.
  delivered ← readTVarIO (ownerDelivered owner)
  latched ← readTVarIO (ownerLatch owner)
  (survived, fromWorker) ← case (delivered, latchedSource <$> latched) of
    (True, Just LatchedWhileRunning) →
      -- The first retained failure is the one the sentinel raised, and the
      -- rest are still this exit's to report. The worker's outcome is
      -- untouched: that latch ended the run without a failure of its own, so
      -- the outcome carries only what the drain found.
      pure (drop 1 kept, drainFailuresOf report)
    (True, Just LatchedByRunEnd) →
      -- The sentinel raised the failure that ended the run, which is exactly
      -- what the worker's outcome carries, so this exit reports none of that
      -- outcome. Nothing distinct is lost with it: whatever the drain found
      -- is retained inside that same outcome, and the group's own scope —
      -- which closes after this exit, outside the protected host lifetime —
      -- reports it there. Re-raising it here would retain a second copy of
      -- each, under a fresh identity that inspection cannot fold together.
      pure (kept, [])
    _ → pure (kept, drainFailuresOf report)
  case awaited <> survived <> fromWorker <> interrupted of
    [] → pure ()
    primary : rest → raiseRetainingOwner primary rest

-- | The most interruptions a join keeps while it waits for its report. It is
-- not evidence the contract promises to report in full — each is the same
-- interruption arriving again — so a small bound is honest here.
joinFailureBound ∷ Int
joinFailureBound = 8

-- | Join the owner's group, absorbing cancellation until it has drained.
--
-- 'closeWorkerGroup' is idempotent and answers the same report once the group
-- has drained, so a cancellation delivered during the wait is kept and the
-- join is entered again rather than abandoned.
joinAbsorbing
  ∷ WorkerGroup
  → [ExceptionWithContext SomeException]
  → IO (GroupReport, [ExceptionWithContext SomeException])
joinAbsorbing group found =
  tryWithContext (closeWorkerGroup group) >>= \case
    Right report → pure (report, found)
    -- Every failure, not only an asynchronous one. What matters is not the
    -- exception's type but how it arrived: an ordinary 'IOException'
    -- delivered with 'throwTo' is indistinguishable here from one the join
    -- itself raised, and returning on either would let the protected host
    -- unwind with the owner never proved terminal. So the join is entered
    -- again — it is documented idempotent, and re-entering it replays no
    -- backend disposal, which the owner's own drain owns — and the failure
    -- is kept for the caller to raise once a report really exists.
    Left caught → joinAbsorbing group (take joinFailureBound (found <> [caught]))

-- | What the joined owner's own run and drain failed with.
--
-- The worker's outcome is the only place a failure of its protected drain is
-- recorded — a 'graphicsRetireOwner' that failed while the destruction after
-- it succeeded leaves no latch and no missing evidence — so a host exit that
-- discarded this report would call that run a success.
drainFailuresOf ∷ GroupReport → [ExceptionWithContext SomeException]
drainFailuresOf report =
  [ failure
  | summary ←
      reportExitedBeforeClosing report <> reportDrained report <> reportObservedFailures report
  , failure ← case completionResult summary of
      Failed caught → [caught]
      -- A cancellation somebody asked for is not a failure to report: the
      -- owner's own drain already deferred it, finished every operation it
      -- owed, and re-raised it in order, which is the contract being kept
      -- rather than broken. One nobody asked for is a different matter, and
      -- is reported like any other outcome.
      Cancelled caught | not (requestedCancel (completionExit summary)) → [caught]
      _ → []
  ]
  where
    requestedCancel = \case
      RunExited _ CancelWasRequested → True
      _ → False

-- | Service the host's bounded native housekeeping until the owner's injected
-- destruction has answered.
--
-- The main thread performs no owner work here. It polls and waits for native
-- events and retries window retirement — which is exactly what the host's own
-- retirement environment lends the attachment drain, bounded per turn by the
-- host's configured idle wait — and nothing else. The owner's own wake ends
-- each wait as soon as it has something to report.
--
-- __It returns for the evidence and for nothing else.__ Not for the owner's
-- run ending, not for its worker becoming terminal, and not for an empty
-- target set: none of those establishes that the owner's shared state was
-- released, and returning on one would let the boundary unwind the windows,
-- the session and every borrowed parent behind it. An owner that ended without
-- the evidence therefore retains them, exactly as a stalled attachment retains
-- its window, and says so once through 'OwnerDestructionUnverified' under
-- 'graphicsOwnerComponent'. Only independent evidence —
-- 'publishOwnerDestruction', from a thread that established it — ends the wait
-- after that, and operator process termination remains the escape. No timeout
-- grants the authority, because a timeout is not evidence.
--
-- __Each turn decides from one coherent snapshot.__ Whether the destruction is
-- verified, whether the owner's run has ended, and every field the diagnostic
-- and its typed failure report are all read in a single transaction over the
-- owner's terminal record and its targets. Read separately, a successful
-- teardown could commit its evidence and then its completion between the two
-- reads, and the exit would declare unverified an owner that destroyed
-- everything it held. The owner commits its evidence before its completion, so
-- no snapshot of a successful teardown shows the run ended without the
-- evidence. One taken earlier either already holds the evidence or holds
-- neither, and then the turn only waits: the owner's own wake brings a later
-- turn to a snapshot that holds both. @observed@ runs after each snapshot is
-- read and before the turn acts on it; production passes @pure ()@.
--
-- It raises nothing. A native pump that fails withdraws itself, its failure
-- kept once rather than repeated every turn, and the wait then runs under a
-- finite timer of the same bound. A cancellation is absorbed and handed back
-- for the caller to re-raise after the join: cutting this wait short would be
-- exactly the early release D-33 forbids, and repeated cancellation may not
-- achieve it either.
awaitOwnerDestruction
  ∷ IO ()
  → (∀ a. IO a → IO a)
  → Logger
  → WindowHost
  → GraphicsOwner scene
  → IO [ExceptionWithContext SomeException]
awaitOwnerDestruction observed restore logger host owner = loop True False []
  where
    environment = retirementEnvironmentOf logger host
    bound = max 1 (round (environmentBound environment * 1e6))
    attempt found action =
      tryWithContext action >>= \case
        Right () → pure (True, found)
        Left caught@(ExceptionWithContext _ (failure ∷ SomeException))
          | isAsynchronous failure → pure (True, found <> [caught])
          | otherwise → pure (False, found <> [caught])
    loop pumping declared found = do
      snapshot ← atomically (destructionSnapshot owner)
      (_, seen) ← attempt found (restore observed)
      if isJust (ownerDestroyedEvidence (snapshotTerminal snapshot))
        then pure seen
        else do
          -- Said once, the first turn the owner is known to have ended with
          -- nothing established. It is a diagnostic and never an authority:
          -- the wait continues after it, and its own failure is retained
          -- rather than allowed to unwind what the wait is retaining.
          (declared', afterReport) ←
            if declared || not (ownerRunEnded (snapshotTerminal snapshot))
              then pure (declared, seen)
              else (,) True . snd <$> attempt seen (restore (declareUnverified logger snapshot))
          if pumping
            then do
              (keeps, waited) ← attempt afterReport (restore (environmentAwait environment >>= evaluate))
              (_, retired) ← attempt waited (restore (environmentRetireWindows environment >>= evaluate))
              loop keeps declared' retired
            else do
              expired ← registerDelay bound
              (_, timed) ←
                attempt
                  afterReport
                  (restore (atomically (readTVar expired >>= \elapsed → check elapsed)))
              loop False declared' timed

-- | One coherent reading of everything a turn of 'awaitOwnerDestruction'
-- decides and reports on: the owner's terminal record and how many targets it
-- still holds, taken together.
data DestructionSnapshot = DestructionSnapshot
  { snapshotTerminal ∷ !OwnerTerminal
  , snapshotTargets ∷ !Int
  }

destructionSnapshot ∷ GraphicsOwner scene → STM DestructionSnapshot
destructionSnapshot owner =
  DestructionSnapshot
    <$> ownerTerminal (ownerHandoff' owner)
    <*> (Map.size <$> readTVar (ownerTargets owner))

-- | The one diagnostic an unverified owner destruction owes, and the typed
-- failure it records.
--
-- The warning says what is being retained; the failure is what the exit hands
-- back, retained beside whatever else it found, so a run whose owner could not
-- destroy its own state reports that even when independent evidence later let
-- the boundary finish. It is never authority: it is raised into the wait's own
-- accumulator, the wait continues, and nothing is released because of it.
--
-- Both report the snapshot the decision was made from, and read nothing again:
-- a later read could describe an owner the decision never saw.
declareUnverified ∷ Logger → DestructionSnapshot → IO ()
declareUnverified logger snapshot = do
  logWarning
    logger
    graphicsOwnerComponent
    "The graphics owner ended without verified destruction; its shared state, the windows, the session and every parent are retained"
    [ ("retired", Text.pack (show retired))
    , ("unverified-targets", Text.pack (show unverified))
    ]
    >>= evaluate
  throwIO (OwnerDestructionUnverified retired unverified)
  where
    retired = isJust (ownerRetiredEvidence (snapshotTerminal snapshot))
    unverified = snapshotTargets snapshot

-- | Publish whole-owner retirement evidence a thread other than the owner
-- established.
--
-- It is the same shape the attachment model already has for retirement facts:
-- which transport carried the evidence decides nothing, and only that it was
-- /established/ does. Nothing here establishes it — the caller must have.
publishOwnerRetirement ∷ GraphicsOwner scene → OwnerRetired → IO ()
publishOwnerRetirement owner evidence = do
  atomically (recordOwnerRetired (ownerHandoff' owner) (evidenceDetail evidence))
  wakeGraphicsHost owner

-- | Publish whole-owner destruction evidence a thread other than the owner
-- established.
--
-- This is the independent evidence that ends a retained exit, and the only
-- thing besides the owner's own injected destruction that can. A composition
-- that publishes one it did not establish has destroyed nothing and has
-- authorized the release of everything the owner borrowed; that is exactly the
-- mistake the whole contract exists to prevent, and no code here can catch it.
publishOwnerDestruction ∷ GraphicsOwner scene → OwnerDestroyed → IO ()
publishOwnerDestruction owner evidence = do
  atomically (recordOwnerDestroyed (ownerHandoff' owner) (evidenceDetail evidence))
  wakeGraphicsHost owner
