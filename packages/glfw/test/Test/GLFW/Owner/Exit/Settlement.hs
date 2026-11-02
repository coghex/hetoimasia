-- | The D-33 exit's stop and settlement: an ordinary stop closes every
-- publication, an attachment the owner never answered for is settled rather
-- than reported as a release, nothing attaches once admission has ended, and
-- the whole owner is retired and destroyed with or without targets.
module Test.GLFW.Owner.Exit.Settlement (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( STM
  , stateTVar
  , atomically
  , check
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM, void, when)
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (..))
import qualified Hetoimasia.Foundation.Worker as Worker
import Hetoimasia.GLFW.Internal.Attachment (AttachmentPhase (..), viewPhase)
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import qualified Hetoimasia.Runtime.GLFW.Internal.Owner.Handoff as Private
import Test.GLFW.Owner.Fixture.Drive
  ( awaitRound
  , awaitTerminal
  , describeHandover
  , handedOver
  , pumpUntil
  , pumpUntilRetired
  , theWindow
  )
import Test.GLFW.Owner.Fixture.Fake (Fake (..), script)
import Test.GLFW.Owner.Fixture.Journal (Note (..), Scripted (..), journalled, ordered)
import Test.GLFW.Owner.Fixture.Rig
  ( Rig (..)
  , countingClock
  , newRig
  , newRigWith
  , ownedHost
  , ownedHostHooked
  , ownerSettings
  )
import Test.GLFW.Support
  ( boundedExample
  , newSinkTrace
  , quietLogger
  , sinkFailingOn
  , traced
  , unexpected
  , windowNamed
  )
import Test.Hspec (Spec, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  it "closes every publication for an ordinary stop, and drains an announcement admitted before it"
    (boundedExample testNormalStopClosesPublications)
  it "settles a direct attachment whose announcement was refused, rather than reporting a release"
    (boundedExample testUnannouncedDirectAttachSettles)
  it "settles one whose window is then closed, with no release of its own"
    (boundedExample testUnannouncedClosedSettles)
  it "settles a published attachment whose answer was lost while the owner was closing"
    (boundedExample testLostAnswerWithClosedOwner)
  it "attaches nothing at all once the owner's admission has ended"
    (boundedExample testHandoverAfterStopAttachesNothing)
  it "retires and destroys the whole owner with no target ever attached"
    (boundedExample testWholeOwnerWithoutTargets)
  it "retires and destroys it after the last target has already detached"
    (boundedExample testWholeOwnerAfterLastTarget)
  it "reads a destruction and completion that both land inside its wait as verified, declaring nothing"
    (boundedExample testCoherentDestructionSnapshot)

-- | An ordinary public stop closes every publication, and an announcement
-- admitted just before it is still drained.
--
-- 'graphicsOwnerWorker' is public, so any caller can stop the owner without a
-- failure to latch. If the stop closed nothing, a handover admitted after the
-- drain's single take would never be processed and the host drain would wait
-- for evidence forever.
testNormalStopClosesPublications ∷ IO ()
testNormalStopClosesPublications = do
  rig ← newRig
  gate ← newTVarIO False
  stepping ← newEmptyMVar
  -- The owner is held inside a step, so the announcement below is admitted
  -- and certainly not yet consumed when the stop arrives.
  script (fakeStep (rigFake rig)) $ \_ → do
    putMVar stepping ()
    atomically (readTVar gate >>= check)
    pure noStepWork
  (stage, refused) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    takeMVar stepping
    service ← handedOver host owner window
    stage ← atomically (custodyOf owner (graphicsAttachment service))
    -- An ordinary stop, from the public handle, with no failure anywhere.
    atomically (Worker.requestStop (graphicsOwnerWorker owner))
    atomically (writeTVar gate True)
    -- The owner's run ends. Its drain must still take that announcement and
    -- retire the target it names: a stop that closed nothing would leave the
    -- event unread and no record would ever appear here.
    _ ← awaitTerminal owner service
    demand ← prepare (OwnerDemand True Nothing)
    refused ← atomically (publishOwnerDemand (ownerHandoff owner) demand)
    pure (stage, refused)
  -- The owner owed it from the instant the announcement was admitted.
  stage `shouldBe` Just CustodyAnnounced
  refused `shouldBe` PublicationClosed

-- | A direct attachment whose announcement was refused is settled by its
-- release, not reported as one the owner will retire.
--
-- The port is full and stays full, so the owner is never told. A release that
-- answered 'ReleaseBegun' would be claiming an evidence path that does not
-- exist, and the host drain would wait on it forever.
testUnannouncedDirectAttachSettles ∷ IO ()
testUnannouncedDirectAttachSettles = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "first"), windowNamed (Text.pack "second")]
          }
  (admitted, answer, stage, pending) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
    takeMVar entered
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [first, second] → do
        -- The one slot is spent by a handover the owner cannot drain.
        _ ← handedOver host owner first
        -- A direct attach, then an announcement the full port refuses.
        attached ← attachWindowGraphics host second (graphicsTargetProtocol host owner)
        service ← case attached of
          GraphicsAttached service → pure service
          other → unexpected ("the direct attachment failed: " <> show other)
        admitted ← announceGraphicsTarget owner service
        stageBefore ← atomically (custodyOf owner (graphicsAttachment service))
        stageBefore `shouldBe` Just CustodyRegistered
        answer ← releaseGraphicsTarget host owner service
        stage ← atomically (custodyOf owner (graphicsAttachment service))
        pending ← atomically (hostPendingAttachments host)
        atomically (writeTVar gate True)
        pure (admitted, describeRelease answer, stage, pending)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  admitted `shouldBe` EventRefusedFull
  -- Settled here, and said so: the owner was never told and owes nothing.
  answer `shouldBe` "settled here"
  -- Settled and forgotten together: the owner is held in its startup and
  -- will take no round that could have pruned it.
  stage `shouldBe` Nothing
  -- Only the first handover's attachment is left pending.
  length pending `shouldBe` 1

describeRelease ∷ ReleaseAnswer → String
describeRelease = \case
  ReleaseBegun → "begun"
  ReleaseSettled → "settled here"
  ReleaseOwnerRetires → "owner retires it"
  ReleaseNoOp answer → "no-op " <> show answer
  ReleasePortFull → "port full"

-- | A direct attachment whose announcement was refused is settled by its
-- window's close, with no release of its own.
--
-- Nothing ever told the owner about it and nothing ever will, so the only
-- place its evidence can come from is the attachment's own protocol step —
-- which is the backstop every path that begins a retirement without a
-- release arrives at.
testUnannouncedClosedSettles ∷ IO ()
testUnannouncedClosedSettles = do
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  gate ← newTVarIO False
  entered ← newEmptyMVar
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "first"), windowNamed (Text.pack "second")]
          }
  (admitted, stage, retirements) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner control → do
    takeMVar entered
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [first, second] → do
        _ ← handedOver host owner first
        attached ← attachWindowGraphics host second (graphicsTargetProtocol host owner)
        service ← case attached of
          GraphicsAttached service → pure service
          other → unexpected ("the direct attachment failed: " <> show other)
        admitted ← announceGraphicsTarget owner service
        -- The close, and nothing else: no release, no detach.
        _ ← closeHostWindow host second
        pumpUntil host control "the closed window's retirement" $
          (== 1) . length <$> atomically (hostPendingAttachments host)
        stage ← atomically (custodyOf owner (graphicsAttachment service))
        retirements ← readTVarIO (fakeRetirements (rigFake rig))
        atomically (writeTVar gate True)
        pure (admitted, stage, retirements)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  admitted `shouldBe` EventRefusedFull
  -- Settled, and forgotten in the same breath: the owner takes no round that
  -- could have pruned it.
  stage `shouldBe` Nothing
  -- The backend was asked to retire nothing: it never had this target.
  retirements `shouldBe` []

-- | An attachment whose service was published and whose answer was then lost,
-- while the owner's admission closed in the same moment, is settled — not
-- marked settled with nothing recorded.
--
-- Certifying a fact is refused for an attachment that is still active, so a
-- settlement that did not first begin its retirement would leave the ledger
-- terminal, the facts unrecorded, and the drain waiting for good. The answer
-- is lost from 'Private.afterPublication', which is the one seam that reaches
-- an attachment in exactly that state: published, /active/, and outside the
-- handler that would otherwise have begun its retirement for us.
testLostAnswerWithClosedOwner ∷ IO ()
testLostAnswerWithClosedOwner = do
  rig ← newRig
  closing ← newTVarIO Nothing
  observedPhases ← newTVarIO Nothing
  let hooks =
        Private.noHostHooks
          { Private.afterPublication =
              readTVarIO closing >>= \case
                Nothing → pure ()
                Just (host, owner) → do
                  -- The owner's admission ends, and the caller's answer is
                  -- lost, at the one instant the attachment is published and
                  -- active.
                  atomically (Private.closeOwnerPublications (ownerHandoff owner))
                  phases ← atomically (attachmentPhases host)
                  atomically (writeTVar observedPhases (Just phases))
                  throwIO (Scripted (Text.pack "answer lost"))
          }
  (answer, pending, stage) ←
    ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      atomically (writeTVar closing (Just (host, owner)))
      answer ← try (handOverGraphicsTarget host owner window)
      (,,) (either (const "raised") describeHandover (answer ∷ Either SomeException GraphicsHandover))
        <$> atomically (hostPendingAttachments host)
        <*> atomically (readOwnerCustody owner)
  answer `shouldBe` "raised"
  -- The state the recovery actually met: one attachment, active. Nothing had
  -- begun its retirement, so 'retireStranded' had to begin it itself before a
  -- single fact could be certified.
  readTVarIO observedPhases `shouldReturn` Just [Just AttachmentActive]
  -- Settled for real: nothing is left pending for a drain to wait on, and
  -- nothing is left in the ledger claiming to be finished.
  pending `shouldBe` []
  stage `shouldBe` []

-- | Every pending attachment's phase, in the host's own order.
attachmentPhases ∷ WindowHost → STM [Maybe AttachmentPhase]
attachmentPhases host = do
  pending ← hostPendingAttachments host
  map (fmap viewPhase) <$> traverse (Private.hostAttachmentView host) pending

-- | Once the owner's admission has ended, a handover attaches nothing at all.
--
-- Discovering the closure only at the announcement would mean reserving a
-- window's slot and settling it again on every attempt, against an owner that
-- will take no further round — one ledger entry per attempt, outside any
-- bound the configuration sets.
testHandoverAfterStopAttachesNothing ∷ IO ()
testHandoverAfterStopAttachesNothing = do
  rig ← newRig
  (answers, entries, pending) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    -- An ordinary public stop, and the owner runs out.
    atomically (Worker.requestStop (graphicsOwnerWorker owner))
    atomically (readOwnerTerminalNow owner >>= check . ownerRunEnded)
    answers ← forM [1 ∷ Int .. 12] $ \_ → describeHandover <$> handOverGraphicsTarget host owner window
    (,,) answers <$> atomically (readOwnerCustody owner) <*> atomically (hostPendingAttachments host)
  answers `shouldBe` replicate 12 "owner closed"
  -- Nothing was attached, so nothing was registered and nothing settled.
  entries `shouldBe` []
  pending `shouldBe` []

-- | Whole-owner retirement does not depend on there ever having been a target.
testWholeOwnerWithoutTargets ∷ IO ()
testWholeOwnerWithoutTargets = do
  rig ← newRig
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control →
    void (awaitRound owner 0)
  requests ← readTVarIO (fakeOwnerRetirements (rigFake rig))
  notes ← journalled (rigJournal rig)
  map retiringUnverified requests `shouldBe` [[]]
  map retiringStarted requests `shouldBe` [True]
  ordered notes [OwnerStartup, OwnerRetirement, OwnerDestruction, SessionEnded]

-- | Nor on a target still being attached when the exit begins.
testWholeOwnerAfterLastTarget ∷ IO ()
testWholeOwnerAfterLastTarget = do
  rig ← newRig
  ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    _ ← releaseGraphicsTarget host owner service
    _ ← awaitTerminal owner service
    pumpUntilRetired host _control
  requests ← readTVarIO (fakeOwnerRetirements (rigFake rig))
  notes ← journalled (rigJournal rig)
  map retiringUnverified requests `shouldBe` [[]]
  ordered notes [TargetRetirement (Text.pack "WindowId 1"), OwnerRetirement, OwnerDestruction]

-- | A successful teardown whose evidence and completion are both committed
-- between the exit reading its snapshot and acting on it is still verified.
--
-- The owner's destruction waits until the exit has read its first snapshot,
-- and the exit's private hook then holds it, before it acts, until the owner
-- has published both its evidence and its run's end. An exit that decided from
-- any read after that snapshot would see the run ended and the evidence
-- missing, and would declare 'OwnerDestructionUnverified' for an owner that
-- destroyed everything: one that decides from the snapshot alone only waits,
-- and its next turn finds the evidence.
testCoherentDestructionSnapshot ∷ IO ()
testCoherentDestructionSnapshot = do
  rig ← newRig
  trace ← newSinkTrace
  let recording = sinkFailingOn (Text.pack "never") trace
  held ← newTVarIO Nothing
  snapshotRead ← newTVarIO False
  turns ← newTVarIO (0 ∷ Int)
  releasedWhileHeld ← newTVarIO Nothing
  script (fakeDestroy (rigFake rig)) $ \_ → do
    atomically (readTVar snapshotRead >>= check)
    pure (ownerDestroyed "destroyed")
  let hooks =
        Private.noHostHooks
          { Private.afterDestructionSnapshot = do
              first ← atomically (stateTVar turns (\n → (n == 0, n + 1)))
              when first $ do
                owner ← atomically (readTVar held >>= maybe retry pure)
                atomically (writeTVar snapshotRead True)
                atomically $ do
                  terminal ← readOwnerTerminalNow owner
                  check (isJust (ownerDestroyedEvidence terminal) && ownerRunEnded terminal)
                notes ← journalled (rigJournal rig)
                atomically (writeTVar releasedWhileHeld (Just (filter released notes)))
          }
  outcome ← try @SomeException $
    ownedHostHooked hooks recording (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \_ owner _control → do
      atomically (writeTVar held (Just owner))
      void (awaitRound owner 0)
  case outcome of
    Right () → pure ()
    Left failure → unexpected ("the exit failed after a successful teardown: " <> show failure)
  -- The forced ordering really happened: the snapshot the hook held was read
  -- before the destruction could answer, and a later turn followed it.
  readTVarIO snapshotRead `shouldReturn` True
  readTVarIO turns >>= (`shouldSatisfy` (>= 2))
  components ← traced trace
  components `shouldSatisfy` notElem (Text.pack "glfw.graphics-owner")
  -- Nothing was released until the evidence existed, and everything was
  -- released after it.
  readTVarIO releasedWhileHeld `shouldReturn` Just []
  notes ← journalled (rigJournal rig)
  ordered notes [OwnerDestruction, SessionEnded]
  where
    released = \case
      WindowGone _ → True
      SessionEnded → True
      _ → False
