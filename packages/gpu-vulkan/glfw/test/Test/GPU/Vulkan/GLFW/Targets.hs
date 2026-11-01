-- | LFE-27's examples: a surface-free offscreen scene target registered with the running host takes part in the
-- same ownership a window has — one scene-target key, the release barrier, the adoption and release of what it
-- publishes, the bound recording boundary that ties a batch to the revision it read, and teardown on every exit —
-- over whole graphics hosts on the GLFW package's scripted seam with the stand-in native layers of
-- "Test.GPU.Vulkan.GLFW.StandIn", and with no window at all unless an example says so.
--
-- Every wait here is on a transaction or on an event the stand-ins journal, never on elapsed time, and each wait
-- names what establishes its precondition:
--
-- * Where an example needs the owner not to have taken a publication yet, it holds the owner's thread inside an
--   owner-thread action that waits on a gate the example opens ("holding the owner"): adoption is the first thing
--   the owner's step does and an action runs after it, so a publication made while the action runs is adopted by
--   the owner's next step and by no earlier one. The example learns the owner is inside the action from the gate's
--   own handshake, not from a clock.
-- * Where it needs a publication and a release request to be one fact, it makes both in one transaction, which no
--   owner step can fall between.
-- * Where it needs a batch to stay pending, it withholds the stand-in's submission completion; where it needs one
--   batch complete and another not, it lets only the next submission fence asked answer signalled, and reads which
--   from the tickets, never from an assumed order.
-- * Where it needs a target at its retention limit it publishes until the host's own scene state says the
--   adoption was deferred.
module Test.GPU.Vulkan.GLFW.Targets (spec) where

import Control.Concurrent (ThreadId, forkIO, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar, readTVarIO, retry, writeTVar, modifyTVar')
import Control.Exception (AsyncException (ThreadKilled), ErrorCall (..), Exception, ExceptionWithContext (..), SomeException, catch, finally, fromException, throwIO, try)
import Control.Monad (void)
import Data.Foldable (for_)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (..), threadStatus)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Unique (newUnique)
import Numeric.Natural (Natural)
import System.IO (hPutStrLn, stderr)

import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, frameSlotLimit, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Controller
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Loop (runVulkanOwnerLoop)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Scenes (adoptScene, endSceneTarget, newScenes, readSceneState, registerSceneTarget, releaseScenes, retentionLimit)
import Hetoimasia.GPU.Vulkan.GLFW.Internal.Target (Adopter (..), OffscreenTargetId (..))
import Hetoimasia.GPU.Vulkan.Native.Recording (BatchTicket, TicketState (..), readTicket)
import Hetoimasia.Runtime.GLFW
  ( OwnerPhase (..)
  , OwnerStatus (..)
  , ScheduledStep (..)
  , ScheduledTurn (..)
  , TargetStanding (..)
  , Turn (..)
  , UpdateSchedule (..)
  , WindowScenePublication (..)
  , defaultScheduledHooks
  , ownerHandoff
  , publishGraphicsWindowScene
  , readOwnerFailure
  , readOwnerStatusNow
  , superviseGraphicsOwner
  , targetEventsOpen
  )
import Hetoimasia.Runtime.Supervision (RuntimeControl, checkRuntime)
import Test.GPU.Vulkan.GLFW.Bound (boundOf, boundedIt)
import Test.GPU.Vulkan.GLFW.StandIn
import Test.Hspec (Spec, describe, expectationFailure, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Offscreen scene targets (LFE-27)" $ do
  describe "registration and publication" $ do
    itBounded "registers targets with distinct identities at the initial scene's revision 0, takes publications as a rising latest value replaced in execution order, and answers what it does not hold naming it, including a stale or foreign identity" testRegistration
    itBounded "refuses a registration with a typed reason before the device exists, after the session failed and once the owner's exit has begun, and refuses a publication to a closed host" testRegistrationRefusals
    itBounded "bounds the targets the host accounts for, counting a retired target until its last record is released, and leaves the windows' own bound alone" testCapacity

  describe "the barrier" $ do
    itBounded "holds a release request made after the target accepted a revision until the target adopts it, and runs it once it has" testBarrierWaitsForAdoption
    itBounded "runs a held release request when the target is unregistered, without the revision ever being adopted, and releases what the target had adopted" testBarrierEndsWithUnregistration
    itBounded "leaves a target at revision 0 out of the barrier when the host declares its initial scene holds nothing, and names it otherwise" testInitialSceneExemption
    itBounded "settles a held release request as refused, never run, when the session fails, and when the owner's exit begins" testHeldRequestRefused

  describe "adoption and release" $ do
    itBounded "releases a superseded revision only when its batch's own ticket is complete, once, in adoption order, and announces nothing while the completion is withheld" testReleaseOnTicketCompletion
    itBounded "keeps a revision while any batch recorded with it is pending, whichever batch of another revision or target completed" testUnrelatedCompletion
    itBounded "ends the use of a batch that was discarded, releasing the revision it read" testDiscardEndsUse
    itBounded "holds a finite number of unreleased revisions for a target, defers an adoption at the limit without making publication wait, and adopts the deferred revision once a release makes room" testRetentionLimit

  describe "teardown" $ do
    itBounded "retains an unregistered target's unresolved records in the observation, counted against capacity, until every batch has completed" testUnregisterRetainsRecords
    itBounded "retains the records of a target whose session failed, releasing nothing on a batch whose completion was never observed" testSessionFailureRetains
    itBounded "ends every target with the owner, leaving a pending use unreleased and a refused request never run" testOwnerExitEndsTargets
    itBounded "discards a batch whose recording the owner's cancellation interrupted before its ticket reached the caller, and releases the revision it read" testCancelledRecording
    itBounded "completes an adoption's record, notification and watermark, and a release's removal and notifications, for an offscreen target whatever cancels the thread meanwhile" testLedgerCancellation

  describe "a host with windows and targets" $ do
    itBounded "leaves a window's barrier entry, adoption and release order as they were with a target registered beside it, and names both in one request" testMixedHost

-- ---------------------------------------------------------------------------
-- Helpers

itBounded ∷ String → IO () → Spec
itBounded requirement test = boundedIt (boundOf 60) requirement (reporting test)
  where
    -- A failure inside a rig's body is reported where it happens: the rig's teardown may wait on what the example
    -- withheld until the bound rescues it, and the bound reports only that it expired.
    reporting action = action `catch` \(failure ∷ SomeException) → hPutStrLn stderr ("Targets example failed: " <> requirement <> ": " <> show failure) >> throwIO failure

failWith ∷ String → IO a
failWith message = expectationFailure message >> throwIO (userError message)

-- | Register a target, failing the example if the host refuses.
registered ∷ VulkanHost Scene → IO OffscreenTargetId
registered host = atomically (registerVulkanSceneTarget host) >>= either (\refusal → failWith ("the registration was refused: " <> show refusal)) pure

-- | Publish a scene to a target in a transaction of its own.
publishNow ∷ VulkanHost Scene → OffscreenTargetId → Scene → IO TargetScenePublication
publishNow host target value = prepare value >>= atomically . publishVulkanTargetScene host target

-- | Block until the owner's startup has made the device and leased the instance.
awaitReady ∷ VulkanHost Scene → IO ()
awaitReady host = atomically (readReadiness (vulkanController host) >>= check . (== RootsReady))

-- | Block, in a transaction over the host's scene state, until the target's standing satisfies the condition.
awaitTargetStanding ∷ VulkanHost Scene → OffscreenTargetId → (WindowSceneStanding -> Bool) → IO ()
awaitTargetStanding host target ok = atomically $ do
  state ← readVulkanSceneState (vulkanController host)
  case Map.lookup (KeyOffscreen target) (sceneWindows state) of
    Just standing | ok standing → pure ()
    _ → retry

currentStanding ∷ VulkanHost Scene → OffscreenTargetId → IO (Maybe WindowSceneStanding)
currentStanding host target = Map.lookup (KeyOffscreen target) . sceneWindows <$> atomically (readVulkanSceneState (vulkanController host))

-- | Block until the lifecycle has reported something that satisfies the condition.
awaitEvents ∷ Rig → ([SceneEvent] → Bool) → IO ()
awaitEvents rig ok = atomically (readTVar (rigSceneEvents rig) >>= check . ok)

adoptedOf ∷ [SceneEvent] → OffscreenTargetId → [(Natural, Scene)]
adoptedOf events target = [(revision, scene) | TargetAdopted at revision scene ← events, at == target]

releasedOf ∷ [SceneEvent] → OffscreenTargetId → [Natural]
releasedOf events target = [revision | TargetReleased at revision ← events, at == target]

-- | Submit an owner-thread action and wait for its outcome.
act ∷ VulkanHost Scene → VulkanAction r → IO (ActionOutcome r)
act host action =
  atomically (submitVulkanAction (vulkanController host) action) >>= \case
    Left refusal → failWith ("the action was refused: " <> show refusal)
    Right ticket → atomically (awaitVulkanAction ticket)

returned ∷ ActionOutcome r → IO r
returned = \case
  ActionReturned value → pure value
  ActionRaised (ExceptionWithContext _ failure) → failWith ("the action raised " <> show failure)
  ActionRefused refusal → failWith ("the action was refused " <> show refusal)

-- | Record one bound frame-less batch for the target in an owner-thread action: its ticket, and the scene and
-- revision the host handed the consumer.
recordFor ∷ VulkanHost Scene → OffscreenTargetId → IO (BatchTicket, (Scene, Natural))
recordFor host target =
  act host (VulkanAction (\construction → recordVulkanTargetBatch host target construction (\scene revision _ → pure (scene, revision))))
    >>= returned
    >>= either (\refusal → failWith ("the batch was refused: " <> show refusal)) pure

-- | A ticket that has settled, by its state in a transaction.
ticketIs ∷ BatchTicket → TicketState → IO ()
ticketIs ticket wanted = atomically (readTicket ticket >>= check . (== wanted))

ticketNow ∷ BatchTicket → IO TicketState
ticketNow = atomically . readTicket

-- | Run an action with the owner's thread held inside an owner-thread action until the body calls the release it
-- is handed (or ends). The handshake is the action's own: the body starts only once the owner is inside it, and
-- the owner is let go however the body ends.
holdingOwner ∷ VulkanHost Scene → (IO () → IO a) → IO a
holdingOwner host body = do
  entered ← newEmptyMVar
  proceed ← newEmptyMVar
  let release = void (tryPutMVar proceed ())
  ticket ←
    atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → putMVar entered () >> takeMVar proceed)))
      >>= either (\refusal → failWith ("the holding action was refused: " <> show refusal)) pure
  takeMVar entered
  answer ← body release `finally` release
  atomically (awaitVulkanAction ticket) >>= \case
    ActionReturned () → pure answer
    ActionRaised failure → failWith ("the holding action raised " <> show failure)
    ActionRefused refusal → failWith ("the holding action was refused " <> show refusal)

-- | A release request whose action records that it ran, with what the lifecycle had reported by then.
requestRecording ∷ VulkanHost Scene → Rig → IO (ActionTicket [SceneEvent])
requestRecording host rig =
  atomically (requestVulkanRelease (vulkanController host) (VulkanAction (\_ → readTVarIO (rigSceneEvents rig))))
    >>= either (\refusal → failWith ("the release request was refused: " <> show refusal)) pure

-- | The request's returned value, once it has run.
ranWith ∷ ActionTicket r → IO (Maybe r)
ranWith ticket =
  atomically (readVulkanAction ticket) >>= \case
    Just (ActionReturned value) → pure (Just value)
    Just _ → failWith "the release request did not return"
    Nothing → pure Nothing

awaitRan ∷ ActionTicket r → IO r
awaitRan ticket = atomically (readVulkanAction ticket >>= maybe retry pure) >>= \case
  ActionReturned value → pure value
  ActionRaised (ExceptionWithContext _ failure) → failWith ("the request raised " <> show failure)
  ActionRefused refusal → failWith ("the request was refused " <> show refusal)

-- | The retention limit of the rig's default budgets.
limitOf ∷ IO Natural
limitOf = either (const (failWith "the default budgets are invalid")) (pure . retentionLimit . frameSlotLimit) (validateBudgets defaultBudgetRequest)

-- ---------------------------------------------------------------------------
-- Registration and publication

testRegistration ∷ IO ()
testRegistration = do
  rig ← surfaceFreeRig 0
  (a, b, first, other, atRest, answers, events) ← runRig rig $ \host _ → do
    awaitReady host
    a ← registered host
    b ← registered host
    -- Each target adopts the initial scene as revision 0 before anything is published, so what follows is
    -- adopted by the owner's later steps only.
    awaitTargetStanding host a ((== Just 0) . windowAdopted)
    awaitTargetStanding host b ((== Just 0) . windowAdopted)
    -- Two publications in one transaction: no owner step falls between, so the first is replaced before any step
    -- could take it.
    one ← prepare 11
    two ← prepare 22
    first ← atomically ((,) <$> publishVulkanTargetScene host a one <*> publishVulkanTargetScene host a two)
    other ← publishNow host b 33
    awaitTargetStanding host a ((== Just 2) . windowAdopted)
    awaitTargetStanding host b ((== Just 1) . windowAdopted)
    atRest ← (,) <$> currentStanding host a <*> currentStanding host b
    unregistered ← atomically (unregisterVulkanSceneTarget host a)
    again ← atomically (unregisterVulkanSceneTarget host a)
    late ← publishNow host a 44
    -- What a had adopted is released once it ended, each revision once.
    awaitEvents rig ((== [0, 2]) . (`releasedOf` a))
    events ← readTVarIO (rigSceneEvents rig)
    pure (a, b, first, other, atRest, (unregistered, again, late), events)
  a `shouldSatisfy` (/= b)
  first `shouldBe` (TargetScenePublished a 1, TargetScenePublished a 2)
  other `shouldBe` TargetScenePublished b 1
  let (standingA, standingB) = atRest
  fmap windowPublished standingA `shouldBe` Just (Just 2)
  fmap windowAdopted standingA `shouldBe` Just (Just 2)
  fmap windowPublished standingB `shouldBe` Just (Just 1)
  -- The revision replaced before a step took it was never adopted, and so never announced.
  adoptedOf events a `shouldBe` [(0, 0), (2, 22)]
  adoptedOf events b `shouldBe` [(0, 0), (1, 33)]
  answers `shouldBe` (True, False, TargetSceneUnknown a)
  releasedOf events a `shouldBe` [0, 2]
  -- An identity another host issued is no registration of this one, and cannot publish to it.
  foreignRig ← surfaceFreeRig 0
  (foreignAnswer, foreignUnregistered, own) ← runRig foreignRig $ \host _ → do
    awaitReady host
    mine ← registered host
    answer ← publishNow host a 1
    gone ← atomically (unregisterVulkanSceneTarget host a)
    pure (answer, gone, mine)
  foreignAnswer `shouldBe` TargetSceneUnknown a
  foreignUnregistered `shouldBe` False
  own `shouldSatisfy` (/= a)

testRegistrationRefusals ∷ IO ()
testRegistrationRefusals = do
  -- No device yet: the device is made at the first window's admission, and there is none.
  early ← newRigOf 0
  notReady ← runRig early $ \host _ → atomically (registerVulkanSceneTarget host)
  notReady `shouldBe` Left TargetDeviceNotReady
  -- A session that failed.
  rig ← surfaceFreeRig 0
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    target ← registered host
    reportErrorNow rig "an error while a target is registered"
    -- The round that takes the error: a publication asks the owner for one, as an application does.
    _ ← publishNow host target 1
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    afterFailure ← atomically (registerVulkanSceneTarget host)
    published ← publishNow host target 2
    atomically (writeTVar observed (Just (afterFailure, published, target)))
    checkRuntime control
  readTVarIO observed >>= \case
    Nothing → failWith ("the failure example did not reach its observation: " <> either show (const "it returned") outcome)
    Just (afterFailure, published, target) → do
      afterFailure `shouldSatisfy` \case
        Left (TargetSessionFailed _) → True
        _ → False
      published `shouldBe` TargetSceneClosed target
  -- An owner whose exit has begun, and a publication made to a closed host.
  ended ← surfaceFreeRig 0
  (hostAfter, target) ← runRig ended $ \host _ → do
    awaitReady host
    t ← registered host
    pure (host, t)
  closedRegistration ← atomically (registerVulkanSceneTarget hostAfter)
  closedRegistration `shouldBe` Left TargetOwnerClosed
  closedPublication ← publishNow hostAfter target 5
  closedPublication `shouldBe` TargetSceneClosed target

testCapacity ∷ IO ()
testCapacity = do
  -- Two targets fit; the third is refused naming the capacity; a window's bound is no part of it.
  rig ← withTargetCapacity 2 <$> surfaceFreeRig 1
  (refused, windowsHeld, again) ← runRig rig $ \host _ → do
    awaitReady host
    a ← registered host
    _ ← registered host
    refused ← atomically (registerVulkanSceneTarget host)
    windowsHeld ← length <$> windowsOf host
    _ ← atomically (unregisterVulkanSceneTarget host a)
    -- The owner ends the retired target in its next step, which frees its place: the registration waits, in a
    -- transaction, for that fact and not for a clock.
    again ← atomically (registerVulkanSceneTarget host >>= either (const retry) pure)
    pure (refused, windowsHeld, again)
  refused `shouldBe` Left (TargetCapacityReached 2)
  windowsHeld `shouldBe` 1
  again `shouldSatisfy` const True
  -- A capacity of nothing refuses every registration, and still holds the window.
  none ← withTargetCapacity 0 <$> surfaceFreeRig 1
  (noneRefused, noneWindows) ← runRig none $ \host _ → do
    awaitReady host
    (,) <$> atomically (registerVulkanSceneTarget host) <*> (length <$> windowsOf host)
  noneRefused `shouldBe` Left (TargetCapacityReached 0)
  noneWindows `shouldBe` 1

-- ---------------------------------------------------------------------------
-- The barrier

testBarrierWaitsForAdoption ∷ IO ()
testBarrierWaitsForAdoption = do
  rig ← surfaceFreeRig 0
  (target, queued, heldStanding, ranAt, afterRun) ← runRig rig $ \host _ → do
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    (queued, heldStanding, ticket) ← holdingOwner host $ \release → do
      -- Accepted, and the request made, in one transaction: the revision it awaits is the one just accepted.
      scene ← prepare 71
      (published, ticket, state) ← atomically $ do
        p ← publishVulkanTargetScene host target scene
        t ← requestVulkanRelease (vulkanController host) (VulkanAction (\_ → readTVarIO (rigSceneEvents rig)))
        s ← readVulkanSceneState (vulkanController host)
        pure (p, t, s)
      published `shouldBe` TargetScenePublished target 1
      held ← either (\refusal → failWith ("refused: " <> show refusal)) pure ticket
      -- The owner is inside the holding action, so it has taken nothing: the request is held by an adoption that
      -- has not happened.
      notRun ← ranWith held
      notRun `shouldSatisfy` isNothing
      release
      pure (sceneRequests state, Map.lookup (KeyOffscreen target) (sceneWindows state), held)
    seen ← awaitRan ticket
    after ← currentStanding host target
    pure (target, queued, heldStanding, seen, after)
  queued `shouldBe` [Map.singleton (KeyOffscreen target) 1]
  fmap windowPublished heldStanding `shouldBe` Just (Just 1)
  fmap windowAdopted heldStanding `shouldBe` Just (Just 0)
  -- It ran only after the target had adopted revision 1.
  adoptedOf ranAt target `shouldBe` [(0, 0), (1, 71)]
  fmap windowAdopted afterRun `shouldBe` Just (Just 1)

testBarrierEndsWithUnregistration ∷ IO ()
testBarrierEndsWithUnregistration = do
  rig ← surfaceFreeRig 0
  (target, ranAt, events) ← runRig rig $ \host _ → do
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    ticket ← holdingOwner host $ \release → do
      scene ← prepare 81
      (_, queued) ← atomically ((,) <$> publishVulkanTargetScene host target scene <*> requestVulkanRelease (vulkanController host) (VulkanAction (\_ → readTVarIO (rigSceneEvents rig))))
      held ← either (\refusal → failWith ("refused: " <> show refusal)) pure queued
      -- The target ends before the owner can adopt what it accepted.
      ended ← atomically (unregisterVulkanSceneTarget host target)
      ended `shouldBe` True
      release
      pure held
    seen ← awaitRan ticket
    awaitEvents rig ((== [0]) . (`releasedOf` target))
    events ← readTVarIO (rigSceneEvents rig)
    pure (target, seen, events)
  -- The request ran, though revision 1 was never adopted; what the target did adopt was released once.
  adoptedOf ranAt target `shouldBe` [(0, 0)]
  adoptedOf events target `shouldBe` [(0, 0)]
  releasedOf events target `shouldBe` [0]

testInitialSceneExemption ∷ IO ()
testInitialSceneExemption = do
  named ← barrierWith False
  named `shouldBe` Map.singleton True 0
  exempt ← barrierWith True
  exempt `shouldBe` Map.empty
  where
    -- The barrier a request names for a target registered while the owner has not yet adopted its revision 0.
    barrierWith ∷ Bool → IO (Map.Map Bool Natural)
    barrierWith holdsNothing = do
      rig ← (if holdsNothing then withInitialSceneHoldsNothing else id) <$> surfaceFreeRig 0
      runRig rig $ \host _ → do
        awaitReady host
        holdingOwner host $ \release → do
          target ← registered host
          queued ← atomically (requestVulkanRelease (vulkanController host) (VulkanAction (\_ → pure ())) >>= \t → (,) t <$> readVulkanSceneState (vulkanController host))
          ticket ← either (\refusal → failWith ("refused: " <> show refusal)) pure (fst queued)
          release
          void (awaitRan ticket)
          pure (Map.mapKeys (== KeyOffscreen target) (Map.unions (sceneRequests (snd queued))))

testHeldRequestRefused ∷ IO ()
testHeldRequestRefused = do
  -- The session fails while a request waits for an adoption: it is settled as refused and never run.
  rig ← surfaceFreeRig 0
  ran ← newTVarIO False
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    ticket ← holdingOwner host $ \release → do
      scene ← prepare 91
      (_, queued) ← atomically ((,) <$> publishVulkanTargetScene host target scene <*> requestVulkanRelease (vulkanController host) (VulkanAction (\_ → atomically (writeTVar ran True))))
      held ← either (\refusal → failWith ("refused: " <> show refusal)) pure queued
      reportErrorNow rig "an error while a request waits"
      release
      pure held
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    settled ← atomically (awaitVulkanAction ticket)
    atomically (writeTVar observed (Just (case settled of ActionRefused refusal → Just refusal; _ → Nothing)))
    checkRuntime control
  readTVarIO observed >>= \case
    Nothing → failWith ("the failure example did not reach its observation: " <> either show (const "it returned") outcome)
    Just refusal → refusal `shouldSatisfy` \case
      Just (ActionSessionFailed _) → True
      Just ActionOwnerClosed → True
      _ → False
  readTVarIO ran >>= (`shouldBe` False)

-- ---------------------------------------------------------------------------
-- Adoption and release

testReleaseOnTicketCompletion ∷ IO ()
testReleaseOnTicketCompletion = do
  rig ← surfaceFreeRig 0
  submissionsComplete rig False
  (target, beforeCompletion, settled) ← runRig rig $ \host _ → do
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    _ ← publishNow host target 11
    awaitTargetStanding host target ((== Just 1) . windowAdopted)
    (ticket, handed) ← recordFor host target
    handed `shouldBe` (11, 1)
    _ ← publishNow host target 22
    awaitTargetStanding host target ((== Just 2) . windowAdopted)
    -- Revision 0 had no use and was released as soon as revision 1 superseded it. Revision 1 is superseded and its
    -- batch is submitted, and neither the submission nor the owner's rounds release it: its completion is withheld.
    awaitEvents rig ((== [0]) . (`releasedOf` target))
    pending ← ticketNow ticket
    standing ← currentStanding host target
    -- A whole owner round after that, in which nothing was announced.
    roundTrip host
    heldEvents ← readTVarIO (rigSceneEvents rig)
    submissionsComplete rig True
    ticketIs ticket TicketComplete
    awaitEvents rig ((== [0, 1]) . (`releasedOf` target))
    -- And a whole round after the release, which announces nothing more.
    roundTrip host
    events ← readTVarIO (rigSceneEvents rig)
    final ← currentStanding host target
    pure (target, (pending, standing, releasedOf heldEvents target), (releasedOf events target, fmap windowAwaitingRelease final))
  let (pending, standing, releasedWhileHeld) = beforeCompletion
  pending `shouldBe` TicketPending
  fmap windowAwaitingRelease standing `shouldBe` Just [1]
  releasedWhileHeld `shouldBe` [0]
  settled `shouldBe` ([0, 1], Just [])
  target `shouldSatisfy` const True

-- | A whole owner step that began after the caller had observed what it was waiting for: an owner-thread action
-- runs in a step that begins after it was admitted, so by the time it has returned, the step that was in progress
-- when it was admitted has ended, with every release it made.
roundTrip ∷ VulkanHost Scene → IO ()
roundTrip host = void (act host (VulkanAction (\_ → pure ())) >>= returned)

testUnrelatedCompletion ∷ IO ()
testUnrelatedCompletion = do
  rig ← surfaceFreeRig 0
  submissionsComplete rig False
  (states, afterOne, afterAll) ← runRig rig $ \host _ → do
    awaitReady host
    t ← registered host
    u ← registered host
    for_ [t, u] $ \target → awaitTargetStanding host target ((== Just 0) . windowAdopted)
    for_ [t, u] $ \target → do
      _ ← publishNow host target 5
      awaitTargetStanding host target ((== Just 1) . windowAdopted)
    -- Two batches read revision 1 of t, and one reads revision 1 of u: three uses, all pending.
    (t1, _) ← recordFor host t
    (t2, _) ← recordFor host t
    (u1, _) ← recordFor host u
    for_ [t, u] $ \target → publishNow host target 6 >> awaitTargetStanding host target ((== Just 2) . windowAdopted)
    -- Exactly one submission fence answers signalled, whichever the owner asks about first.
    completeNextSubmissions rig (Just 1)
    submissionsComplete rig True
    atomically $ do
      current ← traverse readTicket [t1, t2, u1]
      check (length (filter (== TicketComplete) current) == 1)
    states ← (,,) <$> ticketNow t1 <*> ticketNow t2 <*> ticketNow u1
    -- The completion was observed by a step that has since ended: the action below runs in a later one.
    roundTrip host
    afterOne ← (\events → (releasedOf events t, releasedOf events u)) <$> readTVarIO (rigSceneEvents rig)
    completeNextSubmissions rig Nothing
    for_ [t1, t2, u1] (`ticketIs` TicketComplete)
    awaitEvents rig (\events → releasedOf events t == [0, 1] && releasedOf events u == [0, 1])
    afterAll ← (\events → (releasedOf events t, releasedOf events u)) <$> readTVarIO (rigSceneEvents rig)
    pure (states, afterOne, afterAll)
  -- Exactly one batch completed; t's revision needs both of its batches and u's needs its one, so a completion
  -- that belongs to another batch discharged nothing: u's revision was released only if u's own batch completed,
  -- and t's was not released at all.
  let (t1State, t2State, u1State) = states
  length (filter (== TicketComplete) [t1State, t2State, u1State]) `shouldBe` 1
  afterOne `shouldBe` ([0], if u1State == TicketComplete then [0, 1] else [0])
  afterAll `shouldBe` ([0, 1], [0, 1])

-- | A deliberate failure of a consumer, which only the example that raises it expects.
data ConsumerRaised = ConsumerRaised
  deriving (Show)

instance Exception ConsumerRaised

testDiscardEndsUse ∷ IO ()
testDiscardEndsUse = do
  rig ← surfaceFreeRig 0
  submissionsComplete rig False
  (target, raised, events) ← runRig rig $ \host _ → do
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    _ ← publishNow host target 3
    awaitTargetStanding host target ((== Just 1) . windowAdopted)
    -- The consumer records a batch and then raises: the action's scope discards the batch, so its ticket is
    -- discarded and the use it opened ends, though no completion was ever observed and none can be.
    outcome ← act host (VulkanAction (\construction → recordVulkanTargetBatch host target construction (\_ _ _ → throwIO ConsumerRaised)))
    raised ← case outcome of
      ActionRaised (ExceptionWithContext _ failure) → pure (isJust (fromException failure ∷ Maybe ConsumerRaised))
      _ → failWith "the consumer's failure was not the action's outcome"
    _ ← publishNow host target 4
    awaitEvents rig ((== [0, 1]) . (`releasedOf` target))
    events ← readTVarIO (rigSceneEvents rig)
    pure (target, raised, events)
  raised `shouldBe` True
  releasedOf events target `shouldBe` [0, 1]

testRetentionLimit ∷ IO ()
testRetentionLimit = do
  rig ← surfaceFreeRig 0
  submissionsComplete rig False
  limit ← limitOf
  (target, atLimit, notRunYet, ranAt, finalAwaiting) ← runRig rig $ \host _ → do
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    _ ← publishNow host target 1
    awaitTargetStanding host target ((== Just 1) . windowAdopted)
    -- One pending batch on revision 1 keeps it, and every later revision behind it in adoption order, awaiting
    -- release: the records pile up to the limit behind it.
    (ticket, _) ← recordFor host target
    for_ [2 .. limit] $ \revision → do
      _ ← publishNow host target (fromIntegral revision)
      awaitTargetStanding host target ((== Just revision) . windowAdopted)
    -- The next publication is accepted at once, and its adoption is deferred.
    overflow ← publishNow host target 99
    overflow `shouldBe` TargetScenePublished target (limit + 1)
    awaitTargetStanding host target ((>= 1) . windowDeferrals)
    atLimit ← currentStanding host target
    -- A request made after that publication waits for a revision the target cannot adopt yet.
    queued ← requestRecording host rig
    roundTrip host
    notRunYet ← ranWith queued
    -- The pending batch completes: the records are released in adoption order, room is made, and the deferred
    -- revision is adopted, which runs the request.
    submissionsComplete rig True
    ticketIs ticket TicketComplete
    seen ← awaitRan queued
    awaitEvents rig ((== [0 .. limit]) . (`releasedOf` target))
    roundTrip host
    final ← currentStanding host target
    pure (target, atLimit, notRunYet, seen, fmap windowAwaiting final)
  fmap windowAdopted atLimit `shouldBe` Just (Just limit)
  fmap windowPublished atLimit `shouldBe` Just (Just (limit + 1))
  fmap (length . windowAwaitingRelease) atLimit `shouldBe` Just (fromIntegral limit - 1)
  fmap windowDeferrals atLimit `shouldBe` Just 1
  notRunYet `shouldSatisfy` isNothing
  -- The request ran in the step that adopted the deferred revision, after the releases the completion made: the
  -- revisions were released in adoption order, each once, and the deferred one adopted after them.
  releasedOf ranAt target `shouldBe` [0 .. limit - 1]
  adoptedOf ranAt target `shouldBe` [(revision, fromIntegral revision) | revision ← [0 .. limit]] <> [(limit + 1, 99)]
  finalAwaiting `shouldBe` Just []
  where
    windowAwaiting = windowAwaitingRelease

-- ---------------------------------------------------------------------------
-- Teardown

testUnregisterRetainsRecords ∷ IO ()
testUnregisterRetainsRecords = do
  rig ← withTargetCapacity 1 <$> surfaceFreeRig 0
  submissionsComplete rig False
  (target, retained, whileHeld, afterEnd, reused) ← runRig rig $ \host _ → do
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    (ticket, handed) ← recordFor host target
    handed `shouldBe` (0, 0)
    ended ← atomically (unregisterVulkanSceneTarget host target)
    ended `shouldBe` True
    -- The registration is gone and the record is not: the batch that read revision 0 is pending, so the target's
    -- adoption stays in the observation, and it still counts against the capacity.
    awaitTargetStanding host target (\standing → windowPublished standing == Nothing && windowAwaitingRelease standing == [0])
    retained ← currentStanding host target
    whileHeld ← atomically (registerVulkanSceneTarget host)
    afterEnd ← publishNow host target 7
    submissionsComplete rig True
    ticketIs ticket TicketComplete
    awaitEvents rig ((== [0]) . (`releasedOf` target))
    -- Resolved, the place is free again.
    reused ← atomically (registerVulkanSceneTarget host >>= either (const retry) pure)
    pure (target, retained, whileHeld, afterEnd, reused)
  fmap windowAdopted retained `shouldBe` Just Nothing
  fmap windowAwaitingRelease retained `shouldBe` Just [0]
  whileHeld `shouldBe` Left (TargetCapacityReached 1)
  afterEnd `shouldBe` TargetSceneUnknown target
  reused `shouldSatisfy` (/= target)

testSessionFailureRetains ∷ IO ()
testSessionFailureRetains = do
  rig ← surfaceFreeRig 0
  submissionsComplete rig False
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    _ ← publishNow host target 1
    awaitTargetStanding host target ((== Just 1) . windowAdopted)
    (ticket, _) ← recordFor host target
    _ ← publishNow host target 2
    awaitTargetStanding host target ((== Just 2) . windowAdopted)
    -- The device is lost while a second batch is recorded: the session fails, and the first batch's submission is
    -- let go of by the loss, which is not completion.
    loseWhileRecording rig
    _ ← act host (VulkanAction (\construction → recordVulkanTargetBatch host target construction (\_ _ _ → pure ())))
    atomically (readOwnerFailure (vulkanGraphicsOwner host) >>= check . isJust)
    atomically (writeTVar observed (Just (host, target, ticket)))
    checkRuntime control
  readTVarIO observed >>= \case
    Nothing → failWith ("the failure example did not reach its observation: " <> either show (const "it returned") outcome)
    Just (host, target, ticket) → do
      -- The loss settled the ticket as lost, never as complete, so the revision the batch read is not released by
      -- the loss or by the owner's teardown: it stays on the ledger, in the observation.
      ticketNow ticket `shouldReturnState` TicketLost
      events ← readTVarIO (rigSceneEvents rig)
      releasedOf events target `shouldBe` [0]
      state ← atomically (readVulkanSceneState (vulkanController host))
      fmap windowAwaitingRelease (Map.lookup (KeyOffscreen target) (sceneWindows state)) `shouldSatisfy` maybe False (elem 1)
  where
    shouldReturnState action wanted = action >>= (`shouldBe` wanted)

testOwnerExitEndsTargets ∷ IO ()
testOwnerExitEndsTargets = do
  rig ← surfaceFreeRig 0
  entered ← newEmptyMVar
  proceed ← newEmptyMVar
  (hostAfter, target, queued, holding) ← runRig rig $ \host _ → do
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    -- The owner is held inside an action, so a publication accepted now is not adopted before the exit.
    holding ←
      atomically (submitVulkanAction (vulkanController host) (VulkanAction (\_ → putMVar entered () >> takeMVar proceed)))
        >>= either (\refusal → failWith ("the holding action was refused: " <> show refusal)) pure
    takeMVar entered
    scene ← prepare 61
    (_, held) ← atomically ((,) <$> publishVulkanTargetScene host target scene <*> requestVulkanRelease (vulkanController host) (VulkanAction (\_ → readTVarIO (rigSceneEvents rig))))
    queued ← either (\refusal → failWith ("refused: " <> show refusal)) pure held
    -- The owner is let go only once its exit has begun, which the host's own admission says, in a transaction.
    void . forkIO $ do
      atomically (targetEventsOpen (ownerHandoff (vulkanGraphicsOwner host)) >>= check . not)
      putMVar proceed ()
    pure (host, target, queued, holding)
  -- The exit ended the target: nothing can be published to it, nothing can be registered, and the request it held
  -- was refused, never run.
  after ← publishNow hostAfter target 5
  after `shouldBe` TargetSceneClosed target
  atomically (readVulkanAction queued) >>= \case
    Just (ActionRefused ActionOwnerClosed) → pure ()
    _ → failWith "the held request was not settled as refused by the owner's exit"
  atomically (readVulkanAction holding) >>= \case
    Just (ActionReturned ()) → pure ()
    _ → failWith "the holding action did not return"
  -- What the target had adopted was released by its end, once; the revision it never adopted was never announced.
  events ← readTVarIO (rigSceneEvents rig)
  adoptedOf events target `shouldBe` [(0, 0)]
  releasedOf events target `shouldBe` [0]

testCancelledRecording ∷ IO ()
testCancelledRecording = do
  rig ← surfaceFreeRig 0
  submissionsComplete rig False
  observed ← newTVarIO Nothing
  outcome ← runRigCaught rig $ \host control → do
    _ ← superviseGraphicsOwner control (vulkanGraphicsOwner host)
    awaitReady host
    target ← registered host
    awaitTargetStanding host target ((== Just 0) . windowAdopted)
    _ ← publishNow host target 1
    awaitTargetStanding host target ((== Just 1) . windowAdopted)
    -- The owner is cancelled inside the consumer, once the batch exists and before the recording returns, so the
    -- ticket never reaches the caller.
    _ ←
      act host (VulkanAction (\construction →
        recordVulkanTargetBatch host target construction (\_ _ _ → do
          owner ← myThreadId
          throwTo owner ThreadKilled)))
    -- The owner ran its retirement and ended: that is the owner's own phase, read in a transaction.
    atomically (readOwnerStatusNow (vulkanGraphicsOwner host) >>= check . (== OwnerFinished) . statusPhase)
    atomically (writeTVar observed (Just target))
    checkRuntime control
  target ← readTVarIO observed >>= maybe (failWith ("the cancellation example did not reach its observation: " <> either show (const "it returned") outcome)) pure
  events ← readTVarIO (rigSceneEvents rig)
  -- The scope discarded the interrupted batch, so the revision it read was released on that evidence when the
  -- owner's teardown ended the target: each adoption once, in order, and nothing left behind.
  adoptedOf events target `shouldBe` [(0, 0), (1, 1)]
  releasedOf events target `shouldBe` [0, 1]

-- | The ledger's two transitions for an offscreen target, cancelled from outside while their hooks run: the
-- adoption is recorded, notified and published to the barrier, and the release is removed and notified for every
-- record it took, whatever cancels the thread meanwhile.
testLedgerCancellation ∷ IO ()
testLedgerCancellation = do
  identity ← OffscreenTargetId <$> newUnique <*> pure 0
  scenes ← newScenes False
  atomically (registerSceneTarget scenes (TargetAdopter identity))
  hooks ← newTVarIO ([] ∷ [String])
  entered ← newEmptyMVar
  proceed ← newEmptyMVar
  let lifecycle =
        SceneLifecycle
          { sceneAdopted = \_ revision _ → do
              atomically (modifyTVar' hooks (<> ["adopted " <> show revision]))
              putMVar entered ()
              takeMVar proceed
          , sceneReleased = \_ revision → do
              atomically (modifyTVar' hooks (<> ["released " <> show revision]))
              putMVar entered ()
              takeMVar proceed
          }
      cancelDuring action = do
        finished ← newEmptyMVar
        thread ← forkIO (try @SomeException (void action) >>= putMVar finished)
        takeMVar entered
        -- The cancellation is delivered once the transition ends, never in it: the thrower is blocked until then,
        -- and only then is the hook let go.
        cancelled ← forkIO (throwTo thread (ErrorCall "cancelled"))
        awaitSettled cancelled
        putMVar proceed ()
        takeMVar finished
      standingOf = Map.lookup (KeyOffscreen identity) . sceneWindows
  -- An adoption cancelled while its hook runs.
  _ ← cancelDuring (adoptScene scenes lifecycle 100 (TargetAdopter identity) (5 ∷ Scene) 3)
  standing ← atomically (readSceneState scenes (pure []))
  -- A second revision, then the target ends: two records are due, and the release is cancelled while the first
  -- one's hook runs.
  _ ← cancelDuring (adoptScene scenes lifecycle 100 (TargetAdopter identity) (6 ∷ Scene) 4)
  atomically (endSceneTarget scenes (TargetAdopter identity))
  finished ← newEmptyMVar
  thread ← forkIO (try @SomeException (releaseScenes scenes (sceneReleased lifecycle) (\_ _ → pure False)) >>= putMVar finished)
  takeMVar entered
  cancelled ← forkIO (throwTo thread (ErrorCall "cancelled"))
  awaitSettled cancelled
  putMVar proceed ()
  -- The second record's hook runs as well, though the first was cancelled.
  takeMVar entered
  putMVar proceed ()
  _ ← takeMVar finished
  after ← atomically (readSceneState scenes (pure []))
  done ← readTVarIO hooks
  fmap windowAdopted (standingOf standing) `shouldBe` Just (Just 3)
  maybe [] windowAwaitingRelease (standingOf after) `shouldBe` []
  done `shouldBe` ["adopted 3", "adopted 4", "released 3", "released 4"]

-- | Wait until a thread that was thrown to is blocked on the delivery or has finished.
awaitSettled ∷ ThreadId → IO ()
awaitSettled thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → pure ()
    ThreadDied → pure ()
    _ → yield >> awaitSettled thread

-- ---------------------------------------------------------------------------
-- Windows and targets

testMixedHost ∷ IO ()
testMixedHost = do
  rig ← withPerWindowScenes <$> visibleRigOf 1
  (window, key, requests, ranAt, events) ← runRig rig $ \host control → do
    [window] ← windowsOf host
    service ← handedOver host window RequiredTarget
    TargetUsable ← awaitStanding host service
    target ← registered host
    -- Both have adopted the initial scene as revision 0.
    composedUntil host control "both adoptions of revision 0" $ do
      adopted ← (,) <$> (any isWindowAdoption <$> sceneEvents rig) <*> (isJust . (>>= windowAdopted) <$> currentStanding host target)
      pure (fst adopted && snd adopted)
    windowScene ← prepare 31
    targetScene ← prepare 32
    -- The window's publication, the target's and the request are one fact: the request names both.
    (published, ticket, state) ← atomically $ do
      p ← publishGraphicsWindowScene (vulkanGraphicsOwner host) window windowScene
      q ← publishVulkanTargetScene host target targetScene
      t ← requestVulkanRelease (vulkanController host) (VulkanAction (\_ → readTVarIO (rigSceneEvents rig)))
      s ← readVulkanSceneState (vulkanController host)
      pure ((p, q), t, s)
    published `shouldBe` (WindowScenePublished window 1, TargetScenePublished target 1)
    held ← either (\refusal → failWith ("refused: " <> show refusal)) pure ticket
    composedUntil host control "the request's run" (isJust <$> ranWith held)
    seen ← ranWith held >>= maybe (failWith "the request did not run") pure
    final ← readTVarIO (rigSceneEvents rig)
    pure (window, KeyOffscreen target, sceneRequests state, (seen, target), final)
  -- The request waited for the window and the target both, each at its own revision.
  case requests of
    [named] → (Map.lookup (KeyWindow window) named, Map.lookup key named) `shouldBe` (Just 1, Just 1)
    other → failWith ("expected one pending request, saw " <> show other)
  -- Each adopted its own publication when the request ran, and the window's adoptions are what they have always
  -- been: revision 0, then its own.
  let (seen, target) = ranAt
  adoptedByWindow seen window `shouldBe` [(0, 0), (1, 31)]
  adoptedOf seen target `shouldBe` [(0, 0), (1, 32)]
  adoptedByWindow events window `shouldBe` [(0, 0), (1, 31)]
  where
    isWindowAdoption = \case
      SceneAdopted {} → True
      _ → False
    adoptedByWindow events window = [(revision, scene) | SceneAdopted at revision scene ← events, at == window]

-- | Run the composed loop until the condition holds, failing the example past twenty thousand turns.
composedUntil ∷ VulkanHost Scene → RuntimeControl → String → IO Bool → IO ()
composedUntil host control what done =
  runVulkanOwnerLoop host control $
    defaultScheduledHooks quietLogger $ \turn → do
      finished ← done
      if finished
        then pure (FinishWith ())
        else
          if turnNumber (scheduledTurn turn) > 20000
            then failWith ("the loop never reached " <> what)
            else pure (ContinueWith NoUpdateDemand)
