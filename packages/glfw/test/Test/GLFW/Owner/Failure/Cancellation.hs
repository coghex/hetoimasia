-- | Cancellation inside each backend call: one the call absorbs releases
-- nothing early, and one that escapes it leaves the owner settling, retiring
-- or retaining exactly what that call may have left behind.
module Test.GLFW.Owner.Failure.Cancellation (spec) where

import Control.Concurrent.STM
  ( TVar
  , atomically
  , check
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (AsyncException (ThreadKilled), SomeException, mask_, throwTo, uninterruptibleMask_)
import Control.Monad (forM_, join, unless, void, when)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Runtime.GLFW
import Test.GLFW.Owner.Fixture.Drive
  ( absorbing
  , awaitDiagnostic
  , awaitStanding
  , awaitTerminal
  , handedOver
  , pumpUntilRetired
  , theWindow
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig (Rig (..), armedBody, newRig, ownedHost, ownedHostBeforeBody, publishAllFor)
import Test.GLFW.Support
  ( boundedExample
  , caughtAs
  , newSinkTrace
  , sinkFailingOn
  , unexpected
  )
import Test.Hspec (Spec, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.GLFW.Support (Ending (..), Scope, exitFinishes, ownedEnds, withDeferredThreadVia)
import Test.Support.Owned (withOwnedThread, withOwnedThreadOpening)
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)

spec ∷ Spec
spec = do
  it "honours a cancellation inside construction, target retirement and destruction alike"
    (boundedExample testCancellationAtEachBackendCall)
  it "settles a construction the cancellation escaped as unverified, and retires it in order"
    (boundedExample testEscapedConstructionCancellation)
  it "manufactures no evidence for a target retirement the cancellation escaped, and offers it once"
    (boundedExample testEscapedRetirementCancellation)
  it "retains everything until independent evidence when the cancellation escaped the destruction"
    (boundedExample testEscapedDestructionCancellation)
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    for_ [("before the scripted backend behaviour is armed", 0 ∷ Int), ("after it is armed and its release registered", 1), ("after the first attachment exists", 2)] $ \(where', cutAt) → do
      it ("finishes the exit when the example body " <> label <> " " <> where' <> ", at each backend call (#593)") $
        boundedExample (exitFinishes ending (backendCallScenario cutAt))
      it ("finishes the exit when the example body " <> label <> " " <> where' <> ", in the escaped construction (#593)") $
        boundedExample (exitFinishes ending (escapedConstructionScenario cutAt))
      it ("finishes the exit when the example body " <> label <> " " <> where' <> ", in the escaped retirement (#593)") $
        boundedExample (exitFinishes ending (escapedRetirementScenario cutAt))
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    it ("finishes the exit on the interrupter's evidence when the example body " <> label <> " right after the interrupter was handed the owner (#593)") $
      boundedExample (ownedEnds ending escapedDestructionEndedEarlyScenario False)
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    it ("finishes the exit when the example body " <> label <> " at the body's first statement, before the rescue is registered (#593)") $
      boundedExample (ownedEnds ending escapedDestructionBeforeRegistrationScenario False)
  for_ [("fails", BodyFails), ("is cancelled", BodyCancelled)] $ \(label, ending) →
    it ("finishes the exit when the example body " <> label <> " during the run's startup, before the rescue is registered (#593)") $
      boundedExample (ownedEnds ending escapedDestructionStartupScenario False)

-- | Cancellation is honoured inside each backend call in turn, and releases
-- nothing early in any of them.
--
-- The delivery point is chosen rather than raced: each call signals that it
-- has been entered and then waits, and the example throws to the owner's own
-- thread while it is there.
testCancellationAtEachBackendCall ∷ IO ()
testCancellationAtEachBackendCall = cancellationAtEachBackendCall (\_ → pure ())

-- | The same fixture with the example ended at the cut (#593): before the scripted backend behaviour is armed, or after it and its
-- release are registered.
backendCallScenario ∷ Int → Scope → IO () → IO ()
backendCallScenario cutAt _ atParked = cancellationAtEachBackendCall (\armedNow → when (armedNow == cutAt) atParked)

cancellationAtEachBackendCall ∷ (Int → IO ()) → IO ()
cancellationAtEachBackendCall cut =
  forM_ [BackendConstruct, BackendRetireTarget, BackendDestroy] $ \at' → do
    rig ← newRig
    inside ← newTVarIO False
    release ← newTVarIO False
    absorbed ← newTVarIO (0 ∷ Int)
    releasedEarly ← newTVarIO Nothing
    -- Saying it has been entered is itself inside the absorbing loop, so a
    -- cancellation that arrives before the wait is reached is absorbed like
    -- any other rather than escaping the call the example means to interrupt.
    let gated ∷ IO a → IO a
        gated answer = do
          absorbing absorbed $ do
            atomically (writeTVar inside True)
            atomically (readTVar release >>= check)
          answer
    -- Armed inside the body's first masked step, after the release that undoes it is registered (#593).
    let arm = case at' of
          BackendConstruct →
            script (fakeConstruct (rigFake rig)) $ \start →
              gated (pure (TargetConstructed (targetEvidence (Text.pack (show (startingWindow start))))))
          BackendRetireTarget →
            script (fakeRetireTarget (rigFake rig)) $ \retire →
              gated (pure (targetRetired (Text.pack (show (retiringWindow retire)))))
          BackendDestroy →
            script (fakeDestroy (rigFake rig)) $ \_ → gated (pure (ownerDestroyed (Text.pack "destroyed")))
    -- The destruction is only ever entered during the exit, when the main
    -- thread is no longer in the body, so every case delivers from a helper
    -- rather than from the body itself.
    let deliver = do
          atomically (readTVar inside >>= check)
          ownerThread ← atomically $
            readTVar (fakeThreads (rigFake rig)) >>= \case
              thread : _ → pure thread
              [] → retry
          -- Delivered twice while the backend call is running, and absorbed
          -- by the call itself: a cancellation is not permission to abandon
          -- it.
          throwTo ownerThread ThreadKilled
          atomically (readTVar absorbed >>= check . (>= 1))
          throwTo ownerThread ThreadKilled
          atomically (readTVar absorbed >>= check . (>= 2))
          -- Nothing of the host's was released while the call was unfinished.
          notes ← journalled (rigJournal rig)
          atomically (writeTVar releasedEarly (Just (filter released notes)))
          atomically (writeTVar release True)
    -- The helper drives the owner through the gate it is held at and opens that gate itself, so it is owned by the example and
    -- outlives the host body (#593); the scope opens the gate as well, whatever ended it.
    withOwnedThreadOpening (atomically (writeTVar release True)) deliver $ \_ _ → do
      ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → armedBody cut arm (atomically (writeTVar release True)) $ do
        window ← theWindow host
        service ← handedOver host owner window
        cut 2
        -- The body must not return before a call that happens during the run
        -- has been entered and interrupted, or the exit would stop the owner
        -- first and the gate would never be reached at all. The destruction is
        -- the exception: it is only ever entered during the exit.
        case at' of
          BackendConstruct → atomically (readTVar release >>= check)
          BackendRetireTarget → do
            void (awaitStanding owner service)
            _ ← releaseGraphicsTarget host owner service
            atomically (readTVar release >>= check)
            _ ← awaitTerminal owner service
            pumpUntilRetired host control
          BackendDestroy → void (awaitStanding owner service)
      readTVarIO releasedEarly >>= \seen → (show at', seen) `shouldBe` (show at', Just [])
      readTVarIO absorbed >>= \count → count `shouldSatisfy` (>= 2)
      -- And the exit still completed in dependency order.
      notes ← journalled (rigJournal rig)
      ordered notes [OwnerRetirement, OwnerDestruction, SessionEnded]
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- | Which backend call an example delivers its cancellation inside.
data BackendCall
  = BackendConstruct
  | BackendRetireTarget
  | BackendDestroy
  deriving (Eq, Show)

-- | A cancellation that /escapes/ each injected operation, rather than being
-- absorbed by it, and what the owner then does with the call it interrupted.
--
-- The example above proves that a call which absorbs a cancellation is not
-- abandoned. This one asks the opposite question: the fake absorbs nothing,
-- so the exception really does leave the operation, and what is asserted is
-- the owner's own conduct — which is not observable at all while the fake
-- keeps swallowing it.

-- | A construction the cancellation escaped is settled unverified, and the
-- owner retires what it must therefore assume it owns, in dependency order.
testEscapedConstructionCancellation ∷ IO ()
testEscapedConstructionCancellation = escapedConstruction False (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the gated retirement is armed, or after it and its release are registered.
escapedConstructionScenario ∷ Int → Scope → IO () → IO ()
escapedConstructionScenario cutAt _ atParked = escapedConstruction True (\armedNow → when (armedNow == cutAt) atParked)

escapedConstruction ∷ Bool → (Int → IO ()) → IO ()
escapedConstruction scenario cut = do
  rig ← newRig
  inside ← newTVarIO False
  never ← newTVarIO False
  observedStanding ← newTVarIO Nothing
  -- The retirement is held until the example has read the standing: the
  -- cancellation takes the owner into its drain at once, and the drain
  -- retires — and so forgets — the very target the standing is about.
  gate ← newTVarIO False
  -- Both behaviours are armed inside the body's first masked step, after the release of the gate is registered (#593).
  let arm = do
        script (fakeConstruct (rigFake rig)) $ \_ → do
          atomically (writeTVar inside True)
          atomically (readTVar never >>= check)
          unexpected "the interrupted construction returned"
        script (fakeRetireTarget (rigFake rig)) $ \retire → do
          atomically (readTVar gate >>= check)
          pure (targetRetired (Text.pack (show (retiringWindow retire))))
  withOwnedThread (killInside rig inside) $ \_ _ → do
    (raised, _) ← caughtUnlessScenario scenario $
      ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → armedBody cut arm (atomically (writeTVar gate True)) $ do
        window ← theWindow host
        service ← handedOver host owner window
        cut 2
        -- Neither accepted nor verifiably rolled back: the owner records what
        -- it knows, which is that it may own whatever the call had built.
        standing ← awaitStanding owner service
        atomically (writeTVar observedStanding (Just standing))
        atomically (writeTVar gate True)
        _ ← releaseGraphicsTarget host owner service
        _ ← awaitTerminal owner service
        pumpUntilRetired host control
    raised `shouldBe` ThreadKilled
    readTVarIO observedStanding `shouldReturn` Just (TargetUnusable True)
    -- Retired as an unconstructed target, and the whole exit kept its order.
    retirements ← readTVarIO (fakeRetirements (rigFake rig))
    map retiringConstructed retirements `shouldBe` [False]
    notes ← journalled (rigJournal rig)
    ordered
      notes
      [ TargetRetirement (Text.pack "WindowId 1")
      , OwnerRetirement
      , OwnerDestruction
      , WindowGone 1
      , SessionEnded
      ]

-- | A target retirement the cancellation escaped manufactures no evidence and
-- is never offered again — not by a later round, and not by the drain.
--
-- It is the same contract a synchronous failure has, and it must not depend
-- on which kind of exception ended the call: the operation was entered, what
-- it did is unknown, and asking again could dispose something twice.
testEscapedRetirementCancellation ∷ IO ()
testEscapedRetirementCancellation = escapedRetirement False (\_ → pure ())

-- | The same fixture ended at the cut (#593): before the blocking retirement is armed, or after it and the rescue are registered.
escapedRetirementScenario ∷ Int → Scope → IO () → IO ()
escapedRetirementScenario cutAt _ atParked = escapedRetirement True (\armedNow → when (armedNow == cutAt) atParked)

escapedRetirement ∷ Bool → (Int → IO ()) → IO ()
escapedRetirement scenario cut = do
  rig ← newRig
  inside ← newTVarIO False
  never ← newTVarIO False
  rescueRef ← newIORef (pure ())
  let arm = script (fakeRetireTarget (rigFake rig)) $ \_ → do
        atomically (writeTVar inside True)
        atomically (readTVar never >>= check)
        unexpected "the interrupted target retirement returned"
  observedTargets ← newTVarIO []
  observedRecords ← newTVarIO []
  withOwnedThread (killInside rig inside) $ \_ _ → do
    (raised, _) ← caughtUnlessScenario scenario $
      ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → armedBody cut arm (join (readIORef rescueRef)) $ do
        window ← theWindow host
        -- The independent evidence the drain will need is registered with the rescue in the step that creates the attachment.
        service ← uninterruptibleMask_ (handedOver host owner window >>= \target → target <$ writeIORef rescueRef (publishAllFor host owner (graphicsAttachment target)))
        cut 2
        awaitStanding owner service `shouldReturn` TargetUsable
        _ ← releaseGraphicsTarget host owner service
        -- The run has ended and its drain has finished, so nothing is still to
        -- come that could offer the operation a second time.
        atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
        atomically . writeTVar observedRecords . Map.keys =<< atomically (readTargetTerminalsNow owner)
        atomically . writeTVar observedTargets =<< atomically (readOwnerTargets owner)
        -- Independent evidence is the only thing that can retire it now, which
        -- is what lets this example's own exit finish.
        publisher ← maybe (unexpected "the host publishes no completions") pure (hostGraphicsPublisher host)
        acknowledgement ←
          atomically (ownerTargetAcknowledgement owner (graphicsAttachment service))
            >>= maybe (unexpected "the attachment kept no acknowledgement") pure
        forM_ allRetirementFacts $ \fact →
          void (publishCompletion publisher (completionNotice (graphicsAttachment service) acknowledgement fact))
        pumpUntilRetired host control
    raised `shouldBe` ThreadKilled
    -- No acknowledgement was manufactured for a call whose outcome is unknown.
    readTVarIO observedRecords `shouldReturn` []
    -- The target stays the owner's, explicitly unverified.
    readTVarIO observedTargets >>= \held → length held `shouldBe` 1
    -- And it was offered exactly once, over the whole run and its drain.
    notes ← journalled (rigJournal rig)
    length [() | TargetRetirement _ ← notes] `shouldBe` 1

-- | A destruction the cancellation escaped establishes nothing, so the host,
-- its windows, its session and every parent stay retained until independent
-- evidence arrives — and nothing is released early on the way there.
testEscapedDestructionCancellation ∷ IO ()
testEscapedDestructionCancellation = escapedDestruction withOwnedThreadOpening (pure ()) Nothing

-- | The scenario of 'testEscapedDestructionCancellation' for an example that fails or is cancelled right after the interrupter has
-- been handed the owner (#593): the exit's drain must still finish on the evidence the interrupter publishes, which the exit
-- waits for before the scope around the host could stop it.
escapedDestructionEndedEarlyScenario ∷ Scope → IO () → IO ()
escapedDestructionEndedEarlyScenario scope atParked = escapedDestruction scope (pure ()) (Just (\registered → when registered atParked))

-- | The same fixture ended at the body's first statement, with the owner created and the rescue not yet registered (#593): the
-- destruction's blocking behaviour is armed only by the registration step, so there is nothing for the exit to wait for.
escapedDestructionBeforeRegistrationScenario ∷ Scope → IO () → IO ()
escapedDestructionBeforeRegistrationScenario scope atParked = escapedDestruction scope (pure ()) (Just (\registered → unless registered atParked))

-- | The same fixture ended during the run's startup (#593), after the host is built and before the body's first statement.
escapedDestructionStartupScenario ∷ Scope → IO () → IO ()
escapedDestructionStartupScenario scope atParked = escapedDestruction scope atParked (Just (\_ → pure ()))

escapedDestruction ∷ Scope → IO () → Maybe (Bool → IO ()) → IO ()
escapedDestruction scope beforeBody endEarly = do
  rig ← newRig
  inside ← newTVarIO False
  never ← newTVarIO False
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  -- Armed in the body's first masked step, after the interrupter has been handed the owner (#593): until then the destruction
  -- behaves, so a cancellation before the body begins leaves an exit with nothing to wait for.
  let arm = script (fakeDestroy (rigFake rig)) $ \_ → do
        atomically (writeTVar inside True)
        atomically (readTVar never >>= check)
        unexpected "the interrupted destruction returned"
  releasedEarly ← newTVarIO Nothing
  -- The destruction is only ever entered during the exit, when the main thread is no longer in the body, so both the
  -- interruption and the independent evidence come from a thread of the example's own. The evidence is what ends the exit's
  -- wait, so the thread outlives the body: the example owns it, and the body only hands it the owner (#593).
  let interrupter owner = do
        killInside rig inside
        -- The owner's run has ended with nothing established, and the exit
        -- has said once what it is retaining for the want of it.
        atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
        awaitDiagnostic trace
        notes ← journalled (rigJournal rig)
        atomically (writeTVar releasedEarly (Just (filter released notes)))
        publishOwnerDestruction owner (ownerDestroyed (Text.pack "destroyed independently"))
  withDeferredThreadVia scope (pure ()) interrupter $ \_ handOver → case endEarly of
   Just step →
    ownedHostBeforeBody beforeBody recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _ → do
      step False
      mask_ (handOver owner >> arm)
      step True
   Nothing → do
    (unverified, _) ← caughtAs @OwnerDestructionUnverified $
      ownedHostBeforeBody beforeBody recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
        -- Handed over at once: the interrupter waits for the destruction to be entered, which happens only during the exit, so it
        -- acts at the same moment as before, and an example that fails or is cancelled before the run ends can never leave the
        -- exit waiting for the evidence it supplies.
        mask_ (handOver owner >> arm)
        window ← theWindow host
        service ← handedOver host owner window
        awaitStanding owner service `shouldReturn` TargetUsable
        _ ← releaseGraphicsTarget host owner service
        _ ← awaitTerminal owner service
        pumpUntilRetired host control
    -- Nothing was released for a destruction that established nothing: the
    -- windows and the session both outlast the whole retained wait.
    readTVarIO releasedEarly `shouldReturn` Just []
    -- The owner retired; only its destruction is unverified, and no target is.
    unverifiedRetired unverified `shouldBe` True
    unverifiedTargets unverified `shouldBe` 0
    -- The destruction raised and was offered exactly once: an operation whose
    -- outcome is unknown is not repeated, and no evidence was manufactured for
    -- it. Only the independent publication ended the wait.
    notes ← journalled (rigJournal rig)
    length [() | OwnerDestruction ← notes] `shouldBe` 1
    length [() | DestroyRaised _ ← notes] `shouldBe` 1
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False

-- | In a scenario the run's own failure is the point and propagates; otherwise it is caught as the cancellation it must be.
caughtUnlessScenario ∷ Bool → IO a → IO (AsyncException, SomeException)
caughtUnlessScenario True run = run >> ioError (userError "the scenario's run returned")
caughtUnlessScenario False run = caughtAs @AsyncException run

-- | Wait until an injected call has been entered, then cancel the thread it
-- is running on — which is the owner's, because the owner is the only thread
-- that makes one.
killInside ∷ Rig → TVar Bool → IO ()
killInside rig inside = do
  atomically (readTVar inside >>= check)
  ownerThread ← atomically $
    readTVar (fakeThreads (rigFake rig)) >>= \case
      thread : _ → pure thread
      [] → retry
  throwTo ownerThread ThreadKilled
