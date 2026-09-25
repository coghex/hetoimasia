-- | Managed resources and the scoped recorder over stand-in native layers:
-- retention before every capturing call, refusals before any native effect,
-- partial and cancelled recording, discard and reset, replacement, release,
-- readback and disposal.
--
-- A frame is acquired the way the native cases acquire one: in the model
-- alone, through the roots' model, since public acquisition is VK-12's.
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Recording (spec) where

import Control.Concurrent (forkIO, killThread, myThreadId)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, writeTVar)
import Control.Exception (ErrorCall (ErrorCall), SomeException, throwIO, try)
import Control.Monad (void)
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
import System.Directory (listDirectory, doesDirectoryExist)
import System.FilePath ((</>), takeExtension)
import Hetoimasia.Foundation.Time (DurationRequirement (AllowZero), Instant, durationFromNanoseconds, scriptedInstant)
import Hetoimasia.GPU.Model
  ( AcquireAnswer (..)
  , AcquireOutcome (..)
  , CompletionFact (..)
  , GpuModel
  , HoldView (..)
  , Outcome (..)
  , SessionFailureCause (..)
  , SessionState (..)
  , SubmitAnswer (..)
  , SubmitOutcome (..)
  , acquireImage
  , beginAllocation
  , holdView
  , modelBudgets
  , recordCompletion
  , reserveFrame
  , closeSubmittedFrame
  , resetRecorder
  , skipUnsubmittedFrame
  , sessionState
  , submitFrames
  , usage
  , usageObjects
  )
import Hetoimasia.GPU.Model.Budget (BudgetKind (ObjectBudget), BudgetRequest (..), defaultBudgetRequest, objectLimit, validateBudgets)
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
import Hetoimasia.GPU.Vulkan.Native.Generations
import Hetoimasia.GPU.Vulkan.Native.Naming
  ( NativeObjectKind (..)
  , batchLabel
  , commandBufferName
  , commandPoolName
  , passLabel
  , pipelineLayoutName
  , pipelineName
  , readbackBufferName
  , readbackMemoryName
  )
import Hetoimasia.GPU.Vulkan.Native.Presentation
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.RecordingStandIn
import Test.GPU.Vulkan.Native.StandIn
  ( NamingFailure (..)
  , StandIn
  , StandInRoots
  , failNaming
  , namesGiven
  , newStandIn
  , newStandInRoots
  , offerNaming
  , offerSurface
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
    it "computes the atom-aligned mapped range, clamped to the memory" $ do
      mappedRange 64 256 0 256 `shouldBe` (0, 256)
      mappedRange 64 256 10 20 `shouldBe` (0, 64)
      mappedRange 64 256 70 100 `shouldBe` (64, 128)
      mappedRange 64 250 200 50 `shouldBe` (192, 58)
      mappedRange 1 100 3 4 `shouldBe` (3, 4)

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

    it "exposes non-coherent bytes only after the copying batch's submission completed, invalidating the aligned range first" $ do
      rig ← newCapturingRig
      kit ← newKit rig
      atomically (writeTVar (recordingCoherent (rigRecording' rig)) False)
      let bytes = 640 * 480 * 4
      readback ← created (createReadback (rigRecording rig) bytes)
      -- A sentinel from the host is flushed over the whole aligned buffer.
      ok (fillReadback (rigRecording rig) readback 0xAB)
      nativeOf rig `shouldReturn'` \calls → last calls `shouldBe` Flushed (0, standInMemorySize bytes)
      frame ← acquired rig
      (batch, ()) ← recorded rig frame $ \recorder → do
        drawTriangle recorder kit
        ok (transitionImage recorder LayoutColorAttachment LayoutTransferSource)
        ok (copyToReadback recorder readback)
      nativeOf rig `shouldReturn'` \calls →
        [command | Recorded _ command ← calls, isCopyOrHostBarrier command]
          `shouldBe` [ CommandCopyImageToBuffer (kitImage kit) (SurfaceExtent 640 480) (bufferOf calls)
                     , CommandHostReadBarrier (bufferOf calls) (fromIntegral bytes)
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
      readReadback (rigRecording rig) readback 100 16 `shouldReturn` Right (ByteString.replicate 16 0xAB)
      calls ← drop before <$> nativeCalls' rig
      calls `shouldBe` [Invalidated (64, 64), ReadMapped 100 16]
      readReadback (rigRecording rig) readback (bytes - 8) 16 `shouldReturn` Left (RefusedOutOfBounds (bytes + 8) bytes)
      -- An empty read reads nothing and invalidates nothing.
      empty ← nativeCount rig
      readReadback (rigRecording rig) readback 0 0 `shouldReturn` Right ByteString.empty
      nativeCount rig `shouldReturn` empty

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
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Right (ByteString.replicate 4 7)
      drop before <$> nativeCalls' rig `shouldReturn` [ReadMapped 0 4]
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

    it "exposes nothing a fill changed if its flush raised, whatever the buffer held before" $ do
      rig ← newCapturingRig
      atomically (writeTVar (recordingCoherent (rigRecording' rig)) False)
      readback ← created (createReadback (rigRecording rig) 1024)
      ok (fillReadback (rigRecording rig) readback 1)
      readReadback (rigRecording rig) readback 0 4 `shouldReturn` Right (ByteString.replicate 4 1)
      failAt (rigRecording' rig) AtFlush
      raised ← try @RecordingFailure (fillReadback (rigRecording rig) readback 2)
      fmap (const ()) raised `shouldBe` Left (RecordingFailure AtFlush)
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
      namesGiven (rigStandIn rig)
        `shouldReturn` [ (ObjectPipelineLayout, layoutNative, pipelineLayoutName (managedResource layout))
                       , (ObjectPipeline, pipelineNative, pipelineName (managedResource pipeline))
                       , (ObjectCommandPool, pool, commandPoolName (managedResource storage) (rigTarget rig) 0)
                       , (ObjectCommandBuffer, buffer, commandBufferName (managedResource storage) (rigTarget rig) 0)
                       , (ObjectBuffer, firstOr 0 readbackHandles, readbackBufferName (managedResource readback))
                       , (ObjectDeviceMemory, lastOr 0 readbackHandles, readbackMemoryName (managedResource readback))
                       ]

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

  describe "the FFI audit" $
    it "declares a genuine unsafe import for exactly the recording subset the configuration records, and for nothing else" $ do
      sources ← haskellSources "src"
      declarations ← concat <$> mapM (fmap unsafeDeclarations . Text.readFile) sources
      -- Every unsafe "dynamic" import is one Vulkan entry point; the only
      -- other unsafe declaration is the capture callback's address.
      let dynamic = [name | Right name ← declarations]
          addresses = [name | Left name ← declarations]
      sort dynamic `shouldBe` sort (ffiUnsafeImports nativeFfiConfiguration)
      addresses `shouldBe` ["&hetoimasia_vulkan_capture_messenger"]

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
newRigWith capture request = do
  standIn ← newStandIn
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
  DestroyedReadback _ → True
  _ → False

isCopyOrHostBarrier ∷ NativeCommand → Bool
isCopyOrHostBarrier = \case
  CommandCopyImageToBuffer {} → True
  CommandHostReadBarrier {} → True
  _ → False

bufferOf ∷ [RecordingCall] → Word64
bufferOf calls = last [buffer | CreatedReadback buffer _ _ ← calls]

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
