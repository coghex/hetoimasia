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
  , onBoundThread
  , onThreadVia
  , rescuing
  , withDeferredThread
  , withDeferredThreadOpening
  , withDeferredThreadVia
  , withMainThread
  , withMainThreadVia
  , withMainThreadKeepingContext
  , withMainThreadKeepingContextVia
  , caughtAs
  , caughtAsUnless
  , unexpected
  , originOf
  , operationOf
  , contextsOf
  , boundedExample

    -- * Ownership judgements (#593)
  , Scope
  , Ending (..)
  , Boom (..)
  , recordingThreads
  , runEnding
  , ownedEnds
  , exitFinishes
  , cutExamples
  , unownedLeaks
  , unownedScope
  , unownedBoundScope
  , reapUnowned
  , endedAndJoined
  , awaitParked
  , holdForever

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

import Control.Concurrent (ThreadId, forkIOWithUnmask, forkOS, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , annotateIO
  , displayException
  , finally
  , fromException
  , mask_
  , uninterruptibleMask_
  , throwIO
  , try
  , tryWithContext
  )
import Control.Exception.Annotation (ExceptionAnnotation (displayExceptionAnnotation))
import Control.Exception.Context (ExceptionContext, getExceptionAnnotations)
import Control.Monad (forM_, void, when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import GHC.Conc (ThreadStatus (ThreadBlocked, ThreadDied, ThreadFinished), threadStatus)
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
import Hetoimasia.GLFW.Internal.Seam (NativeCall (..), Seam, asProcessMainThread, designateProcessMainThread, seamCalls, seamSession)
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
import GHC.IO (unsafeUnmask)
import System.IO.Unsafe (unsafePerformIO)
import Data.Foldable (for_)
import Test.Hspec (Expectation, Spec, expectationFailure, it, shouldBe)
import Test.Support.Bounded (bounded)
import Test.Support.Cancel (withCancellationAfter)
import Test.Support.Owned (withOwnedBoundThreadOpening, withOwnedThreadOpening)

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

-- | Run an action on a new owned thread and wait for its outcome (#593). However the wait ends (a return, an exception, a
-- timeout of the example, a cancellation), the thread has ended and been joined before this returns, and there is no way to
-- hand it an unowned start. Ownership adds that guarantee; the wait for the outcome is still the example's own.
onThread ∷ IO a → IO a
onThread = onThreadVia withOwnedThreadOpening

-- | 'onThread' on an OS-bound thread, for an example that asserts what a bound caller may or may not do.
onBoundThread ∷ IO a → IO a
onBoundThread = onThreadVia withOwnedBoundThreadOpening

-- | 'onThread' through the given way of starting the thread, so a negative control can run the same helper over an unowned start.
onThreadVia ∷ Scope → IO a → IO a
onThreadVia scope action = do
  finished ← newEmptyMVar
  scope (pure ()) (try action >>= putMVar finished) $ \_ _ → do
    outcome ← takeMVar finished
    either (throwIO ∷ SomeException → IO a) pure outcome

-- | Run an action on an owned bound thread designated as the process main thread, so an example can cancel it (#593). The body is
-- given the thread and the cell its outcome is put into, and waits for it itself; however the body ends, the thread has ended
-- and been joined before this returns. The designation is this helper's own (the generic bound start designates nothing) and
-- happens on the bound thread before the action. The first argument opens whatever the run may be held at, in the
-- uninterruptible release and before the thread is killed: a run held at a gate only the example opens, or draining for
-- evidence only the example supplies, would otherwise hold the join for ever when the example failed first. It must not block.
withMainThread ∷ ∀ a r. Seam → IO () → IO a → (ThreadId → MVar (Either SomeException a) → IO r) → IO r
withMainThread = withMainThreadVia withOwnedBoundThreadOpening

-- | 'withMainThread' through the given way of starting the bound thread: the owned one, or the deliberately unowned start the
-- negative controls compare it with.
withMainThreadVia
  ∷ ∀ a r
   . Scope
  → Seam
  → IO ()
  → IO a
  → (ThreadId → MVar (Either SomeException a) → IO r)
  → IO r
withMainThreadVia scope seam open action body = do
  finished ← newEmptyMVar
  scope
    open
    (designateProcessMainThread seam >> (try action ∷ IO (Either SomeException a)) >>= putMVar finished)
    (\runner _ → body runner finished)

-- | 'withMainThread' keeping the context of whatever the run raised, for an example whose assertions are about the evidence the
-- exception carries.
withMainThreadKeepingContext
  ∷ ∀ a r. Seam → IO () → IO a → (ThreadId → MVar (Either (ExceptionWithContext SomeException) a) → IO r) → IO r
withMainThreadKeepingContext = withMainThreadKeepingContextVia withOwnedBoundThreadOpening

-- | 'withMainThreadKeepingContext' through the given way of starting the bound thread (#612): the owned one, or the unowned one a
-- negative control compares it with.
withMainThreadKeepingContextVia
  ∷ ∀ a r
   . Scope
  → Seam
  → IO ()
  → IO a
  → (ThreadId → MVar (Either (ExceptionWithContext SomeException) a) → IO r)
  → IO r
withMainThreadKeepingContextVia scope seam open action body = do
  finished ← newEmptyMVar
  scope
    open
    (designateProcessMainThread seam >> tryWithContext action >>= putMVar finished)
    (\runner _ → body runner finished)

-- | Run the action, and whatever way it ends hand the rescue to the thread that is waiting for it (#593): the evidence a
-- protected host's exit drain waits for must reach its supplier even when the example fails or is cancelled before the point it
-- would have been handed over, because the drain begins before the scope around the host can stop the supplier. The rescue is
-- idempotent (a hand-over already made wins), so the normal path is unchanged.
rescuing ∷ IO () → IO a → IO a
rescuing rescue action = action `finally` rescue

-- | An owned thread that does its one piece of work only once it is handed what the work acts on: the scope starts the thread
-- and gives the body the thread and the handing-over. For an injector whose target is known only inside a callback (a hook
-- that runs masked on the owner): started from the callback, its scope would end, and kill it, while it was still waiting to
-- deliver to a target that stays masked; started here, around the whole run, it lives until its exception has been delivered
-- and is stopped and joined when the scope ends, delivered or not. The handing-over never blocks. It yields once after handing
-- over: a thread forked in the middle of an example is scheduled soon (the runtime asks for a context switch when it forks),
-- but one that is woken from a wait is only queued, and an example that goes on to loop without blocking on one capability
-- would otherwise never let the thread run before its own bound ran out.
withDeferredThread ∷ (a → IO ()) → (ThreadId → (a → IO ()) → IO r) → IO r
withDeferredThread = withDeferredThreadOpening (pure ())

-- | 'withDeferredThread' for a thread that may be held at something only the scope can open: the first argument is run, in the
-- uninterruptible release and before the kill, however the scope ended. It must not block and must be safe to run when what it
-- opens is already open.
withDeferredThreadOpening ∷ IO () → (a → IO ()) → (ThreadId → (a → IO ()) → IO r) → IO r
withDeferredThreadOpening = withDeferredThreadVia withOwnedThreadOpening

-- | 'withDeferredThreadOpening' through the given way of starting the thread, so a negative control can run the same helper over
-- an unowned start.
withDeferredThreadVia ∷ Scope → IO () → (a → IO ()) → (ThreadId → (a → IO ()) → IO r) → IO r
withDeferredThreadVia scope open work body = do
  handed ← newEmptyMVar
  scope open (takeMVar handed >>= work) $ \thread _ → body thread (\target → void (tryPutMVar handed target) >> yield)

-- | The typed failure an action raised, beside the exception as caught.
caughtAs ∷ Exception e ⇒ IO a → IO (e, SomeException)
caughtAs action = do
  outcome ← try action
  case outcome of
    Right _ → unexpected "the action returned instead of failing"
    Left caught → case fromException caught of
      Just typed → pure (typed, caught)
      Nothing → unexpected ("the action failed with " <> displayException caught)

-- | 'caughtAs', except in a scenario (#593): there the run's own ending is the point, so whatever it raises propagates to the ending's
-- judgement rather than being matched against the exception the full example expects.
caughtAsUnless ∷ Exception e ⇒ Bool → IO a → IO (e, SomeException)
caughtAsUnless True run = run >> unexpected "the scenario's run returned instead of failing"
caughtAsUnless False run = caughtAs run

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
-- Ownership judgements (#593)
--
-- The regression examples for the owned starts judge one thing about a helper thread: that it has ended, and been joined, when
-- the scope that started it has ended, however it ended. A scope is any way of starting a helper for the length of a body; the
-- suite's helpers take theirs as an argument, so the same scenario runs through the owned start (which must pass the judgement)
-- and through the deliberately unowned start the helper used before (which must fail it: the negative control). The control
-- records its failed judgement first and then stops and joins whatever it left, even if an assertion fails, so it leaves
-- nothing for a later example. Nothing here sleeps: a thread is judged by the runtime's own report of its status, polled by
-- yielding a counted number of times, never for a duration.

-- | A way to start a helper thread for the length of a body, which is given the thread and a wait for its end. The first
-- argument opens whatever the helper may be held at (a gate only the scope can open), in the release and before the thread is
-- killed: a helper held in an uninterruptible region ignores the kill, and would otherwise hold the join for ever. It must not
-- block and must be safe to run when what it opens is already open.
type Scope = ∀ r. IO () → IO () → (ThreadId → IO () → IO r) → IO r

-- | How a scope that started a helper is made to end while the helper is parked.
data Ending
  = -- | The example body raises, at the moment its helper is parked.
    BodyFails
  | -- | The example body is cancelled, at the moment its helper is parked: the cancellation is delivered to the thread that runs
    -- the body, wherever the scenario puts it.
    BodyCancelled
  | -- | The example thread is cancelled while it waits for a helper that is parked (a start-and-wait helper has no body of its
    -- own to fail): the helper itself says when it is parked, by calling the action the scenario is given.
    WaiterCancelled
  deriving (Eq, Show)

-- | The failure an example raises from a body, told apart from every other.
data Boom = Boom
  deriving (Eq, Show)

instance Exception Boom

-- | A thread a negative control started without ownership, with the wait for its end and whatever must be let go before it can
-- end, so the control can stop and join it independently of its own assertions.
data Unowned = Unowned ThreadId (MVar ()) (IO ())

-- | Remember every thread a scope starts, so the example can judge it after the scope has returned.
recordingThreads ∷ IORef [ThreadId] → Scope → Scope
recordingThreads recorded scope open action body =
  scope open action $ \thread awaitEnd → modifyIORef' recorded (thread :) >> body thread awaitEnd

-- | Run the scenario and end it the way the ending says, at the moment it calls the action it is given (once its helper is
-- parked). The outcome of every ending is asserted as it is raised, so an example never passes because the wrong thing happened.
-- A cancellation is delivered by a helper the example owns, to the very thread that calls the action: a scenario may run its
-- body on a thread other than the example's (a session is entered on a designated bound thread), and a cancellation sent to the
-- example's thread would then wait for that body to end and never arrive.
runEnding ∷ Ending → (IO () → IO ()) → IO ()
runEnding BodyFails scenario = do
  outcome ← try @Boom (scenario (throwIO Boom))
  outcome `shouldBe` Left Boom
runEnding WaiterCancelled scenario = do
  parked ← newEmptyMVar
  outcome ←
    try @AsyncException . bounded $
      withCancellationAfter (readMVar parked) (pure ()) (scenario (void (tryPutMVar parked ()) >> holdForever))
  outcome `shouldBe` Left UserInterrupt
runEnding BodyCancelled scenario = do
  outcome ←
    try @AsyncException . bounded $
      withDeferredThread (\target → throwTo target UserInterrupt) $ \_ handOver →
        scenario (myThreadId >>= handOver >> holdForever)
  outcome `shouldBe` Left UserInterrupt

-- | Wait where only the thread's own end can reach it. The cell is never filled by anything and is reachable from a top-level
-- binding, so the runtime never mistakes the wait for a deadlock and ends the thread by its own detection: a parked helper ends
-- when its scope stops it, and not before.
holdForever ∷ IO ()
holdForever = readMVar neverFilled

neverFilled ∷ MVar ()
neverFilled = unsafePerformIO newEmptyMVar
{-# NOINLINE neverFilled #-}

-- | Wait, by yielding, until the thread is blocked on something, so an example knows its helper has parked without guessing at a
-- delay. A thread that ended instead has not parked, and fails the example.
awaitParked ∷ ThreadId → IO ()
awaitParked thread =
  threadStatus thread >>= \case
    ThreadBlocked _ → pure ()
    ThreadFinished → unexpected "the thread ended instead of parking"
    ThreadDied → unexpected "the thread died instead of parking"
    _ → yield >> awaitParked thread

-- | Whether every recorded thread has ended: one that is blocked has not; one that ended is finished, or is running its last
-- steps after announcing its end, which the poll yields to. At least one thread must have been started, or nothing was judged.
endedAndJoined ∷ IORef [ThreadId] → IO Bool
endedAndJoined recorded = do
  threads ← readIORef recorded
  if null threads then pure False else and <$> mapM joined threads
  where
    joined thread = go (100000 ∷ Int)
      where
        go 0 = pure False
        go remaining =
          threadStatus thread >>= \case
            ThreadFinished → pure True
            ThreadDied → pure True
            ThreadBlocked _ → pure False
            _ → yield >> go (remaining - 1)

-- | The judgement the owned start makes true: the scenario, ended the way the ending says, leaves every thread it started ended
-- and joined.
ownedEnds ∷ Ending → (Scope → IO () → IO ()) → Bool → Expectation
ownedEnds ending scenario bound = do
  recorded ← newIORef []
  runEnding ending (scenario (recordingThreads recorded (if bound then withOwnedBoundThreadOpening else withOwnedThreadOpening)))
  endedAndJoined recorded >>= (`shouldBe` True)

-- | The judgement for a scenario that starts its own threads inside the fixture (so none is recorded): the example, ended the way
-- the ending says, finishes: its exit does not wait for ever. A fixture that would hang does so here, and the hard bound of the
-- caller ends it.
exitFinishes ∷ Ending → (Scope → IO () → IO ()) → Expectation
exitFinishes ending scenario = runEnding ending (scenario withOwnedThreadOpening)

-- | The examples that end a rig fixture at each of its cuts, for both endings (#593): before its failing or gated backend behaviour
-- is armed, and after it is armed with the release that undoes it registered (the arming and the registration are one masked
-- step, so a cancellation cannot land between them: it is delivered at one cut or the other). Each judges only that the exit
-- finishes; the bound of the example ends a fixture that would wait for ever.
cutExamples ∷ String → [Int] → (Int → Scope → IO () → IO ()) → Spec
cutExamples what cuts scenario =
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    for_ cuts $ \cutAt →
      it ("finishes the exit when the example body " <> label <> " " <> cutName cutAt <> ", in " <> what <> " (#593)") $
        boundedExample (exitFinishes ending (scenario cutAt))
  where
    cutName cutAt = case cutAt of
      0 → "before the behaviour is armed"
      1 → "after it is armed and its release registered"
      2 → "after the first attachment exists"
      _ → "after the first attachment's retirement was requested"

-- | The negative control: the same scenario over an unowned start leaves the thread behind, and the failed judgement is recorded
-- before anything independent stops the thread. Whatever the control left is then stopped and joined, even if the judgement
-- raised.
unownedLeaks ∷ Ending → (Scope → IO () → IO ()) → Bool → Expectation
unownedLeaks ending scenario bound = do
  started ← newIORef []
  recorded ← newIORef []
  ( do
      runEnding ending (scenario (recordingThreads recorded ((if bound then unownedBoundScope else unownedScope) started)))
      judgement ← endedAndJoined recorded
      judgement `shouldBe` False
    )
    `finally` reapUnowned started
  endedAndJoined recorded >>= (`shouldBe` True)

-- | A deliberately unowned start, the negative controls' only one: it starts the thread, announces its end however it ended, and
-- registers no stop-and-join. The start is masked and announces its end so that the independent cleanup can always join the
-- thread, even one it kills before it ran anything: the defect the controls model is the missing stop-and-join of the scope.
unownedScope ∷ IORef [Unowned] → Scope
unownedScope started open action body = do
  (thread, done) ← startUnowned started open action
  body thread (readMVar done)

startUnowned ∷ IORef [Unowned] → IO () → IO () → IO (ThreadId, MVar ())
startUnowned started open action = mask_ $ do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → unmask action `finally` putMVar done ()
  atomicModifyIORef' started (\known → (Unowned thread done open : known, ()))
  pure (thread, done)

-- | 'unownedScope' for an OS-bound thread: the plain @forkOS@ the suite used before the facility offered an owned bound start.
unownedBoundScope ∷ IORef [Unowned] → Scope
unownedBoundScope started open action body = do
  (thread, done) ← startUnownedBound started open action
  body thread (readMVar done)

startUnownedBound ∷ IORef [Unowned] → IO () → IO () → IO (ThreadId, MVar ())
startUnownedBound started open action = uninterruptibleMask_ $ do
  done ← newEmptyMVar
  -- @forkOS@ waits, interruptibly even under @mask_@, for the new OS thread to report itself, and a cancellation taken there
  -- would leave a thread that exists unregistered for the rescue; the start and its registration are uninterruptible, and the
  -- thread, which begins masked uninterruptibly, runs the action unmasked as a plain @forkOS@ from an unmasked caller does.
  thread ← forkOS (unsafeUnmask action `finally` putMVar done ())
  atomicModifyIORef' started (\known → (Unowned thread done open : known, ()))
  pure (thread, done)

-- | Stop and join every thread an unowned control started, even if an assertion before it failed. The rescue is not
-- interruptible: a cancellation arriving during it must not abandon the join.
reapUnowned ∷ IORef [Unowned] → IO ()
reapUnowned started = uninterruptibleMask_ $ do
  known ← readIORef started
  forM_ known $ \(Unowned thread done open) → open >> killThread thread >> readMVar done

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
