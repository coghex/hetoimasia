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
  ) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception
  ( Exception
  , SomeException
  , displayException
  , fromException
  , throwIO
  , try
  )
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
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
  ( Logger
  , callbackSink
  , componentText
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  )
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (withScoped)
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
