-- | Handing a target over: the attachment is registered and announced before
-- the backend constructs anything, each construction settles as what it
-- really is, and no reservation or attachment is stranded however a handover
-- is refused, cancelled or superseded.
module Test.GLFW.Owner.Handover (spec) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
  ( atomically
  , check
  , newTVarIO
  , readTVar
  , readTVarIO
  , writeTVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , SomeException
  , throwIO
  , throwTo
  , try
  )
import Control.Monad (forM, forM_, void)
import qualified Data.Map.Strict as Map
import qualified Data.Text as Text
import Hetoimasia.Runtime.GLFW
import qualified Hetoimasia.Runtime.GLFW.Internal as Private
import Test.GLFW.Owner.Fixture.Drive
  ( awaitConstructed
  , awaitRound
  , awaitStanding
  , awaitTerminal
  , describeHandover
  , handedOver
  , observed
  , pumpUntil
  , pumpUntilRetired
  , sampledObservation
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
  , caughtAs
  , quietLogger
  , unexpected
  , windowNamed
  )
import Test.Hspec (Spec, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  it "registers the attachment, tells the owner, and only then constructs the backend's target"
    (boundedExample testHandoffOrder)
  it "refuses an observation whose revision does not advance, and one for an incarnation the slot moved past"
    (boundedExample testRevisionMonotonicity)
  it "retains a partially constructed target and retires it, publishing nothing usable"
    (boundedExample testPartialConstruction)
  it "keeps a construction that was interrupted as unverified, and retires that too"
    (boundedExample testCancelledConstruction)
  it "certifies a verified rollback's facts without a retirement of its own"
    (boundedExample testVerifiedRollback)
  it "leaks no port reservation when a handover is refused, and tells the owner about an attachment whose answer was lost"
    (boundedExample testHandoverRecovery)
  it "leaves no attachment the owner never hears of, however a handover is cancelled"
    (boundedExample testCancelledHandover)
  it "refuses a delayed announcement of an incarnation the slot has moved past"
    (boundedExample testStaleAnnouncementRefused)
  it "keeps its retained per-target cells bounded across repeated detach-and-reattach cycles"
    (boundedExample testReattachmentBounded)

-- | The order is the contract: the attachment is registered on the main
-- thread, the owner is told through the bounded port, and only then does the
-- backend construct anything. Nothing the backend builds can precede the
-- window's exclusive slot being reserved.
testHandoffOrder ∷ IO ()
testHandoffOrder = do
  rig ← newRig
  gate ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner is held inside its startup, so it can have drained no lifetime
  -- event and constructed nothing while the main thread reserves the slot.
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "started"))
  (pendingBeforeConstruction, notesBefore, views) ←
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      takeMVar entered
      window ← theWindow host
      service ← handedOver host owner window
      pending ← atomically (hostPendingAttachments host)
      before ← journalled (rigJournal rig)
      atomically (writeTVar gate True)
      awaitConstructed rig (Text.pack (show window))
      seen ← sampledObservation host window
      _ ← observed owner service 1 seen
      _ ← awaitRound owner 0
      steps ← readTVarIO (fakeSteps (rigFake rig))
      pure (pending, before, steps)
  -- Registered before the backend was asked for anything at all.
  length pendingBeforeConstruction `shouldBe` 1
  filter isConstruction notesBefore `shouldBe` []
  notes ← journalled (rigJournal rig)
  ordered notes [OwnerStartup, Constructed (Text.pack "WindowId 1")]
  -- What the backend is then stepped with is the target it accepted.
  concat views `shouldSatisfy` all viewConstructed
  where
    isConstruction = \case
      Constructed _ → True
      _ → False

-- | A target's observations carry their own monotonic revision, and the slot
-- is keyed by the exact attachment.
testRevisionMonotonicity ∷ IO ()
testRevisionMonotonicity = do
  rig ← newRig
  answers ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    seen ← sampledObservation host window
    first ← observed owner service 1 seen
    repeated ← observed owner service 1 seen
    backwards ← observed owner service 0 seen
    forwards ← observed owner service 2 seen
    -- Release this incarnation and take a fresh one: the old service names an
    -- attachment the slot has moved past, so the owner holds no slot for it.
    released ← releaseGraphicsTarget host owner service
    released `shouldSatisfy` \case
      ReleaseBegun → True
      _ → False
    _ ← awaitTerminal owner service
    pumpUntilRetired host _control
    later ← handedOver host owner window
    stale ← observed owner service 9 seen
    fresh ← observed owner later 1 seen
    pure [first, repeated, backwards, forwards, stale, fresh]
  answers
    `shouldBe` [ ObservationAccepted 1
               , ObservationStale 1
               , ObservationStale 1
               , ObservationAccepted 2
               , ObservationUnknownTarget
               , ObservationAccepted 1
               ]

-- | A construction that left something behind is the owner's to retire, and
-- publishes nothing usable.
testPartialConstruction ∷ IO ()
testPartialConstruction = do
  rig ← newRig
  script
    (fakeConstruct (rigFake rig))
    (\_ → pure (TargetPartial (targetEvidence (Text.pack "half"))))
  (standing, record, retirements) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    -- Reported, not released: the owner keeps what the construction left and
    -- says the target cannot be used. The attachment is still the main
    -- thread's to retire.
    standing ← awaitStanding owner service
    held ← atomically (hostPendingAttachments host)
    length held `shouldBe` 1
    _ ← releaseGraphicsTarget host owner service
    record ← awaitTerminal owner service
    retirements ← readTVarIO (fakeRetirements (rigFake rig))
    pumpUntilRetired host _control
    pure (standing, record, retirements)
  standing `shouldBe` TargetUnusable True
  accountedFor record `shouldBe` allRetirementFacts
  map retiringConstructed retirements `shouldBe` [False]

-- | Every fact one terminal record established, published or still owed.
--
-- A record is written before its facts are offered to the transport, so which
-- side of the split a fact is on at the instant an example reads it is a
-- race. That they are all on one side or the other is not: it is exactly what
-- the record retaining them means.
accountedFor ∷ TerminalRecord → [RetirementFact]
accountedFor record = terminalPublished record <> terminalOwed record

-- | A construction whose failure the backend did not verify a rollback for
-- leaves the owner owning something, so the owner retires it.
testCancelledConstruction ∷ IO ()
testCancelledConstruction = do
  rig ← newRig
  script (fakeConstruct (rigFake rig)) (\_ → throwIO (Scripted (Text.pack "transfer")))
  observedStanding ← newTVarIO Nothing
  observedRecord ← newTVarIO Nothing
  -- Its retirement is held until the example has read the standing, because
  -- a required failure takes the owner into its drain at once and the drain
  -- retires the target it kept.
  gate ← newTVarIO False
  script (fakeRetireTarget (rigFake rig)) $ \retire → do
    atomically (readTVar gate >>= check)
    pure (targetRetired (Text.pack (show (retiringWindow retire))))
  -- The owner's disposition is required, so the failure it kept is terminal
  -- and the whole run reports it. What the example asserts is what the owner
  -- did with the target /before/ that: it kept it, and it retired it.
  (raised, _) ← caughtAs @Scripted $
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
      window ← theWindow host
      service ← handedOver host owner window
      standing ← awaitStanding owner service
      atomically (writeTVar observedStanding (Just standing))
      atomically (writeTVar gate True)
      _ ← releaseGraphicsTarget host owner service
      record ← awaitTerminal owner service
      atomically (writeTVar observedRecord (Just record))
      pumpUntilRetired host _control
  raised `shouldBe` Scripted (Text.pack "transfer")
  -- Neither accepted nor verifiably rolled back, so the owner still owned
  -- whatever the interrupted construction left, and retired that.
  readTVarIO observedStanding `shouldReturn` Just (TargetUnusable True)
  record ← readTVarIO observedRecord
  fmap accountedFor record `shouldBe` Just allRetirementFacts
  retirements ← readTVarIO (fakeRetirements (rigFake rig))
  map retiringConstructed retirements `shouldBe` [False]

-- | A verified rollback is the one answer that lets the owner certify without
-- a retirement of its own.
testVerifiedRollback ∷ IO ()
testVerifiedRollback = do
  rig ← newRig
  script
    (fakeConstruct (rigFake rig))
    (\_ → pure (TargetRolledBack (rollbackEvidence (Text.pack "rolled back"))))
  (standing, record, retirements) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner _control → do
    window ← theWindow host
    service ← handedOver host owner window
    standing ← awaitStanding owner service
    _ ← releaseGraphicsTarget host owner service
    record ← awaitTerminal owner service
    pumpUntilRetired host _control
    retirements ← readTVarIO (fakeRetirements (rigFake rig))
    pure (standing, record, retirements)
  -- Nothing left for the owner to own, so nothing for it to retire.
  standing `shouldBe` TargetUnusable False
  terminalEvidence record `shouldBe` Text.pack "rolled back"
  accountedFor record `shouldBe` allRetirementFacts
  retirements `shouldBe` []

-- | A refused handover spends no reservation, and an attachment whose answer
-- was lost is still announced.
testHandoverRecovery ∷ IO ()
testHandoverRecovery = do
  -- One event of room, so a leaked reservation makes the next handover fail.
  rig ← newRigWith (\config → config {ownerEventCapacity = 1})
  clock ← countingClock
  let config =
        (ownerSettings clock)
          { hostWindowConfigs = [windowNamed (Text.pack "closing"), windowNamed (Text.pack "open")]
          }
  gate ← newTVarIO False
  entered ← newEmptyMVar
  -- The owner is held inside its startup, so it drains no event: the one slot
  -- has to be given back by each refusal for the last handover to fit at all.
  script (fakeStart (rigFake rig)) $ \_ → do
    putMVar entered ()
    atomically (readTVar gate >>= check)
    pure (ownerReady (Text.pack "late"))
  (refusals, announced, owned) ← ownedHost (rigSeam rig) config (rigOwnerConfig rig) $ \host owner _control → do
    takeMVar entered
    windows ← atomically (hostWindowIdentities host)
    case windows of
      [closing, open] → do
        _ ← closeHostWindow host closing
        -- Refused before any effect, three times over, each of which must
        -- give its held reservation back.
        refusals ← mapM (\_ → handOverGraphicsTarget host owner closing) [1 ∷ Int .. 3]
        -- The recovery path an interrupted handover takes: attach with the
        -- owner's own protocol, then announce. It spends the one slot every
        -- refusal above returned, so a leak would refuse it.
        attached ← attachWindowGraphics host open (graphicsTargetProtocol host owner)
        announced ← case attached of
          GraphicsAttached service → announceGraphicsTarget owner service
          other → unexpected ("the direct attachment failed: " <> show other)
        atomically (writeTVar gate True)
        awaitConstructed rig (Text.pack (show open))
        owned ← atomically (readOwnerTargets owner)
        pure (refusals, announced, owned)
      other → unexpected ("the host created " <> show (length other) <> " windows")
  map describeHandover refusals `shouldBe` replicate 3 "refused"
  announced `shouldBe` EventAdmitted
  length owned `shouldBe` 1

-- | A handover cancelled at the one handoff that matters leaves no
-- attachment the owner was not told about.
--
-- The cancellation is delivered at the instant the attachment's construction
-- has settled and its service is about to be published: the attachment is
-- registered, its acknowledgement recorded, and the caller is about to lose
-- the answer. A helper delivers it to the main thread, because the attachment
-- is the main thread's and a handover on any other thread never reaches this
-- point at all.
testCancelledHandover ∷ IO ()
testCancelledHandover = do
  rig ← newRig
  arming ← newTVarIO Nothing
  let hooks =
        Private.noHostHooks
          { Private.beforePublication =
              readTVarIO arming >>= \case
                Nothing → pure ()
                Just target → throwTo target ThreadKilled
          }
  (answers, stranded, known) ←
    ownedHostHooked hooks quietLogger (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      main ← myThreadId
      answers ← forM [1 ∷ Int .. 6] $ \_ → do
        atomically (writeTVar arming (Just main))
        outcome ← try (handOverGraphicsTarget host owner window)
        atomically (writeTVar arming Nothing)
        -- Whatever the attach settled as, every attachment the host still has
        -- pending is one the owner has an acknowledgement for, so its
        -- evidence has somewhere to come from.
        pending ← atomically (hostPendingAttachments host)
        acknowledgements ← atomically (readOwnerAcknowledged owner)
        let unknown = filter (`notElem` acknowledgements) pending
        -- Put the window back for the next attempt.
        case outcome ∷ Either SomeException GraphicsHandover of
          Right (TargetHandedOver service) → void (releaseGraphicsTarget host owner service)
          _ →
            atomically (windowGraphicsService host window)
              >>= mapM_ (void . releaseGraphicsTarget host owner)
        pumpUntilRetired host control
        pure (either (const "cancelled") describeHandover outcome, unknown)
      -- Nothing is attached, and the owner is holding no acknowledgement for
      -- an incarnation that no longer exists.
      pumpUntil host control "the forgotten acknowledgements" $
        null <$> atomically (readOwnerAcknowledged owner)
      known ← atomically (readOwnerAcknowledged owner)
      pure (map fst answers, concatMap snd answers, known)
  -- The gate really fired: every attempt was interrupted there.
  answers `shouldBe` replicate 6 "cancelled"
  stranded `shouldBe` []
  known `shouldBe` []

-- | A delayed announcement of an incarnation the window's slot has moved past
-- is refused, and touches the replacement not at all.
testStaleAnnouncementRefused ∷ IO ()
testStaleAnnouncementRefused = do
  rig ← newRig
  (admitted, staleStage, owned, laterStage) ←
    ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
      window ← theWindow host
      first ← handedOver host owner window
      _ ← releaseGraphicsTarget host owner first
      _ ← awaitTerminal owner first
      pumpUntilRetired host control
      -- A fresh incarnation now holds the window's slot.
      later ← handedOver host owner window
      awaitStanding owner later `shouldReturn` TargetUsable
      -- The old service, announced now. It names an incarnation the slot has
      -- moved past, so nothing may be reopened for it.
      admitted ← announceGraphicsTarget owner first
      (,,,) admitted
        <$> atomically (custodyOf owner (graphicsAttachment first))
        <*> atomically (readOwnerTargets owner)
        <*> atomically (custodyOf owner (graphicsAttachment later))
  admitted `shouldBe` EventPortClosed
  -- The retired incarnation was not reopened, and no ghost target was made.
  staleStage `shouldSatisfy` (`notElem` [Just CustodyAnnounced, Just CustodyOwned])
  -- Only the replacement is held, and it is untouched.
  length owned `shouldBe` 1
  laterStage `shouldBe` Just CustodyOwned

-- | Repeated detach-and-reattach leaves one window's worth of retained cells,
-- not one per incarnation.
testReattachmentBounded ∷ IO ()
testReattachmentBounded = do
  rig ← newRig
  (records, geometry, acknowledged) ← ownedHost (rigSeam rig) (rigHostConfig rig) (rigOwnerConfig rig) $ \host owner control → do
    window ← theWindow host
    forM_ [1 ∷ Int .. 4] $ \_ → do
      service ← handedOver host owner window
      seen ← sampledObservation host window
      _ ← observed owner service 1 seen
      awaitStanding owner service `shouldReturn` TargetUsable
      _ ← releaseGraphicsTarget host owner service
      _ ← awaitTerminal owner service
      pumpUntilRetired host control
    -- The round after the last validation prunes what it established.
    pumpUntil host control "the pruned round" (Map.null <$> atomically (readTargetTerminalsNow owner))
    (,,)
      <$> atomically (readTargetTerminalsNow owner)
      <*> atomically (readOwnerGeometry owner)
      <*> atomically (readOwnerAcknowledged owner)
  Map.size records `shouldBe` 0
  Map.size geometry `shouldBe` 0
  length acknowledged `shouldBe` 0
