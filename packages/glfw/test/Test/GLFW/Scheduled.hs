-- | Examples for the scheduled owner loop, over the test seam and a scripted
-- clock.
--
-- Each example runs a whole application through
-- 'Hetoimasia.Runtime.GLFW.runWindowApplication' on a thread the seam treats as
-- the process main thread, with a host whose 'hostClock' is a
-- 'Hetoimasia.Foundation.Time.scriptedSource' the example scripts reading by
-- reading: a scheduled turn samples it exactly twice, once for its wait
-- selection and once after the native call, so a script of @2n@ instants covers
-- @n@ turns and a reading past the end fails the example.
--
-- Nothing here sleeps or measures elapsed wall-clock time. The waits asserted
-- are the seconds the production code passed to the seam's
-- @glfwWaitEventsTimeout@, recorded as @WaitEvents@, and the turn sequences are
-- the production loop's own.
module Test.GLFW.Scheduled (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TVar, atomically, check, modifyTVar', newTVarIO, readTVar, writeTVar)
import Control.Exception (Exception, throwIO)
import Control.Monad (forM, forM_, join, void, when)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Foundation.Log
  ( Component
  , Logger
  , callbackSink
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  , unsafeComponent
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
import Hetoimasia.Foundation.Worker (WorkerDefinition, workerDefinition)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Command
  ( CompletionTicket
  , Disposition (..)
  , SubmitResult (..)
  , WindowCommand
  , observeWindowCommand
  , pollCompletion
  , submitWindowCommand
  )
import Hetoimasia.GLFW.Demand (CapturedDemand (..), deadlineDemand, demandDeadline, immediateDemand, publishDemand)
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
  , Seam
  , SeamScript (..)
  , asProcessMainThread
  , defaultScript
  , newSeam
  , seamCalls
  , seamSession
  )
import Hetoimasia.GLFW.Session (defaultSessionConfig)
import Hetoimasia.GLFW.Window
  ( Window
  , WindowConfig
  , WindowId
  , WindowResult (..)
  , hiddenTestWindowConfig
  , windowIdentity
  , withWindow
  )
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (..)
  , Role (..)
  , RuntimeControl
  , SupervisedStart (..)
  , SupervisedWorker
  , WorkerPolicy (..)
  , startSupervised
  , supervisedWorker
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Numeric.Natural (Natural)
import Test.GLFW.Window (boundedExample, caughtAs, entered, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn)

spec ∷ Spec
spec = describe "GLFW scheduled owner turns" $ do
  describe "wait selection" $ do
    it "waits exactly the time remaining to a deadline nearer than the fallback bound, and its update sees the instant the wait reached"
      (boundedExample testDeadlineNearerThanBound)
    it "waits the fallback bound when the deadline is further away, which no deadline may extend"
      (boundedExample testDeadlineBeyondBound)
    it "polls an expired deadline rather than passing a zero or negative native timeout"
      (boundedExample testExpiredDeadlinePolls)
    it "polls on the immediate schedule the caller supplied before the first update, and waits the bound once the schedule asks for nothing"
      (boundedExample testImmediateSchedulePolls)
    it "waits the fallback bound on every turn with no demand at all, and with no windows, rather than spinning"
      (boundedExample testNoDemandWaitsTheBound)
    it "takes a captured request's deadline when it is earlier than the application's schedule"
      (boundedExample (testDeadlinePrecedence (millis 30) (millis 100) 0.03))
    it "keeps the application's schedule when it is earlier than the captured request's deadline"
      (boundedExample (testDeadlinePrecedence (millis 200) (millis 100) 0.1))
    it "shortens the next wait by the time the turn's own work consumed, rather than starting a fresh full one"
      (boundedExample testWorkConsumesTheInterval)

  describe "readiness and the schedule" $ do
    it "polls for an application event that is already ready, with no schedule and nothing published, without dispatching it during the inspection"
      (boundedExample testReadyEventPolls)
    it "offers the update every turn under continuously refilled command queues, each batch ending at the budget"
      (boundedExample testContinuousCommands)
    it "offers the update every turn under a continuously ready application event source, each batch ending at the budget"
      (boundedExample testContinuousEvents)

  describe "demand and the wake protocol" $ do
    it "ends a wait on a publication that wakes the owner, and inspects that request on the next turn, which polls"
      (boundedExample testWakeWithDueWork)
    it "ends a wait on a publication with nothing yet due, recomputes the next turn's wait, and triggers no extra update"
      (boundedExample testWakeWithoutDueWork)
    it "keeps a publication made after a capture, including one made during the update, and returns to bounded waiting once demand stops"
      (boundedExample testPublicationAfterCapture)

  describe "checkpoints and the loop's ending" $ do
    it "rethrows a failure latched during event processing before any dispatch"
      (boundedExample (testPreemption AtEventProcessing))
    it "reaches the check after one command batch, charging rejected commands their attempt"
      (boundedExample (testPreemption AtCommand))
    it "reaches the check after one application event batch, before the update"
      (boundedExample (testPreemption AtApplicationEvent))
    it "returns the update's own result on the turn it finishes, having made exactly that turn's native steps"
      (boundedExample testFinishes)
    it "refuses an idle wait it cannot bound before acquiring anything"
      (boundedExample testUnboundableIdleWait)

-- ---------------------------------------------------------------------------
-- Wait selection

-- | A deadline 50 ms away, with quiet queues and a 250 ms fallback bound: the
-- turn waits exactly 50 ms, and the instant its update is given is the one the
-- wait itself reached, so the deadline is due in that same turn.
testDeadlineNearerThanBound ∷ Expectation
testDeadlineNearerThanBound = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, millis 50, millis 60, millis 100]
  records ←
    scheduled seam (settings [] clock) $ \_ →
      turning (UpdateBy (at (millis 50))) $ \turn →
        if turnNumber (scheduledTurn turn) == 2
          then pure (FinishWith ())
          else pure (ContinueWith (UpdateBy (at (millis 100))))
  map scheduledPacing records
    `shouldBe` [WaitedForDeadline (durationOf (millis 50)), WaitedForDeadline (durationOf (millis 40))]
  map scheduledNow records `shouldBe` [at (millis 50), at (millis 100)]
  pumps seam `shouldReturn` [WaitEvents 0.05, WaitEvents 0.04]
  unread `shouldReturn` 0

-- | A deadline a second away against a 250 ms bound: each turn waits the bound,
-- and the deadline the update keeps answering never extends it.
testDeadlineBeyondBound ∷ Expectation
testDeadlineBeyondBound = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, millis 250, millis 260, millis 510]
  records ←
    scheduled seam (settings [] clock) $ \_ →
      turning (UpdateBy (at (millis 1000))) $ \turn →
        if turnNumber (scheduledTurn turn) == 2
          then pure (FinishWith ())
          else pure (ContinueWith (UpdateBy (at (millis 1000))))
  map scheduledPacing records `shouldBe` replicate 2 (WaitedForFallback (durationOf (millis 250)))
  -- Neither turn reached the deadline it was waiting towards.
  map scheduledNow records `shouldBe` [at (millis 250), at (millis 510)]
  pumps seam `shouldReturn` replicate 2 (WaitEvents 0.25)
  unread `shouldReturn` 0

-- | A deadline already behind the first sample: the turn polls, and the fresh
-- deadline the update answers is waited for as usual.
testExpiredDeadlinePolls ∷ Expectation
testExpiredDeadlinePolls = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [millis 20, millis 21, millis 30, millis 100]
  records ←
    scheduled seam (settings [] clock) $ \_ →
      turning (UpdateBy (at (millis 10))) $ \turn →
        if turnNumber (scheduledTurn turn) == 2
          then pure (FinishWith ())
          else pure (ContinueWith (UpdateBy (at (millis 100))))
  map scheduledPacing records `shouldBe` [PolledForDeadline, WaitedForDeadline (durationOf (millis 70))]
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.07]
  unread `shouldReturn` 0

-- | The initial schedule the caller supplied is in force on the first turn,
-- before any update has answered, and an answer of no demand returns the loop
-- to its bounded wait.
testImmediateSchedulePolls ∷ Expectation
testImmediateSchedulePolls = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, 1, millis 1, millis 2]
  records ←
    scheduled seam (settings [] clock) $ \_ →
      turning UpdateImmediately $ \turn →
        if turnNumber (scheduledTurn turn) == 2
          then pure (FinishWith ())
          else pure (ContinueWith NoUpdateDemand)
  map scheduledPacing records `shouldBe` [PolledForWork, WaitedForFallback (durationOf (millis 250))]
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.25]
  unread `shouldReturn` 0

-- | With no windows, no schedule, and nothing published, every turn waits the
-- configured bound. 'defaultScheduledHooks' leaves the initial schedule at no
-- demand, so the first turn waits too.
testNoDemandWaitsTheBound ∷ Expectation
testNoDemandWaitsTheBound = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock (concat [[millis (turn * 300), millis (turn * 300 + 250)] | turn ← [0 .. 2]])
  records ←
    scheduled seam (settings [] clock) {hostIdleWait = 0.5} $ \_ →
      turning NoUpdateDemand $ \turn →
        if turnNumber (scheduledTurn turn) == 3 then pure (FinishWith ()) else pure (ContinueWith NoUpdateDemand)
  map scheduledPacing records `shouldBe` replicate 3 (WaitedForFallback (durationOf (millis 500)))
  map scheduledDemand records `shouldBe` replicate 3 Nothing
  pumps seam `shouldReturn` replicate 3 (WaitEvents 0.5)
  unread `shouldReturn` 0

-- | One publisher's deadline against the application's own: the earlier of the
-- two bounds the first turn's wait, whichever it is.
testDeadlinePrecedence ∷ Integer → Integer → Double → Expectation
testDeadlinePrecedence requested own expected = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, 1, millis 400, millis 401]
  records ←
    scheduled seam (settings [] clock) $ \host → do
      _ ← publishDemand (hostDemandPublisher host) (deadlineDemand (at requested))
      turning (UpdateBy (at own)) $ \turn →
        if turnNumber (scheduledTurn turn) == 2
          then pure (FinishWith ())
          else pure (ContinueWith NoUpdateDemand)
  -- The first turn captured the publisher's request and weighed it against its
  -- own schedule; the second had neither.
  map (fmap capturedRevision . scheduledDemand) records `shouldBe` [Just 1, Nothing]
  map (fmap (demandDeadline . capturedRequest) . scheduledDemand) records
    `shouldBe` [Just (Just (at requested)), Nothing]
  take 1 <$> pumps seam `shouldReturn` [WaitEvents expected]
  unread `shouldReturn` 0

-- | Time the turn's own work consumed is measured against the fresh sample the
-- next turn takes, so a deadline a turn's work ate into is honoured on the next
-- turn rather than pushed out by a fresh full wait.
testWorkConsumesTheInterval ∷ Expectation
testWorkConsumesTheInterval = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, millis 100, millis 190, millis 200, millis 299, millis 300]
  records ←
    scheduled seam (settings [] clock) $ \_ →
      turning (UpdateBy (at (millis 100))) $ \turn →
        case turnNumber (scheduledTurn turn) of
          1 → pure (ContinueWith (UpdateBy (at (millis 200))))
          2 → pure (ContinueWith (UpdateBy (at (millis 300))))
          _ → pure (FinishWith ())
  map scheduledPacing records
    `shouldBe` [ WaitedForDeadline (durationOf (millis 100))
               , WaitedForDeadline (durationOf (millis 10))
               , WaitedForDeadline (durationOf 1000000)
               ]
  pumps seam `shouldReturn` [WaitEvents 0.1, WaitEvents 0.01, WaitEvents 0.001]
  unread `shouldReturn` 0

-- ---------------------------------------------------------------------------
-- Readiness and the schedule

-- | An application event already ready makes the turn poll with no schedule and
-- nothing published. The readiness query answers without dispatching: the event
-- opportunity is offered only in the turn's own bounded event work.
testReadyEventPolls ∷ Expectation
testReadyEventPolls = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, 1, millis 1, millis 2]
  inspections ← newIORef (0 ∷ Int)
  dispatches ← newIORef (0 ∷ Int)
  records ←
    scheduled seam (settings [] clock) $ \_ → do
      seen ← newIORef []
      let finishing turn =
            if turnNumber (scheduledTurn turn) == 2 then pure (FinishWith ()) else pure (ContinueWith NoUpdateDemand)
      pure
        ( (defaultScheduledHooks quietLogger (recording seen finishing))
            { scheduledReady = (== 0) <$> atomicModifyIORef' inspections (\count → (count + 1, count))
            , scheduledEvent = (== 0) <$> atomicModifyIORef' dispatches (\count → (count + 1, count))
            }
        , readIORef seen
        )
  map scheduledPacing records `shouldBe` [PolledForWork, WaitedForFallback (durationOf (millis 250))]
  map (turnEvents . scheduledTurn) records `shouldBe` [1, 0]
  -- One inspection per turn, and only the event work's own attempts: the
  -- inspection dispatched nothing and spent none of the budget.
  readIORef inspections `shouldReturn` 2
  readIORef dispatches `shouldReturn` 3
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.25]
  unread `shouldReturn` 0

-- | A command queue the update refills every turn: each batch still ends at the
-- budget, and the due update still receives its opportunity every turn.
testContinuousCommands ∷ Expectation
testContinuousCommands = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock (concat [[millis turn, millis turn] | turn ← [0 .. 7]])
  records ←
    scheduled seam ((settings [windowNamed "busy"] clock) {hostCommandCapacity = 16}) $ \host → do
      window ← onlyWindow host
      let refill = forM_ [1 .. 3 ∷ Int] (\_ → void (submitWindowCommand (hostCommandPort host) [] (observeOf window)))
      refill
      turning (UpdateBy (at 0)) $ \turn → do
        refill
        if turnNumber (scheduledTurn turn) == 4 then pure (FinishWith ()) else pure (ContinueWith (UpdateBy (at 0)))
  -- The deadline is always behind the clock, so the update is due on every
  -- turn; the ready queue is why each turn polls rather than waiting.
  map scheduledPacing records `shouldBe` replicate 4 PolledForWork
  map (turnCommands . scheduledTurn) records `shouldBe` replicate 4 3
  length records `shouldBe` 4
  unread `shouldReturn` 8

-- | An application event source that is always ready: the batch still ends at
-- the budget and the update still runs once per turn.
testContinuousEvents ∷ Expectation
testContinuousEvents = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock (concat [[millis turn, millis turn] | turn ← [0 .. 7]])
  records ←
    scheduled seam (settings [] clock) $ \_ → do
      seen ← newIORef []
      let finishing turn =
            if turnNumber (scheduledTurn turn) == 4
              then pure (FinishWith ())
              else pure (ContinueWith (UpdateBy (at 0)))
      pure
        ( (defaultScheduledHooks quietLogger (recording seen finishing))
            {scheduledReady = pure True, scheduledEvent = pure True}
        , readIORef seen
        )
  map scheduledPacing records `shouldBe` replicate 4 PolledForWork
  map (turnEvents . scheduledTurn) records `shouldBe` replicate 4 2
  length records `shouldBe` 4
  unread `shouldReturn` 8

-- ---------------------------------------------------------------------------
-- Demand and the wake protocol

-- | A worker publishes immediate demand while the owner is inside its wait. The
-- wait ends on that post, and the request is inspected by the next turn, which
-- polls for it.
testWakeWithDueWork ∷ Expectation
testWakeWithDueWork = do
  (seam, platform) ← wakingSeam
  (clock, unread) ← scriptedClock [0, 1, millis 1, millis 2, millis 3, millis 4]
  records ←
    scheduled seam (settings [] clock) $ \host → do
      duringTheWait platform (void (publishDemand (hostDemandPublisher host) immediateDemand))
      turning UpdateImmediately $ \turn → do
        when (turnNumber (scheduledTurn turn) == 2) (stopBlocking platform)
        pure (if turnNumber (scheduledTurn turn) == 3 then FinishWith () else ContinueWith NoUpdateDemand)
  map scheduledPacing records
    `shouldBe` [PolledForWork, WaitedForFallback (durationOf (millis 250)), PolledForWork]
  -- The capture is the turn's own inspection, so the publication that ended the
  -- second turn's wait is the third turn's to take.
  map (fmap capturedRevision . scheduledDemand) records `shouldBe` [Nothing, Nothing, Just 1]
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.25, PollEvents]
  posts seam `shouldReturn` 1
  unread `shouldReturn` 0

-- | A publication whose deadline is further away than the fallback bound also
-- ends the wait. The turn that inspects it has nothing due, so it recomputes an
-- ordinary bounded wait and runs its one update opportunity, no more.
testWakeWithoutDueWork ∷ Expectation
testWakeWithoutDueWork = do
  (seam, platform) ← wakingSeam
  (clock, unread) ← scriptedClock [0, 1, millis 1, millis 2, millis 3, millis 4]
  updates ← newIORef (0 ∷ Int)
  records ←
    scheduled seam (settings [] clock) $ \host → do
      duringTheWait platform (void (publishDemand (hostDemandPublisher host) (deadlineDemand (at (millis 10000)))))
      turning UpdateImmediately $ \turn → do
        modifyIORef' updates (+ 1)
        when (turnNumber (scheduledTurn turn) == 2) (stopBlocking platform)
        pure (if turnNumber (scheduledTurn turn) == 3 then FinishWith () else ContinueWith NoUpdateDemand)
  map scheduledPacing records
    `shouldBe` [ PolledForWork
               , WaitedForFallback (durationOf (millis 250))
               , WaitedForFallback (durationOf (millis 250))
               ]
  map (fmap capturedRevision . scheduledDemand) records `shouldBe` [Nothing, Nothing, Just 1]
  readIORef updates `shouldReturn` 3
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.25, WaitEvents 0.25]
  posts seam `shouldReturn` 1
  unread `shouldReturn` 0

-- | A publication made during the update, after that turn's capture consumed an
-- older revision, is still pending for the next turn; once nothing is published
-- the loop returns to its bounded wait.
testPublicationAfterCapture ∷ Expectation
testPublicationAfterCapture = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, 1, millis 1, millis 2, millis 3, millis 4]
  records ←
    scheduled seam (settings [] clock) $ \host → do
      _ ← publishDemand (hostDemandPublisher host) immediateDemand
      turning NoUpdateDemand $ \turn →
        case turnNumber (scheduledTurn turn) of
          1 → do
            -- Published while the older revision this turn captured is already
            -- consumed: the newer one survives for the next capture.
            _ ← publishDemand (hostDemandPublisher host) (deadlineDemand (at (millis 100)))
            pure (ContinueWith NoUpdateDemand)
          2 → pure (ContinueWith NoUpdateDemand)
          _ → pure (FinishWith ())
  map (fmap capturedRevision . scheduledDemand) records `shouldBe` [Just 1, Just 2, Nothing]
  map scheduledPacing records
    `shouldBe` [ PolledForWork
               , WaitedForDeadline (durationOf (millis 99))
               , WaitedForFallback (durationOf (millis 250))
               ]
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.099, WaitEvents 0.25]
  unread `shouldReturn` 0

-- ---------------------------------------------------------------------------
-- Checkpoints and the loop's ending

-- | Where a required worker's failure is made to latch during the first turn.
data Trigger = AtEventProcessing | AtCommand | AtApplicationEvent
  deriving (Eq, Show)

-- | The saturated-queue matrix the unscheduled loop's checkpoints face, run
-- through the scheduled path: six commands against a budget of three, an
-- application event source that is always ready, and a failure latched from
-- inside the step the trigger names. The checks that follow stop the scheduled
-- turn at the same points, with the same dispositions.
testPreemption ∷ Trigger → Expectation
testPreemption trigger = do
  fire ← newIORef (pure ())
  let once = join (atomicModifyIORef' fire (\action → (pure (), action)))
      script =
        defaultScript
          { scriptPollEvents = \_ → when (trigger == AtEventProcessing) once
          , scriptWindowSize = \_ → when (trigger == AtCommand) once >> pure (800, 600)
          }
  seam ← newSeam script
  (clock, _) ← scriptedClock (concat (replicate 4 [0, 0]))
  elsewhere ← unservedWindow
  events ← newIORef (0 ∷ Int)
  updates ← newIORef (0 ∷ Int)
  ticketsSeen ← newIORef []
  (failure, _) ←
    caughtAs $
      hosted
        seam
        (settings [windowNamed "saturated"] clock)
        ( \host control → do
            gate ← newEmptyMVar
            breaker ← startSupervised control (required Job) (breakingAfter gate) >>= expectStarted
            writeIORef fire (putMVar gate () >> void (atomically (Worker.awaitCompletion (supervisedWorker breaker))))
            window ← onlyWindow host
            tickets ← forM [1 .. 6 ∷ Int] $ \index →
              submitWindowCommand
                (hostCommandPort host)
                []
                (observeWindowCommand (if odd index then windowIdentity window else elsewhere))
                >>= admitted
            writeIORef ticketsSeen tickets
            pure host
        )
        ( \host control →
            runScheduledOwnerLoop host control $
              (defaultScheduledHooks quietLogger (\_ → modifyIORef' updates (+ 1) >> pure (ContinueWith UpdateImmediately)))
                { scheduledReady = pure True
                , scheduledEvent = do
                    when (trigger == AtApplicationEvent) once
                    modifyIORef' events (+ 1)
                    pure True
                }
        )
  failure `shouldBe` Broken "worker failed"
  dispositions ← readIORef ticketsSeen >>= atomically . mapM pollCompletion
  let dispatched = if trigger == AtEventProcessing then [] else ["performed", "rejected", "performed"]
  map kind dispositions `shouldBe` dispatched <> replicate (6 - length dispatched) "not executed"
  readIORef events `shouldReturn` (if trigger == AtApplicationEvent then 2 else 0)
  readIORef updates `shouldReturn` 0

-- | The scheduled loop returns what its update finished with, having made
-- exactly the native steps of the turns it ran.
testFinishes ∷ Expectation
testFinishes = do
  seam ← newSeam defaultScript
  (clock, unread) ← scriptedClock [0, 1]
  result ←
    scheduledResult seam (settings [] clock) $ \_ →
      pure (defaultScheduledHooks quietLogger (\turn → pure (FinishWith (turnNumber (scheduledTurn turn)))))
  result `shouldBe` (1 ∷ Natural)
  pumps seam `shouldReturn` [WaitEvents 0.25]
  unread `shouldReturn` 0

-- | An idle wait of less than a whole nanosecond is no bound a scheduled turn
-- could wait for, so the host refuses it before acquiring anything, exactly as
-- it refuses the waits the unscheduled loop cannot bound. A wait that is not a
-- whole number of nanoseconds is floored rather than rounded, because the
-- fallback is an upper bound.
testUnboundableIdleWait ∷ Expectation
testUnboundableIdleWait = do
  (clock, _) ← scriptedClock []
  let base = settings [] clock
      rejected = \case
        Left (IdleWaitRejected _) → True
        _ → False
  validateHostConfig base `shouldBe` Right ()
  -- Refused: nearest-nanosecond rounding would make each of these a one- or
  -- two-nanosecond bound longer than the seconds configured.
  map (rejected . validateHostConfig . (\wait → base {hostIdleWait = wait})) [1e-12, 0.5e-9, 0.75e-9, 0.9e-9]
    `shouldBe` replicate 4 True
  -- The smallest wait that is a whole nanosecond is accepted as itself.
  validateHostConfig base {hostIdleWait = 1e-9} `shouldBe` Right ()
  boundedWaitOf 1e-9 `shouldReturn` (durationOf 1, WaitEvents 1e-9)
  -- An upward-rounding wait is floored to the whole nanosecond below it, so the
  -- bound never exceeds what was configured.
  boundedWaitOf 1.6e-9 `shouldReturn` (durationOf 1, WaitEvents 1e-9)
  boundedWaitOf 2.5e-9 `shouldReturn` (durationOf 2, WaitEvents 2e-9)
  -- A wait already whole in nanoseconds is unchanged.
  boundedWaitOf 0.25 `shouldReturn` (durationOf (millis 250), WaitEvents 0.25)
  boundedWaitOf 0.1 `shouldReturn` (durationOf (millis 100), WaitEvents 0.1)

-- | The fallback bound one quiet scheduled turn waited for, and the seconds it
-- passed to the native wait.
boundedWaitOf ∷ Double → IO (Duration, NativeCall)
boundedWaitOf wait = do
  seam ← newSeam defaultScript
  (clock, _) ← scriptedClock [0, 1]
  records ←
    scheduled seam (settings [] clock) {hostIdleWait = wait} $ \_ →
      turning NoUpdateDemand (\_ → pure (FinishWith ()))
  case (map scheduledPacing records, take 1 <$> pumps seam) of
    ([WaitedForFallback bound], pumped) → pumped >>= \case
      [call] → pure (bound, call)
      calls → unexpected ("expected one native step, found " <> show calls)
    (pacings, _) → unexpected ("expected one turn waiting its bound, found " <> show pacings)

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
-- Running scheduled applications

-- | Run a scheduled loop over a seam host and answer the turns its update saw.
scheduled ∷ Seam → HostConfig → (WindowHost → IO (ScheduledHooks (), IO [ScheduledTurn])) → IO [ScheduledTurn]
scheduled seam config build =
  hosted seam config (\host _ → pure host) $ \host control → do
    (hooks, seen) ← build host
    runScheduledOwnerLoop host control hooks
    seen

-- | 'scheduled' for an example that asserts the loop's own result instead.
scheduledResult ∷ Seam → HostConfig → (WindowHost → IO (ScheduledHooks a)) → IO a
scheduledResult seam config build =
  hosted seam config (\host _ → pure host) $ \host control →
    build host >>= runScheduledOwnerLoop host control

-- | Hooks that record every turn and answer with @decide@.
turning ∷ UpdateSchedule → (ScheduledTurn → IO (ScheduledStep ())) → IO (ScheduledHooks (), IO [ScheduledTurn])
turning start decide = do
  seen ← newIORef []
  pure ((defaultScheduledHooks quietLogger (recording seen decide)) {scheduledStart = start}, readIORef seen)

recording ∷ IORef [ScheduledTurn] → (ScheduledTurn → IO (ScheduledStep a)) → ScheduledTurn → IO (ScheduledStep a)
recording seen decide turn = modifyIORef' seen (<> [turn]) >> decide turn

-- | Run an application over a host in the seam's session, on a bound thread
-- designated as the process main thread.
hosted ∷ Seam → HostConfig → (WindowHost → RuntimeControl → IO s) → (s → RuntimeControl → IO a) → IO a
hosted seam config startup action =
  asProcessMainThread
    seam
    ( runWindowApplication
        (withLoggingLifetime quietLogger)
        "scheduled-example"
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

-- ---------------------------------------------------------------------------
-- The scripted platform

-- | The scripted platform's pending empty-event posts, whether the owner is
-- inside a finite wait, and whether that wait blocks for a post. A blocking
-- wait ends only when something posted, so a loop that continues proves it was
-- woken; an example stops the blocking once it has proved that, so the turns
-- after it can keep turning.
data WakePlatform = WakePlatform
  { platformPending ∷ TVar Int
  , platformWaiting ∷ TVar Bool
  , platformBlocking ∷ TVar Bool
  }

wakingSeam ∷ IO (Seam, WakePlatform)
wakingSeam = do
  platform ← WakePlatform <$> newTVarIO 0 <*> newTVarIO False <*> newTVarIO True
  seam ←
    newSeam
      defaultScript
        { scriptPostEmptyEvent = \reporter → do
            atomically (modifyTVar' (platformPending platform) (+ 1))
            scriptPostEmptyEvent defaultScript reporter
        , scriptPollEvents = \reporter → do
            atomically (writeTVar (platformPending platform) 0)
            scriptPollEvents defaultScript reporter
        , scriptWaitEvents = \seconds reporter → do
            atomically (writeTVar (platformWaiting platform) True)
            atomically $ do
              blocking ← readTVar (platformBlocking platform)
              pending ← readTVar (platformPending platform)
              check (not blocking || pending > 0)
              writeTVar (platformPending platform) 0
              writeTVar (platformWaiting platform) False
            scriptWaitEvents defaultScript seconds reporter
        }
  pure (seam, platform)

stopBlocking ∷ WakePlatform → IO ()
stopBlocking platform = atomically (writeTVar (platformBlocking platform) False)

-- | Run an action once the owner has entered its finite wait.
duringTheWait ∷ WakePlatform → IO () → IO ()
duringTheWait platform action =
  void . forkIO $ do
    atomically (readTVar (platformWaiting platform) >>= check)
    action

-- ---------------------------------------------------------------------------
-- Shared scaffolding

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

-- | How many empty-event posts the seam recorded.
posts ∷ Seam → IO Int
posts seam = length . filter (== PostEmptyEvent) <$> seamCalls seam

-- | The host's only window, on the owner thread.
onlyWindow ∷ WindowHost → IO Window
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [identity] → withHostWindow host identity pure >>= \case
      WindowAvailable window → pure window
      WindowEnded _ → unexpected "the host's only window has ended"
    windows → unexpected ("expected one window, found " <> show (length windows))

-- | The identity of a window no host in the example serves.
unservedWindow ∷ IO WindowId
unservedWindow = do
  seam ← newSeam defaultScript
  asProcessMainThread seam (entered seam (\session → withWindow session (windowNamed "elsewhere") (pure . windowIdentity)))

observeOf ∷ Window → WindowCommand
observeOf = observeWindowCommand . windowIdentity

admitted ∷ SubmitResult → IO CompletionTicket
admitted (SubmitAccepted ticket) = pure ticket
admitted other = unexpected ("the submission was not admitted: " <> show other)

kind ∷ Maybe Disposition → String
kind = \case
  Nothing → "pending"
  Just (Performed _) → "performed"
  Just (Rejected _) → "rejected"
  Just NotExecuted → "not executed"
  Just (Interrupted _) → "interrupted"
  Just (Unsupported _) → "unsupported"
  Just (Attempted _) → "attempted"
  Just (Transitioned _) → "transitioned"

newtype Broken = Broken Text
  deriving (Eq, Show)

instance Exception Broken

testComponent ∷ Component
testComponent = unsafeComponent "test.scheduled"

required ∷ Role → WorkerPolicy
required role = WorkerPolicy role Supervision.Required testComponent (\_ → pure Unrecognized)

expectStarted ∷ SupervisedStart r → IO (SupervisedWorker r)
expectStarted = \case
  WorkerStarted worker → pure worker
  WorkerStartUnavailable _ _ → unexpected "the worker was unavailable"
  WorkerStartRejected → unexpected "the worker's start was rejected"

breakingAfter ∷ MVar () → WorkerDefinition ()
breakingAfter gate = workerDefinition "breaker" (\_ → pure ()) (\_ () → takeMVar gate >> throwIO (Broken "worker failed"))
