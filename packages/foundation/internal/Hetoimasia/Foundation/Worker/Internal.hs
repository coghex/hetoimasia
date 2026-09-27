-- | The worker group behind "Hetoimasia.Foundation.Worker", shared inside the
-- foundation package and nowhere else.
--
-- This module belongs to the package's private @internal@ sublibrary, so no
-- client of the package can import it. The public module re-exports every
-- name here except the coordination probe: 'GroupProbe' and
-- 'withWorkerGroupProbed', which let the foundation's own tests hold a
-- cancellation helper at one fixed point of its production path. A production
-- group is 'withWorkerGroup', which is 'withWorkerGroupProbed' with 'noProbe';
-- there is no second implementation, no global switch, and no probe a client
-- can install.
--
-- It defines nothing. It is the package-private facade over eight hidden
-- modules of the same sublibrary, each owning one responsibility, and
-- re-exports exactly the names in its export list from them:
--
-- * "Hetoimasia.Foundation.Worker.Base" owns worker identity, the request
--   record, the stop token and its readers, 'WorkerCancelled', and the group
--   phase.
-- * "Hetoimasia.Foundation.Worker.Outcome" owns the run-exit record, results,
--   completions, the startup report, the start rejection, the group report,
--   and the helpers that classify a caught failure.
-- * "Hetoimasia.Foundation.Worker.Types" owns the group's state
--   representation: the group, each worker's entry, the closing snapshot, the
--   drain-status records, the coordination probe, the handle, and the
--   definition.
-- * "Hetoimasia.Foundation.Worker.Observation" owns the drain status, startup
--   and completion reads, the committed observation, and settled retirement.
-- * "Hetoimasia.Foundation.Worker.Requests" owns stop and cancellation
--   requests, the cancellation helper, and a failing starter's drain.
-- * "Hetoimasia.Foundation.Worker.Startup" owns registration, the fork and
--   handoff, the child thread, and terminal publication.
-- * "Hetoimasia.Foundation.Worker.Group" owns the lifetime boundary, closing,
--   the report, and the protected drain.
-- * "Hetoimasia.Foundation.Worker.Evidence" owns the evidence attached to a
--   propagated failure and its readers.
--
-- Those modules import one another directly, in that dependency order with
-- "Hetoimasia.Foundation.Worker.Startup" and
-- "Hetoimasia.Foundation.Worker.Group" independent of each other, and never
-- this facade; code outside the sublibrary imports only this facade.
--
-- The contract is documented on the public module and in @docs/workers.md@,
-- which names the module that owns and writes every piece of worker state.
module Hetoimasia.Foundation.Worker.Internal
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

    -- * Coordination probe
  , GroupProbe (..)
  , noProbe
  , withWorkerGroupProbed

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

import Hetoimasia.Foundation.Worker.Base
  ( GroupPhase (..)
  , Requested (..)
  , StopToken
  , WorkerCancelled (..)
  , WorkerId
  , awaitStopRequest
  , stopRequested
  )
import Hetoimasia.Foundation.Worker.Evidence
  ( WorkerEvidence (..)
  , workerEvidence
  , workerEvidenceInContext
  )
import Hetoimasia.Foundation.Worker.Group
  ( allocWorkerGroup
  , closeWorkerGroup
  , withWorkerGroup
  , withWorkerGroupProbed
  )
import Hetoimasia.Foundation.Worker.Observation
  ( activeWorkerCount
  , awaitCompletion
  , awaitStartup
  , groupStatus
  , observeCompletion
  , pollCompletion
  )
import Hetoimasia.Foundation.Worker.Outcome
  ( Completion (..)
  , GroupReport (..)
  , Result (..)
  , RunEnd (..)
  , RunExit (..)
  , StartRejection (..)
  , Startup (..)
  , WorkerSummary
  )
import Hetoimasia.Foundation.Worker.Requests (requestCancel, requestStop)
import Hetoimasia.Foundation.Worker.Startup (startWorker, startWorkerWith)
import Hetoimasia.Foundation.Worker.Types
  ( GroupProbe (..)
  , GroupStatus (..)
  , Outstanding (..)
  , OutstandingWorker (..)
  , StartOutcome (..)
  , Worker
  , WorkerDefinition
  , WorkerGroup
  , noProbe
  , workerDefinition
  , workerId
  , workerLabel
  )
