-- | Rendering into a managed color target and reading it back (GRS-5) over
-- the frames' and the recording's stand-in native layers, in frame batches
-- and frame-less ones: the pass, its render area and the copy; pipeline,
-- viewport and scissor checked against the attachment of the pass they are
-- drawn in; refusals of an uninitialized, released or wrong-kind target, a
-- copy before the transfer-source transition and a readback too small; bytes
-- withheld until the copying batch's completion; and initialization by a
-- clearing pass published only by its submission.
--
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Offscreen (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), throwIO, try)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64, Word8)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..))
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Presentation (SurfaceExtent (..), formatB8G8R8A8Srgb)
import Hetoimasia.GPU.Vulkan.Native.Recording
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), recordingCalls)

type Rec = Recorder () Int Int Text Int Word64

spec ∷ Spec
spec = describe "Offscreen color targets" $ do
  describe "rendering and readback" $ do
    it "renders into a color target in a frame batch, its extent the render area, and copies it whole after the transition, the frame's image untouched" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      frame ← owned rig
      before ← commandCount rig
      (batch, ()) ← recordFrame (rigRecording rig) (ownedFrame frame) (renderAndCopy kit) >>= either (fail . show) pure
      commands ← drop before <$> commandsOf' rig
      [() | CommandBeginRendering view extent _ ← commands, view == kitView kit, extent == SurfaceExtent 32 16] `shouldBe` [()]
      [() | CommandCopyImageToBuffer image extent buffer ← commands, image == kitImageHandle kit, extent == SurfaceExtent 32 16, buffer == kitBuffer kit] `shouldBe` [()]
      [size | CommandHostReadBarrier buffer size ← commands, buffer == kitBuffer kit] `shouldBe` [32 * 16 * 4]
      [() | CommandImageBarrier {} ← commands] `shouldBe` []
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      clean rig

    it "renders into a color target and copies it in a frame-less batch, exposing the bytes only after its completion" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Linear
      ticket ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (renderAndCopy kit) >>= either (fail . show) (pure . fst)
      readReadback (rigRecording rig) (kitReadback kit) 0 4 >>= (`shouldSatisfy` notWritten)
      completeAll (rigStandIn rig)
      _ ← progress rig
      atomically (readTicket ticket) `shouldReturn` TicketComplete
      readReadback (rigRecording rig) (kitReadback kit) 0 4 `shouldReturn` Right (ByteString.replicate 4 sentinel)
      clean rig

  describe "the attachment governs" $ do
    it "refuses a pipeline built for another format than the target's, with no native call" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      other ← createPipeline (rigRecording rig) (kitLayout kit) shaders formatB8G8R8A8Srgb >>= either (fail . show) pure
      frame ← owned rig
      answer ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder → do
        ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
        before ← commandCount rig
        bound ← bindPipeline recorder other
        after ← commandCount rig
        ok (endRendering recorder)
        pure (bound, after - before)
      fmap snd answer `shouldBe` Right (Left (RefusedIncompatible ("a pipeline for format " <> tshow formatB8G8R8A8Srgb <> " and an image of format " <> tshow (formatCode Rgba8Srgb))), 0)

    it "checks a pipeline, a viewport and a scissor left from the frame's pass again against a target of another format and extent" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      framed ← createPipeline (rigRecording rig) (kitLayout kit) shaders formatB8G8R8A8Srgb >>= either (fail . show) pure
      frame ← owned rig
      answers ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder → do
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        ok (beginRendering recorder (ClearColor 0 0 0 1))
        ok (bindPipeline recorder framed)
        ok (setViewport recorder (Viewport 0 0 640 480))
        ok (setScissor recorder (Rect 0 0 640 480))
        ok (draw recorder 3 1)
        ok (endRendering recorder)
        ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
        ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
        -- The frame's pipeline is still bound, for another format.
        wrongFormat ← draw recorder 3 1
        ok (bindPipeline recorder (kitPipeline kit))
        -- The frame's viewport and scissor are still set, beyond the target.
        wrongViewport ← draw recorder 3 1
        ok (setViewport recorder (Viewport 0 0 32 16))
        wrongScissor ← draw recorder 3 1
        ok (setScissor recorder (Rect 0 0 32 16))
        fits ← draw recorder 3 1
        ok (endRendering recorder)
        pure [wrongFormat, wrongViewport, wrongScissor, fits]
      fmap snd answers
        `shouldBe` Right
          [ Left (RefusedIncompatible ("a pipeline for format " <> tshow formatB8G8R8A8Srgb <> " and an image of format " <> tshow (formatCode Rgba8Srgb)))
          , Left (RefusedIllegal "a viewport outside the color target")
          , Left (RefusedIllegal "a scissor outside the color target")
          , Right ()
          ]

    it "refuses dynamic state outside rendering in a frame-less batch, which has no image to check it against" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      answers ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → sequence [bindPipeline recorder (kitPipeline kit), setViewport recorder (Viewport 0 0 1 1)]) >>= either (fail . show) (pure . snd)
      answers `shouldBe` replicate 2 (Left (RefusedIllegal "dynamic state outside rendering in a frame-less batch, with no attachment to check it against"))

  describe "refusals before any native effect" $ do
    it "refuses an uninitialized target a pass keeps, a released target, an image of another kind, a target of more than one mip level and another session's target, recording nothing" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      foreignRig ← newRig
      foreignKit ← newKit foreignRig Rgba8Srgb
      released ← createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 8 8 1) >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) released)
      releasedReadback ← createReadback (rigRecording rig) (32 * 16 * 4) >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) releasedReadback)
      texture ← createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 8 8 1) >>= either (fail . show) pure
      mipmapped ← createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 32 16 2) >>= either (fail . show) pure
      frame ← owned rig
      before ← commandCount rig
      answer ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder →
        sequence
          [ beginRenderingInto recorder (kitTarget kit) ClearTarget (ClearColor 0 0 0 1)
          , beginRenderingInto recorder released ClearFromUndefined (ClearColor 0 0 0 1)
          , beginRenderingInto recorder texture ClearFromUndefined (ClearColor 0 0 0 1)
          , beginRenderingInto recorder mipmapped ClearFromUndefined (ClearColor 0 0 0 1)
          , beginRenderingInto recorder (kitTarget foreignKit) ClearFromUndefined (ClearColor 0 0 0 1)
          , copyTargetToReadback recorder (kitTarget foreignKit) (kitReadback kit)
          , copyTargetToReadback recorder texture (kitReadback kit)
          , copyTargetToReadback recorder (kitTarget kit) releasedReadback
          , copyTargetToReadback recorder (kitTarget kit) (kitReadback foreignKit)
          ]
      fmap snd answer
        `shouldBe` Right
          [ Left RefusedUninitialized
          , Left (RefusedMisuse (WrongPhase ResourceIdentity))
          , Left RefusedWrongKind
          , Left (RefusedUnsupported "rendering into a color target of more than one mip level")
          , Left (RefusedMisuse (ForeignIdentity ResourceIdentity))
          , Left (RefusedMisuse (ForeignIdentity ResourceIdentity))
          , Left RefusedWrongKind
          , Left (RefusedMisuse (WrongPhase ResourceIdentity))
          , Left (RefusedMisuse (ForeignIdentity ResourceIdentity))
          ]
      after ← commandCount rig
      after `shouldBe` before

    it "refuses a copy before the target's transfer-source transition, a copy inside rendering, and a readback too small, recording no copy" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      small ← createReadback (rigRecording rig) 16 >>= either (fail . show) pure
      frame ← owned rig
      answer ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder → do
        ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
        inside ← copyTargetToReadback recorder (kitTarget kit) (kitReadback kit)
        ok (endRendering recorder)
        early ← copyTargetToReadback recorder (kitTarget kit) (kitReadback kit)
        ok (transitionResource recorder (kitTarget kit) (FromUse ColorAttachment) TransferRead)
        tooSmall ← copyTargetToReadback recorder (kitTarget kit) small
        ok (transitionResource recorder (kitTarget kit) (FromUse TransferRead) ColorAttachment)
        pure [inside, early, tooSmall]
      fmap snd answer
        `shouldBe` Right
          [ Left (RefusedIllegal "a copy inside rendering")
          , Left (RefusedIllegal "a resource that is ColorAttachment, not TransferRead")
          , Left (RefusedOutOfBounds (32 * 16 * 4) 16)
          ]
      commands ← commandsOf' rig
      [() | CommandCopyImageToBuffer {} ← commands] `shouldBe` []

    it "refuses to seal a batch that leaves the target in its transfer-source use, leaving it partial" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      frame ← owned rig
      answer ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder → do
        ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1))
        ok (endRendering recorder)
        ok (transitionResource recorder (kitTarget kit) (FromUse ColorAttachment) TransferRead)
        ok (copyTargetToReadback recorder (kitTarget kit) (kitReadback kit))
      fmap (const ()) answer `shouldSatisfy` either (const True) (const False)
      views ← atomically (readBatches (rigRecording rig))
      map viewBatchStanding views `shouldSatisfy` all partial

  describe "readback evidence" $ do
    it "exposes nothing a discarded copy would have written, nor anything on an unrelated batch's completion, and keeps a released target until its batch completes" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      -- A copy in an action that then raises is discarded with its batch.
      _ ← try @ErrorCall $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (renderAndCopy kit)
        throwIO (ErrorCall "the action failed")
      readReadback (rigRecording rig) (kitReadback kit) 0 4 >>= (`shouldSatisfy` notWritten)
      -- A copy, then an unrelated batch: only the unrelated one completes.
      tickets ← withFramelessScope (rigFrames rig) $ \scope → do
        copying ← recordFramelessIn scope (renderAndCopy kit) >>= either (fail . show) (pure . fst)
        unrelated ← recordFramelessIn scope (\_ → pure ()) >>= either (fail . show) (pure . fst)
        pure [copying, unrelated]
      ok (releaseManaged (rigRecording rig) (kitTarget kit))
      fences ← map (framelessFence . viewFramelessSync) <$> atomically (readFramelessSlots (rigFrames rig))
      case fences of
        [_, second] → completeFence (rigStandIn rig) second
        other → expectationFailure ("the fences were " <> show other)
      _ ← progress rig
      _ ← progress rig
      mapM (atomically . readTicket) tickets `shouldReturn` [TicketPending, TicketComplete]
      readReadback (rigRecording rig) (kitReadback kit) 0 4 >>= (`shouldSatisfy` notWritten)
      -- The released target is still the copying batch's.
      views ← atomically (readManaged (rigRecording rig))
      [viewManagedStanding view | view ← views, viewResource view == managedResource (kitTarget kit)] `shouldBe` [ManagedReleased]
      completeAll (rigStandIn rig)
      _ ← progress rig
      readReadback (rigRecording rig) (kitReadback kit) 0 4 `shouldReturn` Right (ByteString.replicate 4 sentinel)
      clean rig

  describe "initialization" $ do
    it "initializes a new target by a pass that clears it from undefined, published to other batches only by its submission" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      refusedBefore ← newIORef []
      withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 0 1)) >> ok (endRendering recorder))
        -- Recorded, not submitted: another batch may not keep its contents.
        other ← recordFramelessIn scope (\recorder → beginRenderingInto recorder (kitTarget kit) ClearTarget (ClearColor 0 0 0 1))
        modifyIORef' refusedBefore (fmap snd other :)
      readIORef refusedBefore `shouldReturn` [Right (Left RefusedUninitialized)]
      -- Submitted when the action returned: now any batch may keep them.
      later ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → beginRenderingInto recorder (kitTarget kit) ClearTarget (ClearColor 0 0 0 1) <* endRendering recorder)
      fmap snd later `shouldBe` Right (Right ())
      clean rig
  where
    notWritten = \case
      Left (RefusedNotWritten _) → True
      _ → False
    partial = \case
      BatchPartial _ → True
      _ → False

-- | A target of 32 by 16 in this format, a pipeline built for it, and a
-- readback buffer exactly its size.
data Kit = Kit
  { kitTarget ∷ !Image
  , kitImageHandle ∷ !Word64
  , kitView ∷ !Word64
  , kitLayout ∷ !PipelineLayout
  , kitPipeline ∷ !Pipeline
  , kitReadback ∷ !Readback
  , kitBuffer ∷ !Word64
  }

newKit ∷ Rig → ImageFormat → IO Kit
newKit rig format = do
  target ← createImage (rigRecording rig) (ImageDescription ColorTarget format 32 16 1) >>= either (fail . show) pure
  layout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
  pipeline ← createPipeline (rigRecording rig) layout shaders (formatCode format) >>= either (fail . show) pure
  readback ← createReadback (rigRecording rig) (32 * 16 * 4) >>= either (fail . show) pure
  -- The stand-in copies nothing: what is exposed is what the host wrote.
  fillReadback (rigRecording rig) readback sentinel >>= either (fail . show) pure
  views ← atomically (readManaged (rigRecording rig))
  (image, view) ← case [handles | ManagedView resource _ _ handles ← views, resource == managedResource target] of
    [image : view : _] → pure (image, view)
    other → fail ("the target's handles were " <> show other)
  buffer ← case [handles | ManagedView resource _ _ handles ← views, resource == managedResource readback] of
    [handle : _] → pure handle
    other → fail ("the readback's handles were " <> show other)
  pure (Kit target image view layout pipeline readback buffer)

-- | Clear the target from undefined, draw the triangle, move it to its
-- transfer-source use, copy it into the readback, and return it to rest.
renderAndCopy ∷ Kit → Rec → IO ()
renderAndCopy kit recorder = do
  ok (beginRenderingInto recorder (kitTarget kit) ClearFromUndefined (ClearColor 0 0 1 1))
  ok (bindPipeline recorder (kitPipeline kit))
  ok (setViewport recorder (Viewport 0 0 32 16))
  ok (setScissor recorder (Rect 0 0 32 16))
  ok (draw recorder 3 1)
  ok (endRendering recorder)
  ok (transitionResource recorder (kitTarget kit) (FromUse ColorAttachment) TransferRead)
  ok (copyTargetToReadback recorder (kitTarget kit) (kitReadback kit))
  ok (transitionResource recorder (kitTarget kit) (FromUse TransferRead) ColorAttachment)

sentinel ∷ Word8
sentinel = 0xA5

shaders ∷ PipelineShaders
shaders = PipelineShaders (ByteString.pack [1, 2, 3, 4]) (ByteString.pack [5, 6, 7, 8])

-- | Every command the recording recorded, oldest first.
commandsOf' ∷ Rig → IO [NativeCommand]
commandsOf' rig = (\calls → [command | Recorded _ command ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

commandCount ∷ Rig → IO Int
commandCount rig = length <$> commandsOf' rig

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
