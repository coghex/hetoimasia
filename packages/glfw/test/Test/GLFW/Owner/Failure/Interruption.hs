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
import Test.GLFW.Owner.Fixture.Rig (Rig (..), newRig, ownedHost, ownedHostCaught, ownedHostCaughtHooked, ownedHostHooked)
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
    for_
      [ (AfterHandover, "immediately after the attachment was created, before the harassment begins")
      , (BetweenAdmissionAndDelivery, "after the harasser was admitted and committed to its throw and before the throw")
      , (AfterHarassment, "after the harassment started and before the body supplies the completion evidence")
      ]
      $ \(position, where') → do
        it ("ends and joins the harasser, offers the retirement once and terminates the owner when the example body " <> label <> " " <> where' <> " (#612)") $
          boundedExample (ownedEnds ending (retirementRecordScenario position) False)
        it ("negative control: an unowned harasser outlives the example whose body " <> label <> " " <> where' <> " (#612)") $
          boundedExample (unownedLeaks ending (retirementRecordScenario position) False)
    it ("ends and joins the deliverer, offers the retirement once and terminates the owner when the example body " <> label <> " after the attachment was created, before the deliverer is released (#612)") $
      boundedExample (ownedEnds ending interruptedScenario False)
    it ("negative control: an unowned deliverer outlives the example whose body " <> label <> " after the attachment was created (#612)") $
      boundedExample (unownedLeaks ending interruptedScenario False)
  it "commits every injected operation's answer with no interruption point after it"
    (boundedExample testOperationAnswersCommitUninterrupted)
  it "waits for a terminal group report however the join is interrupted"
    (boundedExample testJoinAwaitsTerminalReport)
  cutExamples "the join fixture" [0, 1] joinScenario
  it "leaves a target whose retirement call a cancellation interrupted retained as unverified, with no record, and still finishes (#612)"
    (boundedExample testRetirementInterruptedInsideItsCall)

-- | A target retirement that returned is recorded, whatever is delivered to
-- the owner as it returns — so it is never offered a second time.
--
-- The call itself stays interruptible, and a cancellation inside it leaves
-- the target explicitly unverified and the operation spent. What must not
-- happen is a cancellation between the answer and the record of it: the
-- target would be neither retired nor marked, and the drain would offer the
-- operation again, disposing a second time what the backend already disposed.
testRetirementRecordSurvivesCancellation ∷ IO ()
testRetirementRecordSurvivesCancellation = retirementRecord withOwnedThreadOpening Never (pure ())

-- | The same fixture ended at one of the states of the harassment (#612). The run is not asserted to raise the injected ending here:
-- the ending's judgement does that. What is asserted is what must hold whatever raised: the retirement was offered exactly once, the
-- owner was destroyed and the session ended, and the harasser (alive and parked in every one of them) was stopped and joined by its
-- scope.
retirementRecordScenario ∷ EndsAt → Scope → IO () → IO ()
retirementRecordScenario position scope atParked = retirementRecord scope position atParked

-- | Where a scenario ends the example's body.
data EndsAt
  = -- | The full example: nowhere.
    Never
  | -- | Immediately after the attachment was created and registered, before anything of the harassment exists.
    AfterHandover
  | -- | After the harasser was admitted and committed to its throw, and before the throw: the state nothing used to record.
    BetweenAdmissionAndDelivery
  | -- | After the harasser's cancellation was received and before the body supplies the completion evidence.
    AfterHarassment
  deriving (Eq)

-- | The example. The harasser is an owned start of the first argument; at 'BetweenAdmissionAndDelivery' it is held between its
-- commitment and its throw, and at that state and at 'AfterHarassment' it parks after its throw until the scope releases it. The
-- third argument is where a scenario ends the body (at 'Never' it is not called).
--
-- = The harasser's phase, and the harassment windows
--
-- One transaction decides whether the harasser may act: it admits only if the retirement has returned and the body has not
-- abandoned the run, and in the same transaction it records that it is __committed__ (phase 1). Delivery is phase 2. Abandonment
-- cannot recall a commitment, so the owner's later calls wait for @delivered ∨ (abandoned ∧ never committed)@: a throw that was decided
-- before the abandonment is still delivered before they can leave, and one that was never decided never is.
--
-- * __The handover__ (the attachment's creation). The body's step creates and registers the attachment masked; the rescue
--   (@onException@) is installed in the same masked step, before the attachment exists. The harasser has not started: it waits for the
--   retirement to return. A scenario ends the body immediately after the registration.
-- * __The target's retirement call.__ Nothing is masked: the call stays interruptible. No cancellation lands here: the harasser waits
--   for the host hook that runs after the call returned. One that landed here would leave no record, which is its own example
--   ('testRetirementInterruptedInsideItsCall').
-- * __Committed, not delivered.__ The retirement returned and the harasser is admitted, held at its throw. A scenario ends the body
--   here; the rescue opens the throw's gate with the abandonment, so the throw is made, and the owner's later calls wait for it.
-- * __Answer to record.__ The owner is masked until the record commits. The harasser's one cancellation is pending against a masked
--   owner and cannot interrupt the commit.
-- * __Whole-owner retirement.__ An interruptible call. The cancellation may be received at its start (survivable: the destruction is
--   still offered) or in its wait, which absorbs it; the call returns only once the harassment is delivered.
-- * __Destruction.__ An interruptible call, entered only after the whole-owner retirement returned, so after delivery: none is left to
--   arrive, and an interrupted destruction (unverified; the exit would wait for evidence for ever) cannot happen.
--
-- Under @-N2@ the harasser runs beside the owner. The version of this example that sent twenty cancellations from the instant the
-- retirement call was entered hung 8 times in 204 runs there (in the two captured, the journal ended with @OwnerRetirement@ and no
-- @OwnerDestruction@): a cancellation pending against a masked owner is received at the next point it is unmasked, which for a stream
-- of them is the start of each backend call in turn, so one reached the destruction. Production was right to wait.
retirementRecord ∷ Scope → EndsAt → IO () → IO ()
retirementRecord scope position atParked = do
  let held = position == AfterHarassment || position == BetweenAdmissionAndDelivery
  rig ← newRig
  returned ← newTVarIO False
  -- 0: not admitted, 1: admitted and committed to its throw, 2: delivered.
  phase ← newTVarIO (0 ∷ Int)
  abandoned ← newTVarIO False
  throwGate ← newTVarIO (position /= BetweenAdmissionAndDelivery)
  release ← newTVarIO (not held)
  recorded ← newTVarIO []
  absorbed ← newTVarIO (0 ∷ Int)
  tracked ← newIORef []
  -- How often the backend was asked to retire the target, counted by the fake at the call's entry, before anything a cancellation
  -- could interrupt in the call itself.
  let offers = length <$> readTVarIO (fakeRetirements (rigFake rig))
  -- After an operation has returned and before its answer is committed, on the owner's thread and masked, and only to be looked from.
  -- The first one after the retirement call was entered is that call's return: the owner does one thing at a time.
  let hooks =
        Private.noHostHooks
          { Private.afterOwnerOperation = do
              entered ← not . null <$> readTVarIO (fakeRetirements (rigFake rig))
              when entered (atomically (writeTVar returned True))
          }
  -- The owner's later calls wait until the harassment is delivered, or was never decided, and absorb what is still delivered meanwhile.
  let afterHarassment = absorbing absorbed . atomically $ do
        begun ← readTVar returned
        when begun $ do
          reached ← readTVar phase
          gone ← readTVar abandoned
          check (reached == 2 || (gone && reached == 0))
  script (fakeRetireOwner (rigFake rig)) $ \_ → afterHarassment >> pure (ownerRetired (Text.pack "retired"))
  script (fakeDestroy (rigFake rig)) $ \_ → afterHarassment >> pure (ownerDestroyed (Text.pack "destroyed"))
  let harry = do
        -- Admission and commitment are one step; the body's abandonment cannot slip between them.
        atomically $ do
          r ← readTVar returned
          gone ← readTVar abandoned
          check (r && not gone)
          writeTVar phase 1
        atomically (readTVar throwGate >>= check)
        ownerThread ← atomically $
          readTVar (fakeThreads (rigFake rig)) >>= \case
            thread : _ → pure thread
            [] → retry
        ( do
            throwTo ownerThread ThreadKilled
            atomically (writeTVar phase 2)
            atomically (readTVar release >>= check)
          )
          `finally` atomically (writeTVar phase 2)
      letGo = atomically (writeTVar release True)
  -- Owned by the example and not by the host body: the owner's later calls wait for it, and the scope lets it go on whatever ended the
  -- example (#612).
  scope letGo harry $ \_ _ → do
    outcome ← ownedHostCaughtHooked hooks (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control →
      -- The rescue is installed in the masked step that also creates and registers the attachment, before any of it exists: a
      -- cancellation pending when the handover returns finds the handler. It publishes the completion evidence the exit waits for,
      -- records the abandonment and opens the throw's gate in one step, so a harasser that is committed makes its throw and one that is
      -- not never will. The harasser itself is not let go by it: it is the scope's to stop and join.
      mask $ \restore →
        ( restore $ do
            window ← theWindow host
            service ← trackedHandedOver tracked host owner window
            when (position == AfterHandover) atParked
            awaitStanding owner service `shouldReturn` TargetUsable
            _ ← releaseGraphicsTarget host owner service
            when (position == BetweenAdmissionAndDelivery) $ do
              atomically (readTVar phase >>= check . (>= 1))
              atParked
            when (position == AfterHarassment) $ do
              atomically (readTVar phase >>= check . (>= 2))
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
        )
          `onException` ( atomically (writeTVar abandoned True >> writeTVar throwGate True)
                            >> rescuePublishing tracked host owner
                        )
    -- Offered exactly once, over the whole run and its drain, however many
    -- cancellations arrived and however the example ended.
    offers `shouldReturn` 1
    if position /= Never
      then do
        -- Ended by the scenario: the owner was destroyed and the session torn down, and the ending is the run's own, raised as itself
        -- for the ending's judgement. (The whole-owner retirement may have been the call the cancellation interrupted.)
        notes ← journalled (rigJournal rig)
        ordered notes [OwnerDestruction, SessionEnded]
        either throwIO (\() → unexpected "the ended run returned") outcome
      else do
        -- However it ended, it ended by raising the cancellation rather than
        -- swallowing it.
        void (raisedBy outcome)
        -- And because it returned, its record exists: a retirement the owner
        -- performed is never one the owner then forgets, and never one the drain
        -- performs a second time.
        readTVarIO recorded >>= \terminals → length terminals `shouldBe` 1

-- | The scenario of 'interruptedInsideItsCall': the body ends after the attachment was created, before the deliverer is released.
interruptedScenario ∷ Scope → IO () → IO ()
interruptedScenario scope atParked = interruptedInsideItsCall scope True atParked

-- | A cancellation that lands inside the target's retirement call, which stays interruptible, leaves the call spent and the target
-- retained explicitly as unverified, with no record; the operation is not offered again, the owner is destroyed, and the exit finishes
-- on the independent evidence for the attachment (#612). It is the outcome 'testRetirementRecordSurvivesCancellation' excludes by
-- sending its cancellation only after the call returned, so it is covered here, on its own, and deterministically: the call parks, the
-- one cancellation is delivered into it, and nothing else is delivered. The call parks at a gate nothing opens but the cancellation,
-- and the deliverer that sends it waits to be released by the body; the rescue that releases it is installed with the attachment, so a
-- body that ends before it would have released it releases it on the way out, and the drain's retirement of the target is interrupted
-- all the same.
testRetirementInterruptedInsideItsCall ∷ IO ()
testRetirementInterruptedInsideItsCall = interruptedInsideItsCall withOwnedThreadOpening False (pure ())

interruptedInsideItsCall ∷ Scope → Bool → IO () → IO ()
interruptedInsideItsCall scope scenario atParked = do
  rig ← newRig
  inside ← newTVarIO False
  never ← newTVarIO False
  tracked ← newIORef []
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    atomically (writeTVar inside True)
    atomically (readTVar never >>= check)
    pure (targetRetired (Text.pack (show (retiringWindow retire))))
  released ← newTVarIO False
  held ← newTVarIO scenario
  let deliver = do
        atomically (readTVar released >>= check)
        atomically (readTVar inside >>= check)
        ownerThread ← atomically $
          readTVar (fakeThreads (rigFake rig)) >>= \case
            thread : _ → pure thread
            [] → retry
        throwTo ownerThread ThreadKilled
        -- Parked after its throw in a scenario, so that it is certainly alive when the body ends; the scope lets it go.
        atomically (readTVar held >>= check . not)
      letGo = atomically (writeTVar held False)
      -- Opens what the deliverer waits for: the body's hand-over.
      handOver = atomically (writeTVar released True)
  retainedUnverified ← newTVarIO (0 ∷ Int)
  terminals ← newTVarIO (0 ∷ Int)
  scope letGo deliver $ \_ _ → do
    outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control →
      mask $ \restore →
        ( restore $ do
            window ← theWindow host
            service ← trackedHandedOver tracked host owner window
            when scenario atParked
            awaitStanding owner service `shouldReturn` TargetUsable
            handOver
            _ ← releaseGraphicsTarget host owner service
            atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
            publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
            acknowledgement ←
              atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
                >>= maybe (unexpected "the attachment kept no acknowledgement") pure
            forM_ allRetirementFacts $ \fact →
              void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
            pumpUntilRetired host control
            atomically . writeTVar terminals . Map.size =<< atomically (readTargetTerminalsNow owner)
            atomically . writeTVar retainedUnverified . length =<< atomically (readOwnerTargets owner)
        )
          `onException` (handOver >> rescuePublishing tracked host owner)
    -- Spent: offered once and not again, and the owner went on to retire and destroy itself.
    length <$> readTVarIO (fakeRetirements (rigFake rig)) `shouldReturn` 1
    notes ← journalled (rigJournal rig)
    ordered notes [OwnerRetirement, OwnerDestruction, SessionEnded]
    if scenario
      then either throwIO (\() → unexpected "the ended run returned") outcome
      else do
        -- Retained, not recorded.
        void (either (const (pure ())) pure outcome)
        readTVarIO terminals `shouldReturn` 0
        readTVarIO retainedUnverified `shouldReturn` 1

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
