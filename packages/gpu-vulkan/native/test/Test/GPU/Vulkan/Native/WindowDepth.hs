-- | Windowed depth (GRS-13) over the roots', the recording's and the frames'
-- stand-in native layers: a session that asked for a depth image with every
-- swapchain generation — made with the generation, of its extent, named from
-- its identity, shared by its frames in flight; replaced with the generation
-- on resize, released with it and destroyed only once every batch that
-- recorded it has completed; recovered with a lost surface, released by a
-- close and by the loss of the device; and a construction that cannot make it
-- failing as any other of its native calls does — and a session that did not,
-- whose generations never have one.
--
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.WindowDepth (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId)
import Control.Concurrent.MVar (putMVar, newEmptyMVar, takeMVar)
import Control.Concurrent.STM (atomically, check, newTVarIO, readTVar)
import qualified Data.ByteString as ByteString
import Control.Exception (AsyncException (ThreadKilled), SomeException, fromException, try)
import Control.Monad (void)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model (DeviceLossRelease (..), SessionFailureCause (CleanupFailed), SessionState (..), TargetPhase (..), TargetView (..), closeTarget, sessionState, usage, usageObjects)
import Hetoimasia.GPU.Model.Identity (BatchId, GenerationId, ResourceId, TargetClass (..), TargetId, imageGeneration)
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Naming (windowDepthName)
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots (lostDuring, readRootsView, viewAdmitting)
import Test.GPU.Vulkan.Native.AllocatorStandIn (AllocatorCall (..), allocatorCalls, allocatorOutOfMemory)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn
  ( RecordingCall (..)
  , RecordingStep (..)
  , failAt
  , onceAt
  , recordingCalls
  , standInImageLimits
  , supportImages
  )
import Test.GPU.Vulkan.Native.StandIn (StandIn (standAllocator), offerSurface, surfaceNumbered)
import qualified Test.GPU.Vulkan.Native.StandIn as Roots'

type Rec = Recorder () Int Int Text Int Word64

spec ∷ Spec
spec = describe "Windowed depth (GRS-13)" $ do
  describe "a session that asked for it" $ do
    it "gives each generation one depth image of its extent, named from the generation, in the format the device supports" $ do
      rig ← newRigWindowDepth WindowedDepth
      generation ← activeGeneration rig
      Just depth ← depthOf rig generation
      view ← generationsOf rig
      [viewDepth entry | entry ← viewGenerations view] `shouldBe` [Just (managedResource depth)]
      depthManaged rig `shouldReturn` [(managedResource depth, ManagedLive)]
      -- The image was asked of the allocator at the generation's extent and
      -- the format the device supports as a depth attachment.
      requested rig `shouldReturn` [(formatCode Depth32Float, 640, 480)]
      allocations ← allocatorCalls (standAllocator (rigRootsStandIn rig))
      -- The recording named it from its resource when it made it, and the
      -- generation names it from its own identity before publishing it.
      last [name | NamedAllocation _ name ← allocations] `shouldBe` windowDepthName generation
      -- Its one view covers the depth aspect alone.
      calls ← recordingCalls (rigRecordingStandIn rig)
      [(requestViewFormat request, requestViewAspect request) | CreatedView _ request ← calls] `shouldBe` [(formatCode Depth32Float, depthAspect)]
      clean rig

    it "builds no generation until the recording supplies what makes the depth, and then builds it with one" $ do
      rig ← newRigWindowDepth WindowedDepthPending
      stepAt rig 0 640 480
      viewGenerations <$> generationsOf rig `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` AwaitingGeneration
      requested rig `shouldReturn` []
      atomically (supplyRecordingWindowDepth (rigRecording rig))
      stepAt rig 1 640 480
      generation ← activeGeneration rig
      depthOf rig generation >>= (`shouldSatisfy` isJust)
      viewCondition <$> generationsOf rig `shouldReturn` Presenting

    it "gives every target's generation its own depth image, and every frame of one generation the same one" $ do
      rig ← newRigWindowDepthOver [OptionalTarget, OptionalTarget]
      depths ← mapM (\target → activeGenerationOn rig target >>= depthOf rig) (rigTargets rig)
      case depths of
        [Just first, Just second] → first `shouldSatisfy` (/= second)
        other → fail ("the depth images were " <> show other)
      generation ← activeGeneration rig
      Just depth ← depthOf rig generation
      frames ← mapM (const (owned rig)) [0 ∷ Int, 1]
      mapM (\frame → depthOf rig (imageGeneration (ownedImage frame))) frames `shouldReturn` [Just depth, Just depth]

  describe "a session that did not" $ do
    it "gives no generation a depth image, asks the device nothing about one and makes none, as before" $ do
      rig ← newRig
      generation ← activeGeneration rig
      depthOf rig generation `shouldReturn` Nothing
      resizeTo rig 100 800 600
      viewDepths rig `shouldReturn` [Nothing, Nothing]
      requested rig `shouldReturn` []
      recordingCalls (rigRecordingStandIn rig) >>= \calls → [() | QueriedSupport _ ← calls] `shouldBe` []
      depthManaged rig `shouldReturn` []
      allocatorCalls (standAllocator (rigRootsStandIn rig)) >>= \calls → [() | MadeImage {} ← calls] `shouldBe` []

  describe "following the generation" $ do
    it "gives a replacement its own depth image of the new extent, and keeps the old one until every batch that recorded it has completed" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      frame ← owned rig
      (batch, begun) ← depthFrame rig frame (clearedDepth firstDepth ClearFromUndefined)
      begun `shouldBe` Right ()
      _ ← submitted rig (batch :| [])
      presentFrame (rigFrames rig) (ownedFrame frame) >>= either (fail . show) (const (pure ()))
      resizeTo rig 100 800 600
      second ← activeGeneration rig
      second `shouldSatisfy` (/= first)
      Just secondDepth ← depthOf rig second
      secondDepth `shouldSatisfy` (/= firstDepth)
      requested rig `shouldReturn` [(formatCode Depth32Float, 640, 480), (formatCode Depth32Float, 800, 600)]
      -- The old generation is retired and its frame still holds it: its depth
      -- stays, as it does until the generation itself is destroyed.
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedLive), (managedResource secondDepth, ManagedLive)]
      disposeResources (rigRecording rig) (at 130) `shouldReturn` []
      settleAll rig
      -- Nothing holds the generation now, so the next step destroys it and the
      -- depth is released with it; the batch that recorded the depth has
      -- completed, so the recording destroys it.
      stepAt rig 140 800 600
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedReleased), (managedResource secondDepth, ManagedLive)]
      destroyedImages rig `shouldReturn` []
      destroyed ← disposeResources (rigRecording rig) (at 141)
      destroyed `shouldBe` [managedResource firstDepth]
      length <$> destroyedImages rig `shouldReturn` 1
      length <$> destroyedViews rig `shouldReturn` 1
      depthManaged rig `shouldReturn` [(managedResource secondDepth, ManagedLive)]
      clean rig

    it "keeps the old depth image while the old generation's presentation is outstanding, though the batch that recorded it has completed, and releases it only once the generation can retire" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      frame ← owned rig
      (batch, _) ← depthFrame rig frame (clearedDepth firstDepth ClearFromUndefined)
      _ ← submitted rig (batch :| [])
      presentFrame (rigFrames rig) (ownedFrame frame) >>= either (fail . show) (const (pure ()))
      submission ← (\calls → [fence | Submitted _ fence ← calls]) <$> frameCalls (rigStandIn rig)
      resizeTo rig 100 800 600
      -- The graphics submission completes; the presentation's fence does not.
      mapM_ (completeFence (rigStandIn rig)) submission
      _ ← progress rig
      stepAt rig 140 800 600
      disposeResources (rigRecording rig) (at 141) `shouldReturn` []
      depthManaged rig >>= (`shouldSatisfy` elem (managedResource firstDepth, ManagedLive))
      destroyedImages rig `shouldReturn` []
      -- Its presentation retires: the generation can be destroyed, and the depth
      -- goes with it.
      completeAll (rigStandIn rig)
      _ ← progress rig
      stepAt rig 150 800 600
      depthManaged rig >>= (`shouldSatisfy` notElem (managedResource firstDepth, ManagedLive))
      destroyed ← disposeResources (rigRecording rig) (at 151)
      destroyed `shouldSatisfy` elem (managedResource firstDepth)
      clean rig

    it "destroys the old depth image at once when no batch recorded it" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      resizeTo rig 100 800 600
      -- The retired generation, held by nothing, is destroyed by the next step.
      disposeResources (rigRecording rig) (at 130) `shouldReturn` []
      stepAt rig 140 800 600
      destroyed ← disposeResources (rigRecording rig) (at 141)
      destroyed `shouldBe` [managedResource firstDepth]

    it "keeps the old depth image while a consumer holds the retired generation, and releases it only once the generation is destroyed" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      held ← atomically (useGeneration (rigGenerations rig) first) >>= either (fail . show) pure
      resizeTo rig 100 800 600
      second ← activeGeneration rig
      Just secondDepth ← depthOf rig second
      -- Two generations stand, each with its own depth image of its own extent.
      requested rig `shouldReturn` [(formatCode Depth32Float, 640, 480), (formatCode Depth32Float, 800, 600)]
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedLive), (managedResource secondDepth, ManagedLive)]
      atomically (endGenerationUse (rigGenerations rig) held)
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedLive), (managedResource secondDepth, ManagedLive)]
      stepAt rig 140 800 600
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedReleased), (managedResource secondDepth, ManagedLive)]

  describe "recovery and loss" $ do
    it "releases a lost surface's generation's depth with it, and gives the generation recovery builds its own" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      void (atomically (noteSwapchainResult (rigGenerations rig) first SwapchainSurfaceLost))
      wantedAt rig 1 `shouldReturn` []
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceLost
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedLive)]
      -- Held by nothing, the generation is destroyed by the next step, and its
      -- depth is released with it.
      wantedAt rig 2 `shouldReturn` [rigTarget rig]
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedReleased)]
      viewCondition <$> generationsOf rig `shouldReturn` SurfaceReplacing
      offerReplacementSurface (rigGenerations rig) (at 3) (rigTarget rig) (surfaceNumbered (rigRootsStandIn rig) 20) `shouldReturn` ReplacementInstalled
      stepAt rig 3 640 480
      viewCondition <$> generationsOf rig `shouldReturn` Presenting
      second ← activeGeneration rig
      Just secondDepth ← depthOf rig second
      secondDepth `shouldSatisfy` (/= firstDepth)
      requested rig `shouldReturn` [(formatCode Depth32Float, 640, 480), (formatCode Depth32Float, 640, 480)]
      destroyed ← disposeResources (rigRecording rig) (at 4)
      destroyed `shouldBe` [managedResource firstDepth]
      depthManaged rig `shouldReturn` [(managedResource secondDepth, ManagedLive)]
      clean rig

    it "gives the generation that replaces one the swapchain reported out of date at the same extent a depth image of its own" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      void (atomically (noteSwapchainResult (rigGenerations rig) first SwapchainOutOfDate))
      stepAt rig 1 640 480
      stepAt rig 200 640 480
      second ← activeGeneration rig
      second `shouldSatisfy` (/= first)
      Just secondDepth ← depthOf rig second
      secondDepth `shouldSatisfy` (/= firstDepth)
      requested rig `shouldReturn` [(formatCode Depth32Float, 640, 480), (formatCode Depth32Float, 640, 480)]

    it "releases the depth of a generation a close retired, and destroys it once its batches have completed" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      frame ← owned rig
      (batch, _) ← depthFrame rig frame (clearedDepth firstDepth ClearFromUndefined)
      _ ← submitted rig (batch :| [])
      _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      settleAll rig
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      retireTargetGenerations (rigGenerations rig) (at 10) (rigTarget rig)
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedReleased)]
      destroyed ← disposeResources (rigRecording rig) (at 11)
      destroyed `shouldBe` [managedResource firstDepth]
      depthManaged rig `shouldReturn` []

    it "retains a generation's depth image through the recording's retirement while its generation still awaits its presentation" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      frame ← owned rig
      (batch, _) ← depthFrame rig frame (clearedDepth firstDepth ClearFromUndefined)
      _ ← submitted rig (batch :| [])
      presentFrame (rigFrames rig) (ownedFrame frame) >>= either (fail . show) (const (pure ()))
      submission ← (\calls → [fence | Submitted _ fence ← calls]) <$> frameCalls (rigStandIn rig)
      -- The graphics submission completes, the presentation's fence does not,
      -- and the target's drain never finished: the generation stands.
      mapM_ (completeFence (rigStandIn rig)) submission
      _ ← progress rig
      retireRecording (rigRecording rig) (at 10) `raises` \(ResourcesRetained remaining) → managedResource firstDepth `elem` remaining
      depthManaged rig >>= (`shouldSatisfy` elem (managedResource firstDepth, ManagedLive))
      destroyedImages rig `shouldReturn` []

    it "lets the device's loss release a generation's depth image through the recording's retirement, whatever became of its generation" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      frame ← owned rig
      (batch, _) ← depthFrame rig frame (clearedDepth firstDepth ClearFromUndefined)
      _ ← submitted rig (batch :| [])
      loseFrameStep (rigStandIn rig) AtQueryFence
      progress rig `raises` \loss → lostDuring loss == "vkGetFenceStatus"
      _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      _ ← releaseFramesToDeviceLoss (rigFrames rig)
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      -- Its generation was never retired, and the loss let every hold go.
      retireRecording (rigRecording rig) (at 11)
      depthManaged rig `shouldReturn` []

    it "lets the loss of the device release the depth with its generation, and the recording's retirement destroy it under the device-loss rule" $ do
      rig ← newRigWindowDepth WindowedDepth
      first ← activeGeneration rig
      Just firstDepth ← depthOf rig first
      frame ← owned rig
      (batch, _) ← depthFrame rig frame (clearedDepth firstDepth ClearFromUndefined)
      _ ← submitted rig (batch :| [])
      loseFrameStep (rigStandIn rig) AtQueryFence
      progress rig `raises` \loss → lostDuring loss == "vkGetFenceStatus"
      _ ← closeTargetFrames (rigFrames rig) (rigTarget rig)
      released ← releaseFramesToDeviceLoss (rigFrames rig)
      released `shouldSatisfy` either (const False) (null . releaseRemaining)
      retireTargetFrames (rigFrames rig) (rigTarget rig)
      retireTargetGenerations (rigGenerations rig) (at 10) (rigTarget rig)
      depthManaged rig `shouldReturn` [(managedResource firstDepth, ManagedReleased)]
      retireRecording (rigRecording rig) (at 11)
      depthManaged rig `shouldReturn` []

  describe "failure" $ do
    it "fails the construction of a generation whose device supports no depth format: no active generation, no depth, nothing charged, and the next attempt builds" $ do
      rig ← newRigWindowDepth WindowedDepthPending
      supportImages (rigRecordingStandIn rig) (const Nothing)
      atomically (supplyRecordingWindowDepth (rigRecording rig))
      stepAt rig 0 640 480
      view ← generationsOf rig
      viewActive view `shouldBe` Nothing
      viewCondition view `shouldSatisfy` isConstructionFailed
      -- The candidate's swapchain was built, and the candidate was retired
      -- with its holds: nothing of it was published.
      [viewStanding entry | entry ← viewGenerations view] `shouldBe` [GenerationRetiredHeld]
      [viewDepth entry | entry ← viewGenerations view] `shouldBe` [Nothing]
      depthManaged rig `shouldReturn` []
      requested rig `shouldReturn` []
      -- The device is later able to: the next attempt, a recovery, builds.
      supportImages (rigRecordingStandIn rig) (const (Just standInImageLimits))
      stepAt rig 1 640 480
      stepAt rig 150 640 480
      generation ← activeGeneration rig
      depthOf rig generation >>= (`shouldSatisfy` isJust)
      viewTargetPhase <$> targetOf rig `shouldReturn` TargetAdmitted

    it "fails the construction of a generation whose depth view could not be made, destroying the image it made and charging nothing" $ do
      rig ← newRigWindowDepth WindowedDepthPending
      atomically (supplyRecordingWindowDepth (rigRecording rig))
      failAt (rigRecordingStandIn rig) AtCreateView
      stepAt rig 0 640 480
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      viewCondition <$> generationsOf rig >>= (`shouldSatisfy` isConstructionFailed)
      depthManaged rig `shouldReturn` []
      allocations ← allocatorCalls (standAllocator (rigRootsStandIn rig))
      [image | MadeImage image _ _ ← allocations] `shouldBe` [image | DestroyedImage image ← allocations]
      length [() | MadeImage {} ← allocations] `shouldBe` 1
      -- The candidate holds what one whose device offered no depth format at
      -- all holds, which never reserved a depth image: nothing was left charged.
      control ← failedWithoutDepthFormat
      objectsHeld rig `shouldReturn'` \held → objectsHeld control >>= (`shouldBe` held)
      running rig

    it "recovers a depth image whose creation ran out of memory as any allocation is recovered, with one more attempt" $ do
      rig ← newRigWindowDepth WindowedDepthPending
      atomically (supplyRecordingWindowDepth (rigRecording rig))
      -- A released layout nothing holds is what the reclamation pass frees.
      layout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) layout)
      allocatorOutOfMemory (standAllocator (rigRootsStandIn rig)) 1
      stepAt rig 0 640 480
      generation ← activeGeneration rig
      depthOf rig generation >>= (`shouldSatisfy` isJust)
      recordingCalls (rigRecordingStandIn rig) >>= \calls → [() | DestroyedLayout _ ← calls] `shouldBe` [()]
      running rig

    it "fails the construction, and publishes no generation, when the depth could not be made even after recovery" $ do
      rig ← newRigWindowDepth WindowedDepthPending
      atomically (supplyRecordingWindowDepth (rigRecording rig))
      allocatorOutOfMemory (standAllocator (rigRootsStandIn rig)) 8
      stepAt rig 0 640 480
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      viewCondition <$> generationsOf rig >>= (`shouldSatisfy` isConstructionFailed)
      depthManaged rig `shouldReturn` []

    it "retains a candidate whose depth image's creation a cancellation interrupted inside the call, fails the session, and destroys none of it" $ do
      rig ← newRigWindowDepth WindowedDepthPending
      atomically (supplyRecordingWindowDepth (rigRecording rig))
      gate ← newTVarIO False
      began ← newEmptyMVar
      -- The cancellation reaches the step inside the depth view's creation,
      -- which blocks interruptibly: whether it made the view is unknown.
      onceAt (rigRecordingStandIn rig) AtCreateView (putMVar began () >> atomically (readTVar gate >>= check))
      owner ← myThreadId
      _ ← forkIO (takeMVar began >> killThread owner)
      outcome ← try @SomeException (stepAt rig 0 640 480)
      either (\failure → fromException failure `shouldBe` Just ThreadKilled) (const (expectationFailure "the step was not cancelled")) outcome
      [generation] ← viewGenerations <$> generationsOf rig
      viewStanding generation `shouldSatisfy` \case
        GenerationUncertain _ → True
        _ → False
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      viewAdmitting <$> atomically (readRootsView (rigRoots rig)) `shouldReturn` False
      -- Nothing of it is destroyed or retried, and its teardown is refused.
      stepAt rig 1 640 480
      stepAt rig 200 640 480
      recorded ← Roots'.calls (rigRootsStandIn rig)
      [() | Roots'.DestroyedSwapchain _ ← recorded] `shouldBe` []
      [() | Roots'.DestroyedView _ ← recorded] `shouldBe` []
      length [() | Roots'.CreatedSwapchain {} ← recorded] `shouldBe` 1
      -- Nor is the depth image, whose view's outcome is unknown, destroyed or
      -- its allocation freed — at the cancellation or by any teardown.
      allocated ← allocatorCalls (standAllocator (rigRootsStandIn rig))
      length [() | MadeImage {} ← allocated] `shouldBe` 1
      [() | DestroyedImage _ ← allocated] `shouldBe` []
      [() | FreedAllocation _ ← allocated] `shouldBe` []
      depthManaged rig `shouldReturn` []
      retireTargetGenerations (rigGenerations rig) (at 300) (rigTarget rig) `raises` \(GenerationsRetained _ remaining) → remaining == [viewGeneration generation]

    it "releases the depth of a candidate the close superseded after the depth was made, and never publishes it" $ do
      rig ← newRigWindowDepth WindowedDepthPending
      atomically (supplyRecordingWindowDepth (rigRecording rig))
      -- The target is closed inside the depth view's creation: the candidate
      -- has its depth by the time the model refuses to publish it.
      onceAt (rigRecordingStandIn rig) AtCreateView (inModel rig (closeTarget (rigTarget rig)))
      stepAt rig 0 640 480
      viewActive <$> generationsOf rig `shouldReturn` Nothing
      viewCondition <$> generationsOf rig `shouldReturn` Closing
      view ← generationsOf rig
      [viewStanding entry | entry ← viewGenerations view] `shouldBe` [GenerationRetiredHeld]
      [isJust (viewDepth entry) | entry ← viewGenerations view] `shouldBe` [True]
      -- The retired candidate is destroyed by the next step, with its depth.
      stepAt rig 1 640 480
      depths ← depthManaged rig
      map snd depths `shouldBe` [ManagedReleased]
      destroyed ← disposeResources (rigRecording rig) (at 2)
      destroyed `shouldBe` map fst depths

  describe "the frame's pass" $ do
    it "begins rendering into the frame's image with the generation's depth image cleared to 1.0, ordered by an entry barrier before it and an exit barrier after it" $ do
      rig ← newRigWindowDepth WindowedDepth
      generation ← activeGeneration rig
      Just depth ← depthOf rig generation
      before ← length <$> commandsOf' rig
      frame ← owned rig
      (_, begun) ← depthFrame rig frame (clearedDepth depth ClearFromUndefined)
      begun `shouldBe` Right ()
      commands ← drop before <$> commandsOf' rig
      views ← depthViewHandles rig
      [clear | CommandBeginRendering _ _ _ (Just clear) ← commands] `shouldBe` [DepthClear view 1 | view ← views]
      let indexed = zip [0 ∷ Int ..] commands
          barriers = [position | (position, CommandResourceBarrier (BarrierImage _ aspect _ _ _) _ _) ← indexed, aspect == depthAspect]
          begun' = [position | (position, CommandBeginRendering {}) ← indexed]
          ended = [position | (position, CommandEndRendering) ← indexed]
      case (barriers, begun', ended) of
        ([entry, exit], [began], [finished]) → (entry < began, began < finished, finished < exit) `shouldBe` (True, True, True)
        _ → fail ("the commands were " <> show commands)

    it "shares the depth image between the generation's frames in flight, each pass ordered after the last by its entry barrier, including consecutive clearing passes" $ do
      rig ← newRigWindowDepth WindowedDepth
      generation ← activeGeneration rig
      Just depth ← depthOf rig generation
      before ← length <$> commandsOf' rig
      first ← owned rig
      second ← owned rig
      (firstBatch, firstBegun) ← depthFrame rig first (clearedDepth depth ClearFromUndefined)
      firstBegun `shouldBe` Right ()
      _ ← submitted rig (firstBatch :| [])
      -- The first has not completed: the next frame in flight clears the very
      -- same image, from undefined once more, and a third keeps its contents.
      (secondBatch, secondBegun) ← depthFrame rig second (clearedDepth depth ClearFromUndefined)
      secondBegun `shouldBe` Right ()
      _ ← submitted rig (secondBatch :| [])
      settleAll rig
      third ← owned rig
      (thirdBatch, thirdBegun) ← depthFrame rig third (clearedDepth depth ClearTarget)
      thirdBegun `shouldBe` Right ()
      _ ← submitted rig (thirdBatch :| [])
      settleAll rig
      commands ← drop before <$> commandsOf' rig
      -- Three passes, each entered and left by one barrier of the one image.
      length [() | CommandResourceBarrier (BarrierImage _ aspect _ _ _) _ _ ← commands, aspect == depthAspect] `shouldBe` 6
      length <$> depthViewHandles rig `shouldReturn` 1
      clean rig

    it "initializes the depth image only by a pass that clears it from undefined whose batch was submitted, never by an abandoned or a refused one" $ do
      rig ← newRigWindowDepth WindowedDepth
      generation ← activeGeneration rig
      Just depth ← depthOf rig generation
      first ← owned rig
      -- A pass that keeps contents the image does not have yet is refused,
      -- entering nothing.
      (_, refused) ← depthFrame rig first (clearedDepth depth ClearTarget)
      refused `shouldBe` Left RefusedUninitialized
      skipped rig first
      settleAll rig
      -- A first recording that cleared it from undefined and was abandoned
      -- publishes nothing either.
      second ← owned rig
      (_, begun) ← depthFrame rig second (clearedDepth depth ClearFromUndefined)
      begun `shouldBe` Right ()
      skipped rig second
      settleAll rig
      third ← owned rig
      (_, again) ← depthFrame rig third (clearedDepth depth ClearTarget)
      again `shouldBe` Left RefusedUninitialized
      skipped rig third
      settleAll rig
      -- A later clearing pass whose batch is submitted initializes it, and
      -- then a pass may keep it.
      fourth ← owned rig
      (batch, cleared) ← depthFrame rig fourth (clearedDepth depth ClearFromUndefined)
      cleared `shouldBe` Right ()
      _ ← submitted rig (batch :| [])
      settleAll rig
      fifth ← owned rig
      (keeping, kept) ← depthFrame rig fifth (clearedDepth depth ClearTarget)
      kept `shouldBe` Right ()
      _ ← submitted rig (keeping :| [])
      settleAll rig
      clean rig

    it "refuses a depth image of another extent than the frame's, a pass in a frame-less batch, and releasing a generation's depth through its handle" $ do
      rig ← newRigWindowDepth WindowedDepth
      generation ← activeGeneration rig
      Just depth ← depthOf rig generation
      small ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 16 16 1) >>= either (fail . show) pure
      frame ← owned rig
      (_, mismatched) ← depthFrame rig frame (clearedDepth small ClearFromUndefined)
      mismatched `shouldBe` Left (RefusedIncompatible "a depth target of extent 16x16 and the frame's image of extent 640x480")
      releaseManaged (rigRecording rig) depth `shouldReturn` Left (RefusedIllegal "a swapchain generation's depth image: its generation releases it")
      depthManaged rig >>= (`shouldSatisfy` elem (managedResource depth, ManagedLive))
      framed ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → beginFrameRenderingWithDepth recorder blue (clearedDepth depth ClearFromUndefined))
      fmap snd framed `shouldBe` Right (Left (RefusedUnsupported "a command that needs a swapchain image, in a frame-less batch"))

    it "draws in the frame's depth pass with a pipeline that declares the depth format, and refuses one that declares none" $ do
      rig ← newRigWindowDepth WindowedDepth
      generation ← activeGeneration rig
      Just depth ← depthOf rig generation
      layout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
      format ← selectDepthFormat (rigRecording rig) >>= either (fail . show) pure
      tested ← createPipelineWithDepth (rigRecording rig) layout shaders (formatCode Bgra8Srgb) noVertexInput (depthTested format) >>= either (fail . show) pure
      plain ← createPipeline (rigRecording rig) layout shaders (formatCode Bgra8Srgb) >>= either (fail . show) pure
      frame ← owned rig
      answered ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder → do
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        ok (beginFrameRenderingWithDepth recorder blue (clearedDepth depth ClearFromUndefined))
        ok (setViewport recorder (Viewport 0 0 640 480))
        ok (setScissor recorder (Rect 0 0 640 480))
        refusedPlain ← bindPipeline recorder plain
        ok (bindPipeline recorder tested)
        ok (draw recorder 3 1)
        ok (endRendering recorder)
        ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
        pure refusedPlain
      fmap snd answered
        `shouldBe` Right (Left (RefusedIncompatible "a pipeline that declares no depth and a pass with a depth attachment of format Depth32Float"))
      commands ← commandsOf' rig
      length [() | CommandDraw {} ← commands] `shouldBe` 1

-- ---------------------------------------------------------------------------
-- Helpers

blue ∷ ClearColor
blue = ClearColor 0 0 1 1

-- | The aspect of a depth image's view and barriers.
depthAspect ∷ Word32
depthAspect = 2

shaders ∷ PipelineShaders
shaders = PipelineShaders (ByteString.pack [1, 2, 3, 4]) (ByteString.pack [5, 6, 7, 8])

-- | The depth image of a generation, if it has one.
depthOf ∷ Rig → GenerationId → IO (Maybe Image)
depthOf rig generation = atomically (windowDepthOf (rigRecording rig) generation)

-- | The depth of every generation the first target holds, oldest first.
viewDepths ∷ Rig → IO [Maybe ResourceId]
viewDepths rig = (\view → [viewDepth entry | entry ← viewGenerations view]) <$> generationsOf rig

-- | A frame batch that records one pass into the frame's image with this
-- depth, ended and returned to presentation when it began. Answers the batch
-- and what beginning the pass answered.
depthFrame ∷ Rig → OwnedFrame → DepthPass → IO (BatchId, Either Refusal ())
depthFrame rig frame depth =
  recordFrame (rigRecording rig) (ownedFrame frame) (\recorder → record recorder)
    >>= either (fail . ("the recording was refused: " <>) . show) pure
  where
    record ∷ Rec → IO (Either Refusal ())
    record recorder = do
      ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
      begun ← beginFrameRenderingWithDepth recorder blue depth
      case begun of
        Right () → ok (endRendering recorder)
        -- The pass was refused: the frame still ends a balanced batch.
        Left _ → ok (beginRendering recorder blue) >> ok (endRendering recorder)
      ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
      pure begun

-- | Give up a frame that was recorded and not submitted.
skipped ∷ Rig → OwnedFrame → IO ()
skipped rig frame = skipFrame (rigFrames rig) (ownedFrame frame) >>= either (fail . ("the skip was refused: " <>) . show) (const (pure ()))

-- | The depth images the recording holds: each with its standing.
depthManaged ∷ Rig → IO [(ResourceId, ManagedStanding)]
depthManaged rig =
  (\views → [(viewResource entry, viewManagedStanding entry) | entry ← views, viewKind entry == "depth target"])
    <$> atomically (readManaged (rigRecording rig))

-- | The native handle of each depth image's view.
depthViewHandles ∷ Rig → IO [Word64]
depthViewHandles rig =
  (\views → [view | entry ← views, viewKind entry == "depth target", [_, view, _] ← [viewNativeHandles entry]])
    <$> atomically (readManaged (rigRecording rig))

-- | The (format, width, height) of every image the allocator was asked the
-- requirements of: the depth images, since the rig makes no other.
requested ∷ Rig → IO [(Word32, Word32, Word32)]
requested rig = (\calls → [(format, width, height) | AskedImageRequirements format width height ← calls]) <$> allocatorCalls (standAllocator (rigRootsStandIn rig))

destroyedImages, destroyedViews ∷ Rig → IO [Word64]
destroyedImages rig = (\calls → [image | DestroyedImage image ← calls]) <$> allocatorCalls (standAllocator (rigRootsStandIn rig))
destroyedViews rig = (\calls → [view | DestroyedView view ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | Every command the recording recorded, oldest first.
commandsOf' ∷ Rig → IO [NativeCommand]
commandsOf' rig = (\calls → [command | Recorded _ command ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | The objects the model's accounting holds.
objectsHeld ∷ Rig → IO Natural
objectsHeld rig = usageObjects . usage <$> modelOf rig

-- | A session whose first construction failed because the device supports no
-- depth format, so that it reserved nothing for a depth image.
failedWithoutDepthFormat ∷ IO Rig
failedWithoutDepthFormat = do
  rig ← newRigWindowDepth WindowedDepthPending
  supportImages (rigRecordingStandIn rig) (const Nothing)
  atomically (supplyRecordingWindowDepth (rigRecording rig))
  stepAt rig 0 640 480
  pure rig

stepAt ∷ Rig → Integer → Word32 → Word32 → IO ()
stepAt rig instant width height = void (stepGenerations (rigGenerations rig) (at instant) (geometries (rigTargets rig) (SurfaceExtent width height)))

-- | A step that answers the targets whose surface the owner must replace.
wantedAt ∷ Rig → Integer → IO [TargetId]
wantedAt rig instant = summarySurfacesWanted <$> stepGenerations (rigGenerations rig) (at instant) (geometries (rigTargets rig) (SurfaceExtent 640 480))

-- | Resize the surface and publish the matching geometry, then let it settle.
resizeTo ∷ Rig → Integer → Word32 → Word32 → IO ()
resizeTo rig instant width height = do
  offerSurface (rigRootsStandIn rig) $ \offer →
    offer {offerCapabilities = (offerCapabilities offer) {capabilityCurrentExtent = Just (SurfaceExtent width height)}}
  stepAt rig instant width height
  stepAt rig (instant + 16) width height

isConstructionFailed ∷ TargetCondition → Bool
isConstructionFailed = \case
  ConstructionFailed _ → True
  _ → False

-- | The session has not failed.
running ∷ Rig → IO ()
running rig = (sessionState <$> modelOf rig) >>= (`shouldBe` SessionRunning)
