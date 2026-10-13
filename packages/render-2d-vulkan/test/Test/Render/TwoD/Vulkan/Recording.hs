-- | The recorder's work and its recording: what a snapshot comes to before
-- anything is recorded, and what the backend's recorder is then asked to do,
-- over a headless native layer ("Test.Render.TwoD.Vulkan.StandIn").
--
-- __Where the expected values come from.__ Never from the code under test. The
-- scissors, transforms and orders are worked out by hand in the comments of
-- each fixture; the instance bytes are the chunks render-2d's own encoder
-- wrote for the layer, taken in the order worked out by hand; and the commands
-- are the ones the native layer was asked to record, read back from its
-- journal.
module Test.Render.TwoD.Vulkan.Recording (spec) where

import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.ByteString.Builder (floatLE, toLazyByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.List (nub)
import Data.Maybe (mapMaybe)
import Data.Word (Word16, Word32, Word64)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor (..)
  , CompareOp (..)
  , DepthClear (..)
  , Image
  , ImageFormat (..)
  , NativeCommand (..)
  , PipelineBlend (..)
  , PipelineDepth (..)
  , PipelineRequest (..)
  , PushConstantRange (..)
  , PushStage (..)
  , Rect (..)
  , formatCode
  , selectDepthFormat
  , validateRingSize
  , validateStorageWindow
  )
import qualified Hetoimasia.GPU.Vulkan.Native.Recording as Native
import Hetoimasia.GPU.Vulkan.Native.TextureTable (validateTableConfig)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Clip (ClipEntry (..), ClipRect (..))
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, DrawPath (..), cutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (Location (..), ValidSnapshot, validLayers, validateSnapshot)
import Hetoimasia.Render.TwoD.Encoding (encodeLayer)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Layout (ViewPush (..), packViewPush)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldReturn)
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "Recording" $ do
  workSpec
  refusalSpec
  recordingSpec
  clipSpec
  depthSpec
  depthRefusalSpec
  emptySpec

-- ---------------------------------------------------------------------------
-- Fixtures

refA, refB ∷ TargetRef
refA = targetRef 1 1
refB = targetRef 2 1

-- | A unit sprite at this x, with this depth key and sampler choice.
sprite ∷ Float → Word32 → Sampler → Instance
sprite x key sampler =
  Instance
    { instanceTransform = fromColumns (V2 1 0) (V2 0 1) (V2 x 0)
    , instanceUv = UvRect 0 0 1 1
    , instanceTexture = textureHandle 1 1
    , instanceDepthKey = key
    , instanceTint = Tint 255 255 255 255
    , instanceSampler = sampler
    , instanceTranslucent = False
    , instanceAdditive = False
    , instanceClip = 0
    , instanceMaterial = 0
    }

-- | The first frame: two passes.
--
-- Pass 0 renders into a 32 × 32 sRGB target, cleared (0.25, 0.5, 0.75, 1):
--
-- * view 0, viewport (0, 0) 16 × 32, camera at the origin at zoom 1, so the
--   world transform is (1, 0, 0, 1, 8, 16); its world layer holds three
--   sprites of depth keys 5, 1, 5 with the sampler choices default, nearest
--   and linear, drawn in the order 1, 0, 2 (ascending key, then submission);
--   its UI layer holds two sprites at key 0, drawn 0, 1;
-- * view 1, viewport (16.5, 0) 15 × 32, brightness 2, linear, snap on; its UI
--   layer holds one sprite; the viewport's centres 16.5 to 30.5 are inside,
--   so its scissor is (16, 0) 15 × 32;
-- * view 2, viewport (100, 100) 10 × 10: wholly outside the target, so its
--   scissor is empty and it draws nothing.
--
-- Pass 1 renders into a 16 × 16 linear target, cleared (1, 0, 0, 0.5): one view
-- over the whole target, camera (4, 4) at zoom 2 so the transform is
-- (2, 0, 0, 2, 0, 0), and a depth-enabled world layer of one sprite.
firstFrame ∷ ValidSnapshot
firstFrame =
  valid
    [ Pass
        (OffscreenTarget refA)
        (ClearColour 0.25 0.5 0.75 1)
        [ View
            (Camera (V2 0 0) 1 Nothing)
            (Viewport (V2 0 0) (V2 16 32))
            defaultViewSettings
            []
            [ WorldLayer DepthDisabled [sprite 1 5 SamplerDefault, sprite 2 1 SamplerNearest, sprite 3 5 SamplerLinear]
            , UiLayer [sprite 0 0 SamplerDefault, sprite 4 0 SamplerDefault]
            ]
        , View
            (Camera (V2 0 0) 1 Nothing)
            (Viewport (V2 16.5 0) (V2 15 32))
            defaultViewSettings {settingBrightness = 2, settingFilter = FilterLinear, settingPixelSnap = True}
            []
            [UiLayer [sprite 9 0 SamplerDefault]]
        , View
            (Camera (V2 0 0) 1 Nothing)
            (Viewport (V2 100 100) (V2 10 10))
            defaultViewSettings
            []
            [UiLayer [sprite 0 0 SamplerDefault]]
        ]
    , Pass
        (OffscreenTarget refB)
        (ClearColour 1 0 0 0.5)
        [ View
            (Camera (V2 4 4) 2 Nothing)
            (Viewport (V2 0 0) (V2 16 16))
            defaultViewSettings
            []
            [WorldLayer DepthEnabled [sprite 0 0 SamplerDefault]]
        ]
    ]

valid ∷ [Pass] → ValidSnapshot
valid passes = case validateSnapshot (Snapshot passes) of
  Right held → held
  Left refused → error ("the fixture was refused: " <> show refused)

-- | The snapshot's layers' own encodings, in snapshot order.
encodings ∷ ValidSnapshot → [ByteString]
encodings = map encodeLayer . validLayers

-- | The first frame's drawn layers' own encodings: the world layer, the UI
-- layer, view 1's UI layer and pass 1's world layer.
firstFrameLayers ∷ (ByteString, ByteString, ByteString, ByteString)
firstFrameLayers = case encodings firstFrame of
  -- The fifth layer is view 2's, wholly outside the target: it is never drawn.
  [world, ui, second, _, deep] → (world, ui, second, deep)
  other → error ("the first frame has five layers, not " <> show (length other))

-- | The 64-byte chunk at this submission index of a buffer.
chunk ∷ Int → ByteString → ByteString
chunk index = ByteString.take 64 . ByteString.drop (64 * index)

-- | A push block, built by hand, for a view whose clip table starts at entry 0.
push ∷ [Float] → (Word32, Word32) → Float → TextureFilter → Bool → ByteString
push = pushBased 0

-- | A push block, built by hand, whose clip base is this entry. The transforms
-- these examples use are a uniform scale and a translation, whose inverse is
-- written out: scale 1 over s with the off-diagonal terms minus zero, as the
-- inverse of a transform with none gives them, and translation minus the
-- translation over s.
pushBased ∷ Word32 → [Float] → (Word32, Word32) → Float → TextureFilter → Bool → ByteString
pushBased base [a, b, c, d, tx, ty] extent brightness filtering snap
  | b == 0 && c == 0 && a == d =
      packViewPush (ViewPush (fromColumns (V2 a b) (V2 c d) (V2 tx ty)) (fromColumns (V2 (1 / a) (-0.0)) (V2 (-0.0) (1 / a)) (V2 (negate tx / a) (negate ty / a))) base extent brightness filtering snap)
pushBased _ other _ _ _ _ = error ("a hand-built push block needs a uniform scale and six coefficients, not " <> show other)

-- ---------------------------------------------------------------------------
-- The work

-- | A target binding with no depth image.
plainBinding ∷ Image → Attachment → TargetBinding
plainBinding image attachment = TargetBinding image attachment Nothing

-- | A frame with nothing marked cutout, no depth image for the window.
frameOf ∷ ValidSnapshot → (TargetRef → Maybe TargetBinding) → Maybe Attachment → FrameInput
frameOf snapshot lookup' window = FrameInput snapshot noCutoutMarks lookup' window Nothing

-- | The input over the two offscreen targets, with images the rig made: the
-- second, which the first frame's depth-enabled world layer draws to, has a
-- @D32_SFLOAT@ depth target of its extent.
inputOver ∷ Rig → ValidSnapshot → IO FrameInput
inputOver rig snapshot = do
  imageA ← target rig Rgba8Srgb 32 32
  imageB ← target rig Rgba8Linear 16 16
  depthB ← depthTarget rig Depth32Float 16 16
  pure
    FrameInput
      { frameSnapshot = snapshot
      , frameMarks = noCutoutMarks
      , frameTarget = \reference →
          lookup
            reference
            [ (refA, plainBinding imageA (offscreenAttachment Rgba8Srgb 32 32))
            , (refB, TargetBinding imageB (offscreenAttachment Rgba8Linear 16 16) (Just (DepthBinding depthB Depth32Float)))
            ]
      , frameWindow = Nothing
      , frameWindowDepth = Nothing
      }

withRig ∷ (Rig → IO a) → IO a
withRig action = newRig >>= action

workSpec ∷ Spec
workSpec = describe "the work a snapshot comes to" $ do
  it "keeps the passes in list order, each with its target's format, extent and clear" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      case frameWork input of
        Left refused → expectationFailure (show refused)
        Right passes → do
          map (attachmentFormat . workAttachment) passes `shouldBe` [formatCode Rgba8Srgb, formatCode Rgba8Linear]
          map (\p → (attachmentWidth (workAttachment p), attachmentHeight (workAttachment p))) passes `shouldBe` [(32, 32), (16, 16)]
          map workClear passes `shouldBe` [ClearColor 0.25 0.5 0.75 1, ClearColor 1 0 0 0.5]
          map workIndex passes `shouldBe` [0, 1]
          map (any (const True) . workImage) passes `shouldBe` [True, True]

  it "keeps the views in order and gives each its scissor, empty for a viewport outside the target" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      case frameWork input of
        Right [first, second] → do
          map workRect (workViews first) `shouldBe` [Just (Rect 0 0 16 32), Just (Rect 16 0 15 32), Nothing]
          map workRect (workViews second) `shouldBe` [Just (Rect 0 0 16 16)]
        other → expectationFailure ("expected two passes, found " <> either show (show . length) other)

  it "gives a view with an empty scissor no layer, and every other view its layers in order" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      case frameWork input of
        Right [first, _] → map (length . workLayers) (workViews first) `shouldBe` [2, 1, 0]
        other → expectationFailure ("expected two passes, found " <> either show (show . length) other)

  it "encodes each layer's instances in drawing order and draws them as one run" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      let (world, ui, second, deep) = firstFrameLayers
      case frameWork input of
        Right [first, last'] → do
          let layers = concatMap workLayers (workViews first <> workViews last')
          -- The world layer's sprites have keys 5, 1, 5: the drawing order is 1, 0, 2.
          map layerBytes layers `shouldBe` [chunk 1 world <> chunk 0 world <> chunk 2 world, ui, second, deep]
          map layerRunList layers `shouldBe` [[RunWork 0 3 Ordered], [RunWork 0 2 Ordered], [RunWork 0 1 Ordered], [RunWork 0 1 Ordered]]
        other → expectationFailure ("expected two passes, found " <> either show (show . length) other)

  it "pushes each layer the transform of its own space, the view's settings and the attachment's extent" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      case frameWork input of
        Right [first, last'] →
          map layerPushBytes (concatMap workLayers (workViews first <> workViews last'))
            `shouldBe` [ -- view 0's world layer: the camera at the viewport's centre (8, 16).
                         push [1, 0, 0, 1, 8, 16] (32, 32) 1 FilterNearest False
                       , -- view 0's UI layer: the viewport's origin, at UI scale 1.
                         push [1, 0, 0, 1, 0, 0] (32, 32) 1 FilterNearest False
                       , -- view 1's UI layer: its viewport's origin (16.5, 0), brightness 2, linear, snap on.
                         push [1, 0, 0, 1, 16.5, 0] (32, 32) 2 FilterLinear True
                       , -- pass 1's world layer: zoom 2 about the centre (8, 8) with the camera at (4, 4).
                         push [2, 0, 0, 2, 0, 0] (16, 16) 1 FilterNearest False
                       ]
        other → expectationFailure ("expected two passes, found " <> either show (show . length) other)

  it "scales a UI layer by the content scale of the target's metrics" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let metrics = TargetMetrics (PixelExtent 16 16) (PixelExtent 32 32) 2 2
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 4 6) (V2 20 20)) defaultViewSettings [] [UiLayer [sprite 0 0 SamplerDefault]]]]
          input = frameOf snapshot (\_ → Just (plainBinding image (Attachment (formatCode Rgba8Srgb) 32 32 metrics))) Nothing
      case frameWork input of
        Right [only] → map layerPushBytes (concatMap workLayers (workViews only)) `shouldBe` [push [2, 0, 0, 2, 4, 6] (32, 32) 1 FilterNearest False]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)

  it "plans a depth-enabled world layer with nothing marked as one ordered run, with a depth attachment and a clear" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      case frameWork input of
        Right [first, last'] → do
          map (map layerRunList . workLayers) (workViews last') `shouldBe` [[[RunWork 0 1 Ordered]]]
          map layerClearsDepth (concatMap workLayers (workViews last')) `shouldBe` [True]
          fmap depthFormat (workDepth last') `shouldBe` Just Depth32Float
          -- The first pass holds no depth-enabled world layer, so it has none.
          fmap depthFormat (workDepth first) `shouldBe` Nothing
          map layerClearsDepth (concatMap workLayers (workViews first)) `shouldBe` [False, False, False]
        other → expectationFailure ("expected two passes, found " <> either show (show . length) other)

-- ---------------------------------------------------------------------------
-- Refusals

refusalSpec ∷ Spec
refusalSpec = describe "refusals, before anything is recorded" $ do
  it "names an unknown offscreen reference and the pass that names it, even in a later pass" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let input = (inputWith image) {frameTarget = \reference → if reference == refA then Just (plainBinding image (offscreenAttachment Rgba8Srgb 32 32)) else Nothing}
      fmap (const ()) (frameWork input) `shouldBe` Left (UnknownTarget 1 refB)

  it "refuses a window pass with no frame context, naming the pass" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [], Pass WindowTarget (ClearColour 0 0 0 1) []]
          input = frameOf snapshot (\_ → Just (plainBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      fmap (const ()) (frameWork input) `shouldBe` Left (NoWindowAttachment 1)

  it "takes a window pass's attachment from the frame context, with no image of its own" $
    withRig $ \_ → do
      let snapshot = valid [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [] [UiLayer [sprite 0 0 SamplerDefault]]]]
          input = frameOf snapshot (const Nothing) (Just (Attachment (formatCode Bgra8Srgb) 8 8 (TargetMetrics (PixelExtent 4 4) (PixelExtent 8 8) 2 2)))
      case frameWork input of
        Right [only] → do
          any (const True) (workImage only) `shouldBe` False
          attachmentFormat (workAttachment only) `shouldBe` formatCode Bgra8Srgb
          map layerPushBytes (concatMap workLayers (workViews only)) `shouldBe` [push [2, 0, 0, 2, 0, 0] (8, 8) 1 FilterNearest False]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)

  it "refuses metrics with a negative extent or a content scale that is not finite and positive" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let refusedWith metrics =
            fmap (const ()) . frameWork $
              frameOf firstPassOnly (\_ → Just (plainBinding image (Attachment (formatCode Rgba8Srgb) 32 32 metrics))) Nothing
          extent = PixelExtent 32 32
      refusedWith (TargetMetrics extent extent 0 1) `shouldBe` Left (InvalidMetrics 0)
      refusedWith (TargetMetrics extent extent 1 (1 / 0)) `shouldBe` Left (InvalidMetrics 0)
      refusedWith (TargetMetrics extent extent (0 / 0) 1) `shouldBe` Left (InvalidMetrics 0)
      refusedWith (TargetMetrics (PixelExtent (-1) 32) extent 1 1) `shouldBe` Left (InvalidMetrics 0)
      refusedWith (TargetMetrics extent (PixelExtent 32 (-1)) 1 1) `shouldBe` Left (InvalidMetrics 0)

  it "refuses metrics whose framebuffer extent is not the attachment's actual extent" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let refusedWith metrics =
            fmap (const ()) . frameWork $
              frameOf firstPassOnly (\_ → Just (plainBinding image (Attachment (formatCode Rgba8Srgb) 32 32 metrics))) Nothing
      refusedWith (TargetMetrics (PixelExtent 31 32) (PixelExtent 31 32) 1 1) `shouldBe` Left (MetricsDisagree 0 (PixelExtent 31 32) (32, 32))
      refusedWith (TargetMetrics (PixelExtent 32 32) (PixelExtent 32 33) 1 1) `shouldBe` Left (MetricsDisagree 0 (PixelExtent 32 33) (32, 32))

  it "refuses a view the mapping refuses, naming the pass and the view" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      -- A camera position of 2e38 at zoom 2 is finite, so it validates, but its
      -- translation overflows a 32-bit coefficient.
      let overflow = View (Camera (V2 2e38 0) 2 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [] [UiLayer [sprite 0 0 SamplerDefault]]
          fine = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [] []
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [fine, overflow]]
          input = frameOf snapshot (\_ → Just (plainBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      fmap (const ()) (frameWork input) `shouldBe` Left (ViewNotMappable 0 1)

  it "reports the first refusal in snapshot order" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let bad = Attachment (formatCode Rgba8Srgb) 32 32 (TargetMetrics (PixelExtent 1 1) (PixelExtent 1 1) 1 1)
          input = (inputWith image) {frameTarget = \reference → if reference == refA then Nothing else Just (plainBinding image bad)}
      fmap (const ()) (frameWork input) `shouldBe` Left (UnknownTarget 0 refA)
  where
    firstPassOnly = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) []]
    inputWith image =
      FrameInput
        { frameSnapshot = firstFrame
        , frameMarks = noCutoutMarks
        , frameTarget = \_ → Just (plainBinding image (offscreenAttachment Rgba8Srgb 32 32))
        , frameWindow = Nothing
        , frameWindowDepth = Nothing
        }

-- ---------------------------------------------------------------------------
-- Recording

-- | The commands a recording is made of, as they matter to the frame.
data Seen
  = SeenBegin !ClearColor !(Maybe Float)
    -- ^ The pass's colour clear, and its depth clear value if it has a depth attachment.
  | SeenClearDepth !Rect !Float
  | SeenEnd
  | SeenPipeline
  | SeenViewport !Native.Viewport
  | SeenTable
  | SeenStorage !Word32
    -- ^ The storage table (set 2) bound at this dynamic offset into the ring.
  | SeenScissor !Rect
  | SeenPush ![PushStage] !Word32 !ByteString
  | SeenBind !Word32 !Word64
    -- ^ The binding and the offset into the ring's buffer.
  | SeenDraw !Word32 !Word32
  deriving (Eq, Show)

seen ∷ [NativeCommand] → [Seen]
seen = mapMaybe $ \case
  CommandBeginRendering _ _ clear depth → Just (SeenBegin clear (fmap (\(DepthClear _ value) → value) depth))
  CommandClearDepthRect rect value → Just (SeenClearDepth rect value)
  CommandEndRendering → Just SeenEnd
  CommandBindPipeline _ → Just SeenPipeline
  CommandSetViewport viewport → Just (SeenViewport viewport)
  CommandBindDescriptorSets {} → Just SeenTable
  CommandBindStorageSet _ _ offset → Just (SeenStorage offset)
  CommandSetScissor rect → Just (SeenScissor rect)
  CommandPushConstants _ stages offset bytes → Just (SeenPush stages offset bytes)
  CommandBindVertexBuffer binding _ offset → Just (SeenBind binding offset)
  CommandDraw vertices instances _ _ → Just (SeenDraw vertices instances)
  _ → Nothing

-- | A renderer over a ring of this many bytes and a table of 16 slots.
rendererOver ∷ Rig → Integer → IO Render.Renderer
rendererOver rig ringBytes = do
  renderer ←
    newRenderer
      rig
      Render.Configuration
        { Render.configurationRing = either (error . show) id (validateRingSize ringBytes)
        , Render.configurationClipWindow = either (error . show) id (validateStorageWindow (min 4096 ringBytes))
        , Render.configurationTable = either (error . show) id (validateTableConfig 16 8 4)
        }
  -- What the table's own placeholder upload recorded is not the frame's.
  resetJournal rig
  pure renderer

-- | Prepare a frame and record it into a frame-less batch.
recorded ∷ Rig → Render.Renderer → FrameInput → IO (Either FrameRefusal ())
recorded rig renderer input =
  Render.prepareSnapshot (builders rig) renderer input >>= \case
    Left refusal → pure (Left refusal)
    Right recording → framelessOnce rig recording

-- | A native buffer's bytes of every bind: the one ring buffer.
bufferOffsets ∷ [NativeCommand] → [(Word64, Word64)]
bufferOffsets commands = [(buffer, offset) | CommandBindVertexBuffer _ buffer offset ← commands]

recordingSpec ∷ Spec
recordingSpec = describe "recording a frame" $ do
  it "records every pass in list order, each view under its scissor, each layer's push block and one draw per run, then ends the pass" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      commands ← commandsRecorded rig
      -- The ring's five claims: the clip region's one entry, then a layer each,
      -- of 192, 128, 64 and 64 bytes.
      ringOffsets rig >>= (`shouldBe` [0, 16, 208, 336, 400])
      seen commands
        `shouldBe` [ SeenBegin (ClearColor 0.25 0.5 0.75 1) Nothing
                   , SeenPipeline
                   , SeenViewport (Native.Viewport 0 0 32 32)
                   , SeenTable
                   , SeenStorage 0
                   , SeenScissor (Rect 0 0 16 32)
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 8, 16] (32, 32) 1 FilterNearest False)
                   , SeenBind 0 16
                   , SeenDraw 6 3
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 0, 0] (32, 32) 1 FilterNearest False)
                   , SeenBind 0 208
                   , SeenDraw 6 2
                   , SeenScissor (Rect 16 0 15 32)
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 16.5, 0] (32, 32) 2 FilterLinear True)
                   , SeenBind 0 336
                   , SeenDraw 6 1
                   , SeenEnd
                   , SeenBegin (ClearColor 1 0 0 0.5) (Just 1)
                   , SeenPipeline
                   , SeenViewport (Native.Viewport 0 0 16 16)
                   , SeenTable
                   , SeenStorage 0
                   , SeenScissor (Rect 0 0 16 16)
                   , SeenClearDepth (Rect 0 0 16 16) 1
                   , SeenTable
                   , SeenStorage 0
                   , SeenPush [PushVertex, PushFragment] 0 (push [2, 0, 0, 2, 0, 0] (16, 16) 1 FilterNearest False)
                   , SeenBind 0 400
                   , SeenDraw 6 1
                   , SeenEnd
                   ]
      length (nub (map fst (bufferOffsets commands))) `shouldBe` 1

  it "writes each layer's instances in drawing order into its own region, at the offset its draw binds" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      writes ← claimWrites rig
      let (world, ui, second, deep) = firstFrameLayers
      -- The world layer is written 1, 0, 2: ascending key, then submission.
      writes
        `shouldBe` [(0, ByteString.replicate 16 0), (16, chunk 1 world <> chunk 0 world <> chunk 2 world), (208, ui), (336, second), (400, deep)]

  it "keeps instances of mixed sampler choices in one run and one draw" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      writes ← claimWrites rig
      -- The world layer's one draw takes three instances whose flags words
      -- (at offset 56 of each chunk) say nearest, default and linear.
      let flags bytes index = ByteString.index bytes (64 * index + 56) .&. 3
      [map (flags bytes) [0, 1, 2] | (16, bytes) ← writes] `shouldBe` [[1, 0, 2]]
      commands ← commandsRecorded rig
      length [() | SeenDraw 6 3 ← seen commands] `shouldBe` 1

  it "begins a depth attachment and clears depth only for the pass holding a depth-enabled world layer" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      commands ← commandsRecorded rig
      [fmap (\(DepthClear _ value) → value) depth | CommandBeginRendering _ _ _ depth ← commands] `shouldBe` [Nothing, Just 1]
      [(rect, value) | CommandClearDepthRect rect value ← commands] `shouldBe` [(Rect 0 0 16 16, 1)]

  it "makes one pipeline per colour format and kind, on first use only: the plain one declares no depth, the depth pass's tests it unwritten" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      made ← pipelinesMade rig
      [(requestColorFormat request, requestBlend request, requestDepth request) | request ← made]
        `shouldBe` [ (formatCode Rgba8Srgb, BlendPremultipliedAlpha, Nothing)
                   , (formatCode Rgba8Linear, BlendPremultipliedAlpha, Just (PipelineDepth Depth32Float True False CompareLessOrEqual))
                   ]
      -- A second frame into the same formats makes no pipeline.
      recorded rig renderer input `shouldBe'` Right ()
      pipelinesMade rig >>= (\again → length again `shouldBe` 2)

  it "makes the table's shader-sampled layout once, covering both stages with the one push range" $
    withRig $ \rig → do
      _ ← rendererOver rig 4096
      layouts ← layoutsMade rig
      -- The table's two set layouts and the clip table's, and one range of 72 bytes for both stages.
      [(length sets, ranges) | (sets, ranges) ← layouts] `shouldBe` [(3, [PushConstantRange [PushVertex, PushFragment] 0 72])]

  it "refuses an unknown target in a later pass before it records a clear, a claim or a draw" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      let missing = input {frameTarget = \reference → if reference == refA then frameTarget input reference else Nothing}
      recorded rig renderer missing `shouldBe'` Left (UnknownTarget 1 refB)
      commandsRecorded rig >>= (`shouldBe` [])
      ringOffsets rig >>= (`shouldBe` [])
      pipelinesMade rig >>= (`shouldBe` [])

  it "refuses a frame the ring cannot hold, recording no clear and no draw, and keeps the claims the backend granted" $
    withRig $ \rig → do
      -- The clip region's 16 bytes and the first layer's 192 fit a ring of 256;
      -- the second layer's 128 do not.
      renderer ← rendererOver rig 256
      input ← inputOver rig firstFrame
      answer ← recorded rig renderer input
      case answer of
        Left (RefusedByBackend _) → pure ()
        other → expectationFailure ("expected the backend's refusal, found " <> show other)
      -- Only the clip region and the first layer's region were claimed: the
      -- refusal stopped the rest.
      -- The claim's own buffer barriers are the batch's; nothing is cleared or drawn.
      (seen <$> commandsRecorded rig) >>= (`shouldBe` [])
      ringOffsets rig >>= (`shouldBe` [0, 16])

  it "records nothing a refused view would draw, and refuses a view's mapping before any pass begins" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      image ← target rig Rgba8Srgb 32 32
      let overflow = View (Camera (V2 2e38 0) 2 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [] [UiLayer [sprite 0 0 SamplerDefault]]
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [], Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [overflow]]
          input = frameOf snapshot (\_ → Just (plainBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      recorded rig renderer input `shouldBe'` Left (ViewNotMappable 1 0)
      commandsRecorded rig >>= (`shouldBe` [])
  where
    shouldBe' action expected = action >>= (`shouldBe` expected)

-- ---------------------------------------------------------------------------
-- Clip tables (R2D-12)

-- | Floats as little-endian bytes: how the clip region holds a resolved
-- rectangle's four edges.
floats ∷ [Float] → ByteString
floats = Lazy.toStrict . toLazyByteString . foldMap floatLE

-- | A clip entry: this origin and extent, and this parent.
clipEntry ∷ (Float, Float) → (Float, Float) → Maybe Int → ClipEntry
clipEntry (x, y) (width, height) = ClipEntry (ClipRect (V2 x y) (V2 width height))

-- | A UI sprite with this clip index.
clippedSprite ∷ Word16 → Instance
clippedSprite index = (sprite 0 0 SamplerDefault) {instanceClip = index}

-- | A view of this viewport and clip table, holding one UI layer of sprites of
-- these clip indices.
clipView ∷ ((Float, Float), (Float, Float)) → [ClipEntry] → [Word16] → View
clipView (origin, extent') table indices =
  View (Camera (V2 0 0) 1 Nothing) (Viewport (uncurry V2 origin) (uncurry V2 extent')) defaultViewSettings table [UiLayer (map clippedSprite indices)]

-- | Two passes: pass 0 into the 32 × 32 target (refA) holds three views, and
-- pass 1 into the 16 × 16 one (refB) holds one.
--
-- * view 0, viewport (0, 0) 16 × 32, a table of two entries: (0, 0) 10 × 10, and
--   (5, 5) 10 × 10 under it, which resolves to (5, 5) to (10, 10); its sprites
--   take clip indices 1, 2 and 0;
-- * view 1, viewport (100, 100) 10 × 10, wholly outside the target, holds three
--   entries and draws nothing, so its table is not written;
-- * view 2, viewport (16, 0) 16 × 32, one entry (1, 2) 3 × 4, which resolves to
--   (1, 2) to (4, 6), and two layers, a world layer without a clip and a UI
--   layer whose first sprite takes it (a world and a UI layer could not both
--   take one entry);
-- * view 3, in pass 1, viewport (0, 0) 16 × 16, three entries: (0, 0) 1 × 1;
--   (0.5, 0.5) 4 × 4 under it, which resolves to (0.5, 0.5) to (1, 1); and
--   (3, 3) 1 × 1, which resolves to (3, 3) to (4, 4).
--
-- So the region holds, in order, the six entries of views 0, 2 and 3, and the
-- views' first entries are 0, 2 and 3.
clipFrame ∷ ValidSnapshot
clipFrame =
  valid
    [ Pass
        (OffscreenTarget refA)
        (ClearColour 0 0 0 1)
        [ clipView ((0, 0), (16, 32)) [clipEntry (0, 0) (10, 10) Nothing, clipEntry (5, 5) (10, 10) (Just 0)] [1, 2, 0]
        , clipView ((100, 100), (10, 10)) [clipEntry (0, 0) (1, 1) Nothing, clipEntry (0, 0) (2, 2) Nothing, clipEntry (0, 0) (3, 3) Nothing] [1, 2, 3]
        , View
            (Camera (V2 0 0) 1 Nothing)
            (Viewport (V2 16 0) (V2 16 32))
            defaultViewSettings
            [clipEntry (1, 2) (3, 4) Nothing]
            [WorldLayer DepthDisabled [clippedSprite 0], UiLayer [clippedSprite 1, clippedSprite 0]]
        ]
    , Pass
        (OffscreenTarget refB)
        (ClearColour 0 0 0 1)
        [clipView ((0, 0), (16, 16)) [clipEntry (0, 0) (1, 1) Nothing, clipEntry (0.5, 0.5) (4, 4) (Just 0), clipEntry (3, 3) (1, 1) Nothing] [3]]
    ]

-- | The region 'clipFrame' packs, written out by hand.
clipFrameRegion ∷ ByteString
clipFrameRegion =
  floats
    [ 0, 0, 10, 10 -- view 0, entry 0
    , 5, 5, 10, 10 -- view 0, entry 1, intersected with entry 0
    , 1, 2, 4, 6 -- view 2, entry 0
    , 0, 0, 1, 1 -- view 3, entry 0
    , 0.5, 0.5, 1, 1 -- view 3, entry 1, intersected with entry 0
    , 3, 3, 4, 4 -- view 3, entry 2
    ]

clipSpec ∷ Spec
clipSpec = describe "clip tables" $ do
  it "packs the tables of the views that draw into one region, in pass and view order, 16 bytes an entry" $
    withRig $ \rig → do
      input ← inputOver rig clipFrame
      case frameWork input of
        Right passes → clipRegion passes `shouldBe` Just clipFrameRegion
        Left refused → expectationFailure (show refused)

  it "gives each layer the index of its view's first entry, in entries, and a view that draws nothing none" $
    withRig $ \rig → do
      input ← inputOver rig clipFrame
      case frameWork input of
        Right passes →
          [ [(workViewIndex view, map (pushClipBase . layerPush) (workLayers view)) | view ← workViews pass]
          | pass ← passes
          ]
            `shouldBe` [[(0, [0]), (1, []), (2, [2, 2])], [(0, [3])]]
        Left refused → expectationFailure (show refused)

  it "pushes the inverse of the layer's transform, which the fragment stage clips in" $
    withRig $ \rig → do
      input ← inputOver rig clipFrame
      case frameWork input of
        Right (first : _) →
          -- View 0's UI layer: the transform is the identity at the viewport's origin.
          map (layerPushBytes) (concatMap workLayers (take 1 (workViews first)))
            `shouldBe` [pushBased 0 [1, 0, 0, 1, 0, 0] (32, 32) 1 FilterNearest False]
        other → expectationFailure ("expected passes, found " <> either show (show . length) other)

  it "claims the region first, with the table alignment, writes it, and binds it as set 2 wherever the table is bound" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig clipFrame
      recorded rig renderer input `shouldReturn` Right ()
      offsets ← ringOffsets rig
      writes ← claimWrites rig
      take 1 writes `shouldBe` [(0, clipFrameRegion)]
      -- The region's 96 bytes (six entries), then every layer's instances: 192,
      -- 64, 128 and 64 bytes, each at a multiple of 16.
      offsets `shouldBe` [0, 96, 288, 352, 480]
      commands ← commandsRecorded rig
      let bound = [tag | tag ← seen commands, case tag of SeenTable → True; SeenStorage _ → True; _ → False]
      -- Two passes draw: each binds the table and then the region, at the region's own start.
      bound `shouldBe` [SeenTable, SeenStorage 0, SeenTable, SeenStorage 0]
      -- Each layer's push block names its view's first entry.
      [ByteString.take 4 (ByteString.drop 44 bytes) | SeenPush _ _ bytes ← seen commands]
        `shouldBe` [floatlessWord base | base ← [0, 2, 2, 3]]

  it "keeps instances of different clip indices in one run and one draw" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig clipFrame
      recorded rig renderer input `shouldReturn` Right ()
      commands ← commandsRecorded rig
      -- View 0's three sprites (clip indices 1, 2, 0) are one draw.
      [() | SeenDraw 6 3 ← seen commands] `shouldBe` [()]

  it "writes each instance's clip index unchanged into its flags word, bits 16 to 31" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig clipFrame
      recorded rig renderer input `shouldReturn` Right ()
      writes ← claimWrites rig
      -- The first layer's instances were written in drawing order: the sprites
      -- are all at key 0, so submission order, with clip indices 1, 2 and 0.
      let clipOf bytes index = toInteger (ByteString.index bytes (64 * index + 58)) + 256 * toInteger (ByteString.index bytes (64 * index + 59))
      [map (clipOf bytes) [0, 1, 2 ∷ Int] | (96, bytes) ← writes] `shouldBe` [[1, 2, 0]]

  it "binds a region of one zero entry for a frame that draws and holds no clip entry" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      case frameWork input of
        Right passes → clipRegion passes `shouldBe` Just (ByteString.replicate 16 0)
        Left refused → expectationFailure (show refused)

  it "holds no region for a frame that draws nothing" $
    withRig $ \rig → do
      input ← depthFrame rig noCutoutMarks (Just Depth32Float) (onePass [viewAt (0, 0) (16, 16) [WorldLayer DepthEnabled []]])
      case frameWork input of
        Right passes → clipRegion passes `shouldBe` Nothing
        Left refused → expectationFailure (show refused)

  it "accepts tables that exactly fill the window and refuses one entry more, naming the size and the window" $
    withRig $ \rig → do
      let table count = replicate count (clipEntry (0, 0) (1, 1) Nothing)
          frameOf' count = valid [Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) [clipView ((0, 0), (16, 16)) (table count) [1]]]
      exact ← inputOver rig (frameOf' 256)
      over ← inputOver rig (frameOf' 257)
      (frameWork exact >>= requireClipWindow 4096) `shouldBe` Right ()
      (frameWork over >>= requireClipWindow 4096) `shouldBe` Left (ClipTablesTooLarge 4112 4096)

  it "counts only the tables of views that draw against the window" $
    withRig $ \rig → do
      let table count = replicate count (clipEntry (0, 0) (1, 1) Nothing)
          snapshot = valid [Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) [clipView ((100, 100), (4, 4)) (table 300) [1], clipView ((0, 0), (16, 16)) (table 2) [1]]]
      input ← inputOver rig snapshot
      case frameWork input of
        Right passes → do
          fmap ByteString.length (clipRegion passes) `shouldBe` Just 32
          requireClipWindow 4096 passes `shouldBe` Right ()
        Left refused → expectationFailure (show refused)

  it "refuses a frame whose tables do not fit the window before it claims anything or records a command" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      let table = replicate 257 (clipEntry (0, 0) (1, 1) Nothing)
          snapshot = valid [Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) [clipView ((0, 0), (16, 16)) table [1]]]
      input ← inputOver rig snapshot
      recorded rig renderer input `shouldReturn` Left (ClipTablesTooLarge 4112 4096)
      commandsRecorded rig >>= (`shouldBe` [])
      ringOffsets rig >>= (`shouldBe` [])
      pipelinesMade rig >>= (`shouldBe` [])
  where
    floatlessWord ∷ Word32 → ByteString
    floatlessWord base = ByteString.pack [fromIntegral (base `div` (256 ^ k) `mod` 256) | k ← [0 .. 3 ∷ Word32]]

-- ---------------------------------------------------------------------------
-- Depth (R2D-9)

-- | The texture the fixtures' sprites sample, and another.
artHandle, plainHandle ∷ TextureHandle
artHandle = textureHandle 1 1
plainHandle = textureHandle 2 1

-- | A unit sprite of a texture at this x with this depth key.
spriteOf ∷ TextureHandle → Float → Word32 → Instance
spriteOf handle x key = (sprite x key SamplerDefault) {instanceTexture = handle}

-- | The art handle is marked cutout-safe, the other is not.
marked ∷ CutoutMarks
marked = cutoutMarks [artHandle]

-- | A view of this viewport over the 16 × 16 target, camera at the origin.
viewAt ∷ (Float, Float) → (Float, Float) → [Layer] → View
viewAt origin extent' = View (Camera (V2 0 0) 1 Nothing) (Viewport (uncurry V2 origin) (uncurry V2 extent')) defaultViewSettings []

-- | One pass into the 16 × 16 target (refB) of these views.
onePass ∷ [View] → ValidSnapshot
onePass views = valid [Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) views]

-- | A frame into the 16 × 16 target with the depth image, if any, of this
-- format, and these marks.
depthFrame ∷ Rig → CutoutMarks → Maybe ImageFormat → ValidSnapshot → IO FrameInput
depthFrame rig marks depthFormat' snapshot = do
  image ← target rig Rgba8Linear 16 16
  depth ← traverse (\format → (\held → DepthBinding held format) <$> depthTarget rig format 16 16) depthFormat'
  pure (FrameInput snapshot marks (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Linear 16 16) depth)) Nothing Nothing)

-- | The kinds of pipeline the native layer was asked to bind, in order, by the
-- depth each declares and whether it blends.
boundKinds ∷ Rig → [NativeCommand] → IO [PipelineKind]
boundKinds rig commands = do
  made ← pipelineHandles rig
  pure [kindOf request | CommandBindPipeline handle ← commands, Just request ← [lookup handle made]]
  where
    kindOf request = case requestDepth request of
      Nothing → PlainPipeline
      Just (PipelineDepth _ True True _) → CutoutPipeline
      Just (PipelineDepth _ True False _) → OrderedTestedPipeline
      Just (PipelineDepth _ False _ _) → UntestedPipeline

depthSpec ∷ Spec
depthSpec = describe "depth passes" $ do
  it "begins a depth attachment exactly when a view with a non-empty scissor holds a depth-enabled world layer" $
    withRig $ \rig → do
      let ui = UiLayer [spriteOf artHandle 0 0]
          flat = WorldLayer DepthDisabled [spriteOf artHandle 0 0]
          deep = WorldLayer DepthEnabled [spriteOf artHandle 0 0]
          snapshot =
            valid
              [ Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) [viewAt (0, 0) (16, 16) [ui, flat]]
              , -- A depth-enabled layer in a viewport wholly outside the target: no scissor.
                Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) [viewAt (100, 100) (8, 8) [deep]]
              , -- One view outside and one inside, the inside one holding the layer.
                Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) [viewAt (100, 100) (8, 8) [deep], viewAt (0, 0) (16, 16) [ui, deep]]
              , Pass (OffscreenTarget refB) (ClearColour 0 0 0 1) []
              ]
      input ← depthFrame rig noCutoutMarks (Just Depth32Float) snapshot
      case frameWork input of
        Right passes → map (fmap depthFormat . workDepth) passes `shouldBe` [Nothing, Nothing, Just Depth32Float, Nothing]
        Left refused → expectationFailure (show refused)
      renderer ← rendererOver rig 4096
      recorded rig renderer input `shouldReturn` Right ()
      commands ← commandsRecorded rig
      [fmap (\(DepthClear _ value) → value) depth | CommandBeginRendering _ _ _ depth ← commands] `shouldBe` [Nothing, Nothing, Just 1, Nothing]

  it "clears depth to 1.0 within each depth-enabled layer's view scissor, binds the table again, then its push block and draw, and clears in no view with no scissor" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      let deep x = WorldLayer DepthEnabled [spriteOf plainHandle x 0]
          snapshot = onePass [viewAt (0, 0) (8, 16) [deep 0], viewAt (100, 100) (4, 4) [deep 1], viewAt (8, 0) (8, 16) [deep 2]]
      input ← depthFrame rig noCutoutMarks (Just Depth32Float) snapshot
      recorded rig renderer input `shouldReturn` Right ()
      commands ← commandsRecorded rig
      seen commands
        `shouldBe` [ SeenBegin (ClearColor 0 0 0 1) (Just 1)
                   , SeenPipeline
                   , SeenViewport (Native.Viewport 0 0 16 16)
                   , SeenTable
                   , SeenStorage 0
                   , SeenScissor (Rect 0 0 8 16)
                   , SeenClearDepth (Rect 0 0 8 16) 1
                   , SeenTable
                   , SeenStorage 0
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 4, 8] (16, 16) 1 FilterNearest False)
                   , SeenBind 0 16
                   , SeenDraw 6 1
                   , SeenScissor (Rect 8 0 8 16)
                   , SeenClearDepth (Rect 8 0 8 16) 1
                   , SeenTable
                   , SeenStorage 0
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 12, 8] (16, 16) 1 FilterNearest False)
                   , SeenBind 0 80
                   , SeenDraw 6 1
                   , SeenEnd
                   ]

  it "clears each of two depth-enabled layers of a view in turn, with a UI layer between them drawn untested" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      let deep = WorldLayer DepthEnabled [spriteOf plainHandle 0 0]
          snapshot = onePass [viewAt (0, 0) (16, 16) [deep, UiLayer [spriteOf plainHandle 0 0], deep]]
      input ← depthFrame rig noCutoutMarks (Just Depth32Float) snapshot
      recorded rig renderer input `shouldReturn` Right ()
      commands ← commandsRecorded rig
      [(rect, value) | CommandClearDepthRect rect value ← commands] `shouldBe` [(Rect 0 0 16 16, 1), (Rect 0 0 16 16, 1)]
      -- Tested, then untested, then tested again: the pipeline is rebound only where the kind changes.
      boundKinds rig commands >>= (`shouldBe` [OrderedTestedPipeline, UntestedPipeline, OrderedTestedPipeline])
      -- Each clear comes before its own layer's draw and after the previous layer's.
      [tag | tag ← seen commands, case tag of SeenClearDepth {} → True; SeenDraw {} → True; _ → False]
        `shouldBe` [SeenClearDepth (Rect 0 0 16 16) 1, SeenDraw 6 1, SeenDraw 6 1, SeenClearDepth (Rect 0 0 16 16) 1, SeenDraw 6 1]

  it "gives a depth-enabled layer with no instance its clear, a depth attachment and no claim, pipeline or draw" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← depthFrame rig noCutoutMarks (Just Depth32Float) (onePass [viewAt (0, 0) (16, 16) [WorldLayer DepthEnabled []]])
      recorded rig renderer input `shouldReturn` Right ()
      seen <$> commandsRecorded rig
        >>= (`shouldBe` [SeenBegin (ClearColor 0 0 0 1) (Just 1), SeenScissor (Rect 0 0 16 16), SeenClearDepth (Rect 0 0 16 16) 1, SeenEnd])
      ringOffsets rig >>= (`shouldBe` [])
      pipelinesMade rig >>= (`shouldBe` [])

  it "plans with the marks: a marked sprite is a cutout run drawn first, then the ordered run" $
    withRig $ \rig → do
      -- The unmarked sprite is submitted first, at key 9; the marked one, at key 1, is a cutout.
      let layer = WorldLayer DepthEnabled [spriteOf plainHandle 0 9, spriteOf artHandle 1 1]
          snapshot = onePass [viewAt (0, 0) (16, 16) [layer]]
      input ← depthFrame rig marked (Just Depth32Float) snapshot
      case frameWork input of
        Right [only] → do
          map layerRunList (concatMap workLayers (workViews only)) `shouldBe` [[RunWork 0 1 Cutout, RunWork 1 1 Ordered]]
          -- The cutout instance, submission index 1, is encoded first.
          case encodings snapshot of
            [written] → map layerBytes (concatMap workLayers (workViews only)) `shouldBe` [chunk 1 written <> chunk 0 written]
            other → expectationFailure ("expected one layer, found " <> show (length other))
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)

  it "draws a cutout run depth-tested and written with the cutout shaders and no blending, then the ordered run tested and unwritten, rebinding between them" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      let layer = WorldLayer DepthEnabled [spriteOf plainHandle 0 9, spriteOf artHandle 1 1]
          snapshot = onePass [viewAt (0, 0) (16, 16) [layer]]
      input ← depthFrame rig marked (Just Depth32Float) snapshot
      recorded rig renderer input `shouldReturn` Right ()
      commands ← commandsRecorded rig
      boundKinds rig commands >>= (`shouldBe` [CutoutPipeline, OrderedTestedPipeline])
      made ← pipelinesMade rig
      [(requestBlend request, requestDepth request) | request ← made]
        `shouldBe` [ (BlendNone, Just (PipelineDepth Depth32Float True True CompareLessOrEqual))
                   , (BlendPremultipliedAlpha, Just (PipelineDepth Depth32Float True False CompareLessOrEqual))
                   ]
      -- The two kinds do not share a fragment stage: the cutout variant is its own.
      case made of
        [cutout, ordered] → (requestShaders cutout == requestShaders ordered) `shouldBe` False
        other → expectationFailure ("expected two pipelines, found " <> show (length other))
      -- Both runs draw once each, from the one layer's region at the run's first instance.
      [(binding', offset) | CommandBindVertexBuffer binding' _ offset ← commands] `shouldBe` [(0, 16), (0, 80)]
      length [() | CommandDraw {} ← commands] `shouldBe` 2

  it "gives every pipeline of a pass with depth the one declared format, and an untested pipeline neither tests nor writes" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      let snapshot =
            onePass
              [ viewAt
                  (0, 0)
                  (16, 16)
                  [ WorldLayer DepthEnabled [spriteOf artHandle 0 1, spriteOf plainHandle 1 1]
                  , WorldLayer DepthDisabled [spriteOf artHandle 0 1]
                  , UiLayer [spriteOf artHandle 0 1]
                  ]
              ]
      input ← depthFrame rig marked (Just Depth32Float) snapshot
      recorded rig renderer input `shouldReturn` Right ()
      commands ← commandsRecorded rig
      boundKinds rig commands >>= (`shouldBe` [CutoutPipeline, OrderedTestedPipeline, UntestedPipeline])
      made ← pipelinesMade rig
      map (fmap depthAttachmentFormat . requestDepth) made `shouldBe` replicate 3 (Just Depth32Float)
      map (fmap (\declared → (depthTest declared, depthWrite declared, depthCompare declared)) . requestDepth) made
        `shouldBe` [Just (True, True, CompareLessOrEqual), Just (True, False, CompareLessOrEqual), Just (False, False, CompareLessOrEqual)]

  it "keeps the ordered path's pipeline in a pass with no depth attachment, whatever else the frame holds" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      let snapshot = onePass [viewAt (0, 0) (16, 16) [WorldLayer DepthDisabled [spriteOf artHandle 0 1], UiLayer [spriteOf artHandle 0 1]]]
      -- Marks alone do not make a depth pass: the layer has no depth.
      input ← depthFrame rig marked Nothing snapshot
      recorded rig renderer input `shouldReturn` Right ()
      commands ← commandsRecorded rig
      boundKinds rig commands >>= (`shouldBe` [PlainPipeline])
      [depth | CommandBeginRendering _ _ _ depth ← commands] `shouldBe` [Nothing]
      length [() | CommandClearDepthRect {} ← commands] `shouldBe` 0
      pipelinesMade rig >>= (\made → map requestDepth made `shouldBe` [Nothing])

  it "takes a window pass's depth from the frame's depth image, and needs it for a depth-enabled world layer" $
    withRig $ \rig → do
      depth ← depthTarget rig Depth32Float 8 8
      let layer = WorldLayer DepthEnabled [spriteOf artHandle 0 1]
          snapshot = valid [Pass WindowTarget (ClearColour 0 0 0 1) [viewAt (0, 0) (8, 8) [layer]]]
          attachment = Attachment (formatCode Bgra8Srgb) 8 8 (TargetMetrics (PixelExtent 8 8) (PixelExtent 8 8) 1 1)
          input = FrameInput snapshot noCutoutMarks (const Nothing) (Just attachment)
      case frameWork (input (Just (DepthBinding depth Depth32Float))) of
        Right [only] → fmap depthFormat (workDepth only) `shouldBe` Just Depth32Float
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)
      fmap (const ()) (frameWork (input Nothing)) `shouldBe` Left (NoDepthTarget (AtLayer 0 0 0))

depthRefusalSpec ∷ Spec
depthRefusalSpec = describe "the D32_SFLOAT requirement, before anything is recorded" $ do
  let deepLayer = WorldLayer DepthEnabled [spriteOf artHandle 0 1]
      deepSnapshot = onePass [viewAt (0, 0) (16, 16) [UiLayer [], deepLayer]]

  it "refuses a pass that needs a depth attachment and was given none, naming the layer" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← depthFrame rig noCutoutMarks Nothing deepSnapshot
      fmap (const ()) (frameWork input) `shouldBe` Left (NoDepthTarget (AtLayer 0 0 1))
      recorded rig renderer input `shouldReturn` Left (NoDepthTarget (AtLayer 0 0 1))
      commandsRecorded rig >>= (`shouldBe` [])
      ringOffsets rig >>= (`shouldBe` [])
      pipelinesMade rig >>= (`shouldBe` [])

  it "needs no depth target for a depth-enabled layer whose view has no scissor" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← depthFrame rig noCutoutMarks Nothing (onePass [viewAt (100, 100) (8, 8) [deepLayer]])
      recorded rig renderer input `shouldReturn` Right ()

  it "refuses a depth image of another format than D32_SFLOAT on a device that offers only X8_D24, naming the layer" $ do
    rig ← newRigOffering [Depth24, Depth16]
    -- The device's own choice is the lower-precision format.
    selectDepthFormat (rigRecording rig) >>= (`shouldBe` Right Depth24)
    renderer ← rendererOver rig 4096
    input ← depthFrame rig noCutoutMarks (Just Depth24) deepSnapshot
    fmap (const ()) (frameWork input) `shouldBe` Left (DepthFormatRefused (AtLayer 0 0 1) Depth24)
    recorded rig renderer input `shouldReturn` Left (DepthFormatRefused (AtLayer 0 0 1) Depth24)
    commandsRecorded rig >>= (`shouldBe` [])
    ringOffsets rig >>= (`shouldBe` [])
    pipelinesMade rig >>= (`shouldBe` [])
    -- The refusal is the same whatever the format, so long as it is not D32_SFLOAT.
    inputSixteen ← depthFrame rig noCutoutMarks (Just Depth16) deepSnapshot
    fmap (const ()) (frameWork inputSixteen) `shouldBe` Left (DepthFormatRefused (AtLayer 0 0 1) Depth16)

  it "refuses a lower-precision depth image even where the layer's view has no scissor" $
    withRig $ \rig → do
      input ← depthFrame rig noCutoutMarks (Just Depth24) (onePass [viewAt (100, 100) (8, 8) [deepLayer]])
      fmap (const ()) (frameWork input) `shouldBe` Left (DepthFormatRefused (AtLayer 0 0 0) Depth24)

  it "refuses a depth image whose format the backend holds as another than the maker declared, naming the layer, before recording anything" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      -- A 24-bit depth image declared as D32_SFLOAT.
      image ← target rig Rgba8Linear 16 16
      lie ← depthTarget rig Depth24 16 16
      let input snapshot = FrameInput snapshot noCutoutMarks (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Linear 16 16) (Just (DepthBinding lie Depth32Float)))) Nothing Nothing
          clearOnly = onePass [viewAt (0, 0) (16, 16) [WorldLayer DepthEnabled []]]
      recorded rig renderer (input deepSnapshot) `shouldReturn` Left (DepthFormatRefused (AtLayer 0 0 1) Depth24)
      recorded rig renderer (input clearOnly) `shouldReturn` Left (DepthFormatRefused (AtLayer 0 0 0) Depth24)
      recorded rig renderer (input (onePass [viewAt (100, 100) (8, 8) [deepLayer]])) `shouldReturn` Left (DepthFormatRefused (AtLayer 0 0 0) Depth24)
      commandsRecorded rig >>= (`shouldBe` [])
      ringOffsets rig >>= (`shouldBe` [])
      pipelinesMade rig >>= (`shouldBe` [])

  it "refuses a depth-enabled layer wholly outside the target on a device that offers only X8_D24, though no depth image is supplied" $ do
    rig ← newRigOffering [Depth24, Depth16]
    renderer ← rendererOver rig 4096
    input ← depthFrame rig noCutoutMarks Nothing (onePass [viewAt (100, 100) (8, 8) [deepLayer]])
    recorded rig renderer input `shouldReturn` Left (DepthFormatRefused (AtLayer 0 0 0) Depth24)
    commandsRecorded rig >>= (`shouldBe` [])

  it "refuses a depth-enabled layer when the session offers no depth format at all" $ do
    rig ← newRigOffering []
    renderer ← rendererOver rig 4096
    input ← depthFrame rig noCutoutMarks Nothing (onePass [viewAt (0, 0) (16, 16) [deepLayer]])
    recorded rig renderer input `shouldReturn` Left (NoDepthFormat (AtLayer 0 0 0))
    -- What has no such layer still records.
    plain ← depthFrame rig noCutoutMarks Nothing (onePass [viewAt (0, 0) (16, 16) [UiLayer [spriteOf artHandle 0 1]]])
    recorded rig renderer plain `shouldReturn` Right ()

  it "refuses at publication for a session's depth format, naming the first depth-enabled layer, and leaves a snapshot with none alone" $ do
    let twoDeep = onePass [viewAt (0, 0) (16, 16) [UiLayer [], deepLayer, deepLayer]]
        none = onePass [viewAt (0, 0) (16, 16) [UiLayer [], WorldLayer DepthDisabled []]]
    depthLayers twoDeep `shouldBe` [AtLayer 0 0 1, AtLayer 0 0 2]
    requireWorldDepth (Just Depth24) twoDeep `shouldBe` Left (DepthFormatRefused (AtLayer 0 0 1) Depth24)
    requireWorldDepth (Just Depth16) twoDeep `shouldBe` Left (DepthFormatRefused (AtLayer 0 0 1) Depth16)
    requireWorldDepth Nothing twoDeep `shouldBe` Left (NoDepthFormat (AtLayer 0 0 1))
    requireWorldDepth (Just Depth32Float) twoDeep `shouldBe` Right ()
    depthLayers none `shouldBe` []
    mapM_ (\format → requireWorldDepth format none `shouldBe` Right ()) [Just Depth32Float, Just Depth24, Just Depth16, Nothing]

  it "constructs the renderer and publishes and records a depth-free snapshot on a device that offers only X8_D24" $ do
    rig ← newRigOffering [Depth24, Depth16]
    renderer ← rendererOver rig 4096
    let plain = onePass [viewAt (0, 0) (16, 16) [WorldLayer DepthDisabled [spriteOf artHandle 0 1], UiLayer [spriteOf artHandle 0 1]]]
    -- Marks alone change nothing about it, and no depth image is supplied.
    input ← depthFrame rig marked Nothing plain
    requireWorldDepth (Just Depth24) plain `shouldBe` Right ()
    recorded rig renderer input `shouldReturn` Right ()
    commands ← commandsRecorded rig
    length [() | CommandDraw {} ← commands] `shouldBe` 2
    -- No pipeline declares D32_SFLOAT, which the device cannot attach.
    pipelinesMade rig >>= (\made → map requestDepth made `shouldBe` [Nothing])

-- ---------------------------------------------------------------------------
-- Passes that draw nothing

emptySpec ∷ Spec
emptySpec = describe "passes that draw nothing" $ do
  it "begins, clears and ends a pass whose views draw nothing, and binds neither pipeline nor table" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      image ← target rig Rgba8Srgb 32 32
      -- One view wholly outside the target; one inside with no layer.
      let outside = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 100 100) (V2 4 4)) defaultViewSettings [] [UiLayer [sprite 0 0 SamplerDefault]]
          empty' = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 4 4)) defaultViewSettings [] [UiLayer []]
          zeroSize = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 0 4)) defaultViewSettings [] [UiLayer [sprite 0 0 SamplerDefault]]
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0.5 0.5 0.5 1) [outside, empty', zeroSize]]
          input = frameOf snapshot (\_ → Just (plainBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      answer ← Render.prepareSnapshot (builders rig) renderer input >>= either (pure . Left) (framelessOnce rig)
      answer `shouldBe` Right ()
      commands ← commandsRecorded rig
      seen commands `shouldBe` [SeenBegin (ClearColor 0.5 0.5 0.5 1) Nothing, SeenEnd]
      ringOffsets rig >>= (`shouldBe` [])
      pipelinesMade rig >>= (`shouldBe` [])

  it "records an empty snapshot as no pass" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      image ← target rig Rgba8Srgb 32 32
      let input = frameOf (valid []) (\_ → Just (plainBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      answer ← Render.prepareSnapshot (builders rig) renderer input >>= either (pure . Left) (framelessOnce rig)
      answer `shouldBe` Right ()
      commandsRecorded rig >>= (`shouldBe` [])
