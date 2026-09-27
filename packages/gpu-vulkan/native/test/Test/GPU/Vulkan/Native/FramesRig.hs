-- | The frames' headless rig: started roots over the roots' stand-in, one or
-- more targets each with a generation, a recording and the frames over the
-- frames' stand-in ("Test.GPU.Vulkan.Native.FramesStandIn"), and the helpers
-- the frames' examples share — "Test.GPU.Vulkan.Native.Frames" and
-- "Test.GPU.Vulkan.Native.FramesPresentation" both drive it. Nothing here
-- creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.FramesRig
  ( -- * The rig
    Rig (..)
  , newRig
  , newRigWith
  , newRigWithActions
  , newRigOver
  , geometries
  , commandsOf

    -- * Driving it
  , acquired
  , acquiredOn
  , owned
  , ownedOn
  , sealed
  , submitted
  , progress
  , settleAll
  , ok
  , clean
  , cancelled
  , inModel
  , exhaust

    -- * Reading it
  , modelOf
  , frameOf
  , phaseOf
  , targetOf
  , targetViewOf
  , generationsOf
  , generationsOn
  , activeGeneration
  , activeGenerationOn
  , submittedOn
  , standingOf
  , acquisitionState

    -- * Expectations
  , raises
  , shouldReturn'
  , partialStanding
  , uncertainStage
  , failedStage
  , submittedStage
  , kind
  , isSubmission
  , isQuery
  , isRelease
  , isAcquisition
  , isCleanup
  , isDestruction
  , isPresentation
  , isWait
  , at
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, yield)
import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), Exception, SomeException, fromException, try)
import Control.Monad (unless, when)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Conc (BlockReason (..), ThreadStatus (..), threadStatus)
import Numeric.Natural (Natural)
import Test.Hspec (Expectation, expectationFailure, shouldBe, shouldReturn)

import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant)
import Hetoimasia.GPU.Model
  ( FramePhase (..)
  , FrameView (..)
  , GpuModel
  , HoldView (..)
  , Outcome (..)
  , TargetView (..)
  , beginAllocation
  , frameView
  , holdView
  , modelBudgets
  , targetView
  , usage
  , usageObjects
  )
import Hetoimasia.GPU.Model.Budget (BudgetRequest (..), defaultBudgetRequest, objectLimit, validateBudgets)
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , GenerationId
  , HoldSubject (..)
  , SubmissionId
  , TargetClass (..)
  , TargetId
  , frameSlotNumber
  )
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (newRecordingStandIn, recordingStandInOps)
import Test.GPU.Vulkan.Native.StandIn (StandIn, StandInRoots, newStandIn, newStandInRoots, standardRequest, surfaceNumbered)

data Rig = Rig
  { rigStandIn ∷ !FramesStandIn
  , rigRootsStandIn ∷ !StandIn
  , rigRoots ∷ !StandInRoots
  , rigGenerations ∷ !(Generations () Int Int Text Int)
  , rigRecording ∷ !(Recording () Int Int Text Int Word64)
  , rigFrames ∷ !(Frames () Int Int Text Int Word64)
  , rigTarget ∷ !TargetId
    -- ^ The first target.
  , rigTargets ∷ ![TargetId]
    -- ^ Every target, in the order they were admitted.
  , rigStorages ∷ ![FrameStorage]
  , rigCommands ∷ ![Word64]
  }

-- | Started roots over the stand-in, one target on surface 10 with a 640 by
-- 480 generation of three images, a recording, the frames, and a storage for
-- each of the target's two frame slots.
newRig ∷ IO Rig
newRig = newRigWith 2

newRigWith ∷ Integer → IO Rig
newRigWith slots = newRigWithActions slots 32

-- | 'newRigWith' with this many progress actions a step.
newRigWithActions ∷ Integer → Integer → IO Rig
newRigWithActions slots actions = newRigOver 1 defaultBudgetRequest {requestedFrameSlots = slots, requestedProgressActions = actions}

-- | A rig of this many targets — on surfaces 10, 11 and so on, each with a 640
-- by 480 generation of three images and a storage for each of its frame
-- slots — over these budgets. The storages are the first target's first.
newRigOver ∷ Int → BudgetRequest → IO Rig
newRigOver count request = do
  rootsStandIn ← newStandIn
  roots ← newStandInRoots rootsStandIn (either (error . show) id (validateBudgets request))
  _ ← startRoots roots standardRequest
  targets ← mapM (\surface → admitRootTarget roots OptionalTarget (surfaceNumbered rootsStandIn surface) >>= either (fail . show) pure) (take count [10 ..])
  generations ← newGenerations roots
  mapM_ (\(target, surface) → atomically (trackTarget generations target OptionalTarget surface)) (zip targets [10 ..])
  _ ← stepGenerations generations (at 0) (geometries targets (SurfaceExtent 640 480))
  recordingStandIn ← newRecordingStandIn
  recording ← newRecording (recordingStandInOps recordingStandIn) roots generations
  standIn ← newFramesStandIn
  frames ← newFrames (framesStandInOps standIn) recording
  storages ←
    sequence
      [ createFrameStorage recording target slot >>= either (fail . show) pure
      | target ← targets
      , slot ← [0 .. fromIntegral (requestedFrameSlots request) - 1]
      ]
  views ← atomically (readManaged recording)
  let commands = [handle | ManagedView _ _ "frame storage" [handle] ← views]
  case targets of
    first : _ → pure (Rig standIn rootsStandIn roots generations recording frames first targets storages commands)
    [] → fail "a rig needs a target"

-- | Every target at this extent, as its owner would publish it.
geometries ∷ [TargetId] → SurfaceExtent → Map.Map TargetId TargetGeometry
geometries targets extent = Map.fromList [(target, TargetGeometry (Right ()) (Just extent) Nothing 1) | target ← targets]

-- | The command buffer of a slot's storage: the stand-in allocates it right
-- after the pool, so it is the pool's number plus one.
commandsOf ∷ Rig → Natural → Word64
commandsOf rig slot = (rigCommands rig !! fromIntegral slot) + 1

acquired ∷ Rig → IO Acquisition
acquired rig = acquiredOn rig (rigTarget rig)

acquiredOn ∷ Rig → TargetId → IO Acquisition
acquiredOn rig target = tryAcquireFrame (rigFrames rig) target >>= either (fail . ("the acquisition was refused: " <>) . show) pure

owned ∷ Rig → IO OwnedFrame
owned rig = ownedOn rig (rigTarget rig)

ownedOn ∷ Rig → TargetId → IO OwnedFrame
ownedOn rig target =
  acquiredOn rig target >>= \case
    AcquisitionOwned frame → pure frame
    other → fail ("no frame was acquired: " <> show other)

-- | An empty batch, sealed, for the frame.
sealed ∷ Rig → OwnedFrame → IO BatchId
sealed rig frame = fst <$> (recordFrame (rigRecording rig) (ownedFrame frame) (\_ → pure ()) >>= either (fail . ("the recording was refused: " <>) . show) pure)

submitted ∷ Rig → NonEmpty BatchId → IO SubmissionId
submitted rig batches =
  submitFrames (rigFrames rig) batches >>= \case
    Right (SubmittedAs submission) → pure submission
    other → fail ("the submission answered " <> show other)

progress ∷ Rig → IO Progress
progress rig = progressFrames (rigFrames rig) (at 1)

-- | Complete everything pending and step, until no frame is being abandoned
-- and nothing is pending.
settleAll ∷ Rig → IO ()
settleAll rig = go (8 ∷ Int)
  where
    go 0 = expectationFailure "the frames did not settle in eight steps"
    go remaining = do
      completeAll (rigStandIn rig)
      report ← progress rig
      abandoning ← filter (abandoningStage . standingStage) <$> atomically (readFrameStandings (rigFrames rig))
      pending ← pendingFences (rigStandIn rig)
      when (not (null abandoning) || not (null pending) || progressOutstanding report > 0) (go (remaining - 1))
    abandoningStage = \case
      StageSkipping → True
      StageClosing _ → True
      StageSettling → True
      _ → False

ok ∷ Show refusal ⇒ IO (Either refusal ()) → IO ()
ok action = action >>= either (fail . ("refused: " <>) . show) pure

-- | Require that no call broke a rule the stand-in holds the frames to.
clean ∷ Rig → Expectation
clean rig = violations (rigStandIn rig) `shouldReturn` []

-- | Run the action on this, the owner's, thread, with a cancellation aimed at
-- it from inside the first call the predicate selects: it can be delivered
-- only once the handoff that call is part of has recorded its result.
cancelled ∷ Show a ⇒ Rig → (FrameCall → Bool) → IO a → IO ()
cancelled rig selected action = do
  owner ← myThreadId
  armed ← newIORef True
  duringFrameCall (rigStandIn rig) $ \call → when (selected call) $ do
    first ← atomicModifyIORef' armed (\armed' → (False, armed'))
    when first $ do
      killer ← forkIO (killThread owner)
      awaitThrowing killer
  outcome ← try @SomeException action
  duringFrameCall (rigStandIn rig) (\_ → pure ())
  case outcome of
    Left failure → fromException failure `shouldBe` Just ThreadKilled
    Right value → expectationFailure ("the cancellation was not delivered: " <> show value)

awaitThrowing ∷ ThreadId → IO ()
awaitThrowing thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnException → pure ()
    ThreadFinished → pure ()
    _ → yield >> awaitThrowing thread

inModel ∷ Rig → (GpuModel → Outcome GpuModel) → IO ()
inModel rig operation = atomically $ stateRootsModel (rigRoots rig) $ \model → case operation model of
  Admitted next → ((), next)
  _ → error "the model refused the operation"

-- | Fill the object budget, so nothing more can be admitted.
exhaust ∷ Rig → IO ()
exhaust rig = atomically $ stateRootsModel (rigRoots rig) $ \model →
  let remaining = objectLimit (modelBudgets model) - usageObjects (usage model)
   in case beginAllocation 0 remaining model of
        Admitted (next, _) → ((), next)
        _ → error "the budget could not be filled"

modelOf ∷ Rig → IO GpuModel
modelOf rig = atomically (readRootsModel (rigRoots rig))

frameOf ∷ Rig → FrameSlotId → IO (Maybe FrameView)
frameOf rig frame = frameView frame <$> modelOf rig

phaseOf ∷ Rig → FrameSlotId → IO (Maybe FramePhase)
phaseOf rig frame = fmap viewFramePhase <$> frameOf rig frame

targetOf ∷ Rig → IO TargetView
targetOf rig = targetViewOf rig (rigTarget rig)

targetViewOf ∷ Rig → TargetId → IO TargetView
targetViewOf rig target = modelOf rig >>= maybe (fail "the target is not the model's") pure . targetView target

generationsOf ∷ Rig → IO TargetGenerationsView
generationsOf rig = generationsOn rig (rigTarget rig)

generationsOn ∷ Rig → TargetId → IO TargetGenerationsView
generationsOn rig target = atomically (readTargetGenerations (rigGenerations rig) target) >>= maybe (fail "the target is not tracked") pure

activeGeneration ∷ Rig → IO GenerationId
activeGeneration rig = activeGenerationOn rig (rigTarget rig)

activeGenerationOn ∷ Rig → TargetId → IO GenerationId
activeGenerationOn rig target = generationsOn rig target >>= maybe (fail "the target has no active generation") pure . viewActive

submittedOn ∷ Rig → HoldSubject → IO [SubmissionId]
submittedOn rig subject = maybe [] viewSubmitted . holdView subject <$> modelOf rig

standingOf ∷ Rig → FrameSlotId → IO (Maybe FrameStage)
standingOf rig frame = lookup frame . map (\standing → (standingFrame standing, standingStage standing)) <$> atomically (readFrameStandings (rigFrames rig))

acquisitionState ∷ Rig → FrameSlotId → IO (Maybe SemaphoreState)
acquisitionState rig frame =
  lookup (frameSlotNumber frame) . map (\view → (viewSlotNumber view, syncAcquireState (viewSlotSync view))) <$> atomically (readSlots (rigFrames rig))

raises ∷ ∀ e a. (Exception e, Show a) ⇒ IO a → (e → Bool) → Expectation
raises action expected =
  try @e action >>= \case
    Left failure → unless (expected failure) (expectationFailure ("an unexpected failure: " <> show failure))
    Right value → expectationFailure ("nothing was raised: " <> show value)

shouldReturn' ∷ IO a → (a → IO ()) → IO ()
shouldReturn' action assertion = action >>= assertion

partialStanding ∷ BatchStanding → Bool
partialStanding = \case
  BatchPartial _ → True
  _ → False

uncertainStage, failedStage, submittedStage ∷ FrameStage → Bool
uncertainStage = \case
  StageUncertain _ → True
  _ → False
failedStage = \case
  StageFailed _ → True
  _ → False
submittedStage = \case
  StageSubmitted _ → True
  _ → False

kind ∷ FrameCall → Text
kind = \case
  CreatedSemaphore _ → "semaphore"
  CreatedFence _ → "fence"
  Acquired {} → "acquire"
  _ → "other"

isSubmission, isQuery, isRelease, isAcquisition, isCleanup, isDestruction, isPresentation, isWait ∷ FrameCall → Bool
isSubmission = \case
  Submitted {} → True
  _ → False
isQuery = \case
  QueriedFence _ → True
  _ → False
isRelease = \case
  Released {} → True
  _ → False
isAcquisition = \case
  Acquired {} → True
  _ → False
isCleanup = \case
  Submitted batches _ → all (\(_, _, commands, _) → null commands) batches
  _ → False
isDestruction = \case
  DestroyedSemaphore _ → True
  DestroyedFence _ → True
  _ → False
isPresentation = \case
  Presented {} → True
  _ → False
isWait = \case
  WaitedFence {} → True
  _ → False

-- | The instant this many milliseconds after the scripted clock's origin.
at ∷ Integer → Instant
at milliseconds = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000)))
