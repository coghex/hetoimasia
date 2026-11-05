-- | What an interruption cannot undo: a target retirement that returned stays
-- recorded, every injected operation's answer commits with no interruption
-- point after it, and the join waits for a terminal group report.
module Test.GLFW.Owner.Failure.Interruption (spec) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , MaskingState (MaskedInterruptible)
  , IOException
  , finally
  , getMaskingState
  , mask
  , onException
  , throwIO
  , throwTo
  )
import Control.Monad (forM_, unless, void, when)
import Data.Foldable (for_)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Test.GLFW.Owner.Fixture.Drive
  ( absorbing
  , awaitRound
  , awaitStanding
  , awaitTerminal
  , handedOver
  , pumpUntilRetired
  , raisedBy
  , rescuePublishing
  , theWindow
  , trackedHandedOver
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRig, ownedHost, ownedHostCaught, ownedHostHooked)
import Test.GLFW.Support
  ( Ending (..)
  , Scope
  , boundedExample
  , caughtAsUnless
  , cutExamples
  , ownedEnds
  , quietLogger
  , unexpected
  , unownedLeaks
  , withDeferredThreadOpening
  )
import Test.Hspec (Spec, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)
import Test.Support.Owned (withOwnedThreadOpening)
import Data.IORef (newIORef)

spec ∷ Spec
spec = do
  it "records a target retirement that returned, however it is then cancelled"
    (boundedExample testRetirementRecordSurvivesCancellation)
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) → do
    it ("ends and joins the harasser, offers the retirement once and terminates the owner when the example body " <> label <> " after the harassment started and before the body supplies the completion evidence (#612)") $
      boundedExample (ownedEnds ending retirementRecordScenario False)
    it ("negative control: an unowned harasser outlives the example whose body " <> label <> " after the harassment started (#612)") $
      boundedExample (unownedLeaks ending retirementRecordScenario False)
  it "commits every injected operation's answer with no interruption point after it"
    (boundedExample testOperationAnswersCommitUninterrupted)
  it "waits for a terminal group report however the join is interrupted"
    (boundedExample testJoinAwaitsTerminalReport)
  cutExamples "the join fixture" [0, 1] joinScenario

-- | A target retirement that returned is recorded, whatever is delivered to
-- the owner as it returns — so it is never offered a second time.
--
-- The call itself stays interruptible, and a cancellation inside it leaves
-- the target explicitly unverified and the operation spent. What must not
-- happen is a cancellation between the answer and the record of it: the
-- target would be neither retired nor marked, and the drain would offer the
-- operation again, disposing a second time what the backend already disposed.
testRetirementRecordSurvivesCancellation ∷ IO ()
testRetirementRecordSurvivesCancellation = retirementRecord withOwnedThreadOpening False (pure ())

-- | The same fixture ended after the harassment has started and before the body supplies the completion evidence the exit waits for
-- (#612): the harasser is held after its first cancellation until the example's own ending (or its scope) lets it go on, so it is
-- certainly alive and certainly mid-harassment when the body fails or is cancelled. The run is not asserted to raise the injected
-- ending here: the ending's judgement does that. What is asserted is what must hold whatever raised: the retirement was offered
-- exactly once, the owner was destroyed after its retirement and the session ended.
retirementRecordScenario ∷ Scope → IO () → IO ()
retirementRecordScenario scope atParked = retirementRecord scope True atParked

-- | The example. The harasser is an owned start of the first argument; with @held@ it parks after its first cancellation until the body
-- or the scope releases it, and the second argument is where a scenario ends the body ('retirementRecord' with @held@ false never
-- calls it).
--
-- = The harasser and what it may hit
--
-- It delivers 'ThreadKilled' to the owner's thread again and again from the instant the retirement call is entered, so one lands
-- wherever the owner is least protected: inside the call, on its way out, or after the record. It stops once the record exists.
-- It used to go on for all of its cancellations, and that is the cause of the hang this example had under @-N2@ (8 of 204 runs; in
-- the two captured, the journal ended with @OwnerRetirement@ and no @OwnerDestruction@): a cancellation that is pending while the
-- owner is masked is received at the next point it is unmasked, which for a stream of them is the start of each backend call in
-- turn, so one reached the destruction, interrupted a call whose evidence the exit then waits for, for ever, and the owner (correctly)
-- retained everything. Where the harasser runs beside the owner rather than ahead of it, the stream outlasts the target's retirement.
-- Production is not at fault: an interrupted destruction is unverified and the exit waits for independent evidence. So the owner's
-- whole-owner retirement and destruction wait, absorbing what is still delivered, for the harassment to be over; nothing waits on time.
retirementRecord ∷ Scope → Bool → IO () → IO ()
retirementRecord scope held atParked = do
  rig ← newRig
  entered ← newTVarIO False
  harassed ← newTVarIO False
  abandoned ← newTVarIO False
  started ← newTVarIO False
  release ← newTVarIO (not held)
  recorded ← newTVarIO []
  retained ← newTVarIO (0 ∷ Int)
  absorbed ← newTVarIO (0 ∷ Int)
  tracked ← newIORef []
  -- How often the backend was asked to retire the target, counted by the fake at the call's entry, before anything a cancellation
  -- could interrupt in the call itself.
  let offers = length <$> readTVarIO (fakeRetirements (rigFake rig))
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    atomically (writeTVar entered True)
    pure (targetRetired (Text.pack (show (retiringWindow retire))))
  -- The owner's later calls wait for a harassment that has begun, and absorb what is still being delivered while they wait.
  let afterHarassment = absorbing absorbed . atomically $ do
        begun ← readTVar entered
        when begun (readTVar harassed >>= \over → readTVar abandoned >>= check . (over ||))
  script (fakeRetireOwner (rigFake rig)) $ \_ → afterHarassment >> pure (ownerRetired (Text.pack "retired"))
  script (fakeDestroy (rigFake rig)) $ \_ → afterHarassment >> pure (ownerDestroyed (Text.pack "destroyed"))
  -- The owner, handed to the harasser by the body, so that it can tell when the record exists.
  ownerCell ← newTVarIO Nothing
  let harry = do
        atomically (readTVar entered >>= check)
        owner ← atomically (readTVar ownerCell >>= maybe retry pure)
        ownerThread ← atomically $
          readTVar (fakeThreads (rigFake rig)) >>= \case
            thread : _ → pure thread
            [] → retry
        -- Stops as soon as the record exists: a cancellation pending when it is committed is received at the next point the owner is
        -- unmasked, which is the start of its whole-owner retirement, and that one is survivable (the destruction is still offered).
        -- A second, or one for the destruction, is not: it interrupts a call whose evidence the exit then waits for, for ever.
        let harass n = unless (n > (20 ∷ Int)) $ do
              known ← atomically (not . Map.null <$> readTargetTerminalsNow owner)
              unless known (throwTo ownerThread ThreadKilled >> harass (n + 1))
        ( do
            throwTo ownerThread ThreadKilled
            atomically (writeTVar started True)
            atomically (readTVar release >>= check)
            harass 2
          )
          `finally` atomically (writeTVar harassed True)
      letGo = atomically (writeTVar release True)
  -- Owned by the example and not by the host body: the harassment ends before the owner's later calls, which wait for it, and the
  -- scope lets it go on whatever ended the example (#612).
  scope letGo harry $ \_ _ → do
    outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      atomically (writeTVar ownerCell (Just owner))
      service ← trackedHandedOver tracked host owner window
      -- When the body ends before it has published the completion evidence the exit waits for, the rescue publishes it and tells the
      -- owner's later calls not to wait for a harassment that nobody is going to see through. The harasser is not let go by it: it is
      -- the scope's to stop and join, which is what the scenario judges.
      (`onException` (atomically (writeTVar abandoned True) >> rescuePublishing tracked host owner)) $ do
        awaitStanding owner service `shouldReturn` TargetUsable
        _ ← releaseGraphicsTarget host owner service
        when held $ do
          atomically (readTVar started >>= check)
          atParked
        atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
        -- Independent evidence, so this exit finishes whichever way the
        -- retirement settled.
        publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
        acknowledgement ←
          atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
            >>= maybe (unexpected "the attachment kept no acknowledgement") pure
        forM_ allRetirementFacts $ \fact →
          void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
        pumpUntilRetired host control
        -- Captured here rather than returned: the run itself raises the
        -- cancellation at its exit, so the body's value never reaches the caller.
        atomically . writeTVar recorded . Map.keys =<< atomically (readTargetTerminalsNow owner)
        atomically . writeTVar retained . length =<< atomically (readOwnerTargets owner)
    -- Offered exactly once, over the whole run and its drain, however many
    -- cancellations arrived and however the example ended.
    offers `shouldReturn` 1
    if held
      then do
        -- Ended by the scenario: the owner terminated after its retirement and the session was torn down, and the ending is the
        -- run's own, raised as itself for the ending's judgement.
        notes ← journalled (rigJournal rig)
        ordered notes [OwnerRetirement, OwnerDestruction, SessionEnded]
        either throwIO (\() → unexpected "the ended run returned") outcome
      else do
        -- However it ended, it ended by raising the cancellation rather than
        -- swallowing it.
        void (raisedBy outcome)
        -- And the target is accounted for exactly once: a retirement that returned has its record, and is never forgotten or performed a
        -- second time; one a cancellation interrupted inside the call (which stays interruptible) did not return, so it is explicitly
        -- retained as unverified instead and has no record. Which of the two a run meets depends on where the cancellation lands.
        terminals ← readTVarIO recorded
        kept ← readTVarIO retained
        length terminals + kept `shouldBe` 1

-- | Every injected operation's answer is committed with no interruption
-- point between the two.
--
-- This is the window itself, observed from inside it. A cancellation
-- delivered between a /successful/ backend call and the record of what it
-- returned would discard evidence the backend really established: a
-- construction would stay pending and be built a second time, and a target
-- retirement would be neither recorded nor marked, so the drain would offer
-- it again — disposing a second time what the backend has already disposed.
--
-- There is nothing to race here, and deliberately so. The seam only /looks/:
-- anything that blocked in this window would itself be the interruption point
-- the mask exists to keep out, so what an example can assert is that the
-- window is masked, at every site that has one.
testOperationAnswersCommitUninterrupted ∷ IO ()
testOperationAnswersCommitUninterrupted = do
  rig ← newRig
  states ← newTVarIO []
  let hooks =
        Private.noHostHooks
          { Private.afterOwnerOperation =
              getMaskingState >>= \state → atomically (modifyTVar' states (<> [state]))
          }
  ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pumpUntilRetired host control
  -- The owner's startup, one construction and one target retirement, each
  -- masked from the answer through the commit.
  seen ← readTVarIO states
  length seen `shouldSatisfy` (>= 3)
  filter (/= MaskedInterruptible) seen `shouldBe` []

-- | The join is re-entered until it answers a terminal group report,
-- whatever is delivered to the thread waiting in it.
--
-- The exception delivered is an ordinary 'IOException', not an asynchronous
-- one: its type says nothing about how it arrived, and a join that returned
-- on it would let the protected host unwind with the owner never proved
-- terminal. The owner publishes its destruction evidence independently and
-- then stays inside its backend call, so the exit is certainly in the join
-- and not in the wait before it.
testJoinAwaitsTerminalReport ∷ IO ()
testJoinAwaitsTerminalReport = joinAwaitsTerminalReport False (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the destruction is held and the helper handed the owner, or after both, in one
-- masked step.
joinScenario ∷ Int → Scope → IO () → IO ()
joinScenario cutAt _ atParked = joinAwaitsTerminalReport True (\armedNow → when (armedNow == cutAt) atParked)

joinAwaitsTerminalReport ∷ Bool → (Int → IO ()) → IO ()
joinAwaitsTerminalReport scenario cut = do
  rig ← newRig
  release ← newTVarIO False
  joining ← newEmptyMVar
  -- The destruction is held at its gate only from the body's first masked step, which hands the helper the owner (and so what it
  -- opens the gate with) in the same step (#593): the exit never meets a held destruction nobody can release.
  let arm = script (fakeDestroy (rigFake rig)) $ \_ → do
        putMVar joining ()
        atomically (readTVar release >>= check)
        pure (ownerDestroyed (Text.pack "destroyed"))
  released ← newTVarIO Nothing
  -- The helper supplies the evidence the exit's join waits for and opens the gate the owner is held at, so it must outlive the
  -- host's exit that it unblocks: it is owned by the example, not by the host body that hands it the owner (#593). Whatever
  -- ends it, the gate is opened, so the owner it holds is never joined while still held.
  let helper (owner, main) =
        ( do
            takeMVar joining
            -- The owner's destruction evidence exists, so the exit leaves its
            -- wait and enters the join; the owner is still inside the call.
            publishOwnerDestruction owner (ownerDestroyed (Text.pack "published early"))
            atomically (readOwnerTerminalNow owner >>= check . isJust . ownerDestroyedEvidence)
            -- In a scenario the example's own ending is the exit's primary failure, so the delivery (the subject of the full
            -- example) is left out and cannot win a race with it.
            unless scenario (throwTo main (userError "delivered during the join"))
            -- Nothing of the host's may be released while the owner is unjoined.
            notes ← journalled (rigJournal rig)
            atomically (writeTVar released (Just (filter ended notes)))
        )
          `finally` atomically (writeTVar release True)
  withDeferredThreadOpening (atomically (writeTVar release True)) helper $ \_ handOver → do
    (raised, _) ← caughtAsUnless @IOException scenario $
      ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
        main ← myThreadId
        cut 0
        mask $ \restore → do
          handOver (owner, main)
          arm
          restore (cut 1 >> void (awaitRound owner 0)) `onException` atomically (writeTVar release True)
    show raised `shouldContain` "delivered during the join"
    readTVarIO released `shouldReturn` Just []
    notes ← journalled (rigJournal rig)
    notes `shouldContain` [SessionEnded]
  where
    ended = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False
