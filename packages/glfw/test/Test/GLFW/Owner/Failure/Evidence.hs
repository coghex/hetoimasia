-- | Failure evidence and retention: a failed startup drains through the same
-- retirement, a failure is published and closes admission as soon as it is
-- latched, and every failed operation, refused notice and unverified
-- destruction is retained rather than disposed of.
module Test.GLFW.Owner.Failure.Evidence (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM
  ( stateTVar
  , atomically
  , check
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (finally, mask, mask_, throwIO, uninterruptibleMask_)
import Control.Monad (forM_, void, when)
import Data.IORef (newIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Component, unsafeComponent)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..))
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.Foundation.Worker (awaitStopRequest, workerDefinition)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , SupervisedStart (..)
  , WorkerPolicy (..)
  , checkRuntime
  , startSupervised
  )
import Test.GLFW.Owner.Fixture.Drive
  ( awaitDiagnostic
  , awaitRound
  , awaitStanding
  , awaitTerminal
  , describeHandover
  , describeStart
  , awaitConstructed
  , handedOver
  , rescuePublishing
  , trackedHandedOver
  , observed
  , pumpUntilRetired
  , sampledObservation
  , theWindow
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scene (..), Scripted (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig
  ( Rig (..)
  , countingClock
  , newRig
  , newRigWith
  , armedBody
  , armedFinally
  , ownedHostBeforeBody
  , ownedHost
  , ownedHostWith
  , ownerSettings
  )
import Test.GLFW.Support
  ( boundedExample
  , caughtAs
  , caughtAsUnless
  , newSinkTrace
  , sinkFailingOn
  , traced
  , unexpected
  , windowNamed
  )
import Test.Hspec (Spec, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)
import Test.GLFW.Support (Ending (..), Scope, cutExamples, ownedEnds, withDeferredThread, withDeferredThreadVia)
import Data.Foldable (for_)
import Test.Support.Owned (withOwnedThreadOpening)

spec ∷ Spec
spec = do
  it "drains a failed startup through the same retirement, and says startup never returned"
    (boundedExample testFailedStartup)
  it "preserves a failure raised before application supervision exists, and delivers it at the first checkpoint"
    (boundedExample testFailureBeforeSupervision)
  it "publishes a fatal failure to application checkpoints while retirement is still pending"
    (boundedExample testEarlyFatalWhileRetiring)
  it "retains an unexpected completion without retirement evidence, and disposes nothing on it"
    (boundedExample testCompletionWithoutEvidence)
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    it ("finishes the exit on the supplier's evidence when the example body " <> label <> " right after the supplier was handed its host (#593)") $
      boundedExample (ownedEnds ending completionEndedEarlyScenario False)
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    it ("finishes the exit when the example body " <> label <> " during the run's startup, before the rescue is registered (#593)") $
      boundedExample (ownedEnds ending completionStartupScenario False)
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    for_ [-1 .. 2] $ \k →
      it ("finishes the exit on the supplier's evidence when the example body " <> label <> " at setup step " <> show k <> " of the completion fixture (#593)") $
        boundedExample (ownedEnds ending (completionSetupScenario k) False)
  cutExamples "the early fatal failure fixture" [0, 1] earlyFatalScenario
  cutExamples "the required failure fixture" [0, 1] requiredFailureEndedEarlyScenario
  cutExamples "the quiescence fixture" [0, 1] quiescenceScenario
  cutExamples "the failing retirement fixture" [0, 1, 2] retirementFailsOnceScenario
  cutExamples "the every-failure fixture" [0, 1, 2] everyFailureScenario
  it "retains terminal facts the completion publisher refused, and transports them at the next opportunity"
    (boundedExample testRefusedNoticeRetained)
  it "closes the owner's admission and begins its retirement as soon as a required failure is latched"
    (boundedExample testRequiredFailureClosesAdmission)
  it "retains the windows, the session and every parent when whole-owner destruction fails, with no target at all"
    (boundedExample testUnverifiedDestructionRetains)
  it "refuses every publication into the handoff once the owner has quiesced"
    (boundedExample testPublicationsClosedAtExit)
  it "refuses every publication at the application's pre-drain quiescence, while a worker drains and the owner is held"
    (boundedExample testPublicationsClosedAtQuiescence)
  it "refuses every one of them as soon as the owner's own run has failed"
    (boundedExample testPublicationsClosedOnFailure)
  it "reports a whole-owner retirement that failed even though the destruction after it did not"
    (boundedExample testDrainFailureSurfaces)
  it "retains every failed operation, and offers a failed target retirement exactly once"
    (boundedExample testRetirementFailsOnce)
  it "keeps every one of them when more targets fail than an arbitrary cap would hold"
    (boundedExample testEveryRetirementFailureRetained)

-- | A startup that failed enters the same drain, and the drain is told.
testFailedStartup ∷ IO ()
testFailedStartup = do
  rig ← newRig
  script (fakeStart (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "startup")))
  observedTerminal ← newTVarIO noOwnerTerminal
  -- The owner's disposition is required, so its startup failure is terminal
  -- and the run reports it. That it was /drained/ first is what this asserts.
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      held ← atomically $ do
        terminal ← readOwnerTerminalNow owner
        check (ownerRunEnded terminal)
        pure terminal
      atomically (writeTVar observedTerminal held)
  raised `shouldBe` Scripted (Text.pack "startup")
  requests ← readTVarIO (fakeOwnerRetirements (rigFake rig))
  map retiringStarted requests `shouldBe` [False]
  terminal ← readTVarIO observedTerminal
  ownerDestroyedEvidence terminal `shouldBe` Just (Text.pack "destroyed")
  notes ← journalled (rigJournal rig)
  ordered notes [OwnerStartup, OwnerRetirement, OwnerDestruction]

-- | A failure raised before the application has any supervision is kept, and
-- the sentinel delivers it as soon as it is registered.
testFailureBeforeSupervision ∷ IO ()
testFailureBeforeSupervision = do
  rig ← newRig
  script (fakeStart (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "before supervision")))
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner control → do
      -- The owner has already failed: its startup ran inside the managed
      -- construction, before the application's own startup callback.
      atomically (readOwnerFailure owner >>= check . isJust)
      _ ← superviseGraphicsOwner control owner
      checkRuntime control
  raised `shouldBe` Scripted (Text.pack "before supervision")

-- | A fatal owner failure reaches an application checkpoint while the owner is
-- still retiring.
testEarlyFatalWhileRetiring ∷ IO ()
testEarlyFatalWhileRetiring = earlyFatalWhileRetiring False (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the gated retirement is armed, or after it and the release of its gate are registered.
earlyFatalScenario ∷ Int → Scope → IO () → IO ()
earlyFatalScenario cutAt _ atParked = earlyFatalWhileRetiring True (\armedNow → when (armedNow == cutAt) atParked)

earlyFatalWhileRetiring ∷ Bool → (Int → IO ()) → IO ()
earlyFatalWhileRetiring scenario cut = do
  rig ← newRig
  release ← newTVarIO False
  failing ← newTVarIO False
  retiring ← newEmptyMVar
  -- The step fails only once the example says so, so the sentinel is
  -- certainly registered before the failure it must deliver exists.
  script (fakeStep (rigFake rig)) $ \_ →
    readTVarIO failing >>= \doomed →
      if doomed then throwIO (Scripted (Text.pack "fatal step")) else pure noStepWork
  -- Its whole-owner retirement is held open across the checkpoint below; held only from the body's first masked step, after the
  -- release of its gate is registered (#593).
  let arm = script (fakeRetireOwner (rigFake rig)) $ \_ → do
        putMVar retiring ()
        atomically (readTVar release >>= check)
        pure (ownerRetired (Text.pack "retired after the checkpoint"))
  observedPhase ← newTVarIO OwnerStarting
  (raised, _) ← caughtAsUnless scenario $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner control →
      -- However this body leaves, the held retirement is released, so a path
      -- the example did not intend fails it rather than hanging it.
      armedFinally cut arm (atomically (writeTVar release True)) $ do
        started ← superviseGraphicsOwner control owner
        case started of
          WorkerStarted _ → pure ()
          other → unexpected ("the sentinel did not start: " <> describeStart other)
        atomically (writeTVar failing True)
        -- Immediate demand wakes the idle owner into the step that fails.
        demand ← prepare (OwnerDemand True Nothing)
        _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
        takeMVar retiring
        status ← atomically (readOwnerStatusNow owner)
        atomically (writeTVar observedPhase (statusPhase status))
        -- Retirement is deliberately unfinished, and the checkpoint still
        -- raises.
        checkRuntime control
  raised `shouldBe` Scripted (Text.pack "fatal step")
  readTVarIO observedPhase `shouldReturn` OwnerRetiring

-- | An owner that ended without retirement evidence retains its dependencies,
-- and its completion is never permission to dispose them.
testCompletionWithoutEvidence ∷ IO ()
testCompletionWithoutEvidence = completionWithoutEvidence withOwnedThreadOpening (pure ()) Nothing

-- | The scenario of 'testCompletionWithoutEvidence' for an example that fails or is cancelled right after the supplier has been
-- handed what it publishes with (#593): the body ends the way the ending says, and the exit's drain must still finish on the
-- evidence the supplier publishes, which the exit waits for before the scope around the host could stop the supplier.
completionEndedEarlyScenario ∷ Scope → IO () → IO ()
completionEndedEarlyScenario scope atParked = completionWithoutEvidence scope (pure ()) (Just (\i → when (i == 2) atParked))

-- | The same fixture ended during the run's startup (#593): after the host is built and before the body's first statement, the
-- interval in which the rescue is not yet registered. Nothing the backend is asked for fails until the body arms it, so the exit
-- has nothing to wait for.
completionStartupScenario ∷ Scope → IO () → IO ()
completionStartupScenario scope atParked = completionWithoutEvidence scope atParked (Just (\_ → pure ()))

-- | The same fixture ended at the boundary before setup step @k@ (#593): -1 is the body's first statement, with the owner created
-- and the rescue not yet registered (the backend's failing behaviour is armed only by the registration step, so there is nothing
-- for the exit to wait for), 0 is the first statement after the registration (the host exists), 1 follows the
-- window lookup, 2 follows the target handover and the supplier's hand-over, which are one uninterruptible step (an attachment
-- never exists without the supplier holding what it publishes with). Between any two steps the fixture is partially built.
completionSetupScenario ∷ Int → Scope → IO () → IO ()
completionSetupScenario k scope atParked = completionWithoutEvidence scope (pure ()) (Just (\i → when (i == k) atParked))

completionWithoutEvidence ∷ Scope → IO () → Maybe (Int → IO ()) → IO ()
completionWithoutEvidence scope beforeBody endEarly = do
  rig ← newRig
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  -- Nothing the backend is asked for succeeds once it holds a target, so the
  -- owner ends with no record for it and no destruction evidence of its own.
  -- The step fails only after the target exists, so the handover below is the
  -- ordinary one rather than a race with the owner's own admission closing.
  --
  -- The failing behaviour is armed only inside the body's first masked step, after the rescue has been registered (the supplier
  -- handed what it needs, the end of the body announced) (#593): until then the backend behaves, so a cancellation before the
  -- body begins leaves an exit with nothing to wait for.
  let arm = do
        script (fakeStep (rigFake rig)) $ \step →
          if null (stepTargets step) then pure noStepWork else throwIO (Scripted (Text.pack "step"))
        script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
        script (fakeRetireOwner (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire owner")))
        script (fakeDestroy (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "destroy")))
  -- The thread supplies the independent evidence that lets the exit finish, so it is owned by the example and outlives the host
  -- body (#593). The fixture's destroy always fails, so even an exit with no attachment waits for the owner's destruction
  -- evidence: the supplier is handed the host and the owner as the very first step of the body, in the same masked step that
  -- arranges for the end of the body to be announced, and learns of the attachment's service through a cell the setup fills in
  -- the same uninterruptible step that creates it. Whatever way the body ends, the supplier therefore knows what exists.
  serviceCell ← newEmptyMVar
  bodyDone ← newEmptyMVar
  let supplier (host, owner) = do
        -- The exit begins once the body is over, however it ended.
        readMVar bodyDone
        tryReadMVar serviceCell >>= mapM_ (\service → do
          publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
          acknowledgement ←
            atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
              >>= maybe (unexpected "the attachment kept no acknowledgement") pure
          -- The attachment is still the main thread's and is only retiring once
          -- the exit's quiescence has begun it, so the facts are published into
          -- a model that can record them rather than refuse them.
          atomically (readGraphicsService service >>= check . (== SlotRetiring) . observedSlot)
          forM_ allRetirementFacts $ \fact →
            void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact)))
        -- Then the owner's own destruction, once the boundary is demonstrably
        -- retaining everything for the want of it: the attachment drain has
        -- finished and the exit has said, once, what it is retaining.
        atomically (check . null =<< hostPendingAttachments host)
        awaitDiagnostic trace
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "destroyed independently"))
      -- The target handover and the cell that tells the supplier of it are one uninterruptible step.
      establish host owner window =
        uninterruptibleMask_ (handedOver host owner window >>= \target → target <$ putMVar serviceCell target)
      guarded handOver host owner body = mask $ \restore → do
        handOver (host, owner)
        arm
        restore body `finally` void (tryPutMVar bodyDone ())
  withDeferredThreadVia scope (pure ()) supplier $ \_ handOver → case endEarly of
   Just step →
    ownedHostBeforeBody beforeBody recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      -- Step -1: the owner exists and the body has begun, but the rescue is not yet registered and nothing fails yet.
      step (-1)
      guarded handOver host owner $ do
        step 0
        window ← theWindow host
        step 1
        _ ← establish host owner window
        step 2
   Nothing → do
    (unverified, _) ← caughtAs @OwnerDestructionUnverified $
      ownedHostBeforeBody beforeBody recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control →
       guarded handOver host owner $ do
        window ← theWindow host
        service ← establish host owner window
        -- The owner's run has ended and it established nothing.
        atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
        records ← atomically (readTargetTerminalsNow owner)
        Map.keys records `shouldBe` []
        held ← atomically (readOwnerTargets owner)
        length held `shouldBe` 1
        -- The window's slot is still occupied and every fact is still owed: the
        -- worker's completion changed none of that.
        observation ← atomically (readGraphicsService service)
        observedMissing observation `shouldBe` allRetirementFacts
        pending ← atomically (hostPendingAttachments host)
        length pending `shouldBe` 1
        -- Independent evidence, from a thread that is not the main one, is the
        -- only thing that can retire any of this — the attachment's facts, and
        -- then the owner's own destruction. Without both, the boundary retains
        -- the window, the session and every parent for good, which is the whole
        -- point; with them, this example's exit can finish.
    unverifiedRetired unverified `shouldBe` False
    unverifiedTargets unverified `shouldBe` 1
    -- Said exactly once, whatever the wait then had to do.
    components ← traced trace
    length (filter (== Text.pack "glfw.graphics-owner") components) `shouldBe` 1

-- | A terminal fact the completion publisher could not carry stays owed, and
-- nothing loses it.
--
-- The host's completion inbox holds one notice per retirement fact per window
-- it may hold, so a host's own live attachments can never fill it between
-- them. What can is a notice naming an incarnation the slot has already moved
-- past: admission bounds capacity and coalescing only, and the model refuses
-- such a notice later, when the owner thread folds it. This example fills the
-- inbox exactly that way, so the owner's next publication really is refused.
testRefusedNoticeRetained ∷ IO ()
testRefusedNoticeRetained = do
  rig ← newRig
  clock ← countingClock
  -- One window, so the inbox holds exactly one notice per fact.
  let config = (ownerSettings clock) {hostWindowLimit = 1}
  (record, admissions) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    first ← handedOver host owner window
    -- Captured before the retirement below, because the owner forgets an
    -- acknowledgement as soon as its attachment has validated its facts.
    stale ←
      atomically (ownerTargetAcknowledgement owner (graphicsAttachment first))
        >>= maybe (unexpected "the first incarnation kept no acknowledgement") pure
    _ ← releaseGraphicsTarget host owner first
    _ ← awaitTerminal owner first
    pumpUntilRetired host _control
    second ← handedOver host owner window
    -- Fill the inbox with the retired incarnation's notices. Each is a
    -- distinct value, so none coalesces; each will be refused by the model
    -- when the owner thread folds it, and none establishes anything.
    publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
    admissions ← mapM (offer publisher (graphicsAttachment first) stale) allRetirementFacts
    -- The inbox is now full and nothing on the main thread is folding it, so
    -- every fact the owner establishes for the live incarnation is refused.
    _ ← releaseGraphicsTarget host owner second
    record ← awaitTerminal owner second
    pure (record, admissions)
  admissions `shouldBe` replicate (length allRetirementFacts) (CompletionOffered NoticeAdmitted)
  -- Refused, therefore still owed — and nothing was lost: the record accounts
  -- for every fact its own injected retirement established.
  terminalPublished record `shouldBe` []
  terminalOwed record `shouldBe` allRetirementFacts
  where
    offer publisher target acknowledgement fact =
      publishCompletion publisher (completionNotice target acknowledgement fact)

-- | A required failure closes the owner's admission and takes it into its
-- retirement at once, rather than waiting for the exit.
testRequiredFailureClosesAdmission ∷ IO ()
testRequiredFailureClosesAdmission = requiredFailureClosesAdmission False (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the failing step and the gated retirement are armed, or after they and the
-- release of the gate are registered.
requiredFailureEndedEarlyScenario ∷ Int → Scope → IO () → IO ()
requiredFailureEndedEarlyScenario cutAt _ atParked = requiredFailureClosesAdmission True (\armedNow → when (armedNow == cutAt) atParked)

requiredFailureClosesAdmission ∷ Bool → (Int → IO ()) → IO ()
requiredFailureClosesAdmission scenario cut = do
  rig ← newRig
  release ← newTVarIO False
  retiring ← newEmptyMVar
  observedRefusal ← newTVarIO Nothing
  observedPhase ← newTVarIO OwnerStarting
  -- Armed only inside the body's first masked step, in the same step that registers the release of the gate the retiring owner is
  -- held at (#593): nothing fails and nothing is held before the release that undoes it exists, and the release runs whether or
  -- not the body's assertions held, so a failed assertion is reported rather than leaving the exit waiting at the gate. The
  -- owner is woken into the step that now fails.
  let arm owner = do
        script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "fatal step")))
        script (fakeRetireOwner (rigFake rig)) $ \_ → do
          putMVar retiring ()
          atomically (readTVar release >>= check)
          pure (ownerRetired (Text.pack "retired"))
        demand ← prepare (OwnerDemand True Nothing)
        void (atomically (publishOwnerDemand (ownerHandoff owner) demand))
      run =
        ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control →
          armedFinally cut (arm owner) (atomically (writeTVar release True)) $ do
            window ← theWindow host
            takeMVar retiring
            -- The owner is already retiring and its admission is already closed, so
            -- a handover now leaves nothing attached at all.
            answer ← handOverGraphicsTarget host owner window
            pending ← atomically (hostPendingAttachments host)
            length pending `shouldBe` 0
            status ← atomically (readOwnerStatusNow owner)
            atomically $ do
              writeTVar observedRefusal (Just (describeHandover answer))
              writeTVar observedPhase (statusPhase status)
  (raised, _) ← caughtAsUnless scenario run
  raised `shouldBe` Scripted (Text.pack "fatal step")
  readTVarIO observedRefusal `shouldReturn` Just "owner closed"
  readTVarIO observedPhase `shouldReturn` OwnerRetiring

-- | Whole-owner destruction that produced no evidence retains everything the
-- owner borrowed, with no target involved at all.
testUnverifiedDestructionRetains ∷ IO ()
testUnverifiedDestructionRetains = do
  rig ← newRig
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  -- Armed in the body's first masked step, after the supplier has been handed the owner (#593).
  let arm = script (fakeDestroy (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "destroy")))
  releasedWhileRetained ← newTVarIO Nothing
  -- From another thread: wait until the exit has said, once, what it is retaining and why — which it does before it settles
  -- into the wait — then record what has been released, and only then supply the independent evidence that lets the boundary
  -- finish. That evidence is what ends the exit's wait, so the thread is owned by the example and outlives the host body that
  -- hands it the owner (#593).
  let supplier owner = do
        atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
        awaitDiagnostic trace
        notes ← journalled (rigJournal rig)
        atomically (writeTVar releasedWhileRetained (Just (filter released notes)))
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "destroyed independently"))
  withDeferredThread supplier $ \_ handOver → do
    (unverified, _) ← caughtAs @OwnerDestructionUnverified $
      ownedHostWith recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
        mask_ (handOver owner >> arm)
        _ ← awaitRound owner 0
        pure ()
    unverifiedRetired unverified `shouldBe` True
    unverifiedTargets unverified `shouldBe` 0
    -- Nothing of the host's was released while the evidence was missing.
    readTVarIO releasedWhileRetained `shouldReturn` Just []
    -- And it was released in the end, after the evidence existed.
    notes ← journalled (rigJournal rig)
    notes `shouldContain` [SessionEnded]
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- | Every publication into the handoff is refused once the owner has quiesced.
testPublicationsClosedAtExit ∷ IO ()
testPublicationsClosedAtExit = do
  rig ← newRig
  escaped ← newEmptyMVar
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    service ← handedOver host owner window
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pumpUntilRetired host control
    putMVar escaped (ownerHandoff owner)
  handoff ← takeMVar escaped
  demand ← prepare (OwnerDemand True Nothing)
  scene ← prepare (Scene 1)
  atomically (publishOwnerDemand handoff demand) `shouldReturn` PublicationClosed
  atomically (publishOwnerScene handoff scene) `shouldReturn` ScenePublication PublicationClosed
  atomically (targetEventsOpen handoff) `shouldReturn` False

-- | The application's own pre-drain quiescence closes every publication into
-- the handoff, before an ordinary worker is asked to stop, and without
-- waiting for the owner.
--
-- The owner is held inside a step from before the quiescence until after the
-- check, with a second target's ownership queued on its lifetime port, so
-- nothing the owner does could account for what the worker observes. The
-- worker is an ordinary supervised service, held in the supervision drain
-- while it looks: on the far side of the quiescence transaction and on this
-- side of every owner stop, retirement and join. Only once it has looked does
-- it let the owner go, and the exit then accounts for the queued ownership,
-- retires each target, destroys the owner and joins it, in D-33's order.
testPublicationsClosedAtQuiescence ∷ IO ()
testPublicationsClosedAtQuiescence = publicationsClosedAtQuiescence (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the owner is told to hold in its next step, or after it is told and the release
-- of the hold is registered.
quiescenceScenario ∷ Int → Scope → IO () → IO ()
quiescenceScenario cutAt _ atParked = publicationsClosedAtQuiescence (\armedNow → when (armedNow == cutAt) atParked)

publicationsClosedAtQuiescence ∷ (Int → IO ()) → IO ()
publicationsClosedAtQuiescence cut = do
  rig ← newRigWith id
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "first"), windowNamed (Text.pack "second")]
          }
  holding ← newTVarIO False
  held ← newTVarIO False
  released ← newTVarIO False
  stepped ← readTVarIO (fakeStep (rigFake rig))
  script (fakeStep (rigFake rig)) $ \step → do
    armed ← readTVarIO holding
    when armed $ do
      atomically (writeTVar held True)
      atomically (readTVar released >>= check)
    stepped step
  evidence ← newEmptyMVar
  escaped ← newEmptyMVar
  -- However the body ends, the exit's release is what ends the hold; a scenario's own ending propagates.
  ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner control → do
    windows ← atomically (hostWindowIdentities host)
    (first, second) ← case windows of
      [first, second] → pure (first, second)
      other → unexpected ("the host created " <> show (length other) <> " windows")
    service ← handedOver host owner first
    awaitConstructed rig (Text.pack (show first))
    -- The first target has a retained observation slot, which a fresh
    -- revision reaches now. A stale revision or an unknown target would be
    -- refused before any quiescence, so only a fresh one proves the slot
    -- itself closed.
    seen ← sampledObservation host first
    observed owner service 1 seen `shouldReturn` ObservationAccepted 1
    -- Hold the owner inside its next step: a scene publication asks for one.
    -- The hold is armed only inside a masked step that also registers its release (#593).
    armedBody cut (atomically (writeTVar holding True)) (atomically (writeTVar released True)) $ do
      _ ← atomically . publishOwnerScene (ownerHandoff owner) =<< prepare (Scene 1)
      atomically (readTVar held >>= check)
      -- The second target's ownership is queued, and the held owner cannot take
      -- it.
      _ ← handedOver host owner second
      putMVar escaped owner
      let watcher =
            workerDefinition
              (Text.pack "quiescence watcher")
              (\_ → pure ())
              ( \token () → do
                  atomically (awaitStopRequest token)
                  let handoff = ownerHandoff owner
                  demand ← prepare (OwnerDemand True Nothing)
                  scene ← prepare (Scene 2)
                  demanded ← atomically (publishOwnerDemand handoff demand)
                  published ← atomically (publishOwnerScene handoff scene)
                  slot ← observed owner service 2 seen
                  open ← atomically (targetEventsOpen handoff)
                  -- What the owner had done by the time every refusal was read:
                  -- still held in the step, never stopped or joined, and the
                  -- queued ownership untaken.
                  stillHeld ← not <$> readTVarIO released
                  running ← isNothing <$> atomically (Worker.pollCompletion (graphicsOwnerWorker owner))
                  notes ← journalled (rigJournal rig)
                  putMVar evidence (demanded, published, slot, open, stillHeld, running, notes)
                  atomically (writeTVar released True)
              )
      _ ← startSupervised control (WorkerPolicy Service Required ownerExampleComponent (\_ → pure Unrecognized)) watcher
      pure ()
  (demanded, published, slot, open, stillHeld, running, notesAtQuiescence) ← takeMVar evidence
  demanded `shouldBe` PublicationClosed
  published `shouldBe` ScenePublication PublicationClosed
  slot `shouldBe` ObservationSlotClosed
  open `shouldBe` False
  stillHeld `shouldBe` True
  running `shouldBe` True
  notesAtQuiescence `shouldSatisfy` all (`notElem` [Constructed (Text.pack "WindowId 2"), OwnerRetirement, OwnerDestruction])
  notesAtQuiescence `shouldSatisfy` all (not . retiring)
  -- Released, the owner accounts for the ownership that stayed queued, retires
  -- each target, and is destroyed and joined before any window is released.
  owner ← takeMVar escaped
  (isJust <$> atomically (Worker.pollCompletion (graphicsOwnerWorker owner))) `shouldReturn` True
  notes ← journalled (rigJournal rig)
  ordered
    notes
    [ Constructed (Text.pack "WindowId 1")
    , TargetRetirement (Text.pack "WindowId 1")
    , TargetRetirement (Text.pack "WindowId 2")
    , OwnerRetirement
    , OwnerDestruction
    , WindowGone 2
    , WindowGone 1
    , SessionEnded
    ]
  where
    retiring = \case
      TargetRetirement _ → True
      _ → False

ownerExampleComponent ∷ Component
ownerExampleComponent = unsafeComponent "test.graphics-owner"

-- | An owner whose run has failed refuses every publication, not only the
-- lifetime port: it reads none of them again.
testPublicationsClosedOnFailure ∷ IO ()
testPublicationsClosedOnFailure = do
  rig ← newRig
  escaped ← newEmptyMVar
  script (fakeStep (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "fatal step")))
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      atomically (readOwnerFailure owner >>= check . isJust)
      -- The owner has failed and is retiring; the host has not quiesced and
      -- the run has not ended. Every endpoint must already refuse.
      let handoff = ownerHandoff owner
      demand ← prepare (OwnerDemand True Nothing)
      scene ← prepare (Scene 2)
      atomically (publishOwnerDemand handoff demand) `shouldReturn` PublicationClosed
      atomically (publishOwnerScene handoff scene) `shouldReturn` ScenePublication PublicationClosed
      atomically (targetEventsOpen handoff) `shouldReturn` False
      putMVar escaped ()
  raised `shouldBe` Scripted (Text.pack "fatal step")
  takeMVar escaped

-- | A whole-owner retirement that failed is reported even when the
-- destruction after it succeeded.
--
-- Nothing else records it: the destruction evidence exists, so the exit's
-- wait is satisfied and writes no diagnostic, and the failure was the
-- /drain's/ rather than the run's, so no latch holds it. The joined worker's
-- own outcome is the only place it lives.
testDrainFailureSurfaces ∷ IO ()
testDrainFailureSurfaces = do
  rig ← newRig
  script (fakeRetireOwner (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire owner")))
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control →
      void (awaitRound owner 0)
  raised `shouldBe` Scripted (Text.pack "retire owner")
  terminal ← readTVarIO (rigJournal rig)
  -- The destruction after it still ran, and still established its evidence,
  -- so nothing was retained for want of it.
  terminal `shouldContain` [OwnerDestruction]

-- | A failed target retirement is retained, marked unverified, and never
-- offered again — not by a later round, and not by the drain.
testRetirementFailsOnce ∷ IO ()
testRetirementFailsOnce = retirementFailsOnce False (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the failing retirement is armed, or after it and the rescue that publishes the
-- evidence its exit waits for are registered.
retirementFailsOnceScenario ∷ Int → Scope → IO () → IO ()
retirementFailsOnceScenario cutAt _ atParked = retirementFailsOnce True (\armedNow → when (armedNow == cutAt) atParked)

retirementFailsOnce ∷ Bool → (Int → IO ()) → IO ()
retirementFailsOnce scenario cut = do
  rig ← newRig
  attempts ← newTVarIO (0 ∷ Int)
  tracked ← newIORef []
  -- Fails the first time and would succeed on any replay, so a replay is
  -- visible as a target that retired after all. Armed only inside the body's first masked step, which also registers the
  -- rescue that publishes the independent evidence this example's exit waits for (#593).
  let arm = script (fakeRetireTarget (rigFake rig)) $ \retire → do
        seen ← atomically (stateTVar attempts (\n → (n, n + 1)))
        if seen == 0
          then throwIO (Scripted (Text.pack "retire target"))
          else pure (targetRetired (Text.pack (show (retiringWindow retire))))
  observedFailures ← newTVarIO 0
  observedTargets ← newTVarIO []
  (raised, _) ← caughtAsUnless scenario $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → armedBody cut arm (rescuePublishing tracked host owner) $ do
      window ← theWindow host
      service ← trackedHandedOver tracked host owner window
      cut 2
      awaitStanding owner service `shouldReturn` TargetUsable
      _ ← releaseGraphicsTarget host owner service
      -- The failure is latched and retained; the target stays, unverified.
      atomically (readOwnerFailure owner >>= check . isJust)
      atomically $ do
        held ← readOwnerTargets owner
        check (graphicsAttachment service `elem` held)
      -- Turns and rounds go by, and nothing offers the operation again.
      _ ← awaitRound owner 2
      atomically . writeTVar observedFailures . length =<< atomically (readOwnerFailures owner)
      atomically . writeTVar observedTargets =<< atomically (readOwnerTargets owner)
      -- Independent evidence is the only thing that retires it, which is what
      -- lets this example's own exit finish.
      publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
      acknowledgement ←
        atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
          >>= maybe (unexpected "the attachment kept no acknowledgement") pure
      forM_ allRetirementFacts $ \fact →
        void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
      pumpUntilRetired host control
  raised `shouldBe` Scripted (Text.pack "retire target")
  -- Offered exactly once, over the whole run and its drain.
  readTVarIO attempts `shouldReturn` 1
  -- And the failure is evidence, not only a latch.
  readTVarIO observedFailures `shouldReturn` 1
  readTVarIO observedTargets >>= \held → length held `shouldBe` 1
  -- No terminal record was manufactured for it.
  records ← readTVarIO (rigJournal rig)
  length [() | TargetRetirement _ ← records] `shouldBe` 1

-- | Every failed target retirement is retained, not the first few.
--
-- A host of this size can offer more retirements in one round than any
-- arbitrary cap would keep, and each failure is evidence the contract says
-- stays readable.
testEveryRetirementFailureRetained ∷ IO ()
testEveryRetirementFailureRetained = everyRetirementFailureRetained False (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the failing retirement is armed, or after it and the rescue are registered.
everyFailureScenario ∷ Int → Scope → IO () → IO ()
everyFailureScenario cutAt _ atParked = everyRetirementFailureRetained True (\armedNow → when (armedNow == cutAt) atParked)

everyRetirementFailureRetained ∷ Bool → (Int → IO ()) → IO ()
everyRetirementFailureRetained scenario cut = do
  rig ← newRig
  tracked ← newIORef []
  clock ← countingClock
  let windows = [windowNamed (Text.pack ("window " <> show n)) | n ← [1 ∷ Int .. 12]]
      config = (ownerSettings clock) {hostWindowConfigs = windows, hostWindowLimit = 12}
  let arm = script (fakeRetireTarget (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "retire target")))
  keptCount ← newTVarIO 0
  (raised, _) ← caughtAsUnless scenario $
    ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner control → armedBody cut arm (rescuePublishing tracked host owner) $ do
      identities ← atomically (hostWindowIdentities host)
      services ← mapM (trackedHandedOver tracked host owner) identities
      cut 2
      forM_ services (awaitStanding owner)
      forM_ services (releaseGraphicsTarget host owner)
      -- Every one of them fails its retirement, and every failure is kept.
      atomically $ do
        kept ← readOwnerFailures owner
        check (length kept >= length services)
      atomically . writeTVar keptCount . length =<< atomically (readOwnerFailures owner)
      -- Independent evidence lets this example's own exit finish.
      publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
      forM_ services $ \service → do
        acknowledgement ←
          atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
            >>= maybe (unexpected "the attachment kept no acknowledgement") pure
        forM_ allRetirementFacts $ \fact →
          void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
      pumpUntilRetired host control
  raised `shouldBe` Scripted (Text.pack "retire target")
  -- Twelve, which is more than the cap this used to have.
  readTVarIO keptCount >>= \kept → kept `shouldSatisfy` (>= 12)
  -- And the bound is the configuration's, not a number chosen here.
  retainedFailureBound 12 `shouldSatisfy` (>= 12)
