-- | Fixtures the GLFW suite's component specs share.
--
-- It is not a spec module: it declares no example and composes nothing, so a
-- component spec that needs one of these takes it from here rather than from
-- another component's spec. Everything in it is a neutral fixture of this
-- suite's own domain — entering a seam session, reading a window's published
-- observation, running an application over a seam host, scripting a clock, and
-- the small assertion helpers every component uses — so it belongs beside this
-- suite rather than in the cross-suite @hetoimasia-test-support@ library, which
-- holds only utilities more than one suite needs.
--
-- Nothing here initializes GLFW, opens a window, needs a display, or sleeps for
-- a concurrency outcome.
module Test.GLFW.Support
  ( -- * Sessions and windows
    entered
  , current
  , stashed

    -- * Threads, failures, and bounds
  , onThread
  , caughtAs
  , unexpected
  , originOf
  , operationOf
  , contextsOf
  , boundedExample

    -- * Scripted clocks
  , scriptedClock
  , at
  , durationOf
  , millis

    -- * Seam hosts
  , hosted
  , settings
  , windowNamed
  , quietLogger
  , pumps

    -- * Recording and failing sinks
  , SinkFailed (..)
  , SinkMark (..)
  , SinkTrace
  , newSinkTrace
  , traced
  , flushed
  , failingSink
  , sinkFailingOn

    -- * What a failure carries
  , raisedWith
  , diagnosticMarks
  , sinkMarks
  , retainedDiagnostics
  , retainedAs
  ) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , annotateIO
  , displayException
  , fromException
  , throwIO
  , try
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Control.Monad (when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , OperationContext (..)
  , failureEvidence
  , operationText
  )
import Hetoimasia.Foundation.Log
  ( LogEntry (entryComponent)
  , LogFilter
  , Logger
  , callbackSink
  , callbackSinkWith
  , componentText
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  )
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource
  ( cleanupFailureException
  , cleanupFailureLabel
  , cleanupFailuresInContext
  , withScoped
  )
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (AllowZero)
  , Instant
  , MonotonicSource
  , durationFromNanoseconds
  , scriptedInstant
  , scriptedSource
  )
import Hetoimasia.GLFW.Internal.Seam (NativeCall (..), Seam, asProcessMainThread, seamCalls, seamSession)
import Hetoimasia.GLFW.Session (Session, defaultSessionConfig)
import Hetoimasia.GLFW.Window
  ( Window
  , WindowConfig
  , WindowObservation
  , hiddenTestWindowConfig
  , windowObservations
  )
import Hetoimasia.Runtime.GLFW
  ( HostConfig (..)
  , WindowHost
  , allocWindowHostIn
  , defaultHostConfig
  , runWindowApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Reporting (DiagnosticFailure, raisedByDiagnostic)
import Hetoimasia.Runtime.Supervision (RuntimeControl)
import System.Timeout (timeout)
import Test.Hspec (Expectation, expectationFailure)

-- ---------------------------------------------------------------------------
-- Sessions and windows

entered ∷ Seam → (Session → IO r) → IO r
entered seam = withScoped (seamSession seam defaultSessionConfig)

current ∷ Window → IO WindowObservation
current window = preparedValue . observedValue <$> atomically (readSnapshot (windowObservations window))

stashed ∷ IORef (Maybe Window) → IO Window
stashed stash = readIORef stash >>= maybe (unexpected "no window was stashed") pure

-- ---------------------------------------------------------------------------
-- Threads, failures, and bounds

-- | Run an action on a new thread and wait for its outcome.
onThread ∷ (IO () → IO ThreadId) → IO a → IO a
onThread fork action = do
  finished ← newEmptyMVar
  _ ← fork (try action >>= putMVar finished)
  outcome ← takeMVar finished
  either (throwIO ∷ SomeException → IO a) pure outcome

-- | The typed failure an action raised, beside the exception as caught.
caughtAs ∷ Exception e ⇒ IO a → IO (e, SomeException)
caughtAs action = do
  outcome ← try action
  case outcome of
    Right _ → unexpected "the action returned instead of failing"
    Left caught → case fromException caught of
      Just typed → pure (typed, caught)
      Nothing → unexpected ("the action failed with " <> displayException caught)

unexpected ∷ String → IO a
unexpected message = expectationFailure message >> ioError (userError message)

originOf ∷ SomeException → Maybe (Text, Text, [(Text, Text)])
originOf caught = case failureCause (failureEvidence caught) of
  EngineOrigin origin →
    Just
      ( componentText (originComponent origin)
      , operationText (originOperation origin)
      , originIdentifiers origin
      )
  NativeCause → Nothing

operationOf ∷ SomeException → Maybe (Text, Text)
operationOf caught = (\(component, operationName, _) → (component, operationName)) <$> originOf caught

contextsOf ∷ SomeException → [(Text, Text, [(Text, Text)])]
contextsOf caught =
  [ (componentText (contextComponent context), operationText (contextOperation context), contextIdentifiers context)
  | context ← failureContexts (failureEvidence caught)
  ]

boundedExample ∷ Expectation → Expectation
boundedExample action = do
  finished ← timeout (30 * 1000 * 1000) action
  case finished of
    Just () → pure ()
    Nothing → expectationFailure "the example did not finish within its bound"

-- ---------------------------------------------------------------------------
-- Scripted clocks

-- | A clock whose readings are the scripted nanosecond offsets from the
-- script's own origin, in order, with the count still unread beside it. A
-- reading past the end fails the example rather than inventing an instant.
scriptedClock ∷ [Integer] → IO (MonotonicSource, IO Int)
scriptedClock offsets = do
  remaining ← newIORef (map at offsets)
  let next =
        atomicModifyIORef' remaining (\case instant : rest → (rest, Just instant); [] → ([], Nothing))
          >>= maybe (unexpected "the loop read the scripted clock more often than the example scripted") pure
  pure (scriptedSource next, length <$> readIORef remaining)

at ∷ Integer → Instant
at = scriptedInstant . durationOf

durationOf ∷ Integer → Duration
durationOf nanoseconds = case durationFromNanoseconds AllowZero nanoseconds of
  Right duration → duration
  Left rejected → error ("the scripted duration was rejected: " <> show rejected)

millis ∷ Integer → Integer
millis count = count * 1000000

-- ---------------------------------------------------------------------------
-- Seam hosts

-- | Run an application over a host in the seam's session, on a bound thread
-- designated as the process main thread.
hosted ∷ Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
hosted seam config startup action =
  asProcessMainThread
    seam
    ( runWindowApplication
        (withLoggingLifetime quietLogger)
        "seam-example"
        (allocWindowHostIn (seamSession seam defaultSessionConfig) config)
        id
        startup
        action
    )

settings ∷ [WindowConfig] → MonotonicSource → HostConfig
settings windows clock =
  (defaultHostConfig windows)
    { hostCommandCapacity = 8
    , hostCommandBudget = 3
    , hostEventBudget = 2
    , hostIdleWait = 0.25
    , hostClock = clock
    }

windowNamed ∷ Text → WindowConfig
windowNamed name = hiddenTestWindowConfig name 64 48

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

-- | The native event processing calls, in order.
pumps ∷ Seam → IO [NativeCall]
pumps seam = filter pumped <$> seamCalls seam
  where
    pumped = \case
      PollEvents → True
      WaitEvents _ → True
      _ → False

-- ---------------------------------------------------------------------------
-- Recording and failing sinks

-- | The failure a scripted sink raises, distinguishable by type from any
-- application failure the same example raises.
newtype SinkFailed = SinkFailed Text
  deriving (Eq, Show)

instance Exception SinkFailed

-- | Rides on the exception a scripted sink raises, so an example can tell that
-- exception, with the context it was raised with, from a copy of it.
data SinkMark = SinkMark
  deriving (Eq, Show)

instance ExceptionAnnotation SinkMark where
  displayExceptionAnnotation _ = "raised by the example's sink"

-- | What one example's sink was given: every entry, in order, and how many
-- times it was flushed.
data SinkTrace = SinkTrace
  { traceEntries ∷ IORef [LogEntry]
  , traceFlushes ∷ IORef Int
  }

newSinkTrace ∷ IO SinkTrace
newSinkTrace = SinkTrace <$> newIORef [] <*> newIORef 0

-- | The components the sink was given an entry for, in the order it was given
-- them. A terminal report the runtime makes through the same sink appears as
-- @runtime@, so an example that expects none asserts on this whole list rather
-- than on one component's entries alone.
traced ∷ SinkTrace → IO [Text]
traced trace = map (componentText . entryComponent) <$> readIORef (traceEntries trace)

flushed ∷ SinkTrace → IO Int
flushed = readIORef . traceFlushes

-- | A logger that records every entry and counts every flush, and whose write
-- then fails for one component's entries alone.
--
-- The entry is recorded before the failure, because the attempt reached the
-- sink either way, and the observer runs there too, so an example can see what
-- was still live at the moment the entry was written. The exception carries
-- 'SinkMark', so an example can prove the one that propagated is the one this
-- sink raised.
failingSink ∷ LogFilter → Text → (LogEntry → IO ()) → SinkTrace → Logger
failingSink configuration component observe trace =
  mkLoggerWith configuration systemMetadata $
    callbackSinkWith
      ( \entry → do
          modifyIORef' (traceEntries trace) (<> [entry])
          when (componentText (entryComponent entry) == component) $ do
            observe entry
            annotateIO SinkMark (throwIO (SinkFailed component))
      )
      (modifyIORef' (traceFlushes trace) (+ 1))

-- | 'failingSink' with nothing to observe, over the ordinary filter.
sinkFailingOn ∷ Text → SinkTrace → Logger
sinkFailingOn component = failingSink defaultLogFilter component (\_ → pure ())

-- ---------------------------------------------------------------------------
-- What a failure carries

-- | The typed failure a propagating exception carries, beside its context.
raisedWith ∷ Exception e ⇒ ExceptionWithContext SomeException → IO (e, ExceptionContext)
raisedWith (ExceptionWithContext context failure) = case fromException failure of
  Just typed → pure (typed, context)
  Nothing → unexpected ("the run failed with " <> displayException failure)

-- | The runtime's diagnostic-failure marks a context carries.
diagnosticMarks ∷ ExceptionContext → [DiagnosticFailure]
diagnosticMarks = getExceptionAnnotations

-- | The example sink's own marks, which an exception carried out of the sink.
sinkMarks ∷ ExceptionContext → [SinkMark]
sinkMarks = getExceptionAnnotations

-- | Each cleanup failure a context retained, as the label it was retained under
-- beside whether a diagnostic raised it.
retainedDiagnostics ∷ ExceptionContext → [(Text, Bool)]
retainedDiagnostics context =
  [ (cleanupFailureLabel retained, raisedByDiagnostic carried)
  | retained ← cleanupFailuresInContext context
  , ExceptionWithContext carried _ ← [cleanupFailureException retained]
  ]

-- | The exceptions a context retained under one cleanup label, each read back
-- at the type the example expects, with the marks the sink raised it with.
retainedAs ∷ Exception e ⇒ Text → ExceptionContext → [(Maybe e, [SinkMark])]
retainedAs label context =
  [ (fromException failure, sinkMarks carried)
  | retained ← cleanupFailuresInContext context
  , cleanupFailureLabel retained == label
  , ExceptionWithContext carried failure ← [cleanupFailureException retained]
  ]
