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
import Data.List (nub)
import Data.Maybe (mapMaybe)
import Data.Word (Word32, Word64)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( ClearColor (..)
  , DepthClear
  , ImageFormat (..)
  , NativeCommand (..)
  , PipelineBlend (..)
  , PushConstantRange (..)
  , PushStage (..)
  , Rect (..)
  , formatCode
  , validateRingSize
  )
import qualified Hetoimasia.GPU.Vulkan.Native.Recording as Native
import Hetoimasia.GPU.Vulkan.Native.TextureTable (validateTableConfig)
import Hetoimasia.Math.Affine2 (fromColumns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture.Backend (textureHandle)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Target.Backend (targetRef)
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validLayers, validateSnapshot)
import Hetoimasia.Render.TwoD.Encoding (encodeLayer)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Frame
import Hetoimasia.Render.TwoD.Vulkan.Layout (ViewPush (..), packViewPush)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "Recording" $ do
  workSpec
  refusalSpec
  recordingSpec
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
            [ WorldLayer DepthDisabled [sprite 1 5 SamplerDefault, sprite 2 1 SamplerNearest, sprite 3 5 SamplerLinear]
            , UiLayer [sprite 0 0 SamplerDefault, sprite 4 0 SamplerDefault]
            ]
        , View
            (Camera (V2 0 0) 1 Nothing)
            (Viewport (V2 16.5 0) (V2 15 32))
            defaultViewSettings {settingBrightness = 2, settingFilter = FilterLinear, settingPixelSnap = True}
            [UiLayer [sprite 9 0 SamplerDefault]]
        , View
            (Camera (V2 0 0) 1 Nothing)
            (Viewport (V2 100 100) (V2 10 10))
            defaultViewSettings
            [UiLayer [sprite 0 0 SamplerDefault]]
        ]
    , Pass
        (OffscreenTarget refB)
        (ClearColour 1 0 0 0.5)
        [ View
            (Camera (V2 4 4) 2 Nothing)
            (Viewport (V2 0 0) (V2 16 16))
            defaultViewSettings
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

-- | A push block, built by hand.
push ∷ [Float] → (Word32, Word32) → Float → TextureFilter → Bool → ByteString
push [a, b, c, d, tx, ty] extent brightness filtering snap =
  packViewPush (ViewPush (fromColumns (V2 a b) (V2 c d) (V2 tx ty)) extent brightness filtering snap)
push other _ _ _ _ = error ("a transform has six coefficients, not " <> show (length other))

-- ---------------------------------------------------------------------------
-- The work

-- | The input over the two offscreen targets, with images the rig made.
inputOver ∷ Rig → ValidSnapshot → IO FrameInput
inputOver rig snapshot = do
  imageA ← target rig Rgba8Srgb 32 32
  imageB ← target rig Rgba8Linear 16 16
  pure
    FrameInput
      { frameSnapshot = snapshot
      , frameTarget = \reference →
          lookup
            reference
            [ (refA, TargetBinding imageA (offscreenAttachment Rgba8Srgb 32 32))
            , (refB, TargetBinding imageB (offscreenAttachment Rgba8Linear 16 16))
            ]
      , frameWindow = Nothing
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
          map layerRunList layers `shouldBe` [[RunWork 0 3], [RunWork 0 2], [RunWork 0 1], [RunWork 0 1]]
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
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 4 6) (V2 20 20)) defaultViewSettings [UiLayer [sprite 0 0 SamplerDefault]]]]
          input = FrameInput snapshot (\_ → Just (TargetBinding image (Attachment (formatCode Rgba8Srgb) 32 32 metrics))) Nothing
      case frameWork input of
        Right [only] → map layerPushBytes (concatMap workLayers (workViews only)) `shouldBe` [push [2, 0, 0, 2, 4, 6] (32, 32) 1 FilterNearest False]
        other → expectationFailure ("expected one pass, found " <> either show (show . length) other)

  it "treats a depth-enabled world layer as an ordinary ordered layer: one run, no depth work" $
    withRig $ \rig → do
      input ← inputOver rig firstFrame
      case frameWork input of
        Right [_, last'] → map (map layerRunList . workLayers) (workViews last') `shouldBe` [[[RunWork 0 1]]]
        other → expectationFailure ("expected two passes, found " <> either show (show . length) other)

-- ---------------------------------------------------------------------------
-- Refusals

refusalSpec ∷ Spec
refusalSpec = describe "refusals, before anything is recorded" $ do
  it "names an unknown offscreen reference and the pass that names it, even in a later pass" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let input = (inputWith image) {frameTarget = \reference → if reference == refA then Just (TargetBinding image (offscreenAttachment Rgba8Srgb 32 32)) else Nothing}
      fmap (const ()) (frameWork input) `shouldBe` Left (UnknownTarget 1 refB)

  it "refuses a window pass with no frame context, naming the pass" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [], Pass WindowTarget (ClearColour 0 0 0 1) []]
          input = FrameInput snapshot (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      fmap (const ()) (frameWork input) `shouldBe` Left (NoWindowAttachment 1)

  it "takes a window pass's attachment from the frame context, with no image of its own" $
    withRig $ \_ → do
      let snapshot = valid [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [UiLayer [sprite 0 0 SamplerDefault]]]]
          input = FrameInput snapshot (const Nothing) (Just (Attachment (formatCode Bgra8Srgb) 8 8 (TargetMetrics (PixelExtent 4 4) (PixelExtent 8 8) 2 2)))
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
              FrameInput firstPassOnly (\_ → Just (TargetBinding image (Attachment (formatCode Rgba8Srgb) 32 32 metrics))) Nothing
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
              FrameInput firstPassOnly (\_ → Just (TargetBinding image (Attachment (formatCode Rgba8Srgb) 32 32 metrics))) Nothing
      refusedWith (TargetMetrics (PixelExtent 31 32) (PixelExtent 31 32) 1 1) `shouldBe` Left (MetricsDisagree 0 (PixelExtent 31 32) (32, 32))
      refusedWith (TargetMetrics (PixelExtent 32 32) (PixelExtent 32 33) 1 1) `shouldBe` Left (MetricsDisagree 0 (PixelExtent 32 33) (32, 32))

  it "refuses a view the mapping refuses, naming the pass and the view" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      -- A camera position of 2e38 at zoom 2 is finite, so it validates, but its
      -- translation overflows a 32-bit coefficient.
      let overflow = View (Camera (V2 2e38 0) 2 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [UiLayer [sprite 0 0 SamplerDefault]]
          fine = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings []
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [fine, overflow]]
          input = FrameInput snapshot (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      fmap (const ()) (frameWork input) `shouldBe` Left (ViewNotMappable 0 1)

  it "reports the first refusal in snapshot order" $
    withRig $ \rig → do
      image ← target rig Rgba8Srgb 32 32
      let bad = Attachment (formatCode Rgba8Srgb) 32 32 (TargetMetrics (PixelExtent 1 1) (PixelExtent 1 1) 1 1)
          input = (inputWith image) {frameTarget = \reference → if reference == refA then Nothing else Just (TargetBinding image bad)}
      fmap (const ()) (frameWork input) `shouldBe` Left (UnknownTarget 0 refA)
  where
    firstPassOnly = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) []]
    inputWith image =
      FrameInput
        { frameSnapshot = firstFrame
        , frameTarget = \_ → Just (TargetBinding image (offscreenAttachment Rgba8Srgb 32 32))
        , frameWindow = Nothing
        }

-- ---------------------------------------------------------------------------
-- Recording

-- | The commands a recording is made of, as they matter to the frame.
data Seen
  = SeenBegin !ClearColor !(Maybe DepthClear)
  | SeenEnd
  | SeenPipeline
  | SeenViewport !Native.Viewport
  | SeenTable
  | SeenScissor !Rect
  | SeenPush ![PushStage] !Word32 !ByteString
  | SeenBind !Word32 !Word64
    -- ^ The binding and the offset into the ring's buffer.
  | SeenDraw !Word32 !Word32
  deriving (Eq, Show)

seen ∷ [NativeCommand] → [Seen]
seen = mapMaybe $ \case
  CommandBeginRendering _ _ clear depth → Just (SeenBegin clear depth)
  CommandEndRendering → Just SeenEnd
  CommandBindPipeline _ → Just SeenPipeline
  CommandSetViewport viewport → Just (SeenViewport viewport)
  CommandBindDescriptorSets {} → Just SeenTable
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
      -- The ring's four claims, one a layer, are 192, 128, 64 and 64 bytes.
      ringOffsets rig >>= (`shouldBe` [0, 192, 320, 384])
      seen commands
        `shouldBe` [ SeenBegin (ClearColor 0.25 0.5 0.75 1) Nothing
                   , SeenPipeline
                   , SeenViewport (Native.Viewport 0 0 32 32)
                   , SeenTable
                   , SeenScissor (Rect 0 0 16 32)
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 8, 16] (32, 32) 1 FilterNearest False)
                   , SeenBind 0 0
                   , SeenDraw 6 3
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 0, 0] (32, 32) 1 FilterNearest False)
                   , SeenBind 0 192
                   , SeenDraw 6 2
                   , SeenScissor (Rect 16 0 15 32)
                   , SeenPush [PushVertex, PushFragment] 0 (push [1, 0, 0, 1, 16.5, 0] (32, 32) 2 FilterLinear True)
                   , SeenBind 0 320
                   , SeenDraw 6 1
                   , SeenEnd
                   , SeenBegin (ClearColor 1 0 0 0.5) Nothing
                   , SeenPipeline
                   , SeenViewport (Native.Viewport 0 0 16 16)
                   , SeenTable
                   , SeenScissor (Rect 0 0 16 16)
                   , SeenPush [PushVertex, PushFragment] 0 (push [2, 0, 0, 2, 0, 0] (16, 16) 1 FilterNearest False)
                   , SeenBind 0 384
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
        `shouldBe` [(0, chunk 1 world <> chunk 0 world <> chunk 2 world), (192, ui), (320, second), (384, deep)]

  it "keeps instances of mixed sampler choices in one run and one draw" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      writes ← claimWrites rig
      -- The world layer's one draw takes three instances whose flags words
      -- (at offset 56 of each chunk) say nearest, default and linear.
      let flags bytes index = ByteString.index bytes (64 * index + 56) .&. 3
      [map (flags bytes) [0, 1, 2] | (0, bytes) ← writes] `shouldBe` [[1, 0, 2]]
      commands ← commandsRecorded rig
      length [() | SeenDraw 6 3 ← seen commands] `shouldBe` 1

  it "records no depth attachment and no depth clear for a depth-enabled world layer, and no cutout path" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      commands ← commandsRecorded rig
      [depth | CommandBeginRendering _ _ _ depth ← commands] `shouldBe` [Nothing, Nothing]
      length [() | CommandClearDepthRect {} ← commands] `shouldBe` 0

  it "makes one pipeline per colour format, with premultiplied-alpha blending, on a format's first drawing pass only" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      input ← inputOver rig firstFrame
      recorded rig renderer input `shouldBe'` Right ()
      pipelinesMade rig >>= (`shouldBe` [(formatCode Rgba8Srgb, BlendPremultipliedAlpha), (formatCode Rgba8Linear, BlendPremultipliedAlpha)])
      -- A second frame into the same formats makes no pipeline.
      recorded rig renderer input `shouldBe'` Right ()
      pipelinesMade rig >>= (\made → length made `shouldBe` 2)

  it "makes the table's shader-sampled layout once, covering both stages with the one push range" $
    withRig $ \rig → do
      _ ← rendererOver rig 4096
      layouts ← layoutsMade rig
      -- Both of the table's set layouts, and one range of 44 bytes for both stages.
      [(length sets, ranges) | (sets, ranges) ← layouts] `shouldBe` [(2, [PushConstantRange [PushVertex, PushFragment] 0 44])]

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
      -- The first layer's 192 bytes fit a ring of 256; the second's 128 do not.
      renderer ← rendererOver rig 256
      input ← inputOver rig firstFrame
      answer ← recorded rig renderer input
      case answer of
        Left (RefusedByBackend _) → pure ()
        other → expectationFailure ("expected the backend's refusal, found " <> show other)
      -- Only the first layer's region was claimed: the refusal stopped the rest.
      -- The claim's own buffer barriers are the batch's; nothing is cleared or drawn.
      (seen <$> commandsRecorded rig) >>= (`shouldBe` [])
      ringOffsets rig >>= (`shouldBe` [0])

  it "records nothing a refused view would draw, and refuses a view's mapping before any pass begins" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      image ← target rig Rgba8Srgb 32 32
      let overflow = View (Camera (V2 2e38 0) 2 Nothing) (Viewport (V2 0 0) (V2 8 8)) defaultViewSettings [UiLayer [sprite 0 0 SamplerDefault]]
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [], Pass (OffscreenTarget refA) (ClearColour 0 0 0 1) [overflow]]
          input = FrameInput snapshot (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      recorded rig renderer input `shouldBe'` Left (ViewNotMappable 1 0)
      commandsRecorded rig >>= (`shouldBe` [])
  where
    shouldBe' action expected = action >>= (`shouldBe` expected)

-- ---------------------------------------------------------------------------
-- Passes that draw nothing

emptySpec ∷ Spec
emptySpec = describe "passes that draw nothing" $ do
  it "begins, clears and ends a pass whose views draw nothing, and binds neither pipeline nor table" $
    withRig $ \rig → do
      renderer ← rendererOver rig 4096
      image ← target rig Rgba8Srgb 32 32
      -- One view wholly outside the target; one inside with no layer.
      let outside = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 100 100) (V2 4 4)) defaultViewSettings [UiLayer [sprite 0 0 SamplerDefault]]
          empty' = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 4 4)) defaultViewSettings [UiLayer []]
          zeroSize = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 0 4)) defaultViewSettings [UiLayer [sprite 0 0 SamplerDefault]]
          snapshot = valid [Pass (OffscreenTarget refA) (ClearColour 0.5 0.5 0.5 1) [outside, empty', zeroSize]]
          input = FrameInput snapshot (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
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
      let input = FrameInput (valid []) (\_ → Just (TargetBinding image (offscreenAttachment Rgba8Srgb 32 32))) Nothing
      answer ← Render.prepareSnapshot (builders rig) renderer input >>= either (pure . Left) (framelessOnce rig)
      answer `shouldBe` Right ()
      commandsRecorded rig >>= (`shouldBe` [])
