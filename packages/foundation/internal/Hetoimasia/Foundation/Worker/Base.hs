-- | Worker identity, the request a worker has received, its stop token, the
-- cancellation it is delivered, and the group's lifecycle phase.
--
-- This module belongs to the package's private @internal@ sublibrary and is
-- not exposed even there: "Hetoimasia.Foundation.Worker.Internal" re-exports
-- it for the rest of the package, and the other worker modules import it
-- directly. It is private so 'WorkerId' and 'StopToken' keep their
-- constructors away from clients: the public module exports both types
-- abstract.
--
-- It imports no other worker module. Everything here is a value or a single
-- read of one variable; the variables themselves are created and written by the
-- modules that own worker state, which @docs/workers.md@ names.
module Hetoimasia.Foundation.Worker.Base
  ( -- * Identity
    WorkerId (..)

    -- * Requests
  , Requested (..)
  , StopToken (..)
  , stopRequested
  , awaitStopRequest
  , WorkerCancelled (..)

    -- * Group phase
  , GroupPhase (..)
  , Phase (..)
  ) where

import Control.Concurrent.STM (STM, TVar, check, readTVar)
import Control.Exception
  ( Exception (fromException, toException)
  , asyncExceptionFromException
  , asyncExceptionToException
  )

-- Identity and requests ------------------------------------------------------

-- | A worker's identity within its group. Identifiers are issued in
-- registration order, which is the order every report lists workers in; it is
-- not a claim about the wall-clock order of racing threads.
newtype WorkerId = WorkerId Int
  deriving (Eq, Ord, Show)

-- | The strongest request made of a worker so far. Requests only strengthen:
-- a stop never resets a cancellation, and nothing resets either to running.
data Requested
  = NothingRequested
  | StopWasRequested
  | CancelWasRequested
    -- ^ A cancellation request is also a stop request.
  deriving (Eq, Ord, Show)

-- | The worker's own view of its stop request.
--
-- It is the only piece of control state a worker receives. Reading it is an
-- STM transaction, so a worker can combine it with the rest of its own wait.
newtype StopToken = StopToken (TVar Requested)

-- | Whether a stop, or a cancellation, has been requested.
stopRequested ∷ StopToken → STM Bool
stopRequested (StopToken requests) = (/= NothingRequested) <$> readTVar requests

-- | Retry until a stop, or a cancellation, has been requested.
awaitStopRequest ∷ StopToken → STM ()
awaitStopRequest token = stopRequested token >>= check

-- | A cancellation delivered by 'Hetoimasia.Foundation.Worker.requestCancel'.
data WorkerCancelled = WorkerCancelled
  deriving (Eq, Show)

instance Exception WorkerCancelled where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- Group phase ----------------------------------------------------------------

-- | A group's lifecycle phase, as 'Hetoimasia.Foundation.Worker.groupStatus'
-- reports it.
data GroupPhase
  = GroupOpen
    -- ^ Registration is open.
  | GroupClosing
    -- ^ Closing has begun and the 'Hetoimasia.Foundation.Worker.GroupReport'
    -- is not yet published.
  | GroupClosed
    -- ^ The 'Hetoimasia.Foundation.Worker.GroupReport' is published. This says
    -- nothing about what the group's owner does next.
  deriving (Eq, Show)

-- | The group's own phase, as its state holds it. 'GroupPhase' is its public
-- reading.
data Phase
  = Open
  | Closing
  | Closed
  deriving (Eq)
