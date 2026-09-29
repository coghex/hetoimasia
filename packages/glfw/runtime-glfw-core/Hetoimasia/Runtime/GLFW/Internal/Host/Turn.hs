-- | One owner turn's work after its native event step: the single
-- implementation both owner loops share.
--
-- Every operation here runs on the process main thread, the session's owner,
-- inside 'Hetoimasia.Runtime.GLFW.Internal.Host.Loop.runOwnerLoop' or
-- 'Hetoimasia.Runtime.GLFW.Internal.Host.Loop.runScheduledOwnerLoop', which
-- choose how the native step waits and decide nothing else. The turn writes
-- the host's activity, surfaced-request, and window cells in
-- "Hetoimasia.Runtime.GLFW.Internal.Host.State", and nothing of its own.
module Hetoimasia.Runtime.GLFW.Internal.Host.Turn
  ( Turn (..)
  , TurnWork (..)
  , turnWork
  , turnSummary
  , processEvents
  , reportingAsItEnds
  ) where

import Control.Concurrent.STM (atomically, readTVarIO, writeTVar)
import Control.Exception (finally, mask)
import Control.Monad (forM, forM_, unless, void)
import Data.IORef (modifyIORef', readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Hetoimasia.Foundation.Log (Logger)
import Hetoimasia.GLFW.Internal.Input (attemptOverflowWarning, resumeInput)
import Hetoimasia.GLFW.Internal.Session (reconcileMonitorEvents, sessionTrace)
import Hetoimasia.GLFW.Internal.Trace (TraceEvent (TurnBegan), recordTrace)
import Hetoimasia.GLFW.Internal.Window
  ( EventProcessing (..)
  , processWindowEvents
  , reconcileWindowEvents
  , reconcileWindowMode
  )
import Hetoimasia.GLFW.Window (CloseRequest, WindowResult (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Commands (dispatchCommands)
import Hetoimasia.Runtime.GLFW.Internal.Host.Config (HostConfig (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Progress (advanceHostRetirements)
import Hetoimasia.Runtime.GLFW.Internal.Host.State (HostActivity (..), HostEntry (..), WindowHost (..))
import Hetoimasia.Runtime.GLFW.Internal.Host.Wake (hostNotifier, markedDegradationAttempt, promptAttempt, retainingReport)
import Hetoimasia.Runtime.GLFW.Internal.Host.Windows (borrowWindow, latestCloseRequest, retirePending)
import Hetoimasia.Runtime.Supervision (RuntimeControl, checkRuntime)
import Numeric.Natural (Natural)

-- | What one turn did, as its update opportunity sees it.
data Turn = Turn
  { turnNumber ∷ !Natural
    -- ^ Starting at one.
  , turnWaited ∷ !Bool
    -- ^ Whether the turn was idle and made a finite native wait.
  , turnCommands ∷ !Int
    -- ^ Commands attempted across every port, rejected ones included.
  , turnEvents ∷ !Int
    -- ^ Application events dispatched.
  , turnCloseRequests ∷ ![CloseRequest]
    -- ^ Close requests surfaced for the first time, in window order.
  }
  deriving (Eq, Show)

-- | However a loop ends — a result, a supervised failure, a native failure, or
-- a cancellation — the wake path's one report is claimed before it returns, so
-- a degradation this turn's own work already caused is reported here rather
-- than waiting for shutdown.
--
-- This boundary never waits for an obligation. Admission and publication are
-- still open, and a worker that keeps publishing until supervision stops it
-- would keep new obligations coming, so waiting here would hold the loop's own
-- result back from the quiescence and the drain that would end them. The
-- boundary that does wait is the one after quiescence, where nothing new can be
-- registered.
reportingAsItEnds ∷ Logger → WindowHost → IO r → IO r
reportingAsItEnds logger host = retainingReport (\restore → promptAttempt restore logger host)

-- | What one turn's reconciliation and bounded dispatch produced.
data TurnWork = TurnWork
  { workCommands ∷ !Int
  , workEvents ∷ !Int
  , workCloses ∷ ![CloseRequest]
  }

-- | The work of one turn after its native event processing, in the one order
-- both loops use: reconciliation and feed recovery, a check, bounded command
-- work and recovery again, a check, bounded application event work, and a
-- check.
turnWork ∷ WindowHost → RuntimeControl → Logger → IO Bool → IO TurnWork
turnWork host control logger event = do
  reconcileMonitorEvents (hostSession host)
  reconcileWindowModes host
  -- Before the retirement retry below, so an attachment this turn's own bounded
  -- round made safe releases its window in the same turn rather than the next.
  advanceHostRetirements host
  retirePending host
  closes ← surfaceCloseRequests host
  recoverFeeds logger host
  void (mask (\restore → markedDegradationAttempt restore logger (hostNotifier host)))
  checkRuntime control
  commands ← dispatchCommands host (hostCommandBudget settings)
  recoverFeeds logger host
  checkRuntime control
  events ← dispatchEvents event (hostEventBudget settings)
  checkRuntime control
  pure (TurnWork commands events closes)
  where
    settings = hostSettings host

turnSummary ∷ Natural → Bool → TurnWork → Turn
turnSummary number waited work = Turn number waited (workCommands work) (workEvents work) (workCloses work)

-- | Poll, or wait the chosen finite bound, publishing the activity around it.
--
-- The turn number is offered to the session's interaction trace
-- ("Hetoimasia.GLFW.Internal.Trace") first, so the pump's own entry and exit,
-- and every callback delivered between them, are attributable to this turn.
-- The trace is stopped in every ordinary run, which costs one 'IORef' read.
processEvents ∷ WindowHost → Natural → EventProcessing → IO ()
processEvents host number processing = do
  recordTrace (sessionTrace (hostSession host)) (TurnBegan number)
  atomically (writeTVar (hostActivityState host) (HostActivity number waiting))
  processWindowEvents (hostSession host) processing
    `finally` atomically (writeTVar (hostActivityState host) (HostActivity number False))
  where
    waiting = case processing of
      AwaitEventsFor _ → True
      ProcessPending → False

-- | Reconcile the mode of every window the host holds that is not closing, in
-- registration order, after the turn's monitor refresh: a window whose recovery
-- obligation names an ended monitor identity takes its recorded fallback
-- without another command, whatever observations intervened since the
-- disconnect. The obligation is the monitor the last settlement established,
-- or the live monitor an earlier turn's reconciliation confirmed a borderless
-- window had moved onto while both were connected; a move folded in the same
-- turn as a disconnect is judged only by a later turn, against the refreshed
-- inventory, so it never re-points the obligation to an ended monitor.
reconcileWindowModes ∷ WindowHost → IO ()
reconcileWindowModes host = do
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.toAscList entries) $ \(target, entry) →
    if entryClosing entry then pure () else void (borrowWindow host target entry reconcileWindowMode)

-- | Claim each open feed's overflow warning and resume any acknowledged
-- reset, at a safe owner boundary after callbacks have been reconciled.
recoverFeeds ∷ Logger → WindowHost → IO ()
recoverFeeds logger host = do
  entries ← readTVarIO (hostEntries host)
  forM_ (Map.elems entries) $ \entry →
    unless (entryClosing entry) $ do
      void (attemptOverflowWarning logger (entryInput entry))
      void (resumeInput (entryInput entry))

-- | Reconcile every window the host holds, and answer the close requests of
-- windows not closing that were not surfaced before.
surfaceCloseRequests ∷ WindowHost → IO [CloseRequest]
surfaceCloseRequests host = do
  entries ← readTVarIO (hostEntries host)
  fmap catMaybes . forM (Map.toAscList entries) $ \(target, entry) →
    borrowWindow host target entry $ \window →
      reconcileWindowEvents window >>= \case
        WindowEnded _ → pure Nothing
        WindowAvailable ()
          | entryClosing entry → pure Nothing
          | otherwise →
              latestCloseRequest window >>= \case
                Nothing → pure Nothing
                Just request → do
                  surfaced ← Map.lookup target <$> readIORef (hostSurfaced host)
                  if surfaced == Just request
                    then pure Nothing
                    else do
                      modifyIORef' (hostSurfaced host) (Map.insert target request)
                      pure (Just request)

-- | Offer event opportunities until the budget is spent or nothing is ready,
-- answering how many dispatched something.
dispatchEvents ∷ IO Bool → Int → IO Int
dispatchEvents opportunity budget = go 0
  where
    go dispatched
      | dispatched >= budget = pure dispatched
      | otherwise = opportunity >>= \ready → if ready then go (dispatched + 1) else pure dispatched
