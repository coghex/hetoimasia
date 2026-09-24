-- | Owned CPU worker threads: scoped startup, cooperative stop, cancellation,
-- terminal observation, and a protected drain before borrowed dependencies
-- unwind.
--
-- A 'WorkerGroup' is one lifetime owner for the workers started through it.
-- 'withWorkerGroup' is an 'IO' lifetime boundary that runs /inside/ the scopes
-- of the components its workers borrow, and 'allocWorkerGroup' composes the
-- same boundary in 'Scoped'. Every exit from that boundary — a normal return, a
-- startup failure, a body failure, owner cancellation, and a further
-- cancellation delivered while it drains — closes registration, requests a
-- cooperative stop from every live worker before waiting for any, requests
-- cancellation of live workers when the owner is failing, and then waits until
-- every worker has published its terminal outcome and every cancellation
-- helper has finished. Only then does the owner return or rethrow, so the
-- enclosing dependency scopes cannot unwind under a worker still using them.
-- A worker that never stops keeps the owner waiting with its dependencies live:
-- there is no deadline, no detach, and no process termination.
--
-- The drain is deliberately not an 'Hetoimasia.Foundation.Resource.allocResource'
-- release. A release runs under 'Control.Exception.uninterruptibleMask_' and
-- must have a controlled blocking duration, and waiting for a thread has none.
--
-- A worker is a 'WorkerDefinition': a startup written as a 'Scoped' construction
-- and a run action. The four operations on a started worker are distinct:
--
-- * startup acknowledgement, observed with 'awaitStartup';
-- * a cooperative stop request, 'requestStop', which the worker reads through
--   its 'StopToken';
-- * a cancellation request, 'requestCancel', delivered by a group-owned helper;
-- * terminal observation, 'awaitCompletion' for any number of raw readers and
--   'observeCompletion' for the owner that commits an observation.
--
-- Observation never stops or cancels a worker, and observing a worker's
-- cancellation never cancels the observer: a 'Completion' is data.
--
-- This module publishes raw evidence — the terminal 'Result', the 'RunExit'
-- record that fixes whether the run action exited before a stop was requested,
-- the cleanup failures, and a 'GroupReport' at closing. It does not classify
-- services, finite jobs, or required and optional workers; that is supervision,
-- which belongs to the runtime. It makes no OS-thread-affinity guarantee, no
-- wall-clock termination guarantee, and no promise to interrupt arbitrary
-- blocking 'IO'.
--
-- While the group drains, or at any other time, 'groupStatus' reads one
-- coherent snapshot of its phase and of every worker the drain would still
-- wait for. It is observation only: it waits for nothing, changes nothing,
-- names no cause for a stall, and says nothing about whether resources are
-- safe to release. Elapsed time, sampling cadence, output, and any deadline
-- belong to the application that reads it.
--
-- The module takes no logger. 'allocWorkerGroup' builds its 'Scoped' value
-- through the foundation package's private implementation seam, so the 'Scoped'
-- constructor stays unexported and no catch instance is added to it. The
-- implementation lives in that seam too; this module re-exports it without the
-- coordination probe the foundation's own tests use.
--
-- See @docs/workers.md@ for the same contract in prose, including every piece
-- of state, its owner, readers and writers, thread, lifetime, and reset.
module Hetoimasia.Foundation.Worker
  ( -- * Group lifetime
    WorkerGroup
  , withWorkerGroup
  , allocWorkerGroup
  , closeWorkerGroup
  , activeWorkerCount

    -- * Drain status
  , GroupStatus (..)
  , GroupPhase (..)
  , OutstandingWorker (..)
  , Outstanding (..)
  , groupStatus

    -- * Definitions
  , WorkerDefinition
  , workerDefinition
  , StopToken
  , stopRequested
  , awaitStopRequest

    -- * Starting
  , Worker
  , workerId
  , workerLabel
  , WorkerId
  , StartOutcome (..)
  , StartRejection (..)
  , startWorker
  , startWorkerWith

    -- * Requests
  , requestStop
  , requestCancel
  , WorkerCancelled (..)

    -- * Observation
  , Startup (..)
  , awaitStartup
  , awaitCompletion
  , pollCompletion
  , observeCompletion

    -- * Outcomes
  , Completion (..)
  , Result (..)
  , RunExit (..)
  , RunEnd (..)
  , Requested (..)
  , WorkerSummary
  , GroupReport (..)

    -- * Evidence on a propagated failure
  , WorkerEvidence (..)
  , workerEvidence
  , workerEvidenceInContext
  ) where

-- Everything but the coordination probe, which stays inside the package.
import Hetoimasia.Foundation.Worker.Internal hiding
  ( GroupProbe (..)
  , noProbe
  , withWorkerGroupProbed
  )
