-- | The D-33 exit's retirement order: each target, then the owner, then its
-- destruction, the join, and only then the windows — with a released target
-- acknowledged on its own, a retirement still owed asked for again and
-- drained, and the main thread's housekeeping served while it waits.
module Test.GLFW.Owner.Exit.Retirement (spec) where

import Control.Concurrent (forkIO, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception (AsyncException (ThreadKilled), throwIO)
import Control.Monad (when)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Internal.Seam (NativeCall (..))
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Test.GLFW.Owner.Fixture.Drive
  ( awaitConstructed
  , awaitIdle
  , awaitRound
  , awaitStanding
  , awaitTerminal
  , describeHandover
  , handedOver
  , pumpUntil
  , raisedBy
  , theWindow
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..), ScriptedTimer (..), fireTimer, script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig
  ( Rig (..)
  , countingClock
  , newRig
  , newRigWith
  , ownedHost
  , ownedHostCaught
  , ownedHostHooked
  , ownerSettings
  )
import Test.GLFW.Support (boundedExample, quietLogger, unexpected, windowNamed)
import Test.Hspec (Spec, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  it "retires each target, then the owner, then destroys it, then joins, and only then releases the windows"
    (boundedExample testExitOrder)
  it "acknowledges one released target while the owner and a second target stay live"
    (boundedExample testIndividualRelease)
  it "asks again on a later round for a released target whose retirement is owed, certifying nothing meanwhile"
    (boundedExample testOwedRetirementRetried)
  it "waits in its exit drain for a retirement still owed, and retires the target before the owner"
    (boundedExample testOwedRetirementDrained)
  it "leaves a retirement owed, not failed, when a cancellation lands in its preparation, and retires it in the drain"
    (boundedExample testPreparationCancelled)
  it "retires the target of a window closed through its own port, with no detach at all"
    (boundedExample testWindowCloseRetiresTarget)
  it "strands nothing when the host's admission closes during a handover"
    (boundedExample testSupersededHandover)
  it "services the main thread's bounded housekeeping while it awaits the owner"
    (boundedExample testHousekeepingDuringDrain)
  it "keeps the backend's own startup evidence readable through retirement"
    (boundedExample testStartupEvidenceRetained)

-- | The whole-session exit order.
testExitOrder ∷ IO ()
testExitOrder = do
  rig ← newRig
  workerAtExit ← newTVarIO Nothing
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    awaitConstructed rig (Text.pack (show window))
    atomically (writeTVar workerAtExit (Just ()))
  notes ← journalled (rigJournal rig)
  ordered
    notes
    [ OwnerStartup
    , Constructed (Text.pack "WindowId 1")
    , TargetRetirement (Text.pack "WindowId 1")
    , OwnerRetirement
    , OwnerDestruction
    , WindowGone 1
    , SessionEnded
    ]

-- | An individual release retires one target and leaves everything else live.
testIndividualRelease ∷ IO ()
testIndividualRelease = do
  rig ← newRigWith id
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "first"), windowNamed (Text.pack "second")]
          }
  (livingWorker, terminals, secondStillPending) ←
    ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
      windows ← atomically (hostWindowIdentities host)
      case windows of
        [first, second] → do
          firstService ← handedOver host owner first
          _second ← handedOver host owner second
          awaitConstructed rig (Text.pack (show second))
          _ ← releaseGraphicsTarget host owner firstService
          _ ← awaitTerminal owner firstService
          -- The released target's attachment retires and its window may be
          -- released; the other one is untouched and the owner is still live.
          pumpUntil host _control "one retired attachment" $
            (== 1) . length <$> atomically (hostPendingAttachments host)
          settled ← atomically (Worker.pollCompletion (graphicsOwnerWorker owner))
          records ← atomically (readTargetTerminalsNow owner)
          pending ← atomically (windowGraphicsStatus host second)
          pure (isNothing settled, Map.keys records, pending)
        other → unexpected ("the host created " <> show (length other) <> " windows")
  livingWorker `shouldBe` True
  length terminals `shouldBe` 1
  secondStillPending `shouldSatisfy` \case
    GraphicsPresent observation → observedSlot observation == SlotAttached
    _ → False

-- | A released target whose backend says its retirement cannot be performed
-- yet is asked again on a later round, and nothing is retired or certified
-- until it can be.
testOwedRetirementRetried ∷ IO ()
testOwedRetirementRetried = do
  rig ← newRig
  asked ← newTVarIO (0 ∷ Int)
  ready ← newTVarIO False
  script (fakePrepare (rigFake rig)) $ \_ → atomically $ do
    modifyTVar' asked (+ 1)
    open ← readTVar ready
    pure (if open then RetirementReady else RetirementOwed (Text.pack "a present fence is pending"))
  (whileOwed, certifiedWhileOwed, askedInAll, retiredOnce) ←
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      service ← handedOver host owner window
      awaitConstructed rig (Text.pack (show window))
      _ ← releaseGraphicsTarget host owner service
      atomically (readTVar asked >>= check . (>= 1))
      _ ← awaitIdle owner
      whileOwed ← readTVarIO (fakeRetirements (rigFake rig))
      certified ← Map.member (graphicsAttachment service) <$> atomically (readTargetTerminalsNow owner)
      atomically (writeTVar ready True)
      -- Whatever takes the owner's next round asks again: here, a publication.
      demand ← prepare (OwnerDemand False Nothing)
      _ ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
      _ ← awaitTerminal owner service
      total ← readTVarIO asked
      retirements ← readTVarIO (fakeRetirements (rigFake rig))
      pure (whileOwed, certified, total, length retirements)
  whileOwed `shouldBe` []
  certifiedWhileOwed `shouldBe` False
  askedInAll `shouldSatisfy` (>= 2)
  retiredOnce `shouldBe` 1

-- | A retirement still owed when the owner exits is asked again in its drain,
-- between waits for the backend's own deadline, and the target is retired
-- before the owner is.
testOwedRetirementDrained ∷ IO ()
testOwedRetirementDrained = do
  rig ← newRig
  asked ← newTVarIO (0 ∷ Int)
  ownerCell ← newTVarIO Nothing
  -- Owed while the owner is running — the host's quiescence may begin the
  -- attachment's retirement while rounds are still being taken — and ready
  -- only at the drain's second ask, so the drain itself has to wait.
  script (fakePrepare (rigFake rig)) $ \_ → atomically $ do
    phase ← readTVar ownerCell >>= traverse (fmap statusPhase . readOwnerStatusNow)
    let draining = phase == Just OwnerRetiring
    when draining (modifyTVar' asked (+ 1))
    count ← readTVar asked
    pure (if draining && count > 1 then RetirementReady else RetirementOwed (Text.pack "a present fence is pending"))
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    atomically (writeTVar ownerCell (Just owner))
    window ← theWindow host
    _ ← handedOver host owner window
    awaitConstructed rig (Text.pack (show window))
    -- The drain's wait is the backend's: this one names no deadline, so the
    -- drain arms its fallback, and this fires it once it has.
    _ ← forkIO $ do
      atomically (readTVar (timerArmings (rigTimer rig)) >>= check . not . null)
      fireTimer (rigTimer rig)
    pure ()
  notes ← journalled (rigJournal rig)
  ordered
    notes
    [ OwnerStartup
    , Constructed (Text.pack "WindowId 1")
    , TargetRetirement (Text.pack "WindowId 1")
    , OwnerRetirement
    , OwnerDestruction
    , WindowGone 1
    ]
  readTVarIO asked `shouldReturn` 2
  armings ← readTVarIO (timerArmings (rigTimer rig))
  armings `shouldSatisfy` (not . null)

-- | A cancellation delivered inside a retirement's preparation ends the
-- owner's run as any cancellation does, but it is not a failed retirement:
-- the preparation disposed of nothing, so the drain asks again and retires the
-- target, once.
testPreparationCancelled ∷ IO ()
testPreparationCancelled = do
  rig ← newRig
  asked ← newTVarIO (0 ∷ Int)
  script (fakePrepare (rigFake rig)) $ \_ → do
    count ← atomically (modifyTVar' asked (+ 1) >> readTVar asked)
    if count == 1 then throwIO ThreadKilled else pure RetirementReady
  outcome ← ownedHostCaught (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    awaitStanding owner service `shouldReturn` TargetUsable
    _ ← releaseGraphicsTarget host owner service
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
  _ ← raisedBy outcome
  retirements ← readTVarIO (fakeRetirements (rigFake rig))
  length retirements `shouldBe` 1
  notes ← journalled (rigJournal rig)
  ordered notes [TargetRetirement (Text.pack "WindowId 1"), OwnerRetirement, OwnerDestruction]

-- | Closing a window through its own port retires that window's target,
-- although nothing detached it.
--
-- The close begins the attachment's retirement in the host's model, and no
-- event passes through the owner's lifetime port at all. An owner that waited
-- to be told would leave the target unretired, its evidence unproduced, and
-- the window unable to finish closing while the owner stayed live.
testWindowCloseRetiresTarget ∷ IO ()
testWindowCloseRetiresTarget = do
  rig ← newRig
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "closing"), windowNamed (Text.pack "staying")]
          }
  (retirements, livingWorker, other) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner control → do
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [closing, staying] → do
        first ← handedOver host owner closing
        second ← handedOver host owner staying
        awaitConstructed rig (Text.pack (show staying))
        -- The close, and nothing else. No detach, no release, no event.
        _ ← closeHostWindow host closing
        _ ← awaitTerminal owner first
        pumpUntil host control "the closed window's retirement" $
          (== 1) . length <$> atomically (hostPendingAttachments host)
        -- The owner is still live and still holds the other target.
        settled ← atomically (Worker.pollCompletion (graphicsOwnerWorker owner))
        retirements ← readTVarIO (fakeRetirements (rigFake rig))
        other ← atomically (windowGraphicsStatus host (graphicsWindow second))
        pure (retirements, isNothing settled, other)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  -- Exactly the closed window's target, and only it.
  map (Text.pack . show . retiringWindow) retirements `shouldBe` [Text.pack "WindowId 1"]
  livingWorker `shouldBe` True
  other `shouldSatisfy` \case
    GraphicsPresent observation → observedSlot observation == SlotAttached
    _ → False

-- | A handover the host's admission closes under strands nothing.
--
-- Quiescence is delivered at exactly the handoff between the attachment's
-- construction and its publication, which is what makes the boundary answer
-- 'GraphicsSuperseded': a registered, retiring attachment with its
-- acknowledgement recorded and nothing usable published. Nothing but the
-- handover itself could produce its evidence, so an exit that waited for it
-- would never return.
testSupersededHandover ∷ IO ()
testSupersededHandover = do
  rig ← newRig
  quiescing ← newTVarIO Nothing
  let hooks =
        Private.noHostHooks
          { Private.beforePublication =
              readTVarIO quiescing >>= mapM_ (atomically . quiesceWindowHost)
          }
  (answer, pending, acknowledgements) ←
    ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      atomically (writeTVar quiescing (Just host))
      answer ← handOverGraphicsTarget host owner window
      -- The attachment the supersession left behind is retired: the host
      -- holds none pending, and the ledger settled that incarnation and
      -- forgot it in the same breath, so nothing can announce it again and
      -- nothing is retained for an owner round that may never come.
      stage ← case answer of
        HandoverSuperseded target → atomically (custodyOf owner target)
        _ → pure Nothing
      (,,) (describeHandover answer)
        <$> atomically (hostPendingAttachments host)
        <*> pure stage
  answer `shouldBe` "superseded"
  pending `shouldBe` []
  acknowledgements `shouldBe` Nothing

-- | The main thread services the host's own bounded housekeeping while it
-- awaits the owner, and performs no owner work.
testHousekeepingDuringDrain ∷ IO ()
testHousekeepingDuringDrain = do
  rig ← newRig
  release ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner's destruction is held open, so the main thread has to wait for
  -- it with something to do.
  script (fakeDestroy (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar release >>= check)
    pure (ownerDestroyed (Text.pack "destroyed late"))
  mainThread ← newTVarIO Nothing
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    _ ← handedOver host owner window
    awaitConstructed rig (Text.pack (show window))
    caller ← myThreadId
    atomically (writeTVar mainThread (Just caller))
    _ ← forkIO $ do
      takeMVar entered
      -- The main thread is inside the exit's own wait for the owner. It keeps
      -- pumping, and this releases the owner once it has.
      atomically . check . (> 0) . length . housekeeping =<< readTVarIO (rigNative rig)
      atomically (writeTVar release True)
    pure ()
  calls ← readTVarIO (rigNative rig)
  owner ← readTVarIO mainThread
  housekeeping calls `shouldSatisfy` (not . null)
  -- Whatever pumped, pumped on the main thread.
  maybe True (\main → all ((== main) . fst) (filter (isPump . snd) calls)) owner `shouldBe` True
  where
    housekeeping = filter (isPump . snd)

isPump ∷ NativeCall → Bool
isPump = \case
  PollEvents → True
  WaitEvents _ → True
  _ → False

-- | The backend's own startup evidence is recorded as it came back and stays
-- readable after the owner has retired and ended.
testStartupEvidenceRetained ∷ IO ()
testStartupEvidenceRetained = do
  rig ← newRig
  script (fakeStart (rigFake rig)) (\_ → pure (ownerReady (Text.pack "device 7, queue 2")))
  escaped ← newEmptyMVar
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
    _ ← awaitRound owner 0
    putMVar escaped owner
  -- Read from the owner's own record after it has retired, destroyed and
  -- ended, rather than from a copy taken while it was running: a retirement
  -- that cleared the record would pass the second and fail this.
  owner ← takeMVar escaped
  terminal ← atomically (readOwnerTerminalNow owner)
  ownerRunEnded terminal `shouldBe` True
  ownerDestroyedEvidence terminal `shouldSatisfy` isJust
  ownerStartedEvidence terminal `shouldBe` Just (Text.pack "device 7, queue 2")
