-- | Depth attachments (GRS-10) over the frames' and the recording's stand-in
-- native layers, in frame batches and frame-less ones: the depth-only format
-- the backend chooses and its fallback; a pipeline's declared depth test,
-- write and comparison reaching pipeline construction, and a colour-only
-- pipeline declaring none; a pass's depth attachment, its clear value and its
-- boundary barriers under #335's rules; refusals of a mismatched extent, a
-- released, foreign, wrong-kind or multi-level target and a clear value
-- outside zero to one; initialization by a clearing pass, published only by
-- its batch's submission and never by a discarded one; the retention of a
-- released depth target until its batch has completed or been discarded; and
-- the agreement between a pipeline and the pass it is drawn in, however the
-- commands are ordered.
--
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Depth (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), throwIO, try)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..))
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Presentation (formatB8G8R8A8Srgb)
import Hetoimasia.GPU.Vulkan.Native.Recording
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), recordingCalls, standInImageLimits, supportImages)

type Rec = Recorder () Int Int Text Int Word64

spec ∷ Spec
spec = describe "Depth attachments" $ do
  describe "the depth format" $ do
    it "is 32-bit floating point where the device supports it as a depth attachment, asked about alone, with the very query a depth target's creation makes" $ do
      rig ← newRig
      selectDepthFormat (rigRecording rig) `shouldReturn` Right Depth32Float
      chosen ← queriesOf rig
      chosen `shouldBe` [ImageQuery (formatCode Depth32Float) depthUsage depthFeatures]
      _ ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 32 16 1) >>= either (fail . show) pure
      queriesOf rig `shouldReturn` chosen <> chosen
      -- The target's one view covers its depth aspect alone.
      calls ← recordingCalls (rigRecordingStandIn rig)
      [(requestViewFormat request, requestViewAspect request) | CreatedView _ request ← calls] `shouldBe` [(formatCode Depth32Float, depthAspect)]

    it "falls back to the other depth-only formats in order, asking the device about each and assuming none" $ do
      answers ← mapM chooseWithout [[], [Depth32Float], [Depth32Float, Depth24], [Depth32Float, Depth24, Depth16]]
      answers
        `shouldBe` [ (Right Depth32Float, map formatCode [Depth32Float])
                   , (Right Depth24, map formatCode [Depth32Float, Depth24])
                   , (Right Depth16, map formatCode [Depth32Float, Depth24, Depth16])
                   , (Left (RefusedImageUnsupported DepthTarget Depth32Float), map formatCode [Depth32Float, Depth24, Depth16])
                   ]

    it "offers only depth-only formats, none with a stencil aspect, and refuses a depth target of any other format before the device is asked" $ do
      let stencilBearing = [127, 128, 129, 130]
      map formatCode depthFormatPreference `shouldSatisfy` all (`notElem` stencilBearing)
      map formatCode (kindFormats DepthTarget) `shouldSatisfy` all (`notElem` stencilBearing)
      depthFormatPreference `shouldBe` kindFormats DepthTarget
      rig ← newRig
      let others = [Rgba8Srgb, Bgra8Linear, Bc7Srgb]
      answers ← mapM (\format → createImage (rigRecording rig) (ImageDescription DepthTarget format 32 16 1)) others
      map (fmap (const ())) answers `shouldBe` [Left (RefusedImageUnsupported DepthTarget format) | format ← others]
      queriesOf rig `shouldReturn` []

    it "refuses a depth target the device does not support as a depth attachment before anything is created" $ do
      rig ← newRig
      supportImages (rigRecordingStandIn rig) (rejecting [Depth32Float])
      answer ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 32 16 1)
      fmap (const ()) answer `shouldBe` Left (RefusedImageUnsupported DepthTarget Depth32Float)
      calls ← recordingCalls (rigRecordingStandIn rig)
      [() | CreatedView {} ← calls] `shouldBe` []
      views ← atomically (readManaged (rigRecording rig))
      [viewKind view | view ← views, viewKind view == "depth target"] `shouldBe` []

  describe "depth in pipelines" $ do
    it "declares a pipeline's depth test, depth write and comparison to the native layer, the default being less-or-equal, and nothing for a pipeline that declares none" $ do
      rig ← newRig
      layout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
      plain ← createPipeline (rigRecording rig) layout shaders 37 >>= either (fail . show) pure
      let reversed = PipelineDepth Depth32Float True False CompareGreaterOrEqual
          formatOnly = PipelineDepth Depth16 False False CompareAlways
      tested ← createPipelineWithDepth (rigRecording rig) layout shaders 37 noVertexInput (depthTested Depth32Float) >>= either (fail . show) pure
      other ← createPipelineWithDepth (rigRecording rig) layout shaders 37 noVertexInput reversed >>= either (fail . show) pure
      third ← createPipelineWithDepth (rigRecording rig) layout shaders 37 noVertexInput formatOnly >>= either (fail . show) pure
      depthTested Depth32Float `shouldBe` PipelineDepth Depth32Float True True CompareLessOrEqual
      calls ← recordingCalls (rigRecordingStandIn rig)
      let made = [handle | CreatedPipeline handle _ _ ← calls]
      length made `shouldBe` 4
      [(handle, depth) | DeclaredDepth handle depth ← calls] `shouldBe` [(made !! 1, depthTested Depth32Float), (made !! 2, reversed), (made !! 3, formatOnly)]
      (plain, tested, other, third) `seq` clean rig

    it "refuses a depth declaration the device cannot render with, naming it, before any pipeline is created" $ do
      rig ← newRig
      layout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
      supportImages (rigRecordingStandIn rig) (rejecting [Depth24])
      let build depth = fmap (const ()) <$> createPipelineWithDepth (rigRecording rig) layout shaders 37 noVertexInput depth
      answers ←
        sequence
          [ build (PipelineDepth Depth32Float False True CompareLessOrEqual)
          , build (depthTested Rgba8Srgb)
          , build (depthTested Depth24)
          ]
      answers
        `shouldBe` [ Left (RefusedIllegal "a pipeline that writes depth without testing it")
                   , Left (RefusedImageUnsupported DepthTarget Rgba8Srgb)
                   , Left (RefusedImageUnsupported DepthTarget Depth24)
                   ]
      calls ← recordingCalls (rigRecordingStandIn rig)
      [() | CreatedPipeline {} ← calls] `shouldBe` []
      -- Only the last was a question for the device: the others were decided
      -- before it was asked.
      queriesOf rig `shouldReturn` [ImageQuery (formatCode Depth24) depthUsage depthFeatures]

  describe "depth in passes" $ do
    it "begins a pass in a frame batch with the depth target's view cleared to 1.0 unless given another value, and a pass with no depth attachment with none" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      frame ← owned rig
      before ← commandCount rig
      (batch, ()) ← recordFrame (rigRecording rig) (ownedFrame frame) (clearsTwiceAndOnceWithout kit) >>= either (fail . show) pure
      commands ← drop before <$> commandsOf' rig
      beginnings commands (kitColorView kit)
        `shouldBe` [ Just (DepthClear (kitDepthView kit) 1)
                   , Just (DepthClear (kitDepthView kit) 0)
                   , Nothing
                   ]
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      clean rig

    it "begins the same pass in a frame-less batch" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Linear
      before ← commandCount rig
      _ ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (clearsTwiceAndOnceWithout kit) >>= either (fail . show) (pure . fst)
      commands ← drop before <$> commandsOf' rig
      beginnings commands (kitColorView kit)
        `shouldBe` [ Just (DepthClear (kitDepthView kit) 1)
                   , Just (DepthClear (kitDepthView kit) 0)
                   , Nothing
                   ]
      clean rig

    it "orders the depth target by #335's rules: an entry barrier out of undefined before the pass, and an exit barrier back into its resting use when the batch seals" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      _ ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder → do
          ok (beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (depthPass (kitDepth kit) ClearFromUndefined))
          ok (endRendering recorder)
      commands ← drop before <$> commandsOf' rig
      let rest = useScope (imageResourceKind DepthTarget) DepthAttachment
          layout = fromMaybe 0 (useLayout DepthAttachment)
          indexed = zip [0 ∷ Int ..] commands
          barriers = [(position, object, first, second) | (position, CommandResourceBarrier object first second) ← indexed, isDepth kit object]
          begun = [position | (position, CommandBeginRendering {}) ← indexed]
          ended = [position | (position, CommandEndRendering) ← indexed]
      map (\(_, object, first, second) → (object, first, second)) barriers
        `shouldBe` [ (BarrierImage (kitDepthHandle kit) depthAspect 1 0 layout, rest, rest)
                   , (BarrierImage (kitDepthHandle kit) depthAspect 1 layout layout, rest, rest)
                   ]
      case (barriers, begun, ended) of
        ([(entry, _, _, _), (exit, _, _, _)], [began], [finished]) → (entry < began, began < finished, finished < exit) `shouldBe` (True, True, True)
        _ → fail ("the commands were " <> show commands)

    it "refuses a depth target of another extent, a released one, another session's, one of the wrong kind or of more than one level, and a clear value outside zero to one, recording nothing and entering nothing" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      foreignRig ← newRig
      foreignKit ← newKit foreignRig Rgba8Srgb
      small ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 16 16 1) >>= either (fail . show) pure
      released ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 32 16 1) >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) released)
      mipmapped ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 32 16 2) >>= either (fail . show) pure
      texture ← createImage (rigRecording rig) (ImageDescription TextureImage Rgba8Srgb 32 16 1) >>= either (fail . show) pure
      frame ← owned rig
      before ← commandCount rig
      let begin depth recorder = beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue depth
      answer ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder →
        sequence $
          [begin (depthPass target ClearFromUndefined) recorder | target ← [small, released, kitDepth foreignKit, texture, kitColor kit, mipmapped]]
            <> [begin (DepthPass (kitDepth kit) ClearFromUndefined value) recorder | value ← [nan, infinity, 1.5, -0.25]]
            -- The color target was never entered by any of those: it still
            -- awaits initialization.
            <> [beginRenderingInto recorder (kitColor kit) ClearTarget clearBlue]
      fmap snd answer
        `shouldBe` Right
          ( [ Left (RefusedIncompatible "a depth target of extent 16x16 and a color target of extent 32x16")
            , Left (RefusedMisuse (WrongPhase ResourceIdentity))
            , Left (RefusedMisuse (ForeignIdentity ResourceIdentity))
            , Left RefusedWrongKind
            , Left RefusedWrongKind
            , Left (RefusedUnsupported "rendering with a depth target of more than one mip level")
            ]
              <> replicate 4 (Left (RefusedIllegal "a depth clear value that is not between zero and one"))
              <> [Left RefusedUninitialized]
          )
      after ← commandCount rig
      after `shouldBe` before

    it "refuses a pass that keeps an uninitialized depth target, entering neither target" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      answer ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder →
          sequence
            [ beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (depthPass (kitDepth kit) ClearTarget)
            , beginRenderingInto recorder (kitColor kit) ClearTarget clearBlue
            ]
      fmap snd answer `shouldBe` Right [Left RefusedUninitialized, Left RefusedUninitialized]

  describe "initialization" $ do
    it "initializes a new depth target by a pass that clears it from undefined, published to other batches only by that batch's submission" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      refusedBefore ← newIORef []
      withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → ok (clearingPass kit recorder) >> ok (endRendering recorder))
        -- Recorded, not submitted: another batch may not keep its contents.
        other ← recordFramelessIn scope (\recorder → beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (depthPass (kitDepth kit) ClearTarget))
        modifyIORef' refusedBefore (fmap snd other :)
      readIORef refusedBefore `shouldReturn` [Right (Left RefusedUninitialized)]
      -- Submitted when the action returned: now any batch may keep them.
      later ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → beginRenderingWithDepth recorder (kitColor kit) ClearTarget clearBlue (depthPass (kitDepth kit) ClearTarget) <* endRendering recorder)
      fmap snd later `shouldBe` Right (Right ())
      clean rig

    it "leaves a depth target awaiting initialization when the batch that cleared it is discarded" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      _ ← try @ErrorCall $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → ok (clearingPass kit recorder) >> ok (endRendering recorder))
        throwIO (ErrorCall "the action failed")
      later ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (depthPass (kitDepth kit) ClearTarget))
      fmap snd later `shouldBe` Right (Left RefusedUninitialized)

  describe "retention and disposal" $ do
    it "keeps a depth target released after its pass was recorded until that batch has completed, and destroys it then" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      _ ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → ok (clearingPass kit recorder) >> ok (endRendering recorder)) >>= either (fail . show) pure
      ok (releaseManaged (rigRecording rig) (kitDepth kit))
      ok (releaseManaged (rigRecording rig) (kitColor kit))
      standingOfManaged rig (kitDepth kit) `shouldReturn` [ManagedReleased]
      disposeResources (rigRecording rig) (at 1) `shouldReturn` []
      destroyedViews rig `shouldReturn` []
      completeAll (rigStandIn rig)
      _ ← progress rig
      destroyed ← disposeResources (rigRecording rig) (at 1)
      destroyed `shouldSatisfy` elem (managedResource (kitDepth kit))
      destroyed `shouldSatisfy` elem (managedResource (kitColor kit))
      destroyedViews rig >>= (`shouldSatisfy` elem (kitDepthView kit))
      clean rig

    it "destroys a released depth target at once when the batch that recorded it was discarded" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      _ ← try @ErrorCall $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → ok (clearingPass kit recorder) >> ok (endRendering recorder))
        throwIO (ErrorCall "the action failed")
      ok (releaseManaged (rigRecording rig) (kitDepth kit))
      destroyed ← disposeResources (rigRecording rig) (at 1)
      destroyed `shouldSatisfy` elem (managedResource (kitDepth kit))
      destroyedViews rig >>= (`shouldSatisfy` elem (kitDepthView kit))

    it "refuses a pass with a depth target once it is released, recording nothing" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      ok (releaseManaged (rigRecording rig) (kitDepth kit))
      before ← commandCount rig
      answer ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → clearingPass kit recorder)
      fmap snd answer `shouldBe` Right (Left (RefusedMisuse (WrongPhase ResourceIdentity)))
      commandCount rig `shouldReturn` before

  describe "a pipeline and the pass it is drawn in agree about depth" $ do
    it "refuses, with no native call, a pipeline for another depth format, one declaring no depth in a pass with one, and one declaring depth in a pass without, whichever order the commands came in" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      answers ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder → do
          ok (clearingPass kit recorder)
          wrongFormat ← bindPipeline recorder (kitOther kit)
          colourOnly ← bindPipeline recorder (kitPlain kit)
          ok (bindPipeline recorder (kitTested kit))
          dynamicState recorder
          ok (draw recorder 3 1)
          ok (endRendering recorder)
          -- The depth pipeline stays bound into a pass with no depth
          -- attachment, where it can neither be drawn nor bound again.
          ok (beginRenderingInto recorder (kitColor kit) ClearTarget clearBlue)
          retainedIntoNoDepth ← draw recorder 3 1
          boundInNoDepth ← bindPipeline recorder (kitTested kit)
          ok (bindPipeline recorder (kitPlain kit))
          dynamicState recorder
          ok (draw recorder 3 1)
          ok (endRendering recorder)
          -- And the colour-only pipeline stays bound into a pass with one.
          ok (beginRenderingWithDepth recorder (kitColor kit) ClearTarget clearBlue (depthPass (kitDepth kit) ClearTarget))
          retainedIntoDepth ← draw recorder 3 1
          ok (bindPipeline recorder (kitTested kit))
          ok (draw recorder 3 1)
          ok (endRendering recorder)
          pure [wrongFormat, colourOnly, retainedIntoNoDepth, boundInNoDepth, retainedIntoDepth]
      fmap snd answers
        `shouldBe` Right
          [ Left (RefusedIncompatible "a pipeline for depth format Depth16 and a pass with a depth attachment of format Depth32Float")
          , Left (RefusedIncompatible "a pipeline that declares no depth and a pass with a depth attachment of format Depth32Float")
          , Left (RefusedIncompatible "a pipeline for depth format Depth32Float and a pass with no depth attachment")
          , Left (RefusedIncompatible "a pipeline for depth format Depth32Float and a pass with no depth attachment")
          , Left (RefusedIncompatible "a pipeline that declares no depth and a pass with a depth attachment of format Depth32Float")
          ]
      commands ← commandsOf' rig
      -- Three draws reached the native layer, and three bindings: the depth
      -- pipeline, the colour-only one and the depth pipeline again.
      length [() | CommandDraw {} ← commands] `shouldBe` 3
      length [() | CommandBindPipeline {} ← commands] `shouldBe` 3
      clean rig

    it "checks a pipeline bound in a frame batch before any pass against the frame's image, which has no depth attachment" $ do
      rig ← newRig
      kit ← newKit rig Bgra8Srgb
      framedWithDepth ← createPipelineWithDepth (rigRecording rig) (kitLayout kit) shaders formatB8G8R8A8Srgb noVertexInput (depthTested Depth32Float) >>= either (fail . show) pure
      frame ← owned rig
      before ← commandCount rig
      answer ← recordFrame (rigRecording rig) (ownedFrame frame) $ \recorder → do
        -- A depth pipeline cannot be bound against the frame's image; a
        -- colour-only one for its format can, and stays bound into a pass
        -- with a depth attachment, where it cannot be drawn.
        refusedOutside ← bindPipeline recorder framedWithDepth
        ok (bindPipeline recorder (kitPlain kit))
        ok (beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (depthPass (kitDepth kit) ClearFromUndefined))
        dynamicState recorder
        refusedInside ← draw recorder 3 1
        ok (bindPipeline recorder framedWithDepth)
        ok (draw recorder 3 1)
        ok (endRendering recorder)
        -- The depth pipeline is still bound when the frame's own pass begins.
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        ok (beginRendering recorder clearBlue)
        ok (setViewport recorder (Viewport 0 0 640 480))
        ok (setScissor recorder (Rect 0 0 640 480))
        refusedFrame ← draw recorder 3 1
        ok (endRendering recorder)
        ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
        pure (refusedOutside, refusedInside, refusedFrame)
      let noDepth = "a pipeline for depth format Depth32Float and a pass with no depth attachment"
      fmap snd answer
        `shouldBe` Right
          ( Left (RefusedIncompatible noDepth)
          , Left (RefusedIncompatible "a pipeline that declares no depth and a pass with a depth attachment of format Depth32Float")
          , Left (RefusedIncompatible noDepth)
          )
      commands ← drop before <$> commandsOf' rig
      -- Only the colour-only pipeline's binding and the depth pipeline's own
      -- draw reached the native layer.
      length [() | CommandBindPipeline {} ← commands] `shouldBe` 2
      length [() | CommandDraw {} ← commands] `shouldBe` 1
      clean rig

  describe "colour-only passes and pipelines" $ do
    it "begin a pass with no depth attachment and declare no depth, as they did before depth existed" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      _ ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder → do
          ok (beginRenderingInto recorder (kitColor kit) ClearFromUndefined clearBlue)
          ok (bindPipeline recorder (kitPlain kit))
          dynamicState recorder
          ok (draw recorder 3 1)
          ok (endRendering recorder)
      commands ← drop before <$> commandsOf' rig
      beginnings commands (kitColorView kit) `shouldBe` [Nothing]
      -- The kit built the colour-only pipeline first, and then two that
      -- declare depth: only those two declared any.
      calls ← recordingCalls (rigRecordingStandIn rig)
      [handle | DeclaredDepth handle _ ← calls] `shouldBe` drop 1 [handle | CreatedPipeline handle _ _ ← calls]
      clean rig

-- | The depth target's usage and format features — a depth/stencil attachment
-- — and the aspect of its view.
depthUsage, depthFeatures, depthAspect ∷ Word32
depthUsage = 0x20
depthFeatures = 0x200
depthAspect = 2

-- | A color target of 32 by 16 in a format, a depth target of that extent in
-- 32-bit floating point, and over one pipeline layout a pipeline for the color
-- format declaring no depth, one declaring a tested and written depth of the
-- depth target's format, and one declaring 16-bit depth.
data Kit = Kit
  { kitColor ∷ !Image
  , kitColorView ∷ !Word64
  , kitDepth ∷ !Image
  , kitDepthHandle ∷ !Word64
  , kitDepthView ∷ !Word64
  , kitLayout ∷ !PipelineLayout
  , kitPlain ∷ !Pipeline
  , kitTested ∷ !Pipeline
  , kitOther ∷ !Pipeline
  }

newKit ∷ Rig → ImageFormat → IO Kit
newKit rig format = do
  colour ← createImage (rigRecording rig) (ImageDescription ColorTarget format 32 16 1) >>= either (fail . show) pure
  depth ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 32 16 1) >>= either (fail . show) pure
  layout ← createPipelineLayout (rigRecording rig) >>= either (fail . show) pure
  plain ← createPipeline (rigRecording rig) layout shaders (formatCode format) >>= either (fail . show) pure
  tested ← createPipelineWithDepth (rigRecording rig) layout shaders (formatCode format) noVertexInput (depthTested Depth32Float) >>= either (fail . show) pure
  other ← createPipelineWithDepth (rigRecording rig) layout shaders (formatCode format) noVertexInput (depthTested Depth16) >>= either (fail . show) pure
  views ← atomically (readManaged (rigRecording rig))
  let handlesOf image = case [handles | ManagedView resource _ _ handles ← views, resource == managedResource image] of
        [found] → pure found
        other' → fail ("the image's handles were " <> show other')
  colourHandles ← handlesOf colour
  depthHandles ← handlesOf depth
  case (colourHandles, depthHandles) of
    (_ : colourView : _, depthImage : depthView : _) → pure (Kit colour colourView depth depthImage depthView layout plain tested other)
    _ → fail "the targets' handles were not an image and a view"

clearBlue ∷ ClearColor
clearBlue = ClearColor 0 0 1 1

nan, infinity ∷ Float
nan = 0 / 0
infinity = 1 / 0

-- | The pass the examples share: both targets cleared from undefined.
clearingPass ∷ Kit → Rec → IO (Either Refusal ())
clearingPass kit recorder = beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (depthPass (kitDepth kit) ClearFromUndefined)

-- | A pass that clears both from undefined, one that keeps both and clears
-- the depth to 0, and one with no depth attachment.
clearsTwiceAndOnceWithout ∷ Kit → Rec → IO ()
clearsTwiceAndOnceWithout kit recorder = do
  ok (clearingPass kit recorder)
  ok (endRendering recorder)
  ok (beginRenderingWithDepth recorder (kitColor kit) ClearTarget clearBlue (DepthPass (kitDepth kit) ClearTarget 0))
  ok (endRendering recorder)
  ok (beginRenderingInto recorder (kitColor kit) ClearTarget clearBlue)
  ok (endRendering recorder)

-- | The viewport and scissor of the 32 by 16 targets.
dynamicState ∷ Rec → IO ()
dynamicState recorder = do
  ok (setViewport recorder (Viewport 0 0 32 16))
  ok (setScissor recorder (Rect 0 0 32 16))

-- | The depth attachment each pass over this color view began with, in order.
beginnings ∷ [NativeCommand] → Word64 → [Maybe DepthClear]
beginnings commands view = [depth | CommandBeginRendering target _ _ depth ← commands, target == view]

isDepth ∷ Kit → BarrierObject → Bool
isDepth kit = \case
  BarrierImage handle _ _ _ _ → handle == kitDepthHandle kit
  BarrierBuffer _ → False

standingOfManaged ∷ Managed handle ⇒ Rig → handle → IO [ManagedStanding]
standingOfManaged rig handle = do
  views ← atomically (readManaged (rigRecording rig))
  pure [viewManagedStanding view | view ← views, viewResource view == managedResource handle]

-- | The views the recording has destroyed, in order.
destroyedViews ∷ Rig → IO [Word64]
destroyedViews rig = (\calls → [handle | DestroyedView handle ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | Every question the recording has asked the device about an image.
queriesOf ∷ Rig → IO [ImageQuery]
queriesOf rig = (\calls → [query | QueriedSupport query ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

-- | The device supports every image's query but those of these formats.
rejecting ∷ [ImageFormat] → ImageQuery → Maybe ImageLimits
rejecting formats query
  | queryFormat query `elem` map formatCode formats = Nothing
  | otherwise = Just standInImageLimits

-- | What choosing a depth format answers when the device supports none of
-- these, and the formats it was asked about, in order.
chooseWithout ∷ [ImageFormat] → IO (Either Refusal ImageFormat, [Word32])
chooseWithout rejected = do
  rig ← newRig
  supportImages (rigRecordingStandIn rig) (rejecting rejected)
  answer ← selectDepthFormat (rigRecording rig)
  asked ← queriesOf rig
  pure (answer, map queryFormat asked)

shaders ∷ PipelineShaders
shaders = PipelineShaders (ByteString.pack [1, 2, 3, 4]) (ByteString.pack [5, 6, 7, 8])

-- | Every command the recording recorded, oldest first.
commandsOf' ∷ Rig → IO [NativeCommand]
commandsOf' rig = (\calls → [command | Recorded _ command ← calls]) <$> recordingCalls (rigRecordingStandIn rig)

commandCount ∷ Rig → IO Int
commandCount rig = length <$> commandsOf' rig
