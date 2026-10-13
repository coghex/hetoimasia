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
-- commands are ordered; and the clear of a rectangle of the open pass's depth
-- attachment (R2D-17) in both pass kinds and both batch kinds, its refusals,
-- its order among a pass's draws and its leaving the pass's barriers as they
-- are.
--
-- Nothing here creates a Vulkan object, and nothing waits on a clock.
module Test.GPU.Vulkan.Native.Depth (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (when)
import Control.Exception (ErrorCall (ErrorCall), SomeException, throwIO, try)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word32, Word64)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

import Hetoimasia.GPU.Model (SessionFailureCause (CleanupFailed))
import Hetoimasia.GPU.Model.Identity (IdentityKind (..), Misuse (..))
import Hetoimasia.GPU.Vulkan.Native.Frames
import Hetoimasia.GPU.Vulkan.Native.Presentation (formatB8G8R8A8Srgb)
import Hetoimasia.GPU.Vulkan.Native.Recording
import Hetoimasia.GPU.Vulkan.Native.Roots (failRootsSessionBecause)
import Test.GPU.Vulkan.Native.FramesRig
import Test.GPU.Vulkan.Native.FramesStandIn
import Test.GPU.Vulkan.Native.RecordingStandIn (RecordingCall (..), RecordingFailure, RecordingStep (AtRecord), failAt, recordingCalls, standInImageLimits, supportImages)

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

  describe "the format of an image" $ do
    it "is the one the backend made it with, whatever its kind, and a released or foreign handle has none" $ do
      rig ← newRig
      foreignRig ← newRig
      depth ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth24 32 16 1) >>= either (fail . show) pure
      colour ← createImage (rigRecording rig) (ImageDescription ColorTarget Rgba8Srgb 32 16 1) >>= either (fail . show) pure
      released ← createImage (rigRecording rig) (ImageDescription DepthTarget Depth32Float 32 16 1) >>= either (fail . show) pure
      foreignDepth ← createImage (rigRecording foreignRig) (ImageDescription DepthTarget Depth32Float 32 16 1) >>= either (fail . show) pure
      _ ← releaseManaged (rigRecording rig) released
      imageFormatOf (rigRecording rig) depth `shouldReturn` Right Depth24
      imageFormatOf (rigRecording rig) colour `shouldReturn` Right Rgba8Srgb
      answers ← traverse (imageFormatOf (rigRecording rig)) [released, foreignDepth]
      map (either (const True) (const False)) answers `shouldBe` [True, True]

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
          ok (beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (clearedDepth (kitDepth kit) ClearFromUndefined))
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
          [begin (clearedDepth target ClearFromUndefined) recorder | target ← [small, released, kitDepth foreignKit, texture, kitColor kit, mipmapped]]
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
            [ beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (clearedDepth (kitDepth kit) ClearTarget)
            , beginRenderingInto recorder (kitColor kit) ClearTarget clearBlue
            ]
      fmap snd answer `shouldBe` Right [Left RefusedUninitialized, Left RefusedUninitialized]

  describe "clearing depth within a rectangle (R2D-17)" $ do
    it "records the clear in a frame-less batch's pass, journalled with its rectangle and value, and leaves the pass's other commands as they were" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      answer ← framelessRun rig $ \recorder → do
        ok (clearingPass kit recorder)
        cleared ← clearDepthRect recorder (Rect 4 2 8 6) 0.25
        ok (endRendering recorder)
        pure cleared
      answer `shouldBe` Right ()
      commands ← drop before <$> commandsOf' rig
      clearsIn commands `shouldBe` [(Rect 4 2 8 6, 0.25)]
      clean rig

    it "records it in a frame batch's pass into a managed color target" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      frame ← owned rig
      before ← commandCount rig
      (batch, answer) ← recordFrame (rigRecording rig) (ownedFrame frame) (\recorder → do
        ok (clearingPass kit recorder)
        cleared ← clearDepthRect recorder (Rect 0 0 32 16) 1
        ok (endRendering recorder)
        pure cleared) >>= either (fail . show) pure
      answer `shouldBe` Right ()
      commands ← drop before <$> commandsOf' rig
      clearsIn commands `shouldBe` [(Rect 0 0 32 16, 1)]
      fmap viewBatchStanding <$> atomically (readBatch (rigRecording rig) batch) `shouldReturn` Just BatchSealed
      clean rig

    it "records it in a frame batch's pass into the frame's image with the generation's depth image" $ do
      rig ← newRigWindowDepth WindowedDepth
      generation ← activeGeneration rig
      Just depth ← atomically (windowDepthOf (rigRecording rig) generation)
      frame ← owned rig
      before ← commandCount rig
      (_, answers) ← recordFrame (rigRecording rig) (ownedFrame frame) (\recorder → do
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        ok (beginFrameRenderingWithDepth recorder clearBlue (clearedDepth depth ClearFromUndefined))
        inside ← clearDepthRect recorder (Rect 100 50 300 200) 0.5
        whole ← clearDepthRect recorder (Rect 0 0 640 480) 0
        beyond ← clearDepthRect recorder (Rect 1 0 640 480) 0
        ok (endRendering recorder)
        ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
        pure [inside, whole, beyond]) >>= either (fail . show) pure
      answers
        `shouldBe` [ Right ()
                   , Right ()
                   , Left (RefusedIllegal "a depth clear rectangle outside the render area")
                   ]
      commands ← drop before <$> commandsOf' rig
      clearsIn commands `shouldBe` [(Rect 100 50 300 200, 0.5), (Rect 0 0 640 480, 0)]
      clean rig

    it "accepts every rectangle within the render area, touching its edges or covering all of it" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      answers ← framelessRun rig $ \recorder → do
        ok (clearingPass kit recorder)
        cleared ← mapM (\rect → clearDepthRect recorder rect 0.75) fits
        ok (endRendering recorder)
        pure cleared
      answers `shouldBe` map (const (Right ())) fits
      commands ← drop before <$> commandsOf' rig
      map fst (clearsIn commands) `shouldBe` fits
      clean rig

    it "refuses, recording nothing, a rectangle with no area, a negative offset or an extent beyond the render area, however large" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      answers ← framelessRun rig $ \recorder → do
        ok (clearingPass kit recorder)
        refused ← mapM (\rect → clearDepthRect recorder rect 0.5) (map fst misfits)
        ok (endRendering recorder)
        pure refused
      answers `shouldBe` [Left (RefusedIllegal reason) | (_, reason) ← misfits]
      commands ← drop before <$> commandsOf' rig
      clearsIn commands `shouldBe` []
      clean rig

    it "refuses, recording nothing, a value that is not finite or lies outside zero to one, and accepts zero and one" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      answers ← framelessRun rig $ \recorder → do
        ok (clearingPass kit recorder)
        refused ← mapM (clearDepthRect recorder (Rect 0 0 8 8)) [nan, infinity, -infinity, 1.5, -0.25]
        accepted ← mapM (clearDepthRect recorder (Rect 0 0 8 8)) [0, 1]
        ok (endRendering recorder)
        pure (refused, accepted)
      answers
        `shouldBe` ( replicate 5 (Left (RefusedIllegal "a depth clear value that is not between zero and one"))
                   , [Right (), Right ()]
                   )
      commands ← drop before <$> commandsOf' rig
      map snd (clearsIn commands) `shouldBe` [0, 1]

    it "refuses, recording nothing, outside a pass and in a pass with no depth attachment" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      answers ← framelessRun rig $ \recorder → do
        unopened ← clearDepthRect recorder (Rect 0 0 8 8) 0.5
        ok (beginRenderingInto recorder (kitColor kit) ClearFromUndefined clearBlue)
        colourOnly ← clearDepthRect recorder (Rect 0 0 8 8) 0.5
        ok (endRendering recorder)
        ended ← clearDepthRect recorder (Rect 0 0 8 8) 0.5
        pure [unopened, colourOnly, ended]
      answers
        `shouldBe` [ Left (RefusedIllegal "clearing depth with no pass open")
                   , Left (RefusedIllegal "clearing depth in a pass with no depth attachment")
                   , Left (RefusedIllegal "clearing depth with no pass open")
                   ]
      commands ← drop before <$> commandsOf' rig
      clearsIn commands `shouldBe` []

    it "refuses in a frame batch outside a pass, and in the frame's own pass, which has no depth attachment" $ do
      rig ← newRig
      frame ← owned rig
      (_, answers) ← recordFrame (rigRecording rig) (ownedFrame frame) (\recorder → do
        unopened ← clearDepthRect recorder (Rect 0 0 8 8) 0.5
        ok (transitionImage recorder LayoutUndefined LayoutColorAttachment)
        ok (beginRendering recorder clearBlue)
        colourOnly ← clearDepthRect recorder (Rect 0 0 8 8) 0.5
        ok (endRendering recorder)
        ok (transitionImage recorder LayoutColorAttachment LayoutPresentSource)
        pure [unopened, colourOnly]) >>= either (fail . show) pure
      answers
        `shouldBe` [ Left (RefusedIllegal "clearing depth with no pass open")
                   , Left (RefusedIllegal "clearing depth in a pass with no depth attachment")
                   ]
      commands ← commandsOf' rig
      clearsIn commands `shouldBe` []

    it "refuses once the session has failed, with the pass still open, recording no clear" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      outcome ← newIORef Nothing
      _ ← try @SomeException $ withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder → do
          ok (clearingPass kit recorder)
          ok (clearDepthRect recorder (Rect 0 0 8 8) 0.5)
          atomically (failRootsSessionBecause (rigRoots rig) CleanupFailed "a later cleanup failed")
          before ← commandCount rig
          answer ← clearDepthRect recorder (Rect 0 0 8 8) 0.25
          after ← commandCount rig
          writeIORef outcome (Just (answer, after - before))
      Just (answer, recorded) ← readIORef outcome
      answer `shouldSatisfy` \case
        Left (RefusedSessionFailed _) → True
        _ → False
      recorded `shouldBe` 0
      commands ← commandsOf' rig
      clearsIn commands `shouldBe` [(Rect 0 0 8 8, 0.5)]

    it "refuses off the owner's thread and from a recorder kept past its consumer, recording nothing" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      kept ← newIORef Nothing
      offThread ← newEmptyMVar
      before ← commandCount rig
      framelessRun rig $ \recorder → do
        ok (clearingPass kit recorder)
        writeIORef kept (Just recorder)
        _ ← forkIO (clearDepthRect recorder (Rect 0 0 8 8) 0.5 >>= putMVar offThread)
        takeMVar offThread `shouldReturn` Left RefusedNotOwner
        ok (endRendering recorder)
      stale ← readIORef kept >>= maybe (fail "no recorder") pure
      clearDepthRect stale (Rect 0 0 8 8) 0.5 `shouldReturn` Left RefusedRecorderClosed
      commands ← drop before <$> commandsOf' rig
      clearsIn commands `shouldBe` []

    it "names vkCmdClearAttachments when the native layer raises recording it, leaving the batch partial as any command's failure does" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      standing ← newIORef Nothing
      _ ← try @SomeException $ withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope $ \recorder → do
          ok (clearingPass kit recorder)
          failAt (rigRecordingStandIn rig) AtRecord
          raised ← try @RecordingFailure (clearDepthRect recorder (Rect 0 0 8 8) 0.5)
          batches ← atomically (readBatches (rigRecording rig))
          writeIORef standing (Just (either (const True) (const False) raised, map viewBatchStanding batches))
      readIORef standing
        `shouldReturn` Just (True, [BatchPartial "vkCmdClearAttachments raised: RecordingFailure AtRecord"])

    it "orders the clear among the pass's draws as a draw is ordered: draws before it see the old depth, draws after it the cleared depth" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      framelessRun rig $ \recorder → do
        ok (clearingPass kit recorder)
        ok (bindPipeline recorder (kitTested kit))
        dynamicState recorder
        ok (draw recorder 3 1)
        ok (clearDepthRect recorder (Rect 8 4 16 8) 1)
        ok (draw recorder 6 1)
        ok (clearDepthRect recorder (Rect 0 0 32 16) 0)
        ok (endRendering recorder)
      commands ← drop before <$> commandsOf' rig
      [ordering | ordering ← map sequenced commands, ordering /= Other]
        `shouldBe` [Drew 3, Cleared (Rect 8 4 16 8) 1, Drew 6, Cleared (Rect 0 0 32 16) 0]
      clean rig

    it "needs no pipeline, viewport or scissor, clears the requested rectangle whatever scissor is set, and leaves every draw binding as it was" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      before ← commandCount rig
      answers ← framelessRun rig $ \recorder → do
        ok (clearingPass kit recorder)
        -- Before anything a draw needs is bound.
        early ← clearDepthRect recorder (Rect 0 0 32 16) 0.5
        ok (bindPipeline recorder (kitTested kit))
        dynamicState recorder
        -- Under a scissor much smaller than the rectangle.
        ok (setScissor recorder (Rect 0 0 4 4))
        narrowed ← clearDepthRect recorder (Rect 8 8 24 8) 0.5
        -- The pipeline, viewport and scissor stand: a draw needs no rebinding.
        drawn ← draw recorder 3 1
        ok (endRendering recorder)
        pure (early, narrowed, drawn)
      answers `shouldBe` (Right (), Right (), Right ())
      commands ← drop before <$> commandsOf' rig
      clearsIn commands `shouldBe` [(Rect 0 0 32 16, 0.5), (Rect 8 8 24 8, 0.5)]
      -- Only the pass's own bindings and its one draw: the clear added none.
      length [() | CommandBindPipeline {} ← commands] `shouldBe` 1
      length [() | CommandSetScissor {} ← commands] `shouldBe` 2
      length [() | CommandDraw {} ← commands] `shouldBe` 1
      clean rig

    it "leaves the depth target's barriers, use and retention those of the pass: the same commands as the pass without the clear, bar the clear" $ do
      cleared ← barriersAround True
      plain ← barriersAround False
      cleared `shouldBe` plain
      cleared `shouldSatisfy` (not . null)

  describe "initialization" $ do
    it "initializes a new depth target by a pass that clears it from undefined, published to other batches only by that batch's submission" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      refusedBefore ← newIORef []
      withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → ok (clearingPass kit recorder) >> ok (endRendering recorder))
        -- Recorded, not submitted: another batch may not keep its contents.
        other ← recordFramelessIn scope (\recorder → beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (clearedDepth (kitDepth kit) ClearTarget))
        modifyIORef' refusedBefore (fmap snd other :)
      readIORef refusedBefore `shouldReturn` [Right (Left RefusedUninitialized)]
      -- Submitted when the action returned: now any batch may keep them.
      later ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → beginRenderingWithDepth recorder (kitColor kit) ClearTarget clearBlue (clearedDepth (kitDepth kit) ClearTarget) <* endRendering recorder)
      fmap snd later `shouldBe` Right (Right ())
      clean rig

    it "leaves a depth target awaiting initialization when the batch that cleared it is discarded" $ do
      rig ← newRig
      kit ← newKit rig Rgba8Srgb
      _ ← try @ErrorCall $ withFramelessScope (rigFrames rig) $ \scope → do
        _ ← recordFramelessIn scope (\recorder → ok (clearingPass kit recorder) >> ok (endRendering recorder))
        throwIO (ErrorCall "the action failed")
      later ← withFramelessScope (rigFrames rig) $ \scope →
        recordFramelessIn scope (\recorder → beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (clearedDepth (kitDepth kit) ClearTarget))
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
          ok (beginRenderingWithDepth recorder (kitColor kit) ClearTarget clearBlue (clearedDepth (kitDepth kit) ClearTarget))
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
        ok (beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (clearedDepth (kitDepth kit) ClearFromUndefined))
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
clearingPass kit recorder = beginRenderingWithDepth recorder (kitColor kit) ClearFromUndefined clearBlue (clearedDepth (kitDepth kit) ClearFromUndefined)

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

-- | The commands a frame-less pass into the kit's targets records, with the
-- depth clear in it or without, bar the clear itself.
barriersAround ∷ Bool → IO [NativeCommand]
barriersAround clears = do
  rig ← newRig
  kit ← newKit rig Rgba8Srgb
  before ← commandCount rig
  _ ← framelessRun rig $ \recorder → do
    ok (clearingPass kit recorder)
    when clears (ok (clearDepthRect recorder (Rect 2 2 4 4) 0.5))
    ok (endRendering recorder)
  commands ← drop before <$> commandsOf' rig
  clean rig
  pure [command | command ← commands, not (isClear command)]
  where
    isClear = \case
      CommandClearDepthRect {} → True
      _ → False

-- | Run an action against a recorder of a frame-less batch, and answer what it
-- answered.
framelessRun ∷ Rig → (Rec → IO a) → IO a
framelessRun rig action =
  withFramelessScope (rigFrames rig) $ \scope →
    recordFramelessIn scope action >>= either (fail . show) (pure . snd)

-- | The depth clears among these commands, in order.
clearsIn ∷ [NativeCommand] → [(Rect, Float)]
clearsIn commands = [(rect, value) | CommandClearDepthRect rect value ← commands]

-- | What a command is to the order of a pass's draws and clears.
data Sequenced = Drew Word32 | Cleared Rect Float | Other
  deriving (Eq, Show)

sequenced ∷ NativeCommand → Sequenced
sequenced = \case
  CommandDraw vertices _ _ _ → Drew vertices
  CommandClearDepthRect rect value → Cleared rect value
  _ → Other

-- | Rectangles within the 32 by 16 targets: the whole render area, each edge
-- touched, one pixel in a corner and one in the middle.
fits ∷ [Rect]
fits = [Rect 0 0 32 16, Rect 0 0 1 1, Rect 31 15 1 1, Rect 31 0 1 16, Rect 0 15 32 1, Rect 15 7 2 2]

-- | Rectangles that are not within them, and why each is refused.
misfits ∷ [(Rect, Text)]
misfits =
  [ (Rect 0 0 0 4, noArea)
  , (Rect 0 0 4 0, noArea)
  , (Rect 0 0 0 0, noArea)
  , (Rect (-1) 0 4 4, negative)
  , (Rect 0 (-1) 4 4, negative)
  , (Rect minBound minBound 4 4, negative)
  , (Rect 0 0 33 16, outside)
  , (Rect 0 0 32 17, outside)
  , (Rect 1 0 32 16, outside)
  , (Rect 0 1 32 16, outside)
  , (Rect 32 0 1 1, outside)
  , (Rect 0 16 1 1, outside)
  , (Rect maxBound 0 maxBound 1, outside)
  , (Rect 0 maxBound 1 maxBound, outside)
  , (Rect 0 0 maxBound maxBound, outside)
  ]
  where
    noArea = "a depth clear rectangle with no area"
    negative = "a depth clear rectangle with a negative offset"
    outside = "a depth clear rectangle outside the render area"

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
