-- | What the sample's examples share: a real supervision boundary, the UI owner's injected clock
-- and fake timer, the test-only namespace the examples add to a configuration, and the
-- coordination they use instead of sleeping.
--
-- The fake timer holds the registrations the UI owner arms. An example moves the UI owner by
-- advancing the clock and firing the live registration, then waits for the update's own completion
-- signal; nothing here waits for a duration to pass.
module Test.Domains.Support
  ( -- * The boundary
    withBoundary
  , withSample
  , withRealSample
  , sampleConfig
    -- * The UI owner's clock and timer
  , FakeUi
  , newFakeUi
  , tickUi
  , uiStep
  , stopServing
  , liveRegistrations
  , liveCount
  , uiIntervalNanoseconds
    -- * The test-only namespace
  , Fx
  , newFx
  , fxLines
  , awaitLine
  , awaitEntered
  , holdAt
  , releaseGate
  , fxMarks
  , luaLines
    -- * Reading the session
  , awaitUpdates
  , updatesNow
  , snapshotNow
  , revisionNow
  , committedTick
    -- * Waiting
  , waitFor
  , generous
  , spawn
  , forkRegistered
  , reapForked
  , awaitForkedEnded
  , withReleased
  , stepCommitted
  , newSharedFor
  , offer
  , awaitClosed
  , balanced
  , failedEvidence
  , heldTasks
  , stopBounded
  , alongside
  , driving
  , Cancelled (..)
  , cancelWhen
  , TriggerFailed (..)
  ) where

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread, myThreadId, throwTo)
import Control.Concurrent.MVar (MVar, modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, tryPutMVar, tryReadMVar, withMVar)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, catch, finally, fromException, mask, onException, throwIO, try)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Word (Word64)
import Hetoimasia.Foundation.Log (defaultLogFilter)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (cursorRevision, observedCursor, observedValue, readSnapshot)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), MonotonicSource, durationFromNanoseconds, durationNanoseconds, scriptedInstant, scriptedSource)
import Hetoimasia.Runtime.Logging (withHandleLoggingLifetime)
import Hetoimasia.Runtime.Supervision (RuntimeControl, awaitSupervised, withSupervision)
import Hetoimasia.Sample.LuaDomains
  ( Bounds (boundWorkspaces)
  , Domains (domainsConfig, domainsControl, domainsShared)
  , DomainsConfig (configExtensions, configTicks, configUiClock, configUiInterval, configUiSeesEnd, configUiTimer)
  , Extension (Extension)
  , Where (InBoth)
  , TickOutcome (TickCommitted)
  , stepTick
  , stopSession
  , scriptedInputs
  , defaultConfig
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence, GameSnapshot (snapStatus, snapTick), SessionStatus (Failed))
import Hetoimasia.Sample.LuaDomains.Intention (Answer, Submitted (Submitted))
import Hetoimasia.Sample.LuaDomains.Queue (isClosed, reserved)
import Hetoimasia.Sample.LuaDomains.Tally (Counts (countAccepted), settledTotal)
import Hetoimasia.Sample.LuaDomains.Session (Ended (..), SessionState (sessionEnded))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCounts, sharedQueue, sharedReceipts, sharedSession, sharedUiNotes, sharedUpdates), SharedSetup (..), UiNotes (notesSaw), newShared, readerOf, submit, tasksHeld)
import Hetoimasia.Scripting.Lua.Lease (newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Registration (Namespace, namespace, stateOperation)
import Hetoimasia.Scripting.Lua.Scheduler (TimerBackend (TimerBackend))
import Hetoimasia.Scripting.Lua.Value (Schema (SBoolean, SText), Value (VBoolean, VText))
import Data.Maybe (isJust)
import Numeric.Natural (Natural)
import System.IO (stderr)
import System.Timeout (timeout)
import Test.Hspec (shouldBe)
import Test.Support.Bounded (bounded)

-- | A real supervision boundary over a real worker group. Diagnostics go to stderr, as they do
-- in the executable.
withBoundary ∷ (RuntimeControl → IO a) → IO a
withBoundary body = withHandleLoggingLifetime defaultLogFilter stderr (\lifetime → withSupervision lifetime body)

-- | A session over a configuration the example adjusts, with the UI owner on a fake clock and
-- timer and the test-only namespace in both owners; nothing paces it and its ticks are driven by
-- hand.
withSample ∷ (DomainsConfig → DomainsConfig) → (Fx → FakeUi → Domains → IO a) → IO a
withSample adjust body = do
  fx ← newFx
  ui ← newFakeUi
  withBoundary $ \control → withDomains control (adjust (sampleConfig fx ui)) (body fx ui)

-- | A session over a configuration the example adjusts, with the UI owner on the real clock and
-- timer, as in the executable, and the test-only namespace in both owners.
withRealSample ∷ (DomainsConfig → DomainsConfig) → (Fx → Domains → IO a) → IO a
withRealSample adjust body = do
  fx ← newFx
  let config = adjust defaultConfig {configTicks = Nothing, configExtensions = \shared → [Extension (fxNamespace fx shared) InBoth []]}
  withBoundary $ \control → withDomains control config (body fx)

-- | The production configuration with the UI owner on the fake clock and timer, no last tick and
-- the test-only namespace added to both owners.
sampleConfig ∷ Fx → FakeUi → DomainsConfig
sampleConfig fx ui =
  defaultConfig
    { configUiClock = fakeSource ui
    , configUiTimer = fakeTimer ui
    , configTicks = Nothing
    , configUiSeesEnd = False
    , configExtensions = \shared → [Extension (fxNamespace fx shared) InBoth []]
    }

-- The UI owner's clock and timer -----------------------------------------------------------

-- | One registration the owner's timer made: what it calls on expiry, and whether it is still
-- armed.
data Registration = Registration
  { registrationWake ∷ IO ()
  , registrationLive ∷ TVar Bool
  }

-- | The injected clock, a number of nanoseconds, and the registrations the timer was asked for.
data FakeUi = FakeUi
  { fakeNow ∷ IORef Word64
  , fakeRegistrations ∷ TVar [Registration]
  }

newFakeUi ∷ IO FakeUi
newFakeUi = FakeUi <$> newIORef 0 <*> newTVarIO []

fakeSource ∷ FakeUi → MonotonicSource
fakeSource fake = scriptedSource (scriptedInstant . nanos <$> readIORef (fakeNow fake))
  where
    nanos n = either (error . show) id (durationFromNanoseconds AllowZero (toInteger n))

fakeTimer ∷ FakeUi → TimerBackend
fakeTimer fake = TimerBackend $ \_ wake → do
  live ← newTVarIO True
  atomically (modifyTVar' (fakeRegistrations fake) (<> [Registration wake live]))
  pure (atomically (writeTVar live False))

-- | The registrations still armed.
liveRegistrations ∷ FakeUi → STM [Registration]
liveRegistrations fake = readTVar (fakeRegistrations fake) >>= keepLive
  where
    keepLive [] = pure []
    keepLive (registration : rest) = do
      armed ← readTVar (registrationLive registration)
      (if armed then (registration :) else id) <$> keepLive rest

-- | How many registrations are still armed.
liveCount ∷ FakeUi → IO Int
liveCount fake = length <$> atomically (liveRegistrations fake)

-- | The UI behavior's interval in nanoseconds.
uiIntervalNanoseconds ∷ DomainsConfig → Word64
uiIntervalNanoseconds = fromIntegral . durationNanoseconds . configUiInterval

-- | Make one UI update due and wake the owner for it: wait until the owner has armed its timer,
-- move the clock on by the interval, and fire the registration. The example then waits for the
-- update's own completion signal.
tickUi ∷ Domains → FakeUi → IO ()
tickUi domains fake = do
  registration ← bounded . atomically $ liveRegistrations fake >>= \case
    [] → retry
    live → pure (last live)
  atomicModifyIORef' (fakeNow fake) (\now → (now + uiIntervalNanoseconds (domainsConfig domains), ()))
  atomically (writeTVar (registrationLive registration) False)
  registrationWake registration

-- The test-only namespace --------------------------------------------------------------------

-- | What the examples' own bindings keep: lines the scripts recorded, marks with the UI's update
-- count at the time, and gates a binding holds a segment on.
data Fx = Fx
  { fxLog ∷ TVar [Text]
  , fxMarksVar ∷ TVar [(Text, Int)]
  , fxGates ∷ IORef (Map Text Gate)
  }

data Gate = Gate
  { gateEntered ∷ MVar ()
  , gateReleased ∷ MVar ()
  }

newFx ∷ IO Fx
newFx = Fx <$> newTVarIO [] <*> newTVarIO [] <*> newIORef Map.empty

gateFor ∷ Fx → Text → IO Gate
gateFor fx name = do
  fresh ← Gate <$> newEmptyMVar <*> newEmptyMVar
  atomicModifyIORef' (fxGates fx) $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing → (Map.insert name fresh held, fresh)

-- | The namespace the examples add to a configuration: @fx.record(text)@ keeps a line,
-- @fx.mark(name)@ keeps the UI's completed-update count under a name, and @fx.hold(name)@ holds
-- the calling segment until the example releases the gate of that name.
fxNamespace ∷ Fx → Shared → Namespace
fxNamespace fx shared =
  namespace
    "fx"
    [ stateOperation "record" [SText] [] $ \case
        [VText line] → [] <$ atomically (modifyTVar' (fxLog fx) (line :))
        _ → pure []
    , stateOperation "mark" [SText] [] $ \case
        [VText name] → atomically $ do
          updates ← readTVar (sharedUpdates shared)
          modifyTVar' (fxMarksVar fx) ((name, updates) :)
          pure []
        _ → pure []
    , stateOperation "released" [SText] [SBoolean] $ \case
        [VText name] → do
          gate ← gateFor fx name
          opened ← tryReadMVar (gateReleased gate)
          pure [VBoolean (isJust opened)]
        _ → pure [VBoolean False]
    , stateOperation "hold" [SText] [] $ \case
        [VText name] → do
          gate ← gateFor fx name
          void (tryPutMVar (gateEntered gate) ())
          readMVar (gateReleased gate)
          pure []
        _ → pure []
    ]

-- | Hold the calling thread at the gate of this name until the example releases it: what @fx.hold@ does in a
-- script, for a seam an example puts in the application's own code.
holdAt ∷ Fx → Text → IO ()
holdAt fx name = do
  gate ← gateFor fx name
  void (tryPutMVar (gateEntered gate) ())
  readMVar (gateReleased gate)

-- | The lines scripts recorded, oldest first.
fxLines ∷ Fx → IO [Text]
fxLines fx = reverse <$> readTVarIO (fxLog fx)

-- | Wait until a script has recorded this line.
awaitLine ∷ Fx → Text → IO ()
awaitLine fx wanted = bounded . atomically $ do
  recorded ← readTVar (fxLog fx)
  when (wanted `notElem` recorded) retry

-- | Wait until a segment has reached the hold of this name.
awaitEntered ∷ Fx → Text → IO ()
awaitEntered fx name = gateFor fx name >>= bounded . readMVar . gateEntered

-- | Let the segment held under this name go on. Harmless twice.
releaseGate ∷ Fx → Text → IO ()
releaseGate fx name = gateFor fx name >>= void . (`tryPutMVar` ()) . gateReleased

-- | The marks scripts kept, oldest first.
fxMarks ∷ Fx → IO [(Text, Int)]
fxMarks fx = reverse <$> readTVarIO (fxMarksVar fx)

-- | A Lua source from its lines.
luaLines ∷ [Text] → ByteString
luaLines = Text.encodeUtf8 . Text.unlines

-- Reading the session -------------------------------------------------------------------------

-- | How many UI updates have completed.
updatesNow ∷ Domains → IO Int
updatesNow domains = readTVarIO (sharedUpdates (domainsShared domains))

-- | Wait, supervised and bounded, until this many UI updates have completed.
awaitUpdates ∷ Domains → Int → IO ()
awaitUpdates domains wanted =
  bounded . awaitSupervised (domainsControl domains) $ do
    done ← readTVar (sharedUpdates (domainsShared domains))
    when (done < wanted) retry

-- | The latest committed snapshot and its revision.
snapshotNow ∷ Domains → IO (GameSnapshot, Natural)
snapshotNow domains = atomically $ do
  reader ← readerOf (domainsShared domains)
  observation ← readSnapshot reader
  pure (preparedValue (observedValue observation), cursorRevision (observedCursor observation))

-- | The revision of the latest publication: zero for the initial value, one more for each tick.
revisionNow ∷ Domains → IO Natural
revisionNow domains = snd <$> snapshotNow domains

-- | The tick the latest snapshot shows.
committedTick ∷ Domains → IO Word64
committedTick domains = snapTick . fst <$> snapshotNow domains

-- | Wait, bounded and without polling, until a transaction is ready.
waitFor ∷ STM a → IO a
waitFor = bounded . atomically

-- | Run an action on a thread of its own and answer how to collect its result, bounded: the
-- result, or the exception it raised.
spawn ∷ IO a → IO (IO a)
spawn action = do
  result ← newEmptyMVar
  collected ← newIORef False
  thread ← forkTerminating $ \unmask → try (unmask action) >>= putMVar result
  -- A thread that failed and was never collected is the example's failure, raised when it is over: nothing an example
  -- spawns can fail unseen. (Its own cancellation, when the example is over, is not a failure.)
  let unseen = do
        seen ← readIORef collected
        failed ← tryReadMVar result
        case failed of
          Just (Left failure) | not seen, fromException failure /= Just ThreadKilled → throwIO (failure ∷ SomeException)
          _ → pure ()
  atomicModifyIORef' forkedThreads (\held → ((thread, unseen) : held, ()))
  pure (writeIORef collected True >> bounded (readMVar result >>= either (\failure → throwIO (failure ∷ SomeException)) pure))

-- | A thread, and the signal that it has terminated: every handler and finalizer inside it done, which is what makes it
-- over, and not the delivery of the exception that ends it.
type Child = (ThreadId, MVar ())

-- | Fork a thread, handed the means to unmask, that signals its termination once the body, with whatever handlers and
-- finalizers it runs, has ended however it ended.
forkTerminating ∷ ((∀ x. IO x → IO x) → IO ()) → IO Child
forkTerminating body = do
  done ← newEmptyMVar
  thread ← forkIOWithUnmask $ \unmask → body unmask `finally` putMVar done ()
  pure (thread, done)

-- | Cancel a child and wait for its termination: its handlers and finalizers are done when this returns, however long
-- they take, bounded by the examples' guard, which fails loudly where a finalizer never ends.
cancelAndJoin ∷ Child → IO ()
cancelAndJoin (thread, done) = killThread thread >> bounded (readMVar done)

-- | The threads an example forked and has not seen end: 'reapForked' cancels what is left of them when the example is over.
forkedThreads ∷ IORef [(Child, IO ())]
forkedThreads = unsafePerformIO (newIORef [])
{-# NOINLINE forkedThreads #-}

-- | Fork a thread of an example's own, registered so that however the example ends, the thread does not outlive it.
forkRegistered ∷ IO () → IO ThreadId
forkRegistered action = do
  child ← forkTerminating (\unmask → unmask action)
  atomicModifyIORef' forkedThreads (\held → ((child, pure ()) : held, ()))
  pure (fst child)

-- | Wait until every thread an example forked has ended of itself: for an example whose threads are known to end.
awaitForkedEnded ∷ IO ()
awaitForkedEnded = do
  threads ← readIORef forkedThreads
  mapM_ (\((_, done), _) → bounded (readMVar done)) threads

-- | Cancel every thread an example forked that is still running, each having terminated, handlers and finalizers done,
-- before this returns, and raise the failure of any that failed without being collected. It runs after every example,
-- whatever the example's outcome.
reapForked ∷ IO ()
reapForked = do
  threads ← atomicModifyIORef' forkedThreads (\held → ([], held))
  mapM_ (cancelAndJoin . fst) threads
  mapM_ snd (reverse threads)

-- | Run a body, and open these gates however it ends, so a segment an example held never keeps
-- the owner, and with it the session's retirement, waiting.
withReleased ∷ Fx → [Text] → IO a → IO a
withReleased fx names body = body `finally` mapM_ (releaseGate fx) names

-- | A deadlock guard for a call that does real work: two minutes, never an assertion.
generous ∷ IO a → IO a
generous action = timeout 120000000 action >>= maybe (throwIO (userError "a guarded call never returned")) pure

-- | One tick of the driver, expecting it committed: the snapshot it published.
stepCommitted ∷ Domains → IO GameSnapshot
stepCommitted domains =
  stepTick domains >>= \case
    TickCommitted snapshot → pure snapshot
    other → throwIO (userError ("expected a committed tick, found " <> show other))

-- | A shared state over these bounds, with leases of its own, for the examples that read a registration.
newSharedFor ∷ Bounds → IO Shared
newSharedFor bounds = do
  lending ← newLending
  leases ← newLeases lending (boundWorkspaces bounds)
  newShared
    SharedSetup
      { setupBounds = bounds
      , setupSession = 1
      , setupSeed = 1
      , setupFinal = Nothing
      , setupInput = scriptedInputs
      , setupLending = lending
      , setupLeases = leases
      , setupAssignHook = pure ()
      , setupScenario = "normal"
      }

-- | Offer one intention for this entity, carrying version zero, as the UI's binding does.
offer ∷ Domains → Int → IO Answer
offer domains entity = submit (domainsShared domains) (Submitted 1 0 (fromIntegral entity) 0 1 0)

-- | The ledger of a quiescent session balances: every accepted intention reached exactly one terminal
-- disposition, and nothing is reserved.
balanced ∷ Domains → IO ()
balanced domains = do
  (counts, left) ← atomically ((,) <$> readTVar (sharedCounts (domainsShared domains)) <*> reserved (sharedQueue (domainsShared domains)))
  (countAccepted counts, left) `shouldBe` (settledTotal counts, 0)

-- | The evidence a snapshot publishes of a failed session, if it is one.
failedEvidence ∷ GameSnapshot → Maybe FailureEvidence
failedEvidence snapshot = case snapStatus snapshot of
  Failed found → Just found
  _ → Nothing

-- | Block, in STM, until admission to the queue has closed: a stop, a failure or a retirement has begun.
awaitClosed ∷ Domains → STM ()
awaitClosed domains = isClosed (sharedQueue (domainsShared domains)) >>= \closed → when (not closed) retry

-- | Let the UI do its next update and wait until it has completed.
uiStep ∷ Domains → FakeUi → IO ()
uiStep domains ui = do
  done ← updatesNow domains
  tickUi domains ui
  awaitUpdates domains (done + 1)

-- | Stop the session while the UI is serving, keeping the UI's updates coming as its timer would until the stop has
-- returned: the stop waits for the UI to read the settlements of the controls it asked for, and, when the
-- configuration asks, to see the status that ends the session.
stopServing ∷ Domains → FakeUi → IO ()
stopServing domains ui = do
  finished ← newTVarIO False
  let go = do
        next ← waitFor $ do
          done ← readTVar finished
          live ← liveRegistrations ui
          owes ← uiOwes domains
          if done then pure False else if owes && not (null live) then pure True else retry
        when next (uiStep domains ui >> go)
  -- The stop is the application thread's, so the UI is kept going from a thread of its own.
  stepper ← spawn go
  _ ← stopSession domains `finally` atomically (writeTVar finished True)
  _ ← stepper
  pure ()

-- | What the stop is waiting for the UI to do: read the settlements of the controls it asked for, and, when the
-- configuration asks for it, see the status that ends the session once that is published.
uiOwes ∷ Domains → STM Bool
uiOwes domains = do
  let shared = domainsShared domains
  held ← readTVar (sharedReceipts shared)
  state ← readTVar (sharedSession shared)
  notes ← readTVar (sharedUiNotes shared)
  let word = case sessionEnded state of
        Just EndedFailed → Just "failed"
        Just EndedStopped → Just "stopped"
        _ → Nothing
      unseen = configUiSeesEnd (domainsConfig domains) && maybe False (`notElem` notesSaw notes) word
  pure (held > 0 || unseen)

-- | How many tasks the session has admitted and not been told the settlement of.
heldTasks ∷ Domains → IO Int
heldTasks domains = atomically (tasksHeld (domainsShared domains))

-- | The stop, which is the application thread's, bounded: this thread's call, not a thread of its own.
stopBounded ∷ Domains → IO ()
stopBounded domains = void (bounded (stopSession domains))

-- | Run an action on a thread of its own while this thread does the other, and answer the other's result once the
-- first has ended, raising what it raised. A stop or a tick is the application thread's, so what an example does around
-- it, in the interval it holds, is done on the side.
--
-- The side's thread lives no longer than this call, whatever the other does: if the other raises, whatever it raises, the
-- side is cancelled and has ended before this returns, and nothing it does can reach the caller afterwards. If the side
-- fails while this thread is still running the other (a failed assertion, with the other held at a gate the side would
-- have opened), the failure is raised here, in the other's place, so that the example unwinds, opens its gates and retires
-- its owners, and nothing is left hanging.
alongside ∷ IO () → IO a → IO a
alongside side main = mask $ \restore → do
  me ← myThreadId
  open ← newMVar True
  sideResult ← newEmptyMVar
  child@(_, sideDone) ← forkTerminating $ \unmask → do
    outcome ← try @SomeException (unmask side)
    case outcome of
      Left failure → withMVar open (\delivering → when delivering (throwTo me (SideFailed failure))) `finally` putMVar sideResult (Left failure)
      Right () → putMVar sideResult (Right ())
  result ← try @SomeException (restore main)
  -- The side may no longer interrupt this thread; one that is delivering a failure finishes first, and the delivery that
  -- reaches this thread while it waits is the side's own failure, which is reported below.
  let close = modifyMVar_ open (\_ → pure False) `catch` \(SideFailed _) → close
  close
  case result of
    Right value → do
      outcome ← restore (bounded (readMVar sideResult)) `onException` cancelAndJoin child
      -- The side has ended, and its termination is waited for all the same.
      restore (bounded (readMVar sideDone)) `onException` cancelAndJoin child
      either (\failure → throwIO (failure ∷ SomeException)) (const (pure value)) outcome
    Left raised → do
      cancelAndJoin child
      case fromException raised of
        Just (SideFailed failure) → throwIO failure
        Nothing → throwIO raised

-- | What the side of 'alongside' raised, delivered to the other.
newtype SideFailed = SideFailed SomeException
  deriving (Show)

instance Exception SideFailed

-- | The exception that cancels an action an example runs with 'cancelWhen'.
data Cancelled = Cancelled
  deriving (Show)

instance Exception Cancelled

-- | The trigger of 'cancelWhen' failed (an assertion, a gate that never came): the failure, delivered in place of a
-- cancellation, which the trigger did not reach.
newtype TriggerFailed = TriggerFailed SomeException
  deriving (Show)

instance Exception TriggerFailed

-- | Run an action on this thread and cancel it, with an exception of its own, once this has happened (the trigger, which an
-- example makes a gate entered): the action's result, or 'Nothing' if it was cancelled. The thread the action runs on is
-- the thread of the example, so a stop, which is the application thread's, can be the one that is cancelled. The thread
-- that waits for the trigger lives no longer than this call, whatever the action raises: it is cancelled and has ended
-- before this returns, so the trigger firing later cancels nothing. A trigger that fails is not a cancellation: its
-- failure is raised, whatever became of the action, so that an example never passes for having reached a point it did
-- not reach.
cancelWhen ∷ IO () → IO a → IO (Maybe a)
cancelWhen trigger action = mask $ \restore → do
  me ← myThreadId
  armed ← newMVar True
  triggerFailure ← newEmptyMVar
  canceller ← forkTerminating $ \unmask → do
    reached ← try @SomeException (unmask trigger)
    case reached of
      -- This thread's own cancellation, when the call is over, is not the trigger's failure.
      Left failure | Just ThreadKilled ← fromException failure → pure ()
      Left failure → void (tryPutMVar triggerFailure failure) >> withMVar armed (\on → when on (throwTo me (TriggerFailed failure)))
      Right () → withMVar armed (\on → when on (throwTo me Cancelled))
  outcome ← try @SomeException (restore action)
  let disarm = modifyMVar_ armed (\_ → pure False) `catch` \raised → case fromException raised of
        Just Cancelled → disarm
        Nothing → case fromException raised of
          Just (TriggerFailed _) → disarm
          Nothing → throwIO (raised ∷ SomeException)
  disarm
  cancelAndJoin canceller
  failedTrigger ← tryReadMVar triggerFailure
  case (failedTrigger, outcome) of
    (Just failure, _) → throwIO failure
    (Nothing, Right result) → pure (Just result)
    (Nothing, Left raised) → case fromException raised of
      Just Cancelled → pure Nothing
      Nothing → throwIO raised

-- | One tick of the driver, on this thread, which is the application thread's, while another thread does what the example
-- does around it, in the order it does it: the tick's outcome once both have ended, the side's exception raised if it
-- raised one.
driving ∷ Domains → IO () → IO TickOutcome
driving domains around = alongside around (stepTick domains)
