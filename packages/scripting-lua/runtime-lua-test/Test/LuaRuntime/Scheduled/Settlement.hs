-- | Admission and settlement (requirement 14): every outcome, each bound accepted
-- to its limit and full one past it, closed after stop, exactly-once settlement
-- across a thousand admissions racing control requests and a stop, and the
-- reclamation of a ticket's reservation.
module Test.LuaRuntime.Scheduled.Settlement (spec) where

import Control.Concurrent (forkIO, yield)
import Control.Concurrent.MVar (modifyMVar_, newEmptyMVar, newMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, orElse, readTVarIO, retry, writeTVar)
import Control.Monad (forM, forM_, replicateM, replicateM_, void)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner (BoundaryFault (boundaryReason), FaultReason (ScriptFailed, ValueRefused), FaultKind (CallFailed), ModuleRef (ModuleRef))
import Hetoimasia.Scripting.Lua.Runtime
  ( CallFault (BoundaryFailed, ModuleNotLoaded)
  , Discard (Discard)
  , ExitKind (ExitStopped)
  , ExitRecord (exitNotStarted, exitStarted)
  , Progress (NotStarted, Started)
  )
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Scheduler (ReasonCode (ValidationFault), TaskFailure (failureReasonOf), reasonCode)
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, failExample, Gated (..), requiredPolicy, withBoundary, withBoundaryOpening)

-- | Keep asking until the admission is accepted: for the moment between a
-- reservation being forgotten and the owner's next sweep giving it back.
untilAccepted ∷ ScheduledEndpoint → TaskRequest → IO ScheduledTicket
untilAccepted endpoint taskRequest =
  admitScheduledTask endpoint taskRequest >>= \case
    TaskAccepted _ ticket → pure ticket
    TaskQueueFull → yield >> untilAccepted endpoint taskRequest
    TaskAdmissionClosed → failExample "the owner closed"

echoing ∷ Int → TaskRequest
echoing n = request "echo" [VInteger (fromIntegral n)] OrdinaryClass OneShot Nothing

blockedIn ∷ Value → TaskRequest
blockedIn name = request "block_in" [name] OrdinaryClass OneShot Nothing

spec ∷ Spec
spec = describe "admission and settlement" $ do
  describe "every outcome" $ do
    it "settles a task as returned, absent, faulted, refused, cancelled or discarded, once, and goes on serving" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "outcomes" requiredPolicy defaultSchedulerBounds)
        let endpoint = scheduledEndpoint owner
        returned ← admitTask' fixture owner "returned" (echoing 7)
        absent ← admitTask' fixture owner "absent" (request "absent" [] OrdinaryClass OneShot Nothing)
        faulted ← admitTask' fixture owner "faulted" (request "fault" [VText "f"] OrdinaryClass OneShot Nothing)
        ghost ← admitTask' fixture owner "ghost" ((request "echo" [VInteger 1] OrdinaryClass OneShot Nothing) {requestModule = ModuleRef "ghost" "9"})
        refused ← admitTask' fixture owner "refused" (request "bad_wait" [] OrdinaryClass OneShot Nothing)
        stopped ← admitTask' fixture owner "stopped" (request "forever" [VText "x"] OrdinaryClass Looped Nothing)
        outcomeOf returned >>= (`shouldBe` Just [VInteger 7]) . taskReturned
        outcomeOf absent >>= \case
          SettledReturned _ → pure ()
          other → failExample ("expected the absent entry point to settle as returned, found " <> show other)
        outcomeOf faulted >>= \case
          SettledFaulted (BoundaryFailed fault) → boundaryReason fault `shouldSatisfy` \case ScriptFailed CallFailed _ → True; _ → False
          other → failExample ("expected a script fault as data, found " <> show other)
        outcomeOf ghost >>= \case
          SettledFaulted (ModuleNotLoaded ref) → ref `shouldBe` ModuleRef "ghost" "9"
          other → failExample ("expected the unknown module, found " <> show other)
        outcomeOf refused >>= \case
          SettledRefused failure → reasonCode (failureReasonOf failure) `shouldBe` ValidationFault
          other → failExample ("expected the scheduler's refusal, found " <> show other)
        -- None of those ended the owner: it stops a task on request, and a task is
        -- served after them.
        requestTaskControl endpoint (ticketTask stopped) RequestStop >>= \case
          TaskControlAccepted receipt → void (waitControl receipt)
          other → failExample ("the stop was not accepted: " <> show other)
        outcomeOf stopped >>= \case
          SettledCancelled → pure ()
          other → failExample ("expected a cancellation, found " <> show other)
        after ← admitTask' fixture owner "after" (echoing 8)
        outcomeOf after >>= (`shouldBe` Just [VInteger 8]) . taskReturned
        retireScheduled owner

    it "accepts arguments over the owner's limits and settles the task as the refusal the argument check raises" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "over" requiredPolicy defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "over" (request "once" [VText (replicate' 100000)] OrdinaryClass OneShot Nothing)
        outcomeOf ticket >>= \case
          SettledFaulted (BoundaryFailed fault) → boundaryReason fault `shouldSatisfy` \case ValueRefused _ → True; _ → False
          other → failExample ("expected a refused argument, found " <> show other)
        effects fixture >>= (`shouldBe` [])
        retireScheduled owner

    it "discards a task that had not started, and one the owner was running, when the owner exits, and says which" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "discard" requiredPolicy defaultSchedulerBounds)
        running ← admitTask' fixture owner "running" (blockedIn (VText "r"))
        awaitEntered fixture "r"
        waiting ← admitTask' fixture owner "waiting" (echoing 1)
        retireScheduled owner
        -- The running segment is let return; nothing else starts.
        releaseGate fixture "r"
        _ ← awaitScheduledTerminal control owner
        outcomeOf waiting >>= \case
          SettledDiscarded discard → discard `shouldBe` Discard ExitStopped NotStarted
          other → failExample ("expected a discard, found " <> show other)
        -- The task that was running finished its segment and was not discarded.
        outcomeOf running >>= \case
          SettledReturned _ → pure ()
          other → failExample ("expected the running task to finish, found " <> show other)
        atomically (scheduledExitRecord owner) >>= \case
          Just record → (exitNotStarted record, exitStarted record) `shouldBe` (1, 0)
          Nothing → failExample "the owner recorded no exit"

  describe "bounds" $ do
    it "accepts the queue of admissions to its limit and answers full one past it" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundActiveTasks = 1, boundQueuedAdmissions = 2, boundRetainedResults = 10}
        owner ← startScheduled fixture runtime (scheduled fixture "queue" requiredPolicy bounds)
        answers ←
          holding fixture owner $
            replicateM 3 (admitScheduledTask (scheduledEndpoint owner) (echoing 1))
        map isAccepted answers `shouldBe` [True, True, False]
        retireScheduled owner

    it "accepts the results to their limit and answers full one past it, reserving a result when the task is admitted" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundRetainedResults = 3}
        owner ← startScheduled fixture runtime (scheduled fixture "results" requiredPolicy bounds)
        answers ←
          holding fixture owner $
            replicateM 3 (admitScheduledTask (scheduledEndpoint owner) (echoing 1))
        -- The task that held the owner, and two more, hold the three reservations.
        map isAccepted answers `shouldBe` [True, True, False]
        retireScheduled owner

    it "accepts control requests to their limit and answers full one past it, and gives a reservation back when its result is observed" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundControlRequests = 2}
        owner ← startScheduled fixture runtime (scheduled fixture "control" requiredPolicy bounds)
        (target, receipts, full) ←
          holding fixture owner $ do
            target ← admitTask' fixture owner "t" (request "forever" [VText "t"] OrdinaryClass Looped Nothing)
            receipts ← replicateM 2 (requestTaskControl (scheduledEndpoint owner) (ticketTask target) RequestPause)
            full ← requestTaskControl (scheduledEndpoint owner) (ticketTask target) RequestResume
            pure (target, receipts, full)
        case (receipts, full) of
          ([TaskControlAccepted first, TaskControlAccepted _], TaskControlFull) → do
            let resume = requestTaskControl (scheduledEndpoint owner) (ticketTask target) RequestResume
            -- Both reservations are held, applied or not: a result that has left the
            -- queue and has not been observed still holds its reservation.
            resume >>= \case
              TaskControlFull → pure ()
              other → failExample ("expected the reservations to be held, found " <> show other)
            -- Observing the first gives its reservation back, once, however often.
            _ ← waitControl first
            _ ← waitControl first
            resume >>= \case
              TaskControlAccepted _ → pure ()
              other → failExample ("expected the reservation to be given back, found " <> show other)
            resume >>= \case
              TaskControlFull → pure ()
              other → failExample ("expected exactly one reservation to have been given back, found " <> show other)
          other → failExample ("unexpected answers: " <> show other)
        retireScheduled owner

    it "accepts grants to their limit and answers full one past it" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundOutstandingGrants = 2}
        owner ← startScheduled fixture runtime (scheduled fixture "grants" requiredPolicy bounds)
        answers ← holding fixture owner (replicateM 3 (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 5)))
        answers `shouldBe` [GrantAccepted (GrantId 0), GrantAccepted (GrantId 1), GrantFull]
        retireScheduled owner

    it "answers closed to admission, grants and control once the owner has stopped" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "closed" requiredPolicy defaultSchedulerBounds)
        ticket ← admitTask' fixture owner "t" (request "forever" [VText "t"] OrdinaryClass Looped Nothing)
        retireScheduled owner
        _ ← awaitScheduledTerminal control owner
        admitScheduledTask (scheduledEndpoint owner) (echoing 1) >>= \case
          TaskAdmissionClosed → pure ()
          other → failExample ("expected admission to be closed, found " <> show other)
        grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1) >>= (`shouldBe` GrantClosed)
        requestTaskControl (scheduledEndpoint owner) (ticketTask ticket) RequestStop >>= \case
          TaskControlClosed → pure ()
          other → failExample ("expected control to be closed, found " <> show other)

  describe "the grant as a transaction (D-85)" $ do
    it "answers what the grant does by itself, and composes with the application's own state in one atomic step" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        owner ← startScheduled fixture runtime (scheduled fixture "stm grants" requiredPolicy defaultSchedulerBounds)
        let endpoint = scheduledEndpoint owner
            -- the application's own state is written and the grant is made in one transaction, which is undone, with the
            -- write, when the grant is not accepted
            composed flag = atomically $ (writeTVar flag True >> grantScheduledStepSTM endpoint (nanoseconds 5) >>= \case
                                              granted@(GrantAccepted _) → pure (Just granted)
                                              _ → retry)
                                          `orElse` pure Nothing
        open ← newTVarIO False
        composed open >>= (`shouldBe` Just (GrantAccepted (GrantId 0)))
        readTVarIO open `shouldReturn` True
        -- the same grant by itself continues from it: one scheduler, one count
        grantScheduledStep endpoint (nanoseconds 5) >>= (`shouldBe` GrantAccepted (GrantId 1))
        retireScheduled owner
        _ ← awaitScheduledTerminal control owner
        closed ← newTVarIO False
        composed closed >>= (`shouldBe` Nothing)
        -- nothing of the transaction is seen: the write that preceded the refused grant was undone with it
        readTVarIO closed `shouldReturn` False
        atomically (grantScheduledStepSTM endpoint (nanoseconds 5)) >>= (`shouldBe` GrantClosed)
        grantScheduledStep endpoint (nanoseconds 5) >>= (`shouldBe` GrantClosed)

  describe "exactly-once settlement under races" $ do
    it "settles every accepted task once across a thousand admissions racing control requests and a stop" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \control runtime → do
        let bounds = defaultSchedulerBounds {boundActiveTasks = 64, boundQueuedAdmissions = 2048, boundRetainedResults = 4096, boundControlRequests = 64}
        owner ← startScheduled fixture runtime (scheduled fixture "races" requiredPolicy bounds)
        let endpoint = scheduledEndpoint owner
        accepted' ← newMVar []
        let producer = replicateM_ 400 $ do
              admitScheduledTask endpoint (echoing 1) >>= \case
                TaskAccepted identity ticket → modifyMVar_ accepted' (pure . ((identity, ticket) :))
                _ → pure ()
        producersDone ← forM [1 .. 4 ∷ Int] $ \_ → do
          done ← newEmptyMVar
          _ ← forkIO (producer >> putMVar done ())
          pure done
        controllerDone ← newEmptyMVar
        _ ← forkIO $ do
          forM_ [1 .. 600 ∷ Int] $ \n → do
            held ← readMVar accepted'
            case drop (n `mod` 50) held of
              (identity, _) : _ →
                requestTaskControl endpoint identity (if even n then RequestStop else RequestPause) >>= \case
                  TaskControlAccepted receipt → forgetControl receipt
                  _ → yield
              [] → yield
          putMVar controllerDone ()
        -- The stop comes once a thousand tasks have been accepted, whatever the
        -- producers and the controller are then doing.
        awaitDiagnostics owner (\counts → diagAdmitted counts >= 1000)
        retireScheduled owner
        mapM_ takeMVar producersDone
        takeMVar controllerDone
        _ ← awaitScheduledTerminal control owner
        tickets ← map snd <$> readMVar accepted'
        length tickets `shouldSatisfy` (>= 1000)
        settlements ← forM tickets $ \ticket → do
          first ← waitTask ticket
          again ← pollTask ticket
          pure (first, again)
        -- Every accepted task settled, and a second look answers the same thing.
        forM_ settlements $ \(first, again) → fmap (kindOf . settledOutcome) again `shouldBe` Just (kindOf (settledOutcome first))
        let kinds = map (kindOf . settledOutcome . fst) settlements
            discards = [discard | (settled, _) ← settlements, SettledDiscarded discard ← [settledOutcome settled]]
        length (filter (== "returned") kinds) + length (filter (== "cancelled") kinds) + length discards `shouldBe` length tickets
        atomically (scheduledExitRecord owner) >>= \case
          Just record →
            ( length [() | Discard _ NotStarted ← discards]
            , length [() | Discard _ Started ← discards]
            )
              `shouldBe` (exitNotStarted record, exitStarted record)
          Nothing → failExample "the owner recorded no exit"

  describe "a ticket's reservation" $ do
    it "is given back by the first observation only, whatever the later or concurrent observations" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundRetainedResults = 2}
        owner ← startScheduled fixture runtime (scheduled fixture "observe" requiredPolicy bounds)
        let endpoint = scheduledEndpoint owner
        first ← admitTask' fixture owner "first" (echoing 1)
        second ← admitTask' fixture owner "second" (echoing 2)
        awaitDiagnostics owner (\counts → diagCompleted counts >= 2)
        -- Finished, unobserved, and still holding their reservations.
        admitScheduledTask endpoint (echoing 3) >>= (`shouldSatisfy` (not . isAccepted))
        observed ← pollTask first
        fmap (taskReturned . settledOutcome) observed `shouldBe` Just (Just [VInteger 1])
        third ← admitScheduledTask endpoint (echoing 3)
        third `shouldSatisfy` isAccepted
        -- Looking again answers the same and gives nothing more back.
        again ← pollTask first
        fmap (taskReturned . settledOutcome) again `shouldBe` Just (Just [VInteger 1])
        admitScheduledTask endpoint (echoing 4) >>= (`shouldSatisfy` (not . isAccepted))
        -- Two threads looking at once see one outcome and free one reservation.
        results ← newMVar []
        dones ← forM [1 .. 2 ∷ Int] $ \_ → do
          done ← newEmptyMVar
          _ ← forkIO (waitTask second >>= \settled → modifyMVar_ results (pure . (taskReturned (settledOutcome settled) :)) >> putMVar done ())
          pure done
        mapM_ takeMVar dones
        readMVar results >>= (`shouldBe` [Just [VInteger 2], Just [VInteger 2]])
        _ ← untilAccepted endpoint (echoing 5)
        admitScheduledTask endpoint (echoing 6) >>= (`shouldSatisfy` (not . isAccepted))
        retireScheduled owner

    it "is given back at settlement, once, for a task whose result was forgotten before it settled" $ bounded $ do
      fixture ← newSFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundRetainedResults = 1}
        owner ← startScheduled fixture runtime (scheduled fixture "forget" requiredPolicy bounds)
        let endpoint = scheduledEndpoint owner
        blocked ← admitTask' fixture owner "blocked" (blockedIn (VText "b"))
        awaitEntered fixture "b"
        forgetTask blocked
        -- Forgotten, and not yet settled: the reservation is still held.
        admitScheduledTask endpoint (echoing 1) >>= (`shouldSatisfy` (not . isAccepted))
        releaseGate fixture "b"
        _ ← untilAccepted endpoint (echoing 1)
        -- The forgotten ticket still reads what its task settled as.
        pollTask blocked >>= \case
          Just settled → settledOutcome settled `shouldSatisfy` \case SettledReturned _ → True; _ → False
          Nothing → failExample "the forgotten ticket lost its settlement"
        retireScheduled owner

    it "is given back for a cancelled task as for any other, and the engine keeps no other history" $ bounded $ do
      fixture ← newSFixture
      withBoundary $ \_ runtime → do
        let bounds = defaultSchedulerBounds {boundRetainedResults = 1}
        owner ← startScheduled fixture runtime (scheduled fixture "cancelled" requiredPolicy bounds)
        let endpoint = scheduledEndpoint owner
        victim ← admitTask' fixture owner "v" (request "forever" [VText "v"] OrdinaryClass Looped Nothing)
        requestTaskControl endpoint (ticketTask victim) RequestStop >>= \case
          TaskControlAccepted receipt → void (waitControl receipt)
          other → failExample ("the stop was not accepted: " <> show other)
        outcomeOf victim >>= \case
          SettledCancelled → pure ()
          other → failExample ("expected a cancellation, found " <> show other)
        -- Observed by the wait above: the one reservation is back.
        _ ← untilAccepted endpoint (echoing 1)
        retireScheduled owner
  where
    replicate' n = Text.replicate n "x"
    isAccepted = \case
      TaskAccepted _ _ → True
      _ → False
    kindOf ∷ ScheduledOutcome → String
    kindOf = \case
      SettledReturned _ → "returned"
      SettledFaulted _ → "faulted"
      SettledRefused _ → "refused"
      SettledCancelled → "cancelled"
      SettledDiscarded _ → "discarded"
