-- | Managed resources and the scoped recorder over stand-in native layers:
-- retention before every capturing call, refusals before any native effect,
-- partial and cancelled recording, discard and reset, replacement, release,
-- readback and disposal; and buffers and images of every kind (GRS-2), their
-- refusals, failure cleanup, names, holds and disposal.
--
-- A frame is acquired the way the native cases acquire one: in the model
-- alone, through the roots' model, since public acquisition is VK-12's.
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Recording (spec) where

import Control.Arrow ((&&&))
import Control.Concurrent (forkIO, killThread, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), SomeException, throwIO, try)
import Control.Monad (forM_, void, when)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Bits ((.|.))
import Data.Maybe (isJust)
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import System.Directory (listDirectory, doesDirectoryExist)
import System.FilePath ((</>), takeExtension)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant)
import Hetoimasia.GPU.Model
  ( AcquireAnswer (..)
  , AcquireOutcome (..)
  , CompletionFact (..)
  , GpuModel
  , HoldView (..)
  , Initialization (..)
  , Outcome (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , SubmitAnswer (..)
  , SubmitOutcome (..)
  , Usage (..)
  , acquireImage
  , beginAllocation
  , extendBatch
  , holdView
  , modelBudgets
  , recordCompletion
  , reserveFrame
  , resourceInitialization
  , closeSubmittedFrame
  , resetRecorder
  , skipUnsubmittedFrame
  , sessionState
  , submitFrames
  , usage
  )
import Hetoimasia.GPU.Model.Access (ResourceKind (..), legalUses)
import Hetoimasia.GPU.Model.Budget (BudgetKind (ByteBudget, ObjectBudget), BudgetRequest (..), byteLimit, defaultBudgetRequest, objectLimit, validateBudgets)
import Hetoimasia.GPU.Model.Identity
  ( BatchId
  , FrameSlotId
  , GenerationId
  , HoldSubject (..)
  , IdentityKind (..)
  , Misuse (..)
  , ResourceId
  , SubmissionId
  , TargetClass (..)
  , TargetId
  , frameSlotNumber
  )
import Hetoimasia.GPU.Vulkan.Native.Diagnostics (NativeFfiConfiguration (..), nativeFfiConfiguration)
import Hetoimasia.GPU.Vulkan.Native.Allocator (MemoryUsage (..), Placement (..))
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Naming
  ( NativeObjectKind (..)
  , ShaderStage (..)
  , batchLabel
  , bufferName
  , commandBufferName
  , commandPoolName
  , imageName
  , ownedViewName
  , passLabel
  , pipelineLayoutName
  , pipelineName
  , readbackBufferName
  , shaderModuleName
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Profile (DeviceOffer (..), DevicePlan (..))
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.AllocatorStandIn
  ( AllocatorCall (..)
  , AllocatorFailure (..)
  , AllocatorStandIn
  , AllocatorStep (..)
  , allocatorCalls
  , allowTypes
  , clearAllocatorAt
  , deviceLocalType
  , failAllocatorAt
  , heldBlocks
  , heldBytes
  , hostCoherentType
  , liveAllocations
  , nonCoherentReadback
  , standInBlockSize
  )
import Test.GPU.Vulkan.Native.RecordingStandIn
import Test.GPU.Vulkan.Native.StandIn
  ( NamingFailure (..)
  , StandIn (standAllocator, standOffers)
  , StandInRoots
  , failNaming
  , namesGiven
  , newStandIn
  , newStandInRoots
  , offerNaming
  , offerSurface
  , standInDevice
  , standardRequest
  , surfaceNumbered
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "Recording" $ do
  describe "retention" $ do
    it "records a sealed batch that retains the frame's generation, its storage, the pipeline and its layout before each capturing call" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      -- Inside the native call that binds the pipeline, the model already
      -- holds the pipeline and its layout as the batch's references.
      seenAtBind ← newIORef Nothing
      duringRecord (rigRecording' rig) $ \case
        CommandBindPipeline _ → do
          model ← modelOf rig
          writeIORef seenAtBind (Just (recordedOf model (kitPipeline kit), recordedOf model (kitLayout kit)))
        _ → pure ()
      (batch, ()) ← recordTriangle rig kit frame
      readIORef seenAtBind `shouldReturn` Just ([batch], [batch])
      model ← modelOf rig
      [recordedOf model resource | resource ← [kitPipeline kit, kitLayout kit, kitStorage kit]] `shouldBe` [[batch], [batch], [batch]]
      generation ← activeGeneration rig
      recordedIn model (GenerationSubject generation) `shouldBe` [batch]
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      nativeOf rig `shouldReturn'` \calls → do
        let commands = [command | Recorded _ command ← calls]
        length commands `shouldBe` 8
        [() | Began _ ← calls] `shouldBe` [()]
        drop (length calls - 1) calls `shouldSatisfy` all isEnded

    it "retains a subject once however often or however overlapping its use, and recording it again is no duplicate" $ do
      rig ← newRig
      kit ← newKit rig
      other ← created (createPipeline (rigRecording rig) (kitLayoutHandle kit) shaders formatB8G8R8A8Srgb)
      frame ← acquired rig
      (batch, ()) ←
        recorded rig frame $ \recorder → do
          enterRendering recorder
          ok (bindPipeline recorder (kitPipelineHandle kit))
          ok (bindPipeline recorder (kitPipelineHandle kit))
          ok (bindPipeline recorder other)
          ok (setViewport recorder (Viewport 0 0 640 480))
          ok (setScissor recorder (Rect 0 0 640 480))
          ok (draw recorder 3 1)
          ok (draw recorder 6 1)
          ok (endRendering recorder)
      model ← modelOf rig
      [recordedOf model resource | resource ← [kitPipeline kit, managedResource other, kitLayout kit]] `shouldBe` [[batch], [batch], [batch]]

    it "keeps the exact generation a batch recorded when the pipeline is replaced, and records the replacement only in later batches" $ do
      rig ← newRig
      kit ← newKit rig
      first ← acquired rig
      (early, ()) ← recordTriangle rig kit first
      replacement ← created (replacePipeline (rigRecording rig) (kitPipelineHandle kit) (kitLayoutHandle kit) shaders formatB8G8R8A8Srgb)
      model ← modelOf rig
      recordedOf model (kitPipeline kit) `shouldBe` [early]
      recordedOf model (managedResource replacement) `shouldBe` []
      -- The old handle records nothing more; the batch still names it.
      second ← acquiredOn rig 1
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 1)
      stale ← recordFrame (rigRecording rig) second $ \recorder → do
        enterRendering recorder
        answer ← bindPipeline recorder (kitPipelineHandle kit)
        ok (endRendering recorder)
        pure answer
      fmap snd stale `shouldBe` Right (Left (RefusedMisuse (StaleIdentity ResourceIdentity)))
      -- The replaced generation is held by the early batch, so nothing goes.
      dispose rig `shouldReturn` []
      ok (discardBatch (rigRecording rig) early)
      destroyedNow ← dispose rig
      destroyedNow `shouldContain` [kitPipeline kit]
      standingOf' rig (managedResource replacement) `shouldReturn` Just ManagedLive

  describe "refusals before any native effect" $ do
    it "refuses a foreign handle, a stale one and a released one, and calls nothing" $ do
      rig ← newRig
      kit ← newKit rig
      foreignRig ← newRig
      foreignKit ← newKit foreignRig
      frame ← acquired rig
      before ← nativeCount rig
      answers ← newIORef []
      _ ← recorded rig frame $ \recorder → do
        enterRendering recorder
        foreignBind ← bindPipeline recorder (kitPipelineHandle foreignKit)
        modifyIORef' answers (foreignBind :)
        ok (endRendering recorder)
      readIORef answers `shouldReturn` [Left (RefusedMisuse (ForeignIdentity ResourceIdentity))]
      -- A frame of another session is refused before any batch exists.
      foreignFrame ← acquired foreignRig
      fmap (const ()) <$> recordFrame (rigRecording rig) foreignFrame (\_ → pure ())
        `shouldReturn` Left (RefusedMisuse (ForeignIdentity FrameIdentity))
      -- Released: nothing records through it again.
      ok (releaseManaged (rigRecording rig) (kitPipelineHandle kit))
      second ← acquiredOn rig 1
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 1)
      released ← recordFrame (rigRecording rig) second $ \recorder → do
        enterRendering recorder
        answer ← bindPipeline recorder (kitPipelineHandle kit)
        ok (endRendering recorder)
        pure answer
      fmap snd released `shouldBe` Right (Left (RefusedMisuse (WrongPhase ResourceIdentity)))
      after ← nativeCalls' rig
      -- Neither refused binding reached the native layer.
      [call | call ← drop before after, isBind call] `shouldBe` []

    it "refuses a second recording of a frame whose batch is outstanding, a consumed batch, and a stranger's thread" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      (batch, ()) ← recordTriangle rig kit frame
      before ← nativeCount rig
      fmap (const ()) <$> recordFrame (rigRecording rig) frame (\_ → pure ())
        `shouldReturn` Left (RefusedMisuse (DuplicateSubject FrameIdentity))
      ok (discardBatch (rigRecording rig) batch)
      resets ← nativeCount rig
      discardBatch (rigRecording rig) batch `shouldReturn` Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
      nativeCount rig `shouldReturn` resets
      resets `shouldBe` before + 1
      answer ← newEmptyMVar
      _ ← forkIO (discardBatch (rigRecording rig) batch >>= putMVar answer)
      takeMVar answer `shouldReturn` Left RefusedNotOwner

    it "refuses a recorder kept past its consumer's scope, and runs the consumer exactly once" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      runs ← newIORef (0 ∷ Int)
      (_, kept) ← recorded rig frame $ \recorder → do
        modifyIORef' runs (+ 1)
        pure recorder
      readIORef runs `shouldReturn` 1
      before ← nativeCount rig
      transitionImage kept LayoutUndefined LayoutColorAttachment `shouldReturn` Left RefusedRecorderClosed
      bindPipeline kept (kitPipelineHandle kit) `shouldReturn` Left RefusedRecorderClosed
      nativeCount rig `shouldReturn` before

    it "refuses a command outside the supported vocabulary, or illegal in the recorder's state, at the interface" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      frame ← acquired rig
      answers ← newIORef []
      let note action = action >>= \answer → modifyIORef' answers (answer :)
      _ ← recorded rig frame $ \recorder → do
        note (transitionImage recorder LayoutUndefined LayoutTransferSource)
        note (draw recorder 3 1)
        enterRendering recorder
        ok (bindPipeline recorder (kitPipelineHandle kit))
        ok (setViewport recorder (Viewport 0 0 640 480))
        ok (setScissor recorder (Rect 0 0 640 480))
        note (draw recorder 4 1)
        note (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        ok (endRendering recorder)
      answers' ← reverse <$> readIORef answers
      answers'
        `shouldBe` [ Left (RefusedUnsupported "the image transition LayoutUndefined to LayoutTransferSource")
                   , Left (RefusedIllegal "a draw with no pipeline bound")
                   , Left (RefusedUnsupported "a draw that is not whole triangles")
                   , Left (RefusedIllegal "an image transition inside rendering")
                   ]
      nativeOf rig `shouldReturn'` \calls → [() | Recorded _ (CommandDraw {}) ← calls] `shouldBe` []

    it "refuses a viewport that is not finite or leaves the image, and a scissor that leaves it, at the interface" $ do
      rig ← newRig
      _ ← newKit rig
      frame ← acquired rig
      answers ← newIORef []
      let note action = action >>= \answer → modifyIORef' answers (answer :)
          nan = 0 / 0 ∷ Float
          infinite = 1 / 0 ∷ Float
      _ ← recorded rig frame $ \recorder → do
        note (setViewport recorder (Viewport 0 0 nan 480))
        note (setViewport recorder (Viewport 0 0 infinite 480))
        note (setViewport recorder (Viewport 100 0 640 480))
        note (setViewport recorder (Viewport (-1) 0 10 10))
        note (setScissor recorder (Rect 0 0 641 480))
        note (setScissor recorder (Rect 600 400 maxBound 1))
        note (setViewport recorder (Viewport 0 0 640 480))
        note (setScissor recorder (Rect 0 0 640 480))
      reverse <$> readIORef answers
        `shouldReturn` [ Left (RefusedIllegal "a viewport that is not finite")
                       , Left (RefusedIllegal "a viewport that is not finite")
                       , Left (RefusedIllegal "a viewport outside the frame's image")
                       , Left (RefusedIllegal "a viewport outside the frame's image")
                       , Left (RefusedIllegal "a scissor outside the frame's image")
                       , Left (RefusedIllegal "a scissor outside the frame's image")
                       , Right ()
                       , Right ()
                       ]
      nativeOf rig `shouldReturn'` \calls → do
        length [() | Recorded _ (CommandSetViewport _) ← calls] `shouldBe` 1
        length [() | Recorded _ (CommandSetScissor _) ← calls] `shouldBe` 1

    it "refuses a batch whose record the object budget cannot reserve, before beginning any command buffer" $ do
      rig ← newRig
      _ ← newKit rig
      frame ← acquired rig
      exhaust rig
      before ← nativeCount rig
      fmap (const ()) <$> recordFrame (rigRecording rig) frame (\_ → pure ())
        `shouldReturn` Left (RefusedBackpressure ObjectBudget)
      nativeCount rig `shouldReturn` before

  describe "exceptional recording" $ do
    it "keeps a partial batch's commands and captured references owned after its consumer raised, until a discard invalidates them first" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      raised ← try @ErrorCall $ recorded rig frame $ \recorder → do
        enterRendering recorder
        ok (bindPipeline recorder (kitPipelineHandle kit))
        void (throwIO (ErrorCall "the consumer failed"))
      raised `shouldSatisfy` either (const True) (const False)
      [batch] ← map viewBatch <$> atomically (readBatches (rigRecording rig))
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch)
        `shouldReturn` Just (BatchPartial "the consumer raised: the consumer failed")
      model ← modelOf rig
      [recordedOf model resource | resource ← [kitPipeline kit, kitLayout kit, kitStorage kit]] `shouldBe` [[batch], [batch], [batch]]
      -- The partial batch keeps its storage: the frame cannot record again.
      fmap (const ()) <$> recordFrame (rigRecording rig) frame (\_ → pure ())
        `shouldReturn` Left (RefusedMisuse (DuplicateSubject FrameIdentity))
      -- Inside the reset, the references are still held; after it, gone.
      heldDuringReset ← newIORef []
      duringReset (rigRecording' rig) (modelOf rig >>= \current → writeIORef heldDuringReset (recordedOf current (kitPipeline kit)))
      ok (discardBatch (rigRecording rig) batch)
      readIORef heldDuringReset `shouldReturn` [batch]
      after ← modelOf rig
      [recordedOf after resource | resource ← [kitPipeline kit, kitLayout kit, kitStorage kit]] `shouldBe` [[], [], []]

    it "leaves a batch whose consumer was cancelled partial and owned, and re-delivers the cancellation" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      started ← newEmptyMVar
      never ← newEmptyMVar
      -- The recording runs on the owner's thread, this one; the cancellation
      -- comes from another, which also keeps the consumer's MVar reachable so
      -- the runtime cannot mistake the wait for a deadlock.
      owner ← myThreadId
      _ ← forkIO (takeMVar started >> killThread owner >> putMVar never ())
      outcome ← try @SomeException $ recorded rig frame $ \recorder → do
        enterRendering recorder
        ok (bindPipeline recorder (kitPipelineHandle kit))
        putMVar started ()
        takeMVar never
      fmap (const ()) outcome `shouldSatisfy` either (const True) (const False)
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldSatisfy` \case
        BatchPartial reason → "a cancellation ended the consumer" `Text.isPrefixOf` reason
        _ → False
      model ← modelOf rig
      recordedOf model (kitPipeline kit) `shouldBe` [viewBatch view]

    it "leaves a batch whose consumer left rendering open partial, unsealed and owned" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      answer ← recordFrame (rigRecording rig) frame $ \recorder → do
        enterRendering recorder
        ok (bindPipeline recorder (kitPipelineHandle kit))
      fmap (const ()) answer `shouldBe` Left (RefusedIllegal "the consumer left rendering open, so the batch was not sealed")
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldBe` BatchPartial "the consumer left rendering open"
      nativeOf rig `shouldReturn'` \calls → [() | Ended _ ← calls] `shouldBe` []

    it "never seals a batch whose command raised, even when the consumer catches it and returns" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      failAt (rigRecording' rig) AtRecord
      answer ← recordFrame (rigRecording rig) frame $ \recorder → do
        caught ← try @RecordingFailure (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        later ← bindPipeline recorder (kitPipelineHandle kit)
        pure (either (const True) (const False) caught, later)
      fmap snd answer `shouldBe` Left (RefusedIllegal "a command failed during recording, so the batch was not sealed")
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldBe` BatchPartial "vkCmdPipelineBarrier2 raised: RecordingFailure AtRecord"
      nativeOf rig `shouldReturn'` \calls → do
        [() | Ended _ ← calls] `shouldBe` []
        [() | Recorded _ (CommandBindPipeline _) ← calls] `shouldBe` []
      -- It stays owned, partial, until a discard invalidates it.
      succeedAt (rigRecording' rig) AtRecord
      ok (discardBatch (rigRecording rig) (viewBatch view))

    it "retains a batch whose invalidation raised, with every reference, and fails the session" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      (batch, ()) ← recordTriangle rig kit frame
      failAt (rigRecording' rig) AtResetStorage
      raised ← try @BatchInvalidationFailed (discardBatch (rigRecording rig) batch)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch)
        `shouldReturn` Just (BatchUncertain "RecordingFailure AtResetStorage")
      model ← modelOf rig
      recordedOf model (kitPipeline kit) `shouldBe` [batch]
      sessionState model `shouldBe` SessionFailed CleanupFailed
      -- It is never retried, by a discard or by a reset of its frame.
      succeedAt (rigRecording' rig) AtResetStorage
      resets ← length . filter isReset <$> nativeCalls' rig
      discardBatch (rigRecording rig) batch `shouldReturn` Left (RefusedMisuse (WrongPhase BatchIdentity))
      resetFrameRecorder (rigRecording rig) frame `shouldReturn` Left (RefusedMisuse (WrongPhase BatchIdentity))
      length . filter isReset <$> nativeCalls' rig `shouldReturn` resets
      atomically (readBatch (rigRecording rig) batch) >>= (`shouldSatisfy` isJust)
      recordedOf <$> modelOf rig <*> pure (kitPipeline kit) >>= (`shouldBe` [batch])

  describe "discard, reset and release" $ do
    it "discards one batch's references and a reset discards another's, never touching a shared hold of the other" $ do
      rig ← newRig
      kit ← newKit rig
      first ← acquired rig
      second ← acquiredOn rig 1
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 1)
      (one, ()) ← recordTriangle rig kit first
      (two, ()) ← recordTriangle rig kit second
      model ← modelOf rig
      sort (recordedOf model (kitPipeline kit)) `shouldBe` sort [one, two]
      ok (discardBatch (rigRecording rig) one)
      afterDiscard ← modelOf rig
      recordedOf afterDiscard (kitPipeline kit) `shouldBe` [two]
      recordedOf afterDiscard (kitLayout kit) `shouldBe` [two]
      ok (resetFrameRecorder (rigRecording rig) second)
      afterReset ← modelOf rig
      recordedOf afterReset (kitPipeline kit) `shouldBe` []
      -- Neither settled the frames' own acquisitions.
      nativeOf rig `shouldReturn'` \calls → length [() | ResetStorage _ ← calls] `shouldBe` 2

    it "refuses to discard or reset a batch the model has submitted, invalidating nothing" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      (batch, ()) ← recordTriangle rig kit frame
      _ ← submitInModel rig frame
      before ← nativeCount rig
      discardBatch (rigRecording rig) batch `shouldReturn` Left (RefusedMisuse (AlreadyConsumed BatchIdentity))
      resetFrameRecorder (rigRecording rig) frame `shouldReturn` Left (RefusedMisuse (WrongPhase FrameIdentity))
      nativeCount rig `shouldReturn` before

    it "preserves a sealed batch when its resources are released, destroying them only once it is discarded, pipeline before layout" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      (batch, ()) ← recordTriangle rig kit frame
      ok (releaseManaged (rigRecording rig) (kitPipelineHandle kit))
      ok (releaseManaged (rigRecording rig) (kitLayoutHandle kit))
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      dispose rig `shouldReturn` []
      ok (discardBatch (rigRecording rig) batch)
      destroyed ← dispose rig
      sort destroyed `shouldBe` sort [kitPipeline kit, kitLayout kit]
      nativeOf rig `shouldReturn'` \calls →
        [call | call ← calls, isDestruction call] `shouldBe` [DestroyedPipeline (kitPipelineNative kit), DestroyedLayout (kitLayoutNative kit)]

    it "keeps a pipeline layout while a pipeline built over it remains" $ do
      rig ← newRig
      kit ← newKit rig
      ok (releaseManaged (rigRecording rig) (kitLayoutHandle kit))
      dispose rig `shouldReturn` []
      standingOf' rig (kitLayout kit) `shouldReturn` Just ManagedReleased
      ok (releaseManaged (rigRecording rig) (kitPipelineHandle kit))
      sort <$> dispose rig `shouldReturn` sort [kitPipeline kit, kitLayout kit]

    it "records every destruction that returned, even beyond one progress turn's action limit" $ do
      rig ← newRig
      layouts ← mapM (const (created (createPipelineLayout (rigRecording rig)))) [1 .. 70 ∷ Int]
      mapM_ (ok . releaseManaged (rigRecording rig)) layouts
      destroyed ← dispose rig
      length destroyed `shouldBe` 70
      atomically (readManaged (rigRecording rig)) `shouldReturn` []
      retireRecording (rigRecording rig) (at 2)

    it "refuses frame storage for a foreign target or a slot the frame budget cannot issue, before any native call" $ do
      rig ← newRig
      foreignRig ← newRig
      before ← nativeCount rig
      fmap (const ()) <$> createFrameStorage (rigRecording rig) (rigTarget foreignRig) 0
        `shouldReturn` Left (RefusedMisuse (ForeignIdentity TargetIdentity))
      fmap (const ()) <$> createFrameStorage (rigRecording rig) (rigTarget rig) 2
        `shouldReturn` Left (RefusedOutOfBounds 2 2)
      nativeCount rig `shouldReturn` before

    it "retains a resource whose destruction raised, never retries it, and fails the session" $ do
      rig ← newRig
      kit ← newKit rig
      failAt (rigRecording' rig) AtDestroyPipeline
      ok (releaseManaged (rigRecording rig) (kitPipelineHandle kit))
      raised ← try @ResourceDestructionFailed (dispose rig)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      standingOf' rig (kitPipeline kit) `shouldReturn` Just (ManagedUncertain "RecordingFailure AtDestroyPipeline")
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      succeedAt (rigRecording' rig) AtDestroyPipeline
      _ ← try @ResourceDestructionFailed (dispose rig)
      nativeOf rig `shouldReturn'` \calls → length [() | DestroyedPipeline _ ← calls] `shouldBe` 1
      raisedRetirement ← try @ResourcesRetained (retireRecording (rigRecording rig) (at 1))
      fmap (const ()) raisedRetirement `shouldSatisfy` either (const True) (const False)

    it "retires every resource whose holds have ended, and names the ones a batch still holds" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      _ ← recordTriangle rig kit frame
      retained ← try @ResourcesRetained (retireRecording (rigRecording rig) (at 1))
      case retained of
        Left (ResourcesRetained remaining) → sort remaining `shouldBe` sort [kitLayout kit, kitPipeline kit, kitStorage kit]
        Right () → expectationFailure "retirement claimed resources a batch still holds"

  describe "readback" $ do
    it "refuses a transfer-source transition or a copy of an image its generation did not make a transfer source, before recording either" $ do
      rig ← newRig
      _ ← newKit rig
      readback ← created (createReadback (rigRecording rig) (640 * 480 * 4))
      frame ← acquired rig
      answers ← newIORef []
      _ ← recorded rig frame $ \recorder → do
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        transitionImage recorder LayoutColorAttachment LayoutTransferSource >>= \answer → modifyIORef' answers (answer :)
        copyToReadback recorder readback >>= \answer → modifyIORef' answers (answer :)
      reverse <$> readIORef answers
        `shouldReturn` [ Left (RefusedUnsupported "a transfer-source transition of an image its generation did not make a transfer source")
                       , Left (RefusedUnsupported "a copy from an image its generation did not make a transfer source")
                       ]
      nativeOf rig `shouldReturn'` \calls → do
        [() | Recorded _ (CommandCopyImageToBuffer {}) ← calls] `shouldBe` []
        [() | Recorded _ (CommandImageBarrier _ _ LayoutTransferSource) ← calls] `shouldBe` []

    it "refuses a copy the buffer cannot hold, before recording it" $ do
      rig ← newCapturingRig
      _ ← newKit rig
      small ← created (createReadback (rigRecording rig) 1024)
      frame ← acquired rig
      answers ← newIORef []
      _ ← recorded rig frame $ \recorder → do
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        copyToReadback recorder small >>= \answer → modifyIORef' answers (answer :)
      readIORef answers `shouldReturn` [Left (RefusedOutOfBounds (640 * 480 * 4) 1024)]
      nativeOf rig `shouldReturn'` \calls → [() | Recorded _ (CommandCopyImageToBuffer {}) ← calls] `shouldBe` []

    it "exposes non-coherent bytes only after the copying batch's submission completed, invalidating the bytes read first" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      nonCoherentReadback (allocatorOf rig)
      let bytes = 640 * 480 * 4
      readback ← created (createReadback (rigRecording rig) bytes)
      allocation ← allocationOf rig
      -- A sentinel from the host is flushed over the whole buffer, as a range
      -- of its own allocation the allocator aligns.
      ok (fillReadback (rigRecording rig) readback 0xAB)
      last <$> allocatorCalls (allocatorOf rig) `shouldReturn` Flushed allocation (0, bytes)
      frame ← acquired rig
      (batch, ()) ← recorded rig frame $ \recorder → do
        drawTriangle recorder kit
        ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        ok (copyToReadback recorder readback)
      buffer ← bufferOf rig
      nativeOf rig `shouldReturn'` \calls →
        [command | Recorded _ command ← calls, isCopyOrHostBarrier command]
          `shouldBe` [ CommandCopyImageToBuffer (kitImage kit) (SurfaceExtent 640 480) buffer
                     , CommandHostReadBarrier buffer (fromIntegral bytes)
                     ]
      -- Recorded, not submitted: no bytes, and no host write either.
      readReadback (rigRecording rig) readback 0 16 `shouldReturn` Left (RefusedNotWritten "a batch or a submission still holds the buffer")
      fillReadback (rigRecording rig) readback 0 `shouldReturn` Left RefusedInUse
      submission@(SubmissionIdOf submitted) ← submitInModel rig frame
      readReadback (rigRecording rig) readback 0 16 `shouldReturn` Left (RefusedNotWritten "a batch or a submission still holds the buffer")
      ok (noteBatchSubmitted (rigRecording rig) batch submitted)
      readReadback (rigRecording rig) readback 0 16 `shouldReturn` Left (RefusedNotWritten "a batch or a submission still holds the buffer")
      completeInModel rig submission
      before ← nativeCount rig
      allocatorBefore ← length <$> allocatorCalls (allocatorOf rig)
      readReadback (rigRecording rig) readback 100 16 `shouldReturn` Right (ByteString.replicate 16 0xAB)
      drop before <$> nativeCalls' rig `shouldReturn` [ReadMapped 100 16]
      drop allocatorBefore <$> allocatorCalls (allocatorOf rig) `shouldReturn` [Invalidated allocation (100, 16)]
      readReadback (rigRecording rig) readback (bytes - 8) 16 `shouldReturn` Left (RefusedOutOfBounds (bytes + 8) bytes)
      -- An empty read reads nothing and invalidates nothing.
      empty ← nativeCount rig
      allocatorEmpty ← length <$> allocatorCalls (allocatorOf rig)
      readReadback (rigRecording rig) readback 0 0 `shouldReturn` Right ByteString.empty
      nativeCount rig `shouldReturn` empty
      length <$> allocatorCalls (allocatorOf rig) `shouldReturn` allocatorEmpty

    it "forgets what a discarded copy would have written, and reads coherent memory without invalidating it" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      readback ← created (createReadback (rigRecording rig) (640 * 480 * 4))
      frame ← acquired rig
      (batch, ()) ← recorded rig frame $ \recorder → do
        drawTriangle recorder kit
        ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        ok (copyToReadback recorder readback)
      ok (discardBatch (rigRecording rig) batch)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Left (RefusedNotWritten "nothing has written the buffer")
      ok (fillReadback (rigRecording rig) readback 7)
      before ← nativeCount rig
      allocatorBefore ← length <$> allocatorCalls (allocatorOf rig)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Right (ByteString.replicate 4 7)
      drop before <$> nativeCalls' rig `shouldReturn` [ReadMapped 0 4]
      drop allocatorBefore <$> allocatorCalls (allocatorOf rig) `shouldReturn` []
      -- Released, it is read no more.
      ok (releaseManaged (rigRecording rig) readback)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Left (RefusedMisuse (WrongPhase ResourceIdentity))

    it "exposes nothing a copy would have written once the model skipped or reset its unsubmitted batch, and records no submission for it" $ do
      -- Three slots: the skipped frame keeps its own until it is settled.
      rig ← newRigWith CaptureWhenOffered defaultBudgetRequest {requestedFrameSlots = 3}
      kit ← newKit rig
      readback ← created (createReadback (rigRecording rig) (640 * 480 * 4))
      skipped ← acquired rig
      second ← acquiredOn rig 1
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 1)
      let copying recorder = do
            drawTriangle recorder kit
            ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
            ok (copyToReadback recorder readback)
      (first, ()) ← recorded rig skipped copying
      inModel rig (skipUnsubmittedFrame skipped)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Left (RefusedNotWritten "no submission of the batch that copies into it is recorded")
      (reset, ()) ← recorded rig second copying
      inModel rig (resetRecorder second)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Left (RefusedNotWritten "no submission of the batch that copies into it is recorded")
      -- Neither batch was submitted, so neither can be recorded as submitted.
      third ← acquiredOn rig 2
      submission ← submitInModel rig third
      let SubmissionIdOf submitted = submission
      noteBatchSubmitted (rigRecording rig) first submitted `shouldReturn` Left (RefusedMisuse (WrongParent SubmissionIdentity))
      noteBatchSubmitted (rigRecording rig) reset submitted `shouldReturn` Left (RefusedMisuse (WrongParent SubmissionIdentity))

    it "records no submission for a batch the model reset before submitting its still-acquired frame" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      readback ← created (createReadback (rigRecording rig) (640 * 480 * 4))
      frame ← acquired rig
      (batch, ()) ← recorded rig frame $ \recorder → do
        drawTriangle recorder kit
        ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        ok (copyToReadback recorder readback)
      inModel rig (resetRecorder frame)
      submission@(SubmissionIdOf submitted) ← submitInModel rig frame
      noteBatchSubmitted (rigRecording rig) batch submitted `shouldReturn` Left (RefusedMisuse (WrongParent SubmissionIdentity))
      completeInModel rig submission
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Left (RefusedNotWritten "no submission of the batch that copies into it is recorded")

    it "refuses a second copy into a buffer another batch, or an earlier copy in the same batch, still holds" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      readback ← created (createReadback (rigRecording rig) (640 * 480 * 4))
      first ← acquired rig
      second ← acquiredOn rig 1
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 1)
      answers ← newIORef []
      let copyingTwice recorder = do
            drawTriangle recorder kit
            ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
            copyToReadback recorder readback >>= \answer → modifyIORef' answers (answer :)
            copyToReadback recorder readback >>= \answer → modifyIORef' answers (answer :)
      _ ← recorded rig first copyingTwice
      _ ← recorded rig second copyingTwice
      reverse <$> readIORef answers `shouldReturn` [Right (), Left RefusedInUse, Left RefusedInUse, Left RefusedInUse]
      nativeOf rig `shouldReturn'` \calls → length [() | Recorded _ (CommandCopyImageToBuffer {}) ← calls] `shouldBe` 1

    it "reuses a slot for a second submitted frame once the first's submission completed, keeping the readback's evidence" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      readback ← created (createReadback (rigRecording rig) (640 * 480 * 4))
      first ← acquired rig
      (batch, ()) ← recorded rig first $ \recorder → do
        drawTriangle recorder kit
        ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        ok (copyToReadback recorder readback)
      submission@(SubmissionIdOf submitted) ← submitInModel rig first
      ok (noteBatchSubmitted (rigRecording rig) batch submitted)
      completeInModel rig submission
      inModel rig (closeSubmittedFrame first)
      inModel rig (recordCompletion (at 1) (UnpresentedFrameSettled first))
      second ← acquiredOn rig 1
      frameSlotNumber second `shouldBe` frameSlotNumber first
      resets ← length . filter isReset <$> nativeCalls' rig
      (again, ()) ← recordTriangle rig kit second
      length . filter isReset <$> nativeCalls' rig `shouldReturn` resets + 1
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) again) `shouldReturn` Just BatchSealed
      atomically (readBatch (rigRecording rig) batch) `shouldReturn` Nothing
      readReadback (rigRecording rig) readback 0 4 `shouldSatisfy'` either (const False) (const True)

    it "refuses a frame whose slot's storage was released, before resetting it, and drops the completed batch with the storage" $ do
      rig ← newRig
      kit ← newKit rig
      first ← acquired rig
      (batch, ()) ← recordTriangle rig kit first
      submission@(SubmissionIdOf submitted) ← submitInModel rig first
      ok (noteBatchSubmitted (rigRecording rig) batch submitted)
      completeInModel rig submission
      inModel rig (closeSubmittedFrame first)
      inModel rig (recordCompletion (at 1) (UnpresentedFrameSettled first))
      ok (releaseManaged (rigRecording rig) (kitStorageHandle kit))
      second ← acquiredOn rig 1
      before ← nativeCount rig
      fmap (const ()) <$> recordFrame (rigRecording rig) second (\_ → pure ())
        `shouldReturn` Left RefusedNoStorage
      nativeCount rig `shouldReturn` before
      -- Destroying the storage takes the completed batch's record with it,
      -- and a new storage for the slot records again.
      destroyed ← dispose rig
      destroyed `shouldContain` [kitStorage kit]
      atomically (readBatch (rigRecording rig) batch) `shouldReturn` Nothing
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) (frameSlotNumber second))
      (again, ()) ← recordTriangle rig kit second
      map viewBatch <$> atomically (readBatches (rigRecording rig)) `shouldReturn` [again]

    it "refuses a stale frame for a slot whose submitted batch completed, before resetting that slot's storage" $ do
      rig ← newRig
      kit ← newKit rig
      first ← acquired rig
      (batch, ()) ← recordTriangle rig kit first
      submission@(SubmissionIdOf submitted) ← submitInModel rig first
      ok (noteBatchSubmitted (rigRecording rig) batch submitted)
      completeInModel rig submission
      inModel rig (closeSubmittedFrame first)
      inModel rig (recordCompletion (at 1) (UnpresentedFrameSettled first))
      -- The slot is issued again, so the old frame's identity is stale.
      second ← acquiredOn rig 1
      frameSlotNumber second `shouldBe` frameSlotNumber first
      before ← nativeCount rig
      fmap (const ()) <$> recordFrame (rigRecording rig) first (\_ → pure ())
        `shouldReturn` Left (RefusedMisuse (StaleIdentity FrameIdentity))
      nativeCount rig `shouldReturn` before
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just (BatchSubmitted submitted)

    it "frees a readback's allocation only once completion evidence ends its submitted use, the buffer before its memory" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      readback ← created (createReadback (rigRecording rig) (640 * 480 * 4))
      allocation ← allocationOf rig
      frame ← acquired rig
      (batch, ()) ← recorded rig frame $ \recorder → do
        drawTriangle recorder kit
        ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        ok (copyToReadback recorder readback)
      submission@(SubmissionIdOf submitted) ← submitInModel rig frame
      ok (noteBatchSubmitted (rigRecording rig) batch submitted)
      ok (releaseManaged (rigRecording rig) readback)
      -- Released, but the submission still uses it: nothing is freed.
      dispose rig >>= (`shouldSatisfy` notElem (managedResource readback))
      allocatorCalls (allocatorOf rig) >>= \journal → [() | FreedAllocation _ ← journal] `shouldBe` []
      completeInModel rig submission
      dispose rig >>= (`shouldContain` [managedResource readback])
      buffer ← bufferOf rig
      teardown ← filter (\case Unmapped _ → True; DestroyedBuffer _ → True; FreedAllocation _ → True; _ → False) <$> allocatorCalls (allocatorOf rig)
      teardown `shouldBe` [Unmapped allocation, DestroyedBuffer buffer, FreedAllocation allocation]

    it "exposes nothing a fill changed if its flush raised, whatever the buffer held before" $ do
      rig ← newCapturingRig
      nonCoherentReadback (allocatorOf rig)
      readback ← created (createReadback (rigRecording rig) 1024)
      ok (fillReadback (rigRecording rig) readback 1)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Right (ByteString.replicate 4 1)
      failAllocatorAt (allocatorOf rig) AtFlush
      raised ← try @AllocatorFailure (fillReadback (rigRecording rig) readback 2)
      fmap (const ()) raised `shouldBe` Left (AllocatorFailure AtFlush)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Left (RefusedNotWritten "nothing has written the buffer")

  describe "names" $ do
    it "names every managed resource's objects from its ResourceId before its handle is returned" $ do
      rig ← newNamingRig
      layout ← created (createPipelineLayout (rigRecording rig))
      pipeline ← created (createPipeline (rigRecording rig) layout shaders formatB8G8R8A8Srgb)
      storage ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 0)
      readback ← created (createReadback (rigRecording rig) 1024)
      calls ← nativeCalls' rig
      let layoutNative = last [handle | CreatedLayout handle ← calls]
          pipelineNative = last [handle | CreatedPipeline handle _ _ ← calls]
          (pool, buffer) = last [(created', commands) | CreatedStorage created' commands ← calls]
      [readbackHandles] ← map viewNativeHandles . filter ((== managedResource readback) . viewResource) <$> atomically (readManaged (rigRecording rig))
      allocation ← allocationOf rig
      namesGiven (rigStandIn rig)
        `shouldReturn` [ (ObjectPipelineLayout, layoutNative, pipelineLayoutName (managedResource layout))
                       , -- The stand-in numbers the modules just before the pipeline.
                         (ObjectShaderModule, pipelineNative - 2, shaderModuleName (managedResource pipeline) VertexStage)
                       , (ObjectShaderModule, pipelineNative - 1, shaderModuleName (managedResource pipeline) FragmentStage)
                       , (ObjectPipeline, pipelineNative, pipelineName (managedResource pipeline))
                       , (ObjectCommandPool, pool, commandPoolName (managedResource storage) (rigTarget rig) 0)
                       , (ObjectCommandBuffer, buffer, commandBufferName (managedResource storage) (rigTarget rig) 0)
                       , (ObjectBuffer, firstOr 0 readbackHandles, readbackBufferName (managedResource readback))
                       ]
      -- The readback's allocation is named inside the allocator, and the
      -- device memory it lies in, which others may share, is named nowhere.
      lastOr 0 readbackHandles `shouldBe` allocation
      allocatorNames ← allocatorCalls (allocatorOf rig)
      [(handle, name) | NamedAllocation handle name ← allocatorNames] `shouldBe` [(allocation, readbackBufferName (managedResource readback))]

    it "fails a pipeline whose shader module could not be named: nothing is created or managed, and the reservation is given back" $ do
      rig ← newNamingRig
      layout ← created (createPipelineLayout (rigRecording rig))
      before ← usage <$> modelOf rig
      failNaming (rigStandIn rig) ObjectShaderModule
      raised ← try @NamingFailure (createPipeline (rigRecording rig) layout shaders formatB8G8R8A8Srgb)
      fmap (const ()) raised `shouldBe` Left (NamingFailure ObjectShaderModule)
      nativeOf rig `shouldReturn'` \calls → [() | CreatedPipeline {} ← calls] `shouldBe` []
      map viewKind <$> atomically (readManaged (rigRecording rig)) `shouldReturn` ["pipeline layout"]
      usage <$> modelOf rig `shouldReturn` before

    it "releases a resource whose naming raised, returns no handle, and lets disposal destroy it" $ do
      rig ← newNamingRig
      layout ← created (createPipelineLayout (rigRecording rig))
      failNaming (rigStandIn rig) ObjectPipeline
      raised ← try @NamingFailure (createPipeline (rigRecording rig) layout shaders formatB8G8R8A8Srgb)
      fmap (const ()) raised `shouldBe` Left (NamingFailure ObjectPipeline)
      [(unnamed, standing)] ←
        (\views → [(viewResource view, viewManagedStanding view) | view ← views, viewKind view == "pipeline"]) <$> atomically (readManaged (rigRecording rig))
      standing `shouldBe` ManagedReleased
      pipelineNative ← (\calls → last [handle | CreatedPipeline handle _ _ ← calls]) <$> nativeCalls' rig
      disposed ← dispose rig
      disposed `shouldContain` [unnamed]
      nativeOf rig `shouldReturn'` \calls → [() | DestroyedPipeline handle ← calls, handle == pipelineNative] `shouldBe` [()]
      standingOf' rig unnamed `shouldReturn` Nothing
      -- The layout it was built over is untouched.
      standingOf' rig (managedResource layout) `shouldReturn` Just ManagedLive

  describe "labels" $ do
    it "brackets a batch and its rendering pass in balanced labels naming the batch, the target and the generation" $ do
      rig ← newNamingRig
      kit ← newKit rig
      frame ← acquired rig
      generation ← activeGeneration rig
      (batch, ()) ← recordTriangle rig kit frame
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      fmap viewBatchCommands <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just 12
      nativeOf rig `shouldReturn'` \calls →
        map labelOrKind [command | Recorded _ command ← calls]
          `shouldBe` [ Just (Left (batchLabel batch generation))
                     , Just (Right "barrier")
                     , Just (Left (passLabel batch generation))
                     , Just (Right "begin rendering")
                     , Nothing
                     , Nothing
                     , Nothing
                     , Nothing
                     , Just (Right "end rendering")
                     , Just (Right "end label")
                     , Just (Right "barrier")
                     , Just (Right "end label")
                     ]

    it "records no label, and seals exactly as before, when the device offers no naming" $ do
      rig ← newRig
      kit ← newKit rig
      frame ← acquired rig
      (batch, ()) ← recordTriangle rig kit frame
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      nativeOf rig `shouldReturn'` \calls → [() | Recorded _ command ← calls, isLabel command] `shouldBe` []

    it "closes every open label, innermost first, when the consumer raises inside rendering, and keeps its failure" $ do
      rig ← newNamingRig
      kit ← newKit rig
      frame ← acquired rig
      raised ← try @ErrorCall $ recorded rig frame $ \recorder → do
        enterRendering recorder
        ok (bindPipeline recorder (kitPipelineHandle kit))
        void (throwIO (ErrorCall "the consumer failed"))
      fmap (const ()) raised `shouldBe` Left (ErrorCall "the consumer failed")
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldBe` BatchPartial "the consumer raised: the consumer failed"
      nativeOf rig `shouldReturn'` \calls → do
        labelBalance calls `shouldBe` 0
        [command | Recorded _ command ← drop (length calls - 2) calls] `shouldBe` [CommandEndLabel, CommandEndLabel]
        [() | Ended _ ← calls] `shouldBe` []

    it "closes every open label after a cancellation, and re-delivers the cancellation" $ do
      rig ← newNamingRig
      kit ← newKit rig
      frame ← acquired rig
      started ← newEmptyMVar
      never ← newEmptyMVar
      owner ← myThreadId
      _ ← forkIO (takeMVar started >> killThread owner >> putMVar never ())
      outcome ← try @SomeException $ recorded rig frame $ \recorder → do
        enterRendering recorder
        ok (bindPipeline recorder (kitPipelineHandle kit))
        putMVar started ()
        takeMVar never
      fmap (const ()) outcome `shouldSatisfy` either (const True) (const False)
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldSatisfy` \case
        BatchPartial reason → "a cancellation ended the consumer" `Text.isPrefixOf` reason
        _ → False
      nativeOf rig `shouldReturn'` \calls → labelBalance calls `shouldBe` 0

    it "closes every open label when a command failed and the consumer returned, and still refuses to seal" $ do
      rig ← newNamingRig
      kit ← newKit rig
      frame ← acquired rig
      answer ← recordFrame (rigRecording rig) frame $ \recorder → do
        enterRendering recorder
        failAt (rigRecording' rig) AtRecord
        try @RecordingFailure (bindPipeline recorder (kitPipelineHandle kit))
      fmap (const ()) answer `shouldBe` Left (RefusedIllegal "a command failed during recording, so the batch was not sealed")
      nativeOf rig `shouldReturn'` \calls → labelBalance calls `shouldBe` 0

    it "leaves a batch whose labels could not be balanced partial and unsubmittable, raising the closing failure" $ do
      rig ← newNamingRig
      frame ← acquired rig
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 0)
      failAt (rigRecording' rig) AtEndLabel
      raised ← try @RecordingFailure $ recorded rig frame $ \recorder →
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
      fmap (const ()) raised `shouldBe` Left (RecordingFailure AtEndLabel)
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldBe` BatchPartial "the batch's labels could not be balanced: RecordingFailure AtEndLabel"
      nativeOf rig `shouldReturn'` \calls → [() | Ended _ ← calls] `shouldBe` []
      -- Never sealed, so never submittable; it keeps its storage and holds
      -- until a discard invalidates it.
      model ← modelOf rig
      [storage] ← (\views → [viewResource each | each ← views, viewKind each == "frame storage"]) <$> atomically (readManaged (rigRecording rig))
      recordedOf model storage `shouldBe` [viewBatch view]
      ok (discardBatch (rigRecording rig) (viewBatch view))
      after ← modelOf rig
      recordedOf after storage `shouldBe` []

    it "keeps the consumer's own failure when its labels could not be balanced either" $ do
      rig ← newNamingRig
      kit ← newKit rig
      frame ← acquired rig
      raised ← try @ErrorCall $ recorded rig frame $ \recorder → do
        enterRendering recorder
        ok (bindPipeline recorder (kitPipelineHandle kit))
        failAt (rigRecording' rig) AtEndLabel
        void (throwIO (ErrorCall "the consumer failed"))
      fmap (const ()) raised `shouldBe` Left (ErrorCall "the consumer failed")
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldBe` BatchPartial "the batch's labels could not be balanced: RecordingFailure AtEndLabel"
      model ← modelOf rig
      recordedOf model (kitPipeline kit) `shouldBe` [viewBatch view]
      succeedAt (rigRecording' rig) AtEndLabel
      ok (discardBatch (rigRecording rig) (viewBatch view))

  describe "buffers and images" $ do
    it "fixes each kind's usage flags, memory usage, format features and view aspect, and the formats each image kind takes" $ do
      map bufferKindUse [minBound .. maxBound]
        `shouldBe` [ (0x80 .|. 0x02, UsageStaticGeometry)
                   , (0x40 .|. 0x02, UsageStaticGeometry)
                   , (0x80 .|. 0x40, UsageFrameRing)
                   , (0x20, UsageFrameRing)
                   , (0x01, UsageStaging)
                   ]
      map imageKindUse [minBound .. maxBound]
        `shouldBe` [ ImageUse (0x04 .|. 0x02) (0x0001 .|. 0x8000) UsageTexture 0x1
                   , ImageUse 0x20 0x0200 UsageTexture 0x2
                   , ImageUse (0x10 .|. 0x01) (0x0080 .|. 0x4000) UsageTexture 0x1
                   ]
      map kindFormats [minBound .. maxBound]
        `shouldBe` [[Rgba8Srgb, Rgba8Linear, Bc7Srgb, Bc7Linear], [Depth32Float, Depth24, Depth16], [Rgba8Srgb, Rgba8Linear, Bgra8Srgb, Bgra8Linear]]
      [fullMipChain width height | (width, height) ← [(1, 1), (64, 64), (64, 1), (100, 30), (4096, 2048), (0, 0)]] `shouldBe` [1, 7, 7, 7, 13, 0]

    it "creates a buffer of every kind in the memory its usage chooses, mapping only host-visible memory, and reports each live by kind" $ do
      rig ← newRig
      buffers ← mapM (\kind → created (createBuffer (rigRecording rig) (BufferDescription kind 256))) [minBound .. maxBound]
      views ← managedOf rig (map managedResource buffers)
      [(viewKind view, viewManagedStanding view) | view ← views]
        `shouldBe` [(kind, ManagedLive) | kind ← ["vertex buffer", "index buffer", "instance buffer", "lookup buffer", "staging buffer"]]
      calls ← allocatorCalls (allocatorOf rig)
      blocks ← heldBlocks (allocatorOf rig)
      let placed view = case viewNativeHandles view of
            [buffer, allocation] →
              ( [kind | MadeBuffer made allocated block ← calls, made == buffer, allocated == allocation, (held, kind, _, _) ← blocks, held == block]
              , [() | Mapped mapped ← calls, mapped == allocation]
              )
            _ → ([], [])
      map placed views
        `shouldBe` [ ([deviceLocalType], [])
                   , ([deviceLocalType], [])
                   , ([hostCoherentType], [()])
                   , ([hostCoherentType], [()])
                   , ([hostCoherentType], [()])
                   ]

    it "creates an image of every kind, BC7 included, with its one owned view of the whole image, after asking the device about exactly its use" $ do
      rig ← newRig
      let described = [ImageDescription TextureImage Rgba8Srgb 64 64 7, ImageDescription TextureImage Bc7Linear 64 32 7, ImageDescription DepthTarget Depth32Float 64 64 1, ImageDescription ColorTarget Bgra8Srgb 64 64 1]
      images ← mapM (created . createImage (rigRecording rig)) described
      views ← managedOf rig (map managedResource images)
      [(viewKind view, viewManagedStanding view) | view ← views]
        `shouldBe` [("texture", ManagedLive), ("texture", ManagedLive), ("depth target", ManagedLive), ("color target", ManagedLive)]
      native ← nativeCalls' rig
      [query | QueriedSupport query ← native]
        `shouldBe` [ ImageQuery (formatCode format) (useImageFlags (imageKindUse kind)) (useFormatFeatures (imageKindUse kind))
                   | ImageDescription kind format _ _ _ ← described
                   ]
      calls ← allocatorCalls (allocatorOf rig)
      blocks ← heldBlocks (allocatorOf rig)
      -- Each view covers its own image, in its format, over the kind's aspect,
      -- across every mip level; each image is device-local and never mapped.
      [ (request, [kind | MadeImage made allocated block ← calls, made == image, allocated == allocation, (held, kind, _, _) ← blocks, held == block], [() | Mapped mapped ← calls, mapped == allocation])
        | view ← views
        , [image, owned, allocation] ← [viewNativeHandles view]
        , CreatedView handle request ← native
        , handle == owned
        ]
        `shouldBe` [ (ViewRequest image (formatCode format) (useAspect (imageKindUse kind)) levels, [deviceLocalType], [])
                   | (ImageDescription kind format _ _ levels, image) ← zip described [image | MadeImage image _ _ ← calls]
                   ]

    it "charges the allocator's blocks and never a resource's own size, reserving two objects for a buffer and three for an image" $ do
      rig ← newRig
      base ← chargedOf rig
      _ ← created (createBuffer (rigRecording rig) (BufferDescription StagingBuffer 100))
      chargedSince rig base `shouldReturn` (standInBlockSize, 2)
      -- A second buffer places in the block the first opened: nothing new is
      -- charged but its objects.
      _ ← created (createBuffer (rigRecording rig) (BufferDescription StagingBuffer 100))
      chargedSince rig base `shouldReturn` (standInBlockSize, 4)
      _ ← created (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      chargedSince rig base `shouldReturn` (2 * standInBlockSize, 7)
      usageDeviceMemory <$> usageOf' rig >>= \charged → heldBytes (allocatorOf rig) `shouldReturn` charged

    it "destroys a released image's view, then the image, then its allocation, and a buffer before its allocation, giving back their objects" $ do
      rig ← newRig
      base ← chargedOf rig
      image ← created (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      buffer ← created (createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64))
      [[imageNative, view, imageAllocation], [bufferNative, bufferAllocation]] ← map viewNativeHandles <$> managedOf rig [managedResource image, managedResource buffer]
      -- What the allocator had done when the view was destroyed.
      seen ← newIORef Nothing
      onceAt (rigRecording' rig) AtDestroyView (allocatorCalls (allocatorOf rig) >>= writeIORef seen . Just)
      ok (releaseManaged (rigRecording rig) image)
      ok (releaseManaged (rigRecording rig) buffer)
      sort <$> dispose rig `shouldReturn` sort [managedResource image, managedResource buffer]
      nativeOf rig `shouldReturn'` \calls → [handle | DestroyedView handle ← calls] `shouldBe` [view]
      readIORef seen `shouldReturn'` \case
        Just atView → [() | DestroyedImage _ ← atView] `shouldBe` []
        Nothing → expectationFailure "the view was never destroyed"
      teardown ← filter (\case DestroyedImage _ → True; DestroyedBuffer _ → True; FreedAllocation _ → True; Unmapped _ → True; _ → False) <$> allocatorCalls (allocatorOf rig)
      [call | call ← teardown, call `elem` [DestroyedImage imageNative, FreedAllocation imageAllocation]] `shouldBe` [DestroyedImage imageNative, FreedAllocation imageAllocation]
      [call | call ← teardown, call `elem` [DestroyedBuffer bufferNative, FreedAllocation bufferAllocation]] `shouldBe` [DestroyedBuffer bufferNative, FreedAllocation bufferAllocation]
      liveAllocations (allocatorOf rig) `shouldReturn` 0
      -- The blocks VMA keeps stay charged; the objects are given back.
      snd <$> chargedSince rig base `shouldReturn` 0
      managedOf rig [managedResource image, managedResource buffer] `shouldReturn` []

    it "keeps a released buffer and image while a batch's hold on them remains, and destroys them once it ends" $ do
      rig ← newRig
      kit ← newKit rig
      buffer ← created (createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64))
      image ← created (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      frame ← acquired rig
      -- Nothing records through them yet (GRS-3), so the batch takes its
      -- references in the model directly.
      (batch, ()) ← recorded rig frame $ \recorder → do
        inModel rig (extendBatch (recorderBatch recorder) [managedResource buffer, managedResource image])
        drawTriangle recorder kit
      ok (releaseManaged (rigRecording rig) buffer)
      ok (releaseManaged (rigRecording rig) image)
      dispose rig `shouldReturn` []
      map viewManagedStanding <$> managedOf rig [managedResource buffer, managedResource image] `shouldReturn` [ManagedReleased, ManagedReleased]
      allocatorCalls (allocatorOf rig) >>= \calls → [() | FreedAllocation _ ← calls] `shouldBe` []
      ok (discardBatch (rigRecording rig) batch)
      disposed ← dispose rig
      disposed `shouldContain` [managedResource buffer]
      disposed `shouldContain` [managedResource image]
      liveAllocations (allocatorOf rig) `shouldReturn` 0

    it "retains an image whose view's destruction raised, never retries it, keeps its image and allocation, and fails the session" $ do
      rig ← newRig
      image ← created (createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 16 16 1))
      failAt (rigRecording' rig) AtDestroyView
      ok (releaseManaged (rigRecording rig) image)
      raised ← try @ResourceDestructionFailed (dispose rig)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      standingOf' rig (managedResource image) `shouldReturn` Just (ManagedUncertain "RecordingFailure AtDestroyView")
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      succeedAt (rigRecording' rig) AtDestroyView
      _ ← try @ResourceDestructionFailed (dispose rig)
      nativeOf rig `shouldReturn'` \calls → length [() | DestroyedView _ ← calls] `shouldBe` 1
      allocatorCalls (allocatorOf rig) >>= \calls → [() | DestroyedImage _ ← calls] `shouldBe` []
      liveAllocations (allocatorOf rig) `shouldReturn` 1

    it "retains a buffer whose destruction raised, never retries it, and fails the session" $ do
      rig ← newRig
      buffer ← created (createBuffer (rigRecording rig) (BufferDescription IndexBuffer 64))
      failAllocatorAt (allocatorOf rig) AtDestroyBuffer
      ok (releaseManaged (rigRecording rig) buffer)
      raised ← try @ResourceDestructionFailed (dispose rig)
      fmap (const ()) raised `shouldSatisfy` either (const True) (const False)
      standingOf' rig (managedResource buffer) `shouldReturn` Just (ManagedUncertain "AllocatorFailure AtDestroyBuffer")
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      clearAllocatorAt (allocatorOf rig) AtDestroyBuffer
      _ ← try @ResourceDestructionFailed (dispose rig)
      allocatorCalls (allocatorOf rig) >>= \calls → length [() | DestroyedBuffer _ ← calls] `shouldBe` 1
      liveAllocations (allocatorOf rig) `shouldReturn` 1

  describe "buffer and image refusals before any native effect" $ do
    it "refuses a format the image kind does not take, an empty extent, and mip levels beyond the full chain, calling nothing" $ do
      rig ← newRig
      let refusal description = createImage (rigRecording rig) description
      refusal (ImageDescription TextureImage Depth32Float 16 16 1) `shouldReturn` Left (RefusedImageUnsupported TextureImage Depth32Float)
      refusal (ImageDescription DepthTarget Rgba8Srgb 16 16 1) `shouldReturn` Left (RefusedImageUnsupported DepthTarget Rgba8Srgb)
      refusal (ImageDescription ColorTarget Bc7Srgb 16 16 1) `shouldReturn` Left (RefusedImageUnsupported ColorTarget Bc7Srgb)
      refusal (ImageDescription TextureImage Rgba8Srgb 0 16 1) `shouldReturn` Left (RefusedOutOfBounds 0 0)
      refusal (ImageDescription TextureImage Rgba8Srgb 16 0 1) `shouldReturn` Left (RefusedOutOfBounds 0 0)
      refusal (ImageDescription TextureImage Rgba8Srgb 16 16 0) `shouldReturn` Left (RefusedOutOfBounds 0 0)
      refusal (ImageDescription TextureImage Rgba8Srgb 64 64 8) `shouldReturn` Left (RefusedOutOfBounds 8 7)
      nativeCount rig `shouldReturn` 0
      allocatorCalls (allocatorOf rig) `shouldReturn` []

    it "refuses an image the device does not support for the kind's use, or beyond its limits, after its one query and before anything else" $ do
      rig ← newRig
      supportImages (rigRecording' rig) (const Nothing)
      createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Linear 16 16 1) `shouldReturn` Left (RefusedImageUnsupported ColorTarget Rgba8Linear)
      supportImages (rigRecording' rig) (const (Just (ImageLimits 32 16 3 (2 ^ (31 ∷ Int)))))
      createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 64 16 1) `shouldReturn` Left (RefusedOutOfBounds 64 32)
      createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 32 1) `shouldReturn` Left (RefusedOutOfBounds 32 16)
      createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 4) `shouldReturn` Left (RefusedOutOfBounds 4 3)
      nativeOf rig `shouldReturn'` \calls → [() | call ← calls, not (isQuery call)] `shouldBe` []
      length <$> nativeCalls' rig `shouldReturn` 4
      allocatorCalls (allocatorOf rig) `shouldReturn` []

    it "refuses an image whose memory the device needs beyond its largest resource, having created nothing and kept no reservation" $ do
      rig ← newRig
      base ← chargedOf rig
      supportImages (rigRecording' rig) (const (Just (ImageLimits 16384 16384 15 1000)))
      -- The stand-in's image needs four bytes a texel of its base level.
      createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 32 32 1) `shouldReturn` Left (RefusedOutOfBounds 4096 1000)
      allocatorCalls (allocatorOf rig) `shouldReturn` [AskedImageRequirements 43 32 32]
      nativeOf rig `shouldReturn'` \calls → [() | CreatedView {} ← calls] `shouldBe` []
      chargedSince rig base `shouldReturn` (0, 0)
      atomically (readManaged (rigRecording rig)) `shouldReturn` []

    it "refuses a BC7 texture on a device created without BC compression, asking it nothing, and still creates the other textures" $ do
      rig ← newRigOn (\standIn → standIn {standOffers = [standInDevice {offerTextureCompressionBC = False}]}) defaultBudgetRequest
      (planTextureCompressionBC . fst <$>) <$> atomically (readRootsDevice (rigRoots rig)) `shouldReturn` Just False
      createImage (rigRecording rig) (ImageDescription TextureImage Bc7Srgb 16 16 1) `shouldReturn` Left (RefusedImageUnsupported TextureImage Bc7Srgb)
      nativeCount rig `shouldReturn` 0
      allocatorCalls (allocatorOf rig) `shouldReturn` []
      _ ← created (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      pure ()

    it "refuses an empty buffer, one no device size can hold, and one beyond the device's largest, calling nothing" $ do
      rig ← newRig
      limitBuffers (rigRecording' rig) 1024
      let refusal kind bytes = createBuffer (rigRecording rig) (BufferDescription kind bytes)
      refusal StagingBuffer 0 `shouldReturn` Left (RefusedOutOfBounds 0 0)
      refusal VertexBuffer (2 ^ (64 ∷ Int)) `shouldReturn` Left (RefusedOutOfBounds (2 ^ (64 ∷ Int)) (2 ^ (64 ∷ Int) - 1))
      refusal LookupBuffer 1025 `shouldReturn` Left (RefusedOutOfBounds 1025 1024)
      nativeCount rig `shouldReturn` 0
      allocatorCalls (allocatorOf rig) `shouldReturn` []

    it "refuses a buffer or image whose objects the budget cannot reserve, and one from a stranger's thread, calling nothing" $ do
      rig ← newRig
      exhaust rig
      createBuffer (rigRecording rig) (BufferDescription StagingBuffer 64) `shouldReturn` Left (RefusedBackpressure ObjectBudget)
      createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1) `shouldReturn` Left (RefusedBackpressure ObjectBudget)
      answer ← newEmptyMVar
      _ ← forkIO (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1) >>= putMVar answer)
      takeMVar answer `shouldReturn` Left RefusedNotOwner
      allocatorCalls (allocatorOf rig) `shouldReturn` []
      nativeOf rig `shouldReturn'` \calls → [() | call ← calls, not (isQuery call)] `shouldBe` []

    it "passes the allocator's backpressure and memory-type refusals through, having opened nothing" $ do
      rig ← newRig
      base ← chargedOf rig
      exhaustBytes rig
      createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1) `shouldReturn` Left (RefusedBackpressure ByteBudget)
      createBuffer (rigRecording rig) (BufferDescription StagingBuffer 64) `shouldReturn` Left (RefusedBackpressure ByteBudget)
      allocatorCalls (allocatorOf rig) >>= \calls → [() | Placing _ _ MayOpenMemory ← calls] `shouldBe` []
      heldBytes (allocatorOf rig) `shouldReturn` 0
      allowTypes (allocatorOf rig) (2 ^ hostCoherentType)
      createImage (rigRecording rig) (ImageDescription DepthTarget Depth16 16 16 1) `shouldReturn` Left (RefusedNoMemoryType UsageTexture)
      usageDeviceMemory <$> usageOf' rig `shouldReturn` 0
      snd <$> chargedSince rig base `shouldReturn` 0
      nativeOf rig `shouldReturn'` \calls → [() | CreatedView {} ← calls] `shouldBe` []

  describe "buffer and image failure cleanup" $ do
    it "leaves nothing made, allocated or reserved when a buffer's requirements, creation, bind or map raised" $
      forM_ [AtRequirements, AtCreate, AtBind, AtMap] $ \step → do
        rig ← newRig
        base ← chargedOf rig
        failAllocatorAt (allocatorOf rig) step
        raised ← try @AllocatorFailure (createBuffer (rigRecording rig) (BufferDescription StagingBuffer 64))
        fmap (const ()) raised `shouldBe` Left (AllocatorFailure step)
        liveAllocations (allocatorOf rig) `shouldReturn` 0
        atomically (readRootsAllocations (rigRoots rig)) `shouldReturn` 0
        snd <$> chargedSince rig base `shouldReturn` 0
        atomically (readManaged (rigRecording rig)) `shouldReturn` []
        sessionState <$> modelOf rig `shouldReturn` SessionRunning

    it "keeps counting a buffer whose map and whose cleanup both raised, so its allocator outlives it, and fails the session, raising the map's failure" $ do
      rig ← newRig
      failAllocatorAt (allocatorOf rig) AtMap
      failAllocatorAt (allocatorOf rig) AtDestroyBuffer
      raised ← try @AllocatorFailure (createBuffer (rigRecording rig) (BufferDescription StagingBuffer 64))
      fmap (const ()) raised `shouldBe` Left (AllocatorFailure AtMap)
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      liveAllocations (allocatorOf rig) `shouldReturn` 1
      atomically (readRootsAllocations (rigRoots rig)) `shouldReturn` 1
      atomically (readManaged (rigRecording rig)) `shouldReturn` []

    it "leaves nothing made, allocated or reserved when an image's requirements, creation, bind or view raised, destroying the image a view failed over" $ do
      forM_ [AtRequirements, AtCreate, AtBind] $ \step → do
        rig ← newRig
        base ← chargedOf rig
        failAllocatorAt (allocatorOf rig) step
        raised ← try @AllocatorFailure (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
        fmap (const ()) raised `shouldBe` Left (AllocatorFailure step)
        liveAllocations (allocatorOf rig) `shouldReturn` 0
        snd <$> chargedSince rig base `shouldReturn` 0
        atomically (readManaged (rigRecording rig)) `shouldReturn` []
        nativeOf rig `shouldReturn'` \calls → [() | CreatedView {} ← calls] `shouldBe` []
      rig ← newRig
      base ← chargedOf rig
      failAt (rigRecording' rig) AtCreateView
      raised ← try @RecordingFailure (createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 16 16 1))
      fmap (const ()) raised `shouldBe` Left (RecordingFailure AtCreateView)
      image ← (\calls → [made | MadeImage made _ _ ← calls]) <$> allocatorCalls (allocatorOf rig)
      allocatorCalls (allocatorOf rig) >>= \calls → [destroyed | DestroyedImage destroyed ← calls] `shouldBe` image
      liveAllocations (allocatorOf rig) `shouldReturn` 0
      snd <$> chargedSince rig base `shouldReturn` 0
      atomically (readManaged (rigRecording rig)) `shouldReturn` []
      sessionState <$> modelOf rig `shouldReturn` SessionRunning

    it "retains the image when destroying it after its view failed raised too, and fails the session, raising the view's failure" $ do
      rig ← newRig
      failAt (rigRecording' rig) AtCreateView
      failAllocatorAt (allocatorOf rig) AtDestroyImage
      raised ← try @RecordingFailure (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      fmap (const ()) raised `shouldBe` Left (RecordingFailure AtCreateView)
      sessionState <$> modelOf rig `shouldReturn` SessionFailed CleanupFailed
      liveAllocations (allocatorOf rig) `shouldReturn` 1

  describe "buffer and image names" $ do
    it "names a buffer, an image and its view from the ResourceId, and each allocation inside the allocator, before returning them" $ do
      rig ← newNamingRig
      buffer ← created (createBuffer (rigRecording rig) (BufferDescription InstanceBuffer 64))
      image ← created (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      [[bufferNative, bufferAllocation], [imageNative, view, imageAllocation]] ← map viewNativeHandles <$> managedOf rig [managedResource buffer, managedResource image]
      namesGiven (rigStandIn rig)
        `shouldReturn` [ (ObjectBuffer, bufferNative, bufferName (managedResource buffer))
                       , (ObjectImage, imageNative, imageName (managedResource image))
                       , (ObjectImageView, view, ownedViewName (managedResource image))
                       ]
      allocatorCalls (allocatorOf rig) >>= \calls →
        [(handle, name) | NamedAllocation handle name ← calls]
          `shouldBe` [(bufferAllocation, bufferName (managedResource buffer)), (imageAllocation, imageName (managedResource image))]

    it "releases an image whose naming raised, returns no handle, and disposal destroys it and restores its objects" $ do
      rig ← newNamingRig
      base ← chargedOf rig
      failNaming (rigStandIn rig) ObjectImageView
      raised ← try @NamingFailure (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      fmap (const ()) raised `shouldBe` Left (NamingFailure ObjectImageView)
      [(unnamed, standing)] ← (\views → [(viewResource view, viewManagedStanding view) | view ← views]) <$> atomically (readManaged (rigRecording rig))
      standing `shouldBe` ManagedReleased
      -- The generation keeps its accounting until its disposal restores it.
      snd <$> chargedSince rig base `shouldReturn` 3
      dispose rig `shouldReturn` [unnamed]
      nativeOf rig `shouldReturn'` \calls → length [() | DestroyedView _ ← calls] `shouldBe` 1
      liveAllocations (allocatorOf rig) `shouldReturn` 0
      snd <$> chargedSince rig base `shouldReturn` 0
      sessionState <$> modelOf rig `shouldReturn` SessionRunning

    it "releases a buffer whose allocation could not be named, and disposal destroys it" $ do
      rig ← newRig
      base ← chargedOf rig
      failAllocatorAt (allocatorOf rig) AtName
      raised ← try @AllocatorFailure (createBuffer (rigRecording rig) (BufferDescription StagingBuffer 64))
      fmap (const ()) raised `shouldBe` Left (AllocatorFailure AtName)
      [(unnamed, ManagedReleased)] ← (\views → [(viewResource view, viewManagedStanding view) | view ← views]) <$> atomically (readManaged (rigRecording rig))
      dispose rig `shouldReturn` [unnamed]
      liveAllocations (allocatorOf rig) `shouldReturn` 0
      snd <$> chargedSince rig base `shouldReturn` 0

  describe "ordering managed resources (GRS-3)" $ do
    it "maps every kind's legal uses onto the stages, accesses and layouts the issue fixes" $ do
      let scope kind use = (scopeStages (useScope kind use), scopeAccess (useScope kind use), useLayout use)
      [scope (imageResourceKind kind) use | kind ← [minBound .. maxBound], use ← legalUses (imageResourceKind kind)]
        `shouldBe` [ (0x80, 0x100000000, Just 5)
                   , (0x1000, 0x1000, Just 7)
                   , (0x300, 0x600, Just 1000241000)
                   , (0x400, 0x180, Just 2)
                   , (0x1000, 0x800, Just 6)
                   ]
      -- A buffer has no layout: only its stages and accesses matter.
      [(\(stages, access, _) → (stages, access)) (scope (bufferResourceKind kind) use) | kind ← [minBound .. maxBound], use ← legalUses (bufferResourceKind kind)]
        `shouldBe` [ (0x4, 0x4)
                   , (0x1000, 0x1000)
                   , (0x4, 0x2)
                   , (0x1000, 0x1000)
                   , (0x8C, 0x26)
                   , (0x88, 0x200000000)
                   , (0x1000, 0x800)
                   ]

    it "records the entry barrier at a batch's first touch, the explicit transitions, and the exit barriers at its seal, retaining each resource first" $ do
      rig ← newRig
      kit ← newKit rig
      buffer ← created (createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64))
      image ← created (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 2))
      [bufferNative : _, imageNative : _] ← map viewNativeHandles <$> managedOf rig [managedResource buffer, managedResource image]
      frame ← acquired rig
      -- Inside the first barrier's native call, the batch already retains the
      -- buffer's exact generation.
      retainedAtFirst ← newIORef Nothing
      duringRecord (rigRecording' rig) $ \case
        CommandResourceBarrier {} → readIORef retainedAtFirst >>= \case
          Nothing → modelOf rig >>= \model → writeIORef retainedAtFirst (Just (recordedOf model (managedResource buffer)))
          Just _ → pure ()
        _ → pure ()
      before ← nativeCount rig
      (batch, ()) ← recorded rig frame $ \recorder → do
        ok (transitionResource recorder buffer (FromUse GeometryRead) TransferWrite)
        ok (transitionResource recorder buffer (FromUse TransferWrite) GeometryRead)
        ok (transitionResource recorder image FromUndefined TransferWrite)
        ok (transitionResource recorder image (FromUse TransferWrite) ShaderSampled)
        drawTriangle recorder kit
        ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
      readIORef retainedAtFirst `shouldReturn` Just [batch]
      calls ← drop before <$> nativeCalls' rig
      let vertex = useScope VertexResource
          texture = useScope TextureResource
          wholeImage = BarrierImage imageNative 1 2
          barriers = [(object, from, to) | Recorded _ (CommandResourceBarrier object from to) ← calls]
      barriers
        `shouldBe` [ (BarrierBuffer bufferNative, vertex GeometryRead, vertex TransferWrite)
                   , (BarrierBuffer bufferNative, vertex TransferWrite, vertex GeometryRead)
                   , (wholeImage 0 7, texture ShaderSampled, texture TransferWrite)
                   , (wholeImage 7 5, texture TransferWrite, texture ShaderSampled)
                   , (BarrierBuffer bufferNative, vertex GeometryRead, vertex GeometryRead)
                   , (wholeImage 5 5, texture ShaderSampled, texture ShaderSampled)
                   ]
      -- The exit barriers come after every consumer command and before the
      -- command buffer ends.
      let tail' = reverse (take 3 (reverse calls))
      [isExit call | call ← tail'] `shouldBe` [True, True, False]
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      model ← modelOf rig
      [recordedOf model (managedResource handle) | handle ← [buffer]] `shouldBe` [[batch]]
      recordedOf model (managedResource image) `shouldBe` [batch]

    it "records a resource a batch touches without a layout change with its boundary barriers alone" $ do
      rig ← newRig
      _ ← newKit rig
      buffer ← created (createBuffer (rigRecording rig) (BufferDescription LookupBuffer 64))
      [native : _] ← map viewNativeHandles <$> managedOf rig [managedResource buffer]
      frame ← acquired rig
      before ← nativeCount rig
      _ ← recorded rig frame $ \recorder → ok (transitionResource recorder buffer (FromUse StorageRead) StorageRead)
      calls ← drop before <$> nativeCalls' rig
      let lookup' = useScope LookupResource StorageRead
      [(object, from, to) | Recorded _ (CommandResourceBarrier object from to) ← calls]
        `shouldBe` replicate 2 (BarrierBuffer native, lookup', lookup')

    it "refuses an illegal transition, one that does not start from the batch's use, and one inside rendering, with no native call or retention" $ do
      rig ← newRig
      _ ← newKit rig
      vertices ← created (createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64))
      lookup' ← created (createBuffer (rigRecording rig) (BufferDescription LookupBuffer 64))
      depth ← created (createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 16 16 1))
      frame ← acquired rig
      answers ← newIORef []
      counts ← newIORef []
      let attempt recorder action = do
            before ← nativeCount rig
            answer ← action recorder
            after ← nativeCount rig
            modifyIORef' answers (answer :)
            modifyIORef' counts ((after - before) :)
      _ ← recorded rig frame $ \recorder → do
        attempt recorder $ \r → transitionResource r depth FromUndefined TransferWrite
        attempt recorder $ \r → transitionResource r lookup' (FromUse StorageRead) TransferWrite
        attempt recorder $ \r → transitionResource r vertices FromUndefined TransferWrite
        attempt recorder $ \r → transitionResource r vertices (FromUse TransferWrite) GeometryRead
        enterRendering recorder
        attempt recorder $ \r → transitionResource r vertices (FromUse GeometryRead) TransferWrite
        ok (endRendering recorder)
      reverse <$> readIORef answers
        `shouldReturn` [ Left (RefusedUnsupported "the use TransferWrite of a DepthTargetResource")
                       , Left (RefusedUnsupported "the use TransferWrite of a LookupResource")
                       , Left (RefusedUnsupported "discarding the contents of a VertexResource")
                       , Left (RefusedIllegal "a resource that is GeometryRead, not TransferWrite")
                       , Left (RefusedIllegal "a resource transition inside rendering")
                       ]
      readIORef counts `shouldReturn` replicate 5 0
      model ← modelOf rig
      [recordedOf model (managedResource handle) | handle ← [vertices, lookup']] `shouldBe` [[], []]
      recordedOf model (managedResource depth) `shouldBe` []

    it "refuses a foreign, a released and a stranger's transition, and one through a recorder kept past its consumer, before any native call" $ do
      rig ← newRig
      _ ← newKit rig
      foreignRig ← newRig
      foreign' ← created (createBuffer (rigRecording foreignRig) (BufferDescription VertexBuffer 64))
      released ← created (createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64))
      ok (releaseManaged (rigRecording rig) released)
      live ← created (createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64))
      frame ← acquired rig
      before ← nativeCount rig
      stranger ← newEmptyMVar
      (_, (foreignAnswer, releasedAnswer, kept)) ← recorded rig frame $ \recorder → do
        foreignAnswer ← transitionResource recorder foreign' (FromUse GeometryRead) TransferWrite
        releasedAnswer ← transitionResource recorder released (FromUse GeometryRead) TransferWrite
        _ ← forkIO (transitionResource recorder released (FromUse GeometryRead) GeometryRead >>= putMVar stranger)
        strangerAnswer ← takeMVar stranger
        strangerAnswer `shouldBe` Left RefusedNotOwner
        pure (foreignAnswer, releasedAnswer, recorder)
      (foreignAnswer, releasedAnswer) `shouldBe` (Left (RefusedMisuse (ForeignIdentity ResourceIdentity)), Left (RefusedMisuse (WrongPhase ResourceIdentity)))
      transitionResource kept live (FromUse GeometryRead) GeometryRead `shouldReturn` Left RefusedRecorderClosed
      calls ← drop before <$> nativeCalls' rig
      [() | Recorded _ (CommandResourceBarrier {}) ← calls] `shouldBe` []

    it "leaves a batch whose consumer left a resource away from rest partial, unsealed and owned, recording no exit barrier" $ do
      rig ← newRig
      kit ← newKit rig
      buffer ← created (createBuffer (rigRecording rig) (BufferDescription IndexBuffer 64))
      frame ← acquired rig
      before ← nativeCount rig
      answer ← recordFrame (rigRecording rig) frame $ \recorder → do
        ok (transitionResource recorder buffer (FromUse GeometryRead) TransferWrite)
        drawTriangle recorder kit
      let away = Text.pack (show (managedResource buffer)) <> ", a IndexResource, TransferWrite rather than at rest"
      fmap (const ()) answer `shouldBe` Left (RefusedIllegal ("the consumer left " <> away <> ", so the batch was not sealed"))
      [view] ← atomically (readBatches (rigRecording rig))
      viewBatchStanding view `shouldBe` BatchPartial ("the consumer left " <> away)
      calls ← drop before <$> nativeCalls' rig
      length [() | Recorded _ (CommandResourceBarrier {}) ← calls] `shouldBe` 1
      [() | Ended _ ← calls] `shouldBe` []
      model ← modelOf rig
      recordedOf model (managedResource buffer) `shouldBe` [viewBatch view]
      -- Only a discard ends it: the storage is reset first, then the
      -- references go.
      ok (discardBatch (rigRecording rig) (viewBatch view))
      after ← modelOf rig
      recordedOf after (managedResource buffer) `shouldBe` []

    it "leaves a batch partial, every reference retained, when an entry, a transition or an exit barrier raised" $ do
      forM_ [(0 ∷ Int, "entry"), (1, "transition"), (2, "exit")] $ \(failing, name) → do
        rig ← newRig
        _ ← newKit rig
        buffer ← created (createBuffer (rigRecording rig) (BufferDescription VertexBuffer 64))
        frame ← acquired rig
        seen ← newIORef (0 ∷ Int)
        duringRecord (rigRecording' rig) $ \case
          CommandResourceBarrier {} → do
            count ← readIORef seen
            writeIORef seen (count + 1)
            when (count == failing) (throwIO (ErrorCall ("the " <> name <> " barrier failed")))
          _ → pure ()
        raised ← try @ErrorCall $ recorded rig frame $ \recorder → do
          ok (transitionResource recorder buffer (FromUse GeometryRead) TransferWrite)
          ok (transitionResource recorder buffer (FromUse TransferWrite) GeometryRead)
        fmap (const ()) raised `shouldBe` Left (ErrorCall ("the " <> name <> " barrier failed"))
        [view] ← atomically (readBatches (rigRecording rig))
        viewBatchStanding view `shouldSatisfy` \case
          BatchPartial reason → "vkCmdPipelineBarrier2 raised" `Text.isPrefixOf` reason
          _ → False
        nativeOf rig `shouldReturn'` \calls → [() | Ended _ ← calls] `shouldBe` []
        model ← modelOf rig
        recordedOf model (managedResource buffer) `shouldBe` [viewBatch view]
        ok (discardBatch (rigRecording rig) (viewBatch view))
        after ← modelOf rig
        recordedOf after (managedResource buffer) `shouldBe` []

    it "lets only a batch that initializes a new image touch it, and no other until that batch is submitted" $ do
      rig ← newRig
      _ ← newKit rig
      _ ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 1)
      image ← created (createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 16 16 1))
      let resource = managedResource image
      initializationOf rig resource `shouldReturn` Just Uninitialized
      first ← acquired rig
      second ← acquiredOn rig 1
      -- A first touch that keeps the contents of an uninitialized image.
      before ← nativeCount rig
      keeping ← recordFrame (rigRecording rig) first (\recorder → transitionResource recorder image (FromUse ColorAttachment) ColorAttachment)
      fmap snd keeping `shouldBe` Right (Left RefusedUninitialized)
      [discarded] ← map viewBatch <$> atomically (readBatches (rigRecording rig))
      ok (discardBatch (rigRecording rig) discarded)
      (initializing, ()) ← recorded rig first $ \recorder → ok (transitionResource recorder image FromUndefined ColorAttachment)
      initializationOf rig resource `shouldReturn` Just (InitializingIn initializing)
      -- Another batch, however it would touch it, before the submission.
      during ← recordFrame (rigRecording rig) second $ \recorder → do
        keeps ← transitionResource recorder image (FromUse ColorAttachment) ColorAttachment
        discards ← transitionResource recorder image FromUndefined ColorAttachment
        pure (keeps, discards)
      fmap snd during `shouldBe` Right (Left RefusedUninitialized, Left RefusedUninitialized)
      model ← modelOf rig
      recordedOf model resource `shouldBe` [initializing]
      length . filter (\case Recorded _ (CommandResourceBarrier {}) → True; _ → False) . drop before <$> nativeCalls' rig `shouldReturn` 2
      -- Submitted, not completed: initialized, and the other batch may use it.
      _ ← submitInModel rig first
      initializationOf rig resource `shouldReturn` Just Initialized
      [other] ← map viewBatch . filter ((== second) . viewBatchFrame) <$> atomically (readBatches (rigRecording rig))
      ok (discardBatch (rigRecording rig) other)
      _ ← recorded rig second $ \recorder → ok (transitionResource recorder image (FromUse ColorAttachment) TransferRead) >> ok (transitionResource recorder image (FromUse TransferRead) ColorAttachment)
      pure ()

    it "leaves an image uninitialized, and every resting use unchanged, when its initializing batch is discarded or its recorder reset" $ do
      rig ← newRig
      _ ← newKit rig
      image ← created (createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 16 16 1))
      let resource = managedResource image
      frame ← acquired rig
      (batch, ()) ← recorded rig frame $ \recorder → do
        ok (transitionResource recorder image FromUndefined TransferWrite)
        ok (transitionResource recorder image (FromUse TransferWrite) ShaderSampled)
      ok (discardBatch (rigRecording rig) batch)
      initializationOf rig resource `shouldReturn` Just Uninitialized
      (again, ()) ← recorded rig frame $ \recorder → ok (transitionResource recorder image FromUndefined ShaderSampled)
      initializationOf rig resource `shouldReturn` Just (InitializingIn again)
      ok (resetFrameRecorder (rigRecording rig) frame)
      initializationOf rig resource `shouldReturn` Just Uninitialized
      -- A partial initializing batch initializes nothing either, and the next
      -- batch finds the image at rest, wherever the last one left it.
      _ ← recordFrame (rigRecording rig) frame (\recorder → ok (transitionResource recorder image FromUndefined TransferWrite))
      [partial] ← map viewBatch <$> atomically (readBatches (rigRecording rig))
      ok (discardBatch (rigRecording rig) partial)
      initializationOf rig resource `shouldReturn` Just Uninitialized
      (_, answer) ← recorded rig frame $ \recorder → transitionResource recorder image (FromUse TransferWrite) ShaderSampled
      answer `shouldBe` Left (RefusedIllegal "a resource that is ShaderSampled, not TransferWrite")

  describe "the FFI audit" $
    it "declares a genuine unsafe import for exactly the recording subset and the allocator shim the configuration records, and for nothing else" $ do
      sources ← haskellSources "src"
      declarations ← concat <$> mapM (fmap unsafeDeclarations . Text.readFile) sources
      -- Every unsafe "dynamic" import is one Vulkan entry point; the other
      -- unsafe declarations are the capture callback's address and the
      -- allocator shim's entries.
      let dynamic = [name | Right name ← declarations]
          addresses = [name | Left name ← declarations]
      sort dynamic `shouldBe` sort (ffiUnsafeImports nativeFfiConfiguration)
      sort addresses `shouldBe` sort ("&hetoimasia_vulkan_capture_messenger" : ffiAllocatorImports nativeFfiConfiguration)

-- ---------------------------------------------------------------------------
-- The rig

data Rig = Rig
  { rigRecording' ∷ !RecordingStandIn
  , rigStandIn ∷ !StandIn
  , rigRoots ∷ !StandInRoots
  , rigGenerations ∷ !(Generations () Int Int Text Int)
  , rigRecording ∷ !(Recording () Int Int Text Int Word64)
  , rigTarget ∷ !TargetId
  }

-- | Started roots over the stand-in, one target on surface 10 with a 640 by
-- 480 generation of three images, and a recording over them.
newRig ∷ IO Rig
newRig = newRigWith WithoutCapture defaultBudgetRequest

-- | 'newRig' on a device that offers naming, so resources are named and
-- batches labelled.
newNamingRig ∷ IO Rig
newNamingRig = do
  rig ← newRig
  offerNaming (rigStandIn rig)
  pure rig

-- | 'newRig' whose surface offers transfer-source usage and whose
-- generations ask for it, as a verification capture's do.
newCapturingRig ∷ IO Rig
newCapturingRig = newRigWith CaptureWhenOffered defaultBudgetRequest

newRigWith ∷ CaptureUsage → BudgetRequest → IO Rig
newRigWith capture = newRigFrom capture id

-- | 'newRig' over a stand-in this edits before any roots exist, under this
-- budget.
newRigOn ∷ (StandIn → StandIn) → BudgetRequest → IO Rig
newRigOn = newRigFrom WithoutCapture

newRigFrom ∷ CaptureUsage → (StandIn → StandIn) → BudgetRequest → IO Rig
newRigFrom capture edit request = do
  standIn ← edit <$> newStandIn
  offerSurface standIn $ \offer →
    offer {offerCapabilities = (offerCapabilities offer) {capabilityUsage = imageUsageColorAttachment .|. imageUsageTransferSource}}
  roots ← newStandInRoots standIn (either (error . show) id (validateBudgets request))
  _ ← startRoots roots standardRequest
  target ← admitRootTarget roots OptionalTarget (surfaceNumbered standIn 10) >>= either (fail . show) pure
  generations ← case capture of
    WithoutCapture → newGenerations roots
    CaptureWhenOffered → newGenerationsCapturing roots
  atomically (trackTarget generations target OptionalTarget 10)
  _ ← stepGenerations generations (at 0) (Map.singleton target (TargetGeometry (Right ()) (Just (SurfaceExtent 640 480)) Nothing 1))
  recordingStandIn ← newRecordingStandIn
  recording ← newRecording (recordingStandInOps recordingStandIn) roots generations
  pure (Rig recordingStandIn standIn roots generations recording target)

-- | A layout, a pipeline over it for the generation's format, and slot 0's
-- storage.
data Kit = Kit
  { kitLayoutHandle ∷ !PipelineLayout
  , kitPipelineHandle ∷ !Pipeline
  , kitStorageHandle ∷ !FrameStorage
  , kitLayoutNative ∷ !Word64
  , kitPipelineNative ∷ !Word64
  , kitImage ∷ !Word64
  }

kitLayout, kitPipeline, kitStorage ∷ Kit → ResourceId
kitLayout = managedResource . kitLayoutHandle
kitPipeline = managedResource . kitPipelineHandle
kitStorage = managedResource . kitStorageHandle

newKit ∷ Rig → IO Kit
newKit rig = do
  layout ← created (createPipelineLayout (rigRecording rig))
  pipeline ← created (createPipeline (rigRecording rig) layout shaders formatB8G8R8A8Srgb)
  storage ← created (createFrameStorage (rigRecording rig) (rigTarget rig) 0)
  calls ← nativeCalls' rig
  let layoutNative = last [handle | CreatedLayout handle ← calls]
      pipelineNative = last [handle | CreatedPipeline handle _ _ ← calls]
  image ← firstImage rig
  pure (Kit layout pipeline storage layoutNative pipelineNative image)

shaders ∷ PipelineShaders
shaders = PipelineShaders (ByteString.pack [1, 2, 3, 4]) (ByteString.pack [5, 6, 7, 8])

created ∷ Show refusal ⇒ IO (Either refusal a) → IO a
created action = action >>= either (fail . ("a construction was refused: " <>) . show) pure

ok ∷ IO (Either Refusal ()) → IO ()
ok action = action >>= either (fail . ("a command was refused: " <>) . show) pure

-- | Acquire the next image of the active generation for a fresh frame, in
-- the model alone.
acquired ∷ Rig → IO FrameSlotId
acquired rig = acquiredOn rig 0

acquiredOn ∷ Rig → Word32 → IO FrameSlotId
acquiredOn rig image = atomically $ stateRootsModel (rigRoots rig) $ \model → case reserveFrame (rigTarget rig) model of
  Admitted (reserved, frame) → case acquireImage frame (AcquiredImage (fromIntegral image)) reserved of
    Admitted (acquiredModel, ImageOwned _ _) → (frame, acquiredModel)
    other → error ("the acquisition was refused: " <> show (fmap (const ()) other))
  other → error ("the reservation was refused: " <> show (fmap (const ()) other))

recorded ∷ Rig → FrameSlotId → (Recorder () Int Int Text Int Word64 → IO a) → IO (BatchId, a)
recorded rig frame consumer = recordFrame (rigRecording rig) frame consumer >>= either (fail . ("the recording was refused: " <>) . show) pure

enterRendering ∷ Recorder () Int Int Text Int Word64 → IO ()
enterRendering recorder = do
  ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
  ok (beginRendering recorder (ClearColor 0 0 0 1))

drawTriangle ∷ Recorder () Int Int Text Int Word64 → Kit → IO ()
drawTriangle recorder kit = do
  enterRendering recorder
  ok (bindPipeline recorder (kitPipelineHandle kit))
  ok (setViewport recorder (Viewport 0 0 640 480))
  ok (setScissor recorder (Rect 0 0 640 480))
  ok (draw recorder 3 1)
  ok (endRendering recorder)

-- | The triangle, ended in the presentation layout: eight commands.
recordTriangle ∷ Rig → Kit → FrameSlotId → IO (BatchId, ())
recordTriangle rig kit frame = recorded rig frame $ \recorder → do
  drawTriangle recorder kit
  ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)

submitInModel ∷ Rig → FrameSlotId → IO SubmissionIdOf
submitInModel rig frame = atomically $ stateRootsModel (rigRoots rig) $ \model → case submitFrames [frame] SubmissionAccepted model of
  Admitted (next, SubmissionRecorded submission) → (SubmissionIdOf submission, next)
  _ → error "the submission was refused"

-- | Apply one model operation through the roots, as VK-12's skip or reset
-- would, bypassing this module.
inModel ∷ Rig → (GpuModel → Outcome GpuModel) → IO ()
inModel rig operation = atomically $ stateRootsModel (rigRoots rig) $ \model → case operation model of
  Admitted next → ((), next)
  _ → error "the model refused the operation"

completeInModel ∷ Rig → SubmissionIdOf → IO ()
completeInModel rig (SubmissionIdOf submission) = atomically $ stateRootsModel (rigRoots rig) $ \model →
  case recordCompletion (at 1) (SubmissionCompleted submission) model of
    Admitted next → ((), next)
    _ → error "the completion was refused"

newtype SubmissionIdOf = SubmissionIdOf SubmissionId

-- | Fill the byte budget, so no device memory can be reserved.
exhaustBytes ∷ Rig → IO ()
exhaustBytes rig = atomically $ stateRootsModel (rigRoots rig) $ \model →
  let remaining = byteLimit (modelBudgets model) - usageBytes (usage model)
   in case beginAllocation remaining 0 model of
        Admitted (next, _) → ((), next)
        _ → error "the byte budget could not be filled"

-- | The model's usage now.
usageOf' ∷ Rig → IO Usage
usageOf' rig = usage <$> modelOf rig

-- | The device memory charged and the objects reserved now.
chargedOf ∷ Rig → IO (Natural, Natural)
chargedOf rig = (usageDeviceMemory &&& usageObjects) <$> usageOf' rig

-- | How much more device memory is charged, and how many more objects are
-- reserved, than at a baseline 'chargedOf' answered.
chargedSince ∷ Rig → (Natural, Natural) → IO (Natural, Natural)
chargedSince rig (memory, objects) = (\(now, held) → (now - memory, held - objects)) <$> chargedOf rig

-- | The managed views of these resources, in this order, of those still
-- managed.
managedOf ∷ Rig → [ResourceId] → IO [ManagedView]
managedOf rig resources = (\views → [view | resource ← resources, view ← views, viewResource view == resource]) <$> atomically (readManaged (rigRecording rig))

isQuery ∷ RecordingCall → Bool
isQuery = \case
  QueriedSupport _ → True
  _ → False

-- | Fill the object budget, so nothing more can be admitted.
exhaust ∷ Rig → IO ()
exhaust rig = atomically $ stateRootsModel (rigRoots rig) $ \model →
  let remaining = objectLimit (modelBudgets model) - usageObjects (usage model)
   in case beginAllocation 0 remaining model of
        Admitted (next, _) → ((), next)
        _ → error "the budget could not be filled"

dispose ∷ Rig → IO [ResourceId]
dispose rig = disposeResources (rigRecording rig) (at 1)

modelOf ∷ Rig → IO GpuModel
modelOf rig = atomically (readRootsModel (rigRoots rig))

recordedOf ∷ GpuModel → ResourceId → [BatchId]
recordedOf model resource = recordedIn model (ResourceSubject resource)

recordedIn ∷ GpuModel → HoldSubject → [BatchId]
recordedIn model subject = maybe [] viewRecorded (holdView subject model)

activeGeneration ∷ Rig → IO GenerationId
activeGeneration rig =
  atomically (readTargetGenerations (rigGenerations rig) (rigTarget rig)) >>= \case
    Just view | Just generation ← viewActive view → pure generation
    _ → fail "the target has no active generation"

firstImage ∷ Rig → IO Word64
firstImage rig =
  atomically (readTargetGenerations (rigGenerations rig) (rigTarget rig)) >>= \case
    Just view | (generation : _) ← viewGenerations view, (image : _) ← viewImages generation → pure image
    _ → fail "the target has no image"

standingOf' ∷ Rig → ResourceId → IO (Maybe ManagedStanding)
standingOf' rig resource = lookup resource . map (\view → (viewResource view, viewManagedStanding view)) <$> atomically (readManaged (rigRecording rig))

nativeCalls' ∷ Rig → IO [RecordingCall]
nativeCalls' = recordingCalls . rigRecording'

nativeOf ∷ Rig → IO [RecordingCall]
nativeOf = nativeCalls'

nativeCount ∷ Rig → IO Int
nativeCount rig = length <$> nativeCalls' rig

shouldReturn' ∷ IO a → (a → IO ()) → IO ()
shouldReturn' action assertion = action >>= assertion

shouldSatisfy' ∷ IO a → (a → Bool) → IO ()
shouldSatisfy' action predicate = action >>= \value → predicate value `shouldBe` True

isReset ∷ RecordingCall → Bool
isReset = \case
  ResetStorage _ → True
  _ → False

isEnded, isBind, isDestruction ∷ RecordingCall → Bool
isEnded = \case
  Ended _ → True
  _ → False
isBind = \case
  Recorded _ (CommandBindPipeline _) → True
  _ → False
isDestruction = \case
  DestroyedPipeline _ → True
  DestroyedLayout _ → True
  DestroyedStorage _ → True
  _ → False

-- | Whether the call recorded a managed resource's barrier.
isExit ∷ RecordingCall → Bool
isExit = \case
  Recorded _ (CommandResourceBarrier {}) → True
  _ → False

-- | Where an image's initialization stands in the model.
initializationOf ∷ Rig → ResourceId → IO (Maybe Initialization)
initializationOf rig resource = resourceInitialization resource <$> modelOf rig

isCopyOrHostBarrier ∷ NativeCommand → Bool
isCopyOrHostBarrier = \case
  CommandCopyImageToBuffer {} → True
  CommandHostReadBarrier {} → True
  _ → False

-- | The stand-in allocator every device of the rig is given.
allocatorOf ∷ Rig → AllocatorStandIn
allocatorOf = standAllocator . rigStandIn

-- | The last buffer the allocator made, and its allocation.
bufferOf, allocationOf ∷ Rig → IO Word64
bufferOf rig = (\calls → last [buffer | MadeBuffer buffer _ _ ← calls]) <$> allocatorCalls (allocatorOf rig)
allocationOf rig = (\calls → last [allocation | MadeBuffer _ allocation _ ← calls]) <$> allocatorCalls (allocatorOf rig)

-- | A label command's name as 'Left', a few other commands' kinds as 'Right',
-- and anything else as 'Nothing'.
labelOrKind ∷ NativeCommand → Maybe (Either ByteString.ByteString Text)
labelOrKind = \case
  CommandBeginLabel name → Just (Left name)
  CommandEndLabel → Just (Right "end label")
  CommandImageBarrier {} → Just (Right "barrier")
  CommandBeginRendering {} → Just (Right "begin rendering")
  CommandEndRendering → Just (Right "end rendering")
  _ → Nothing

isLabel ∷ NativeCommand → Bool
isLabel = \case
  CommandBeginLabel _ → True
  CommandEndLabel → True
  _ → False

-- | Opened less closed label regions, over every label call that returned.
labelBalance ∷ [RecordingCall] → Int
labelBalance calls = length [() | Recorded _ (CommandBeginLabel _) ← calls] - length [() | Recorded _ CommandEndLabel ← calls]

firstOr, lastOr ∷ a → [a] → a
firstOr fallback = \case
  first : _ → first
  [] → fallback
lastOr fallback = \case
  [] → fallback
  values → last values

-- | The instant this many milliseconds after the scripted clock's origin.
at ∷ Integer → Instant
at milliseconds = scriptedInstant (either (error . show) id (durationFromNanoseconds AllowZero (milliseconds * 1000000)))

-- ---------------------------------------------------------------------------
-- The audit's reading of the sources

haskellSources ∷ FilePath → IO [FilePath]
haskellSources directory = do
  entries ← listDirectory directory
  concat
    <$> mapM
      ( \entry → do
          let path = directory </> entry
          isDirectory ← doesDirectoryExist path
          if isDirectory
            then haskellSources path
            else pure [path | takeExtension path == ".hs"]
      )
      entries

-- | Every @foreign import ccall unsafe@ in a module: the Vulkan entry point of
-- a @dynamic@ one, named after its @mk@ binding, on the right; the imported
-- entity of any other on the left.
unsafeDeclarations ∷ Text → [Either Text Text]
unsafeDeclarations source = go (Text.lines source)
  where
    go = \case
      line : rest
        | "foreign import ccall unsafe" `Text.isPrefixOf` Text.strip line →
            let declaration = Text.unwords (line : take 2 rest)
                quoted = Text.takeWhile (/= '"') (Text.drop 1 (Text.dropWhile (/= '"') declaration))
                afterQuote = Text.words (Text.drop 1 (Text.dropWhile (/= '"') (Text.drop 1 (Text.dropWhile (/= '"') declaration))))
             in if quoted == "dynamic"
                  then Right (entryPoint (headOr "" afterQuote)) : go rest
                  else Left (last (Text.words quoted)) : go rest
      _ : rest → go rest
      [] → []
    headOr fallback = \case
      value : _ → value
      [] → fallback
    -- @mkCmdDraw@ calls @vkCmdDraw@; @mkBeginCommandBuffer@ calls
    -- @vkBeginCommandBuffer@.
    entryPoint name = "vk" <> Text.drop 2 name
