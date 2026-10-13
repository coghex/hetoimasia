-- | Animation's window-free evidence (R2D-18): instances that name a frame table
-- of their view, rendered through @hetoimasia-render-2d-vulkan@ into offscreen
-- targets of a surface-free session, every pixel of every target judged against
-- @hetoimasia-render-2d-oracle@ by "Test.GPU.Vulkan.Native.OrderedPath"'s
-- runner. The recorder computes each table's current frame on the host, exactly,
-- at the view's time, writes the tables into the batch's storage region, and the
-- vertex stage reads the instance's rectangle from the table; the oracle applies
-- the same formula itself.
--
-- = The texture and the tables
--
-- One texture is registered: a strip of four opaque texels in a row, red, green,
-- blue and yellow, sampled nearest, so a pixel's colour names the texel, and a
-- table's frame @k@ shows one texel of it. A forward table of four frames shows
-- texel @k@ in frame @k@, a backward one texel @3 − k@. The target is 32 × 32 with a
-- depth image, the layers are depth-enabled world layers, and every instance is
-- cutout-eligible, so the retained tile is drawn from its chunk's own device
-- buffer, which the case builds once and never rebuilds.
--
-- = The frames
--
-- Each frame is one fixture of the record. The first six are one view over the
-- whole target, camera at its centre so that a world unit is a pixel, holding a
-- forward and a backward table of four frames of 0.5 s, and three tiles, each 8 × 8:
--
-- > D  dynamic, animated by table 1   pixels  4..11 × 4..11    probed at (8, 8)
-- > N  dynamic, not animated          pixels 20..27 × 4..11    probed at (24, 8)   texel 2, blue
-- > C  in the retained chunk, table 2 pixels  4..11 × 20..27   probed at (8, 24)
--
-- With the view's time @t@ and @q = t / 0.5@ the frame is @floor q mod 4@, worked
-- out here by hand and checked against the oracle's expectation:
--
-- > frame                t           q            frame   D (forward)   C (backward)
-- > dynamic-t0           0           0            0       red           yellow
-- > dynamic-t0.75       0.75         1.5          1       green         blue
-- > dynamic-boundary    1.0          2            2       blue          green
-- > dynamic-1e6-mid     999999.75    1999999.5    3       yellow        red        (1999999 mod 4 = 3)
-- > dynamic-1e6-boundary 1000000     2000000      0       red           yellow     (exactly on a boundary)
-- > dynamic-1e6-before  1e6 − 2^-33  1999999.9999999998 (the double below 2·10^6) 3 yellow red
--
-- The seventh draws the chunk's tile in two views of the target, side by side,
-- each with its own two tables and time, which show different frames; an
-- animated dynamic instance and a non-animated one are in the same draw. The
-- eighth and ninth are the review's two counterexamples: count 2, duration 8192
-- and time 991231.9998, whose 32-bit phase rounds up to the next frame, and a
-- duration of 2^127 at 2.5 times that, whose 32-bit phase does not exist.
--
-- Each fixture names the behaviour it shows by probes the oracle must give a
-- determinate expectation, which must differ from their contrast's, and the case
-- checks the colour of each against the frame worked out above, which does not
-- depend on the formula the recorder and the oracle share.
module Test.GPU.Vulkan.Native.AnimationPath
  ( animationSuite
  , runAnimation
  ) where

import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word16, Word8)
import GHC.Float (castDoubleToWord64, castWord64ToDouble)
import System.Directory (createDirectoryIfMissing)

import Control.Concurrent (threadDelay)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.GPU.Vulkan.GLFW
  ( ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (..)
  , Refusal (..)
  , UploadRefusal
  , UploadRequest (..)
  , UploadTicket
  , constructDepthFormat
  , constructImage
  )
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (..), ChunkKind (..), ChunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks)
import Hetoimasia.Render.TwoD.Oracle (Expectation (..), Probe (..))
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (ValidSnapshot, validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( ChunkStanding (..)
  , Retained
  , buildRetainedChunk
  , chunkStanding
  , newRetained
  , retainedBuffers
  , retainedChunks
  )
import Hetoimasia.Render.TwoD.Vulkan.Textures
  ( MarkPolicy (..)
  , Textures
  , newTextures
  , registerTexture
  , registeredMarks
  )
import Test.GPU.Vulkan.Native.OrderedPath
  ( Evidence
  , FixtureResult (..)
  , NamedResult (..)
  , Suite (..)
  , awaitPlaceholder
  , finishEvidence
  , runValidated
  )
import qualified Test.GPU.Vulkan.Native.OrderedPath as OrderedPath
import Test.GPU.Vulkan.Native.OrderedPath.Fixtures
  ( Fixture (..)
  , NamedProbe (..)
  , TargetShape
  , depthShape
  , keyed
  , pass
  , quad
  , sampled
  , tinted
  )
import Test.GPU.Vulkan.Native.RetainedPath (RetainedHost (..), buildersWith)

-- ---------------------------------------------------------------------------
-- The suite

-- | The frames the case judges.
frameCount ∷ Int
frameCount = 9

-- | The suite: its record, and as many fixtures as there are frames.
animationSuite ∷ Suite
animationSuite = Suite "animation" "animation-probes.json" [] (replicate frameCount placeholder) True
  where
    placeholder = Fixture "frame" [] [] (const (Snapshot [])) []

-- ---------------------------------------------------------------------------
-- The texture

-- | The strip's four texels: red, green, blue, yellow, opaque.
stripBytes ∷ [Word8]
stripBytes = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 0, 255]

-- | The image the oracle samples for the strip.
stripImage ∷ DecodedImage
stripImage =
  DecodedImage
    { decodedFormat = TexelRgba8Linear
    , decodedWidth = 4
    , decodedHeight = 1
    , decodedLevels = [ByteString.pack stripBytes]
    , decodedBinaryAlpha = True
    }

-- | Texel @k@ of the strip as a colour, worked out by hand.
texelColour ∷ Int → (Word8, Word8, Word8, Word8)
texelColour = \case
  0 → (255, 0, 0, 255)
  1 → (0, 255, 0, 255)
  2 → (0, 0, 255, 255)
  _ → (255, 255, 0, 255)

-- | The rectangle that shows texel @k@ and nothing else.
texelRect ∷ Int → UvRect
texelRect k = UvRect (fromIntegral k / 4) 0 (fromIntegral k / 4 + 0.25) 1

-- | A table of this many frames of this duration whose frame @k@ shows this texel.
tableShowing ∷ Int → Double → (Int → Int) → FrameTable
tableShowing count duration texelOf = FrameTable count duration [texelRect (texelOf k `mod` 4) | k ← [0 .. count - 1]]

-- | Frame @k@ shows texel @k@, wrapping at four.
forward ∷ Int → Double → FrameTable
forward count duration = tableShowing count duration id

-- | Frame @k@ shows texel @3 − k@.
backward ∷ Int → Double → FrameTable
backward count duration = tableShowing count duration (\k → 3 - k `mod` 4)

-- ---------------------------------------------------------------------------
-- The session

data Ctx = Ctx
  { ctxHost ∷ !RetainedHost
  , ctxSubmit ∷ UploadRequest → IO (Either UploadRefusal UploadTicket)
  , ctxSubmits ∷ !(IORef Int)
  , ctxDirectory ∷ !FilePath
  , ctxFormat ∷ !ImageFormat
  , ctxRenderer ∷ !Render.Renderer
  , ctxTextures ∷ !Textures
  , ctxRetained ∷ !Retained
  , ctxStrip ∷ !Api.TextureHandle
  }

base ∷ Ctx → OrderedPath.Host
base = retainedBase . ctxHost

-- | The target every frame draws into: 32 × 32, with a depth image.
shape ∷ TargetShape
shape = depthShape 1 Rgba8Linear 32 32

-- | Run the case, writing the PNGs and the probe record into this directory.
runAnimation ∷ RetainedHost → FilePath → IO Evidence
runAnimation host directory = do
  createDirectoryIfMissing True directory
  depth ← OrderedPath.hostAct (retainedBase host) "choosing the depth format" constructDepthFormat
  case depth of
    Left why → finish Nothing Nothing (Just why) []
    Right format
      | format /= Depth32Float →
          finish (Just format) (Just ("D32_SFLOAT is not available: the device chose " <> tshow format <> "; the animation case, which draws depth-enabled world layers, renders nothing")) Nothing []
      | otherwise →
          prepare host directory format >>= \case
            Left why → finish (Just format) Nothing (Just why) []
            Right ctx →
              buildTile ctx >>= \case
                Left why → finish (Just format) Nothing (Just why) []
                Right reference → do
                  singles ← mapM (frameOf ctx reference) singleViewFrames
                  others ← sequence [twoViews ctx reference, counterexample ctx reference, hugeDuration ctx reference]
                  let results = singles <> others
                  submits ← readIORef (ctxSubmits ctx)
                  let once = ("the retained tile's chunk was uploaded once for all " <> tshow frameCount <> " frames, and never rebuilt", submits == 1)
                      wrong = if length results == frameCount then Nothing else Just ("the case judged " <> tshow (length results) <> " frames, not " <> tshow frameCount)
                  finish (Just format) Nothing wrong (map (verified [once]) results)
  where
    finish format unavailable failure results = finishEvidence animationSuite directory format unavailable failure results

-- | Make the renderer, the strip texture and the chunk registry.
prepare ∷ RetainedHost → FilePath → ImageFormat → IO (Either Text Ctx)
prepare host directory format = do
  submits ← newIORef 0
  let submit request = do
        answer ← retainedSubmit host request
        either (const (pure ())) (const (atomicModifyIORef' submits (\count → (count + 1, ())))) answer
        pure answer
  made ← OrderedPath.hostAct (retainedBase host) "making the renderer and the strip texture" $ \construction → do
    renderer ← Render.makeRenderer (buildersWith submit construction) OrderedPath.configuration
    image ← constructImage construction (ImageDescription TextureImage Rgba8Linear 4 1 1)
    pure ((,) <$> renderer <*> image)
  case made of
    Left failure → pure (Left failure)
    Right (renderer, image) →
      OrderedPath.hostUpload (retainedBase host) (UploadImage image [ByteString.pack stripBytes]) >>= \case
        Left failure → pure (Left ("the strip's upload did not complete: " <> failure))
        Right _ →
          awaitPlaceholder (retainedBase host) (200 ∷ Int) >>= \case
            Left failure → pure (Left failure)
            Right () → do
              textures ← newTextures
              registered ←
                OrderedPath.hostAct (retainedBase host) "registering the strip" $ \construction →
                  registerTexture (buildersWith submit construction) textures image stripImage DefaultMark >>= \case
                    Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                    Right handle → pure (Right handle)
              case registered of
                Left failure → pure (Left failure)
                Right handle → do
                  retained ← newRetained
                  pure (Right (Ctx host submit submits directory format renderer textures retained handle))

-- ---------------------------------------------------------------------------
-- Building blocks

-- | An instance showing the strip over this rectangle of the world, nearest
-- sampled, opaque, at key 3 (a cutout in a depth-enabled layer) and carrying
-- this frame-table index; its own rectangle is the whole strip, which an
-- animated instance never shows.
tile ∷ Ctx → Word16 → (Float, Float) → Instance
tile ctx index origin = (keyed 3 (tinted (255, 255, 255, 255) (sampled SamplerNearest (quad origin (8, 8) (ctxStrip ctx))))) {instanceFrameTable = index}

-- | A tile that is not animated and shows this texel through its own rectangle.
fixedTile ∷ Ctx → Int → (Float, Float) → Instance
fixedTile ctx texel' origin = (tile ctx 0 origin) {instanceUv = texelRect texel'}

-- | A view over a viewport of the target whose camera is at this world position,
-- with these tables and time.
animatedView ∷ (Float, Float) → (Float, Float) → (Float, Float) → [FrameTable] → Double → [Layer] → View
animatedView (x, y) (w, h) (cx, cy) tables time = ViewWith (Camera (V2 cx cy) 1 Nothing) (Viewport (V2 x y) (V2 w h)) defaultViewSettings [] Map.empty tables time

-- | The whole-target view: the camera at the target's centre, a world unit a pixel.
wholeView ∷ [FrameTable] → Double → [Layer] → View
wholeView = animatedView (0, 0) (32, 32) (16, 16)

-- | Build the retained tile on the owner's thread and wait, within a deadline,
-- for its upload to complete: world (4, 20), table 2.
buildTile ∷ Ctx → IO (Either Text ChunkRef)
buildTile ctx = do
  marks ← registeredMarks (ctxTextures ctx)
  built ←
    OrderedPath.hostAct (base ctx) "building the retained tile" $ \construction →
      buildRetainedChunk (buildersWith (ctxSubmit ctx) construction) (ctxRetained ctx) marks ChunkWorldDepth DeriveBounds [tile ctx 2 (4, 20)] >>= \case
        Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
        Right reference → pure (Right reference)
  case built of
    Left failure → pure (Left failure)
    Right reference → do
      ready ← awaitStanding ctx reference (400 ∷ Int)
      pure (if ready then Right reference else Left ("the chunk's upload did not complete: " <> tshow reference))

awaitStanding ∷ Ctx → ChunkRef → Int → IO Bool
awaitStanding ctx reference remaining =
  chunkStanding (ctxRetained ctx) reference >>= \case
    Just ChunkReady → pure True
    _
      | remaining <= 0 → pure False
      | otherwise → threadDelay 25000 >> awaitStanding ctx reference (remaining - 1)

-- | Render one frame of a snapshot of these views and judge it.
renderFrame ∷ Ctx → Text → [View] → [NamedProbe] → IO FixtureResult
renderFrame ctx name views probes = do
  chunks ← retainedChunks (ctxRetained ctx)
  case validateSnapshotWith chunks (Snapshot [pass shape (0, 0, 0, 1) views]) of
    Left refused → pure (FixtureResult name [] [] [] (Just ("the snapshot was refused: " <> tshow refused)))
    Right valid → judged valid
  where
    judged ∷ ValidSnapshot → IO FixtureResult
    judged valid = do
      marks ← registeredMarks (ctxTextures ctx)
      buffers ← retainedBuffers (ctxRetained ctx)
      runValidated (base ctx) animationSuite (ctxDirectory ctx) (ctxFormat ctx) (ctxRenderer ctx) (marks ∷ CutoutMarks) buffers decodedAt name [shape] probes valid
    decodedAt handle = if handle == ctxStrip ctx then Just stripImage else Nothing

-- | The fixture, failed by the first check that did not hold.
verified ∷ [(Text, Bool)] → FixtureResult → FixtureResult
verified checks result = case (resultFailure result, [what | (what, False) ← checks]) of
  (Nothing, what : _) → result {resultFailure = Just ("a check failed: " <> what)}
  _ → result

-- | A named probe at a pixel of the target, with the background as its contrast.
named ∷ Text → (Int, Int) → NamedProbe
named behaviour (x, y) = NamedProbe behaviour (Probe 0 x y) (Probe 0 30 30)

-- | The checks that each named probe expects the colour worked out by hand.
expecting ∷ FixtureResult → [(Text, (Word8, Word8, Word8, Word8))] → [(Text, Bool)]
expecting result wanted =
  [ (behaviour <> " expects " <> tshow colour, any (matches colour) [found | found ← resultNamed result, namedName found == behaviour])
  | (behaviour, colour) ← wanted
  ]
  where
    matches (r, g, b, a) found = case namedExpected found of
      Expected pixel _ → pixel == Rgba8 r g b a
      _ → False

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- | The double just below this positive one.
below ∷ Double → Double
below value = castWord64ToDouble (castDoubleToWord64 value - 1)

-- ---------------------------------------------------------------------------
-- The single-view frames

-- | A frame of the whole-target view at a time, and the texel D, C show then.
data Single = Single
  { singleName ∷ !Text
  , singleTime ∷ !Double
  , singleD ∷ !Int
  , singleC ∷ !Int
  }

-- | The six frames worked out in the module header: D is forward, C backward, the
-- frame is @floor (t / 0.5) mod 4@ and texel @frame@ and @3 − frame@.
singleViewFrames ∷ [Single]
singleViewFrames =
  [ Single "dynamic-t0" 0 0 3
  , Single "dynamic-t0.75" 0.75 1 2
  , Single "dynamic-boundary" 1.0 2 1
  , Single "dynamic-1e6-mid" 999999.75 3 0
  , Single "dynamic-1e6-boundary" 1000000 0 3
  , Single "dynamic-1e6-before" (below 1000000) 3 0
  ]

-- | D (dynamic, table 1), N (dynamic, not animated) and the chunk's tile C (table 2).
frameOf ∷ Ctx → ChunkRef → Single → IO FixtureResult
frameOf ctx reference single = do
  let layer = WorldLayerWith DepthEnabled [reference] [tile ctx 1 (4, 4), fixedTile ctx 2 (20, 4)]
      view = wholeView [forward 4 0.5, backward 4 0.5] (singleTime single) [layer]
      dynamic = "the dynamic animated instance shows its table's current frame"
      fixed = "an instance with no frame table in the same draw shows its own rectangle"
      retained = "the retained tile, built once, shows the current frame of its view's table"
      probes = [named dynamic (8, 8), named fixed (24, 8), named retained (8, 24)]
  result ← renderFrame ctx (singleName single) [view] probes
  pure (verified (expecting result [(dynamic, texelColour (singleD single)), (fixed, texelColour 2), (retained, texelColour (singleC single))]) result)

-- ---------------------------------------------------------------------------
-- The same chunk in two views

-- | The retained tile's chunk in the left half and the right half of the target,
-- each view with its own two tables and its own time, and a dynamic animated
-- instance and a non-animated one in the same draw. The cameras put the tile at
-- world (4, 20) on pixels 4..11 × 20..27 in the left view and 20..27 × 20..27 in
-- the right:
--
-- * left, table 2 backward of four frames of 0.5 s at 0.75 s: 1.5, frame 1, texel 2, blue;
--   table 1 forward at 0.75 s: frame 1, green (the dynamic tile at 4..11 × 4..11);
-- * right, table 2 forward of four frames of 0.25 s at 999999.75 s: 3999999, frame
--   3 (3999999 mod 4), texel 3, yellow; table 1 backward of the same at that time:
--   frame 3, texel 0, red.
twoViews ∷ Ctx → ChunkRef → IO FixtureResult
twoViews ctx reference = do
  let layer = WorldLayerWith DepthEnabled [reference] [tile ctx 1 (4, 4), fixedTile ctx 2 (4, 12)]
      left = animatedView (0, 0) (16, 32) (8, 16) [forward 4 0.5, backward 4 0.5] 0.75 [layer]
      right = animatedView (16, 0) (16, 32) (8, 16) [backward 4 0.25, forward 4 0.25] 999999.75 [layer]
      leftRetained = "the retained tile shows the left view's own table at the left view's time"
      rightRetained = "the same retained tile shows the right view's own table at the right view's time"
      leftDynamic = "the left view's dynamic instance shows its frame"
      rightDynamic = "the right view's dynamic instance shows its frame"
      fixedLeft = "a non-animated instance draws its own rectangle in the left view"
      fixedRight = "a non-animated instance draws its own rectangle in the right view"
      probes =
        [ named leftRetained (8, 24)
        , named rightRetained (24, 24)
        , named leftDynamic (8, 8)
        , named rightDynamic (24, 8)
        , named fixedLeft (8, 16)
        , named fixedRight (24, 16)
        ]
  result ← renderFrame ctx "two-views" [left, right] probes
  pure (verified (expecting result [(leftRetained, texelColour 2), (rightRetained, texelColour 3), (leftDynamic, texelColour 1), (rightDynamic, texelColour 0), (fixedLeft, texelColour 2), (fixedRight, texelColour 2)]) result)

-- ---------------------------------------------------------------------------
-- The review's counterexamples

-- | Count 2 and duration 8192 at 991231.9998 s, which divided is 120.99999997558594:
-- frame 120 mod 2 = 0. A 32-bit phase rounds 8191.9997999999905 up to 8192 and
-- selects frame 1. Table 1 shows texels red, green; table 2 yellow, blue.
counterexample ∷ Ctx → ChunkRef → IO FixtureResult
counterexample ctx reference = do
  let layer = WorldLayerWith DepthEnabled [reference] [tile ctx 1 (4, 4)]
      tables = [tableShowing 2 8192 id, tableShowing 2 8192 (\k → [3, 1] !! (k `mod` 2))]
      view = wholeView tables 991231.9998 [layer]
      dynamic = "a time 0.0002 s short of a frame boundary selects the frame before it, as the exact formula does"
      retained = "the same holds for the retained tile"
  result ← renderFrame ctx "counterexample-8192" [view] [named dynamic (8, 8), named retained (8, 24)]
  -- Table 2's frames are texel 3, yellow, then texel 1, green; frame 0 is yellow.
  pure (verified (expecting result [(dynamic, texelColour 0), (retained, texelColour 3)]) result)

-- | A duration of 2^127 with three frames at 2.5 × 2^127 s: the quotient is 2.5
-- and the frame 2; a 32-bit phase of 2.5 × 2^127 does not exist. Table 1 shows
-- red, green, blue; table 2 yellow, red, green.
hugeDuration ∷ Ctx → ChunkRef → IO FixtureResult
hugeDuration ctx reference = do
  let layer = WorldLayerWith DepthEnabled [reference] [tile ctx 1 (4, 4)]
      duration = 2 ^ (127 ∷ Int)
      tables = [tableShowing 3 duration id, tableShowing 3 duration (\k → [3, 0, 1] !! (k `mod` 3))]
      view = wholeView tables (2.5 * duration) [layer]
      dynamic = "a huge finite duration selects the frame its quotient gives"
      retained = "the same holds for the retained tile"
  result ← renderFrame ctx "huge-duration" [view] [named dynamic (8, 8), named retained (8, 24)]
  pure (verified (expecting result [(dynamic, texelColour 2), (retained, texelColour 1)]) result)
