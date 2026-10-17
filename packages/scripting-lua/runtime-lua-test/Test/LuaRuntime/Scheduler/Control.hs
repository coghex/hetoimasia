-- | Safe-boundary control (requirement 10): every answer, pause and resume at
-- boundaries including on the running task, the interplay with a wait, stop
-- while paused and while waiting, stop never undone, repeated and stale
-- requests, the lifecycle of results and their reservations, and the closing of
-- a stopped task's continuation on the owner's thread.
module Test.LuaRuntime.Scheduler.Control (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), SomeException, displayException, fromException, toException, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity (TaskId (TaskId), TaskName (TaskName))
import Hetoimasia.Scripting.Lua.Scheduler
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduler.Support

-- | Make a request and require that it was accepted.
request ∷ Rig → TaskId → ControlRequest → IO ControlTicket
request rig identity what =
  atomically (requestControl (rigScheduler rig) identity what) >>= \case
    ControlAccepted ticket → pure ticket
    other → fail ("the request was not accepted: " <> answerName other)

-- | The answer, for a refusal that is expected.
ask ∷ Rig → TaskId → ControlRequest → IO String
ask rig identity what = answerName <$> atomically (requestControl (rigScheduler rig) identity what)

answerName ∷ ControlAnswer → String
answerName = \case
  ControlAccepted _ → "accepted"
  ControlFull → "full"
  ControlClosed → "closed"
  ControlUnknownTarget → "unknown"

-- | Read a settlement, which observes it.
settlement ∷ ControlTicket → IO (Maybe ControlSettlement)
settlement = atomically . pollControl

resultOf ∷ ControlTicket → IO (Maybe ControlResult)
resultOf ticket = fmap settledResult <$> settlement ticket

-- | Ask the scheduler to pause its own running task from inside its segment.
pauseSelf ∷ Rig → TaskId → IO ControlTicket
pauseSelf rig identity = request rig identity RequestPause

spec ∷ Spec
spec = describe "safe-boundary control" $ do
  describe "the answers" $ do
    it "answers accepted, full, closed or unknown, and a refusal changes nothing but a counter" $ do
      rig ← newRigWith defaultOptions {optBounds = defaultBounds {boundControlRequests = 1, boundActiveTasks = 1}}
      active ← admit rig "active" OrdinaryClass Looped
      queued ← admit rig "queued" OrdinaryClass Looped
      loop rig "active"
      phase rig queued >>= (`shouldBe` Just PhaseQueued)
      -- Never issued, another owner's, and an admission still in the queue, which
      -- has no task to control yet.
      let elsewhere = TaskId (scope {keySession = SessionId 2}) (TaskName 0)
      mapM_ (\identity → ask rig identity RequestPause >>= (`shouldBe` "unknown")) [taskIdAt 999, elsewhere, queued]
      accepted ← request rig active RequestPause
      ask rig active RequestResume >>= (`shouldBe` "full")
      setStop rig True
      ask rig active RequestResume >>= (`shouldBe` "closed")
      setStop rig False
      counts ← diagnostics rig
      (diagControlAccepted counts, diagControlRefused counts) `shouldBe` (1, 5)
      -- Nothing about the task changed, and the one reservation is still the first
      -- request's: it settles once, and is given back once.
      phase rig active >>= (`shouldBe` Just PhaseReady)
      _ ← turn rig
      resultOf accepted >>= (`shouldBe` Just ControlApplied)
      phase rig active >>= (`shouldBe` Just PhasePaused)
      ask rig active RequestResume >>= (`shouldBe` "accepted")

    it "refuses a stale identity once the task has ended, and settles a request the task's end overtook" $ do
      rig ← newRig
      ending ← admit rig "ending" OrdinaryClass OneShot
      overtaken ← newIORef Nothing
      script rig "ending" [pauseSelf rig ending >>= writeIORef overtaken . Just >> completed "ending"]
      _ ← turn rig
      phase rig ending >>= (`shouldBe` Just (PhaseEnded OutcomeCompleted))
      readIORef overtaken >>= \case
        Just ticket → resultOf ticket >>= (`shouldBe` Just ControlNoLongerApplicable)
        Nothing → fail "the request was not made"
      ask rig ending RequestPause >>= (`shouldBe` "unknown")
      -- Observing the result takes the record with it, and the identity stays stale.
      observe rig ending >>= (`shouldSatisfy` \case Just (ResultCompleted _) → True; _ → False)
      ask rig ending RequestStop >>= (`shouldBe` "unknown")

  describe "pause and resume" $ do
    it "applies a request about the running task when its segment returns, and resumes it at the tail of its class" $ do
      rig ← newRig
      a ← admit rig "a" OrdinaryClass Looped
      _ ← admit rig "b" OrdinaryClass Looped
      loop rig "b"
      inside ← newIORef Nothing
      script
        rig
        "a"
        ( ( do
              running ← phase rig a
              ticket ← pauseSelf rig a
              pending ← atomically (pollControl ticket)
              writeIORef inside (Just (running, ticket, fmap settledResult pending))
              yielded "a"
          )
            : repeat (yielded "a")
        )
      _ ← turn rig
      ran rig >>= (`shouldBe` ["a", "b", "b", "b"])
      readIORef inside >>= \case
        Just (running, ticket, pending) → do
          -- While its segment ran the task was running and the request was not yet
          -- applied; afterwards it was.
          running `shouldBe` Just PhaseRunning
          pending `shouldBe` Nothing
          resultOf ticket >>= (`shouldBe` Just ControlApplied)
        Nothing → fail "the segment did not run"
      phase rig a >>= (`shouldBe` Just PhasePaused)
      resume ← request rig a RequestResume
      _ ← turn rig
      resultOf resume >>= (`shouldBe` Just ControlApplied)
      -- It rejoined behind "b", with a fresh ordinal.
      ran rig >>= (`shouldBe` ["a", "b", "b", "b", "b", "a", "b", "a"])

    it "answers already-in-state for a repeated pause or an unneeded resume, and harms nothing" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      first ← request rig task RequestPause
      second ← request rig task RequestPause
      unneeded ← request rig task RequestResume
      _ ← turn rig
      mapM resultOf [first, second, unneeded] >>= (`shouldBe` [Just ControlApplied, Just ControlAlreadyInState, Just ControlApplied])
      -- The resume that came third was needed after all: the pause applied first.
      phase rig task >>= (`shouldBe` Just PhaseReady)
      stray ← request rig task RequestResume
      _ ← turn rig
      resultOf stray >>= (`shouldBe` Just ControlAlreadyInState)

  describe "a task that waits" $ do
    it "stays paused when its wait is satisfied while it is paused, and resumes at the tail with what the wait earned" $ do
      rig ← newRig
      a ← admit rig "a" OrdinaryClass OneShot
      ticket ← newIORef Nothing
      script rig "a" [pauseSelf rig a >>= writeIORef ticket . Just >> waitTicks "a" 1]
      _ ← turn rig
      -- The pause was asked for inside a segment that then waited: it applied to a
      -- waiting task, which is paused and still waiting.
      phase rig a >>= (`shouldBe` Just PhasePaused)
      readIORef ticket >>= maybe (fail "no request") (\t → resultOf t >>= (`shouldBe` Just ControlApplied))
      _ ← granted rig 10
      _ ← turn rig
      -- The wait was satisfied and the grant finished, and the task did not run.
      ran rig >>= (`shouldBe` ["a"])
      phase rig a >>= (`shouldBe` Just PhasePaused)
      atomically (stepsOutstanding (rigScheduler rig)) >>= (`shouldBe` 0)
      resume ← request rig a RequestResume
      _ ← turn rig
      resultOf resume >>= (`shouldBe` Just ControlApplied)
      handed rig >>= (`shouldBe` [("a", 0, Nothing), ("a", 1, Just (ResumedLogical 1 (nanoseconds 10)))])

    it "does not skip an unsatisfied wait when it is resumed: it goes on waiting" $ do
      rig ← newRig
      a ← admit rig "a" OrdinaryClass OneShot
      script rig "a" [pauseSelf rig a >> waitTicks "a" 2]
      _ ← turn rig
      resume ← request rig a RequestResume
      _ ← turn rig
      resultOf resume >>= (`shouldBe` Just ControlApplied)
      phase rig a >>= (`shouldBe` Just PhaseWaiting)
      ran rig >>= (`shouldBe` ["a"])
      mapM_ (granted rig) [3, 4]
      _ ← turnsUntilIdle rig 5
      handed rig >>= (`shouldBe` [("a", 0, Nothing), ("a", 1, Just (ResumedLogical 2 (nanoseconds 7)))])

    it "holds an elapsed wake the same way: paused through its deadline, it resumes with the time measured" $ do
      rig ← newRig
      sleeper ← admit rig "sleeper" OrdinaryClass OneShot
      script rig "sleeper" [waitFor "sleeper" 100]
      _ ← turn rig
      pause ← request rig sleeper RequestPause
      _ ← turn rig
      resultOf pause >>= (`shouldBe` Just ControlApplied)
      setClock rig 500
      _ ← turn rig
      ran rig >>= (`shouldBe` ["sleeper"])
      phase rig sleeper >>= (`shouldBe` Just PhasePaused)
      resume ← request rig sleeper RequestResume
      _ ← turn rig
      resultOf resume >>= (`shouldBe` Just ControlApplied)
      handed rig >>= (`shouldBe` [("sleeper", 0, Nothing), ("sleeper", 1, Just (ResumedElapsed (nanoseconds 500)))])

  describe "stop" $ do
    it "cancels a task that is paused, waiting or holding a wake it earned, closing each continuation once" $ do
      rig ← newRig
      paused ← admit rig "paused" OrdinaryClass Looped
      waiting ← admit rig "waiting" OrdinaryClass OneShot
      held ← admit rig "held" OrdinaryClass OneShot
      loop rig "paused"
      script rig "waiting" [waitTicks "waiting" 5]
      script rig "held" [waitTicks "held" 1]
      _ ← request rig paused RequestPause
      _ ← turn rig
      _ ← request rig held RequestPause
      _ ← turn rig
      _ ← granted rig 5
      _ ← turn rig
      -- "held" earned its wake while paused and has not run.
      ran rig >>= (`shouldBe` ["waiting", "held"])
      stops ← mapM (\identity → request rig identity RequestStop) [paused, waiting, held]
      _ ← turn rig
      settled ← mapM settlement stops
      settled `shouldSatisfy` all (\case Just (ControlSettlement ControlApplied (Just CloseClean)) → True; _ → False)
      mapM_ (\identity → phase rig identity >>= (`shouldBe` Just (PhaseEnded OutcomeCancelled))) [paused, waiting, held]
      mapM (observe rig) [paused, waiting, held] >>= (`shouldSatisfy` all (\case Just ResultCancelled → True; _ → False))
      map fst <$> closedTasks rig >>= (`shouldBe` [paused, waiting, held])
      -- Nothing ran again, and the cancelled tasks are not resurrected by a late
      -- grant, a late resume or the passage of turns.
      _ ← granted rig 5
      _ ← turnsUntilIdle rig 5
      ran rig >>= (`shouldBe` ["waiting", "held"])

    it "is safe to repeat: a second stop of the same task settles as no longer applicable and closes nothing again" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      first ← request rig task RequestStop
      second ← request rig task RequestStop
      _ ← turn rig
      resultOf first >>= (`shouldBe` Just ControlApplied)
      resultOf second >>= (`shouldBe` Just ControlNoLongerApplicable)
      length <$> closedTasks rig >>= (`shouldBe` 1)

    it "is not undone by a resume or a pause accepted beside it, whatever order they arrived in" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      _ ← request rig task RequestPause
      _ ← turn rig
      resumeBefore ← request rig task RequestResume
      stop ← request rig task RequestStop
      resumeAfter ← request rig task RequestResume
      pause ← request rig task RequestPause
      _ ← turn rig
      resultOf stop >>= (`shouldBe` Just ControlApplied)
      mapM resultOf [resumeBefore, resumeAfter, pause] >>= (`shouldBe` replicate 3 (Just ControlNoLongerApplicable))
      phase rig task >>= (`shouldBe` Just (PhaseEnded OutcomeCancelled))
      ran rig >>= (`shouldBe` [])

    it "is applied when the running task's segment returns: a task that completes in it was not stopped" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass OneShot
      ticket ← newIORef Nothing
      script rig "task" [request rig task RequestStop >>= writeIORef ticket . Just >> completed "task"]
      _ ← turn rig
      readIORef ticket >>= maybe (fail "no request") (\t → resultOf t >>= (`shouldBe` Just ControlNoLongerApplicable))
      phase rig task >>= (`shouldBe` Just (PhaseEnded OutcomeCompleted))
      closedTasks rig >>= (`shouldSatisfy` null)

  describe "the continuation's close" $ do
    it "keeps a failure of the close as evidence in the settlement and the turn report, and cancels the task all the same" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      writeFailure rig task (toException (userError "close boom"))
      stop ← request rig task RequestStop
      report ← turn rig
      settlement stop >>= \case
        Just (ControlSettlement ControlApplied (Just (CloseFailed failure))) → displayException failure `shouldSatisfy` ("close boom" `isInfixOf`)
        other → fail ("expected a failed close, found " <> show other)
      map fst (turnCloseFailures report) `shouldBe` [task]
      phase rig task >>= (`shouldBe` Just (PhaseEnded OutcomeCancelled))
      observe rig task >>= (`shouldSatisfy` \case Just ResultCancelled → True; _ → False)
      length <$> closedTasks rig >>= (`shouldBe` 1)

    it "does not keep an asynchronous exception as the close's failure: it propagates, and the stop is left for the scheduler's stop to settle" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      writeFailure rig task (toException ThreadKilled)
      stop ← request rig task RequestStop
      outcome ← try (turn rig)
      case outcome of
        Left failure → fromException failure `shouldBe` Just ThreadKilled
        Right _ → fail "the turn should have been interrupted"
      -- Nothing was cancelled, nothing was settled, and the request is still the
      -- scheduler's to settle when it stops.
      phase rig task >>= (`shouldBe` Just PhaseReady)
      -- The interruption was a one-off: the stop that follows closes the task, once.
      writeIORef (rigCloseFailures rig) Map.empty
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      stopControlsSettled report `shouldBe` 1
      settlement stop >>= (`shouldSatisfy` \case Just (ControlSettlement ControlNoLongerApplicable Nothing) → True; _ → False)

    it "is made on the thread that drives the scheduler, whichever thread asked for the stop" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      requested ← newEmptyMVar
      asker ← forkIO (request rig task RequestStop >>= putMVar requested)
      _ ← takeMVar requested
      driver ← myThreadId
      _ ← turn rig
      closedTasks rig >>= \closed → map snd closed `shouldBe` [driver]
      asker `shouldSatisfy` (/= driver)

  describe "a task woken by a grant" $ do
    it "frees the grant's slot when it is stopped before it runs, and never runs" $ do
      rig ← newRig
      waiter ← admit rig "waiter" OrdinaryClass OneShot
      script rig "waiter" [waitTicks "waiter" 1]
      _ ← turn rig
      _ ← granted rig 10
      stop ← request rig waiter RequestStop
      _ ← turn rig
      resultOf stop >>= (`shouldBe` Just ControlApplied)
      atomically (stepsOutstanding (rigScheduler rig)) >>= (`shouldBe` 0)
      ran rig >>= (`shouldBe` ["waiter"])

    it "frees the grant's slot when it is paused before it runs, and keeps the wake it earned for when it resumes" $ do
      rig ← newRig
      waiter ← admit rig "waiter" OrdinaryClass OneShot
      script rig "waiter" [waitTicks "waiter" 1]
      _ ← turn rig
      _ ← granted rig 10
      pause ← request rig waiter RequestPause
      _ ← turn rig
      resultOf pause >>= (`shouldBe` Just ControlApplied)
      atomically (stepsOutstanding (rigScheduler rig)) >>= (`shouldBe` 0)
      ran rig >>= (`shouldBe` ["waiter"])
      _ ← request rig waiter RequestResume
      _ ← turn rig
      handed rig >>= (`shouldBe` [("waiter", 0, Nothing), ("waiter", 1, Just (ResumedLogical 1 (nanoseconds 10)))])

  describe "results and their reservations" $ do
    it "settles each accepted request once, and gives each reservation back once, on observation or abandonment" $ do
      rig ← newRigWith defaultOptions {optBounds = defaultBounds {boundControlRequests = 2}}
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      first ← request rig task RequestPause
      second ← request rig task RequestPause
      ask rig task RequestResume >>= (`shouldBe` "full")
      _ ← turn rig
      -- Settled, applied and no longer queued, and still holding their reservations.
      ask rig task RequestResume >>= (`shouldBe` "full")
      settlement first >>= (`shouldSatisfy` \case Just (ControlSettlement ControlApplied Nothing) → True; _ → False)
      third ← request rig task RequestResume
      ask rig task RequestPause >>= (`shouldBe` "full")
      -- A second look at an observed result gives nothing back.
      settlement first >>= (`shouldSatisfy` \case Just (ControlSettlement ControlApplied Nothing) → True; _ → False)
      ask rig task RequestPause >>= (`shouldBe` "full")
      -- Abandoning a settled result gives its reservation back, once.
      atomically (forgetControl second)
      atomically (forgetControl second)
      _ ← request rig task RequestPause
      ask rig task RequestPause >>= (`shouldBe` "full")
      -- Abandoning one that has not settled gives it back when it does.
      atomically (forgetControl third)
      ask rig task RequestPause >>= (`shouldBe` "full")
      _ ← turn rig
      _ ← request rig task RequestPause
      ask rig task RequestPause >>= (`shouldBe` "full")

    it "answers a request settled by the whole scheduler's stop as no longer applicable" $ do
      rig ← newRig
      task ← admit rig "task" OrdinaryClass Looped
      loop rig "task"
      pending ← request rig task RequestPause
      report ← stopScheduler (rigScheduler rig) (rigHost rig)
      stopControlsSettled report `shouldBe` 1
      settlement pending >>= (`shouldSatisfy` \case Just (ControlSettlement ControlNoLongerApplicable Nothing) → True; _ → False)

writeFailure ∷ Rig → TaskId → SomeException → IO ()
writeFailure rig identity failure = do
  current ← readIORef (rigCloseFailures rig)
  writeIORef (rigCloseFailures rig) (Map.insert identity failure current)
