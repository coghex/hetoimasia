-- | Fixtures for supervision examples, written so the application-runner
-- examples can drive the same workers.
--
-- Every fixture hands its caller fresh state. Coordination is explicit: a gate
-- is an 'MVar' a worker waits on, and 'awaitBlockedOnSTM' decides that the
-- application thread has parked in a supervised wait. No fixture sleeps.
module Test.Engine.Runtime.Supervision.Support
  ( -- * Failures
    Broken (..)
  , brokenIs

    -- * Policies
  , required
  , optional
  , recognizing
  , supervisionComponent

    -- * Workers
  , Gate
  , newGate
  , openGate
  , serviceUntilStopped
  , failingAfter
  , returningAfter
  , job
  , owned

    -- * Logging lifetime
  , CollectedLifetime (..)
  , withCollectedLifetime
  , warningCount

    -- * Coordination
  , awaitBlockedOnSTM
  , awaitTerminal
  , boundedSupervision
  , expectFailure
  , expectStarted
  , Trace
  , newTrace
  , record
  , traced
  ) where

import Control.Concurrent (ThreadId, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , throwIO
  , tryWithContext
  )
import Control.Monad (void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Log
  ( Component
  , LogEntry (..)
  , LogLevel (..)
  , Logger
  , callbackSink
  , defaultLogFilter
  , mkLoggerWith
  , unsafeComponent
  )
import Hetoimasia.Foundation.Resource (Scoped, allocResource)
import Hetoimasia.Foundation.Worker
  ( Completion
  , StopToken
  , Worker
  , WorkerDefinition
  , awaitCompletion
  , awaitStopRequest
  , workerDefinition
  )
import Hetoimasia.Runtime.Logging (LoggingLifetime, withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Disposition (..)
  , Recognition (..)
  , Role
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  )
import System.Timeout (timeout)
import Test.Engine.Logging.Support (fixedMetadata)
import Test.Hspec (Expectation, expectationFailure)

-- Failures ---------------------------------------------------------------------

-- | A typed synthetic failure, distinguishable by its text.
newtype Broken = Broken Text
  deriving (Eq, Show)

instance Exception Broken

brokenIs ∷ Text → ExceptionWithContext SomeException → Bool
brokenIs expected (ExceptionWithContext _ failure) = fromException failure == Just (Broken expected)

-- Policies ---------------------------------------------------------------------

supervisionComponent ∷ Component
supervisionComponent = unsafeComponent "test.supervision"

-- | A required worker whose component recognizes nothing.
required ∷ Role → WorkerPolicy
required role = WorkerPolicy role Required supervisionComponent (\_ → pure Unrecognized)

-- | An optional worker whose component recognizes every failure.
optional ∷ Role → WorkerPolicy
optional role = recognizing role Optional (\_ → True)

recognizing ∷ Role → Disposition → (ExceptionWithContext SomeException → Bool) → WorkerPolicy
recognizing role disposition recognizes =
  WorkerPolicy role disposition supervisionComponent $ \failure →
    pure (if recognizes failure then Recognized else Unrecognized)

-- Workers ----------------------------------------------------------------------

-- | A one-shot signal a worker waits on. Opening it twice is harmless.
type Gate = MVar ()

newGate ∷ IO Gate
newGate = newEmptyMVar

openGate ∷ Gate → IO ()
openGate gate = void (tryPutMVar gate ())

-- | An append-only trace of acquisitions, releases, and example steps.
type Trace = IORef [Text]

newTrace ∷ IO Trace
newTrace = newIORef []

record ∷ Trace → Text → IO ()
record trace entry = atomicModifyIORef' trace (\entries → (entries <> [entry], ()))

traced ∷ Trace → IO [Text]
traced = readIORef

-- | A traced resource the worker owns for its run.
owned ∷ Trace → Text → Scoped ()
owned trace name = allocResource (record trace ("acquire " <> name)) (\() → record trace ("release " <> name))

-- | A service that runs until it is asked to stop, then returns.
serviceUntilStopped ∷ Trace → Text → WorkerDefinition ()
serviceUntilStopped trace name =
  workerDefinition name (\_ → owned trace name) $ \token () → atomically (awaitStopRequest token)

-- | A worker that throws once its gate opens.
failingAfter ∷ Trace → Text → Gate → Broken → WorkerDefinition ()
failingAfter trace name gate failure =
  workerDefinition name (\_ → owned trace name) $ \_ () → readMVar gate >> throwIO failure

-- | A worker that returns normally once its gate opens, whether or not a stop
-- was requested.
returningAfter ∷ Trace → Text → Gate → WorkerDefinition ()
returningAfter trace name gate = workerDefinition name (\_ → owned trace name) $ \_ () → readMVar gate

-- | A finite job with a result.
job ∷ Text → (StopToken → IO r) → WorkerDefinition r
job name work = workerDefinition name (\_ → pure ()) (\token () → work token)

-- Logging lifetime -------------------------------------------------------------

-- | A lifetime over a collecting logger, with the collected entries.
data CollectedLifetime = CollectedLifetime
  { collectedLifetime ∷ LoggingLifetime
  , collectedEntries ∷ IO [LogEntry]
  }

-- | Run inside a logging lifetime whose sink collects entries and runs an
-- injected write action, which may throw.
withCollectedLifetime ∷ (LogEntry → IO ()) → (CollectedLifetime → IO a) → IO a
withCollectedLifetime onWrite body = do
  entries ← newIORef []
  let sink entry = atomicModifyIORef' entries (\collected → (entry : collected, ())) >> onWrite entry
      logger ∷ Logger
      logger = mkLoggerWith defaultLogFilter fixedMetadata (callbackSink sink)
  withLoggingLifetime logger $ \lifetime → body (CollectedLifetime lifetime (reverse <$> readIORef entries))

warningCount ∷ CollectedLifetime → IO Int
warningCount collected = length . filter ((== Warning) . entryLevel) <$> collectedEntries collected

-- Coordination -----------------------------------------------------------------

-- | Wait until a thread is parked in an STM transaction.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnSTM → pure ()
    _ → yield >> awaitBlockedOnSTM thread

-- | Raw observation: wait for a worker's terminal outcome without handling it.
awaitTerminal ∷ Worker r → IO (Completion r)
awaitTerminal = atomically . awaitCompletion

-- | Stop an example that has already hung. Never a concurrency assertion.
boundedSupervision ∷ Expectation → Expectation
boundedSupervision action =
  timeout (30 * 1000 * 1000) action
    >>= maybe (expectationFailure "the example did not finish within its bound") pure

-- | Require a failure, keeping its context.
expectFailure ∷ IO a → IO (ExceptionWithContext SomeException)
expectFailure action =
  tryWithContext action >>= either pure (\_ → throwIO (userError "expected a failure, but it returned"))

expectStarted ∷ SupervisedStart r → IO (SupervisedWorker r)
expectStarted (WorkerStarted worker) = pure worker
expectStarted (WorkerStartUnavailable _ _) = throwIO (userError "expected a start, found an unavailable worker")
expectStarted WorkerStartRejected = throwIO (userError "expected a start, found a rejection")
