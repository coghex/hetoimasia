-- | Retained chunks in the oracle (R2D-10): a layer that lists chunks is
-- evaluated as the plan orders it, a chunk's routing is the one it was built
-- with, and a view that culls a chunk loses nothing that is visible.
--
-- Every expectation in the examples is worked on paper, as in the depth
-- examples: the target is an 8 × 8 UNORM one, a unit sprite at the world origin
-- covers pixel (4, 4), and so does a unit sprite at UI point (4, 4); every
-- texture is one linear texel. The ordered path draws opaque art over what is
-- there in the order the plan gives, so the last draw at a pixel is the one
-- that shows; the cutout path is depth-tested, a larger key nearer, and the
-- later draw wins among cutouts of an equal key.
--
-- The generated example compares a layer that lists chunks with the layer that
-- holds their instances itself, in source order. It must give the same
-- expectation at every pixel: a chunk is the same content kept, so whatever
-- the oracle does with it, culling included, may change no determinate pixel.
module Test.Render.TwoD.Oracle.Chunks (spec) where

import qualified Data.Map.Strict as Map
import Data.Word (Word32)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Chunk
import Hetoimasia.Render.TwoD.Chunk.Backend (chunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (CutoutMarks, cutoutMarks, noCutoutMarks)
import Hetoimasia.Render.TwoD.Oracle
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..), Tolerance)
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (validateSnapshotWith)
import Test.Hspec hiding (Expectation)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, checkCoverage, choose, conjoin, counterexample, cover, elements, forAll, listOf, resize, (===))
import Test.Render.TwoD.Oracle.Support

-- * Fixtures

red, green, blue ∷ Rgba
red = (255, 0, 0, 255)
green = (0, 255, 0, 255)
blue = (0, 0, 255, 255)

-- | Red, green and blue under the three handles.
textures ∷ [(TextureHandle, Rgba)]
textures = [(h1, red), (h2, green), (h3, blue)]

allMarked ∷ CutoutMarks
allMarked = cutoutMarks [h1, h2, h3]

-- | A reference, by index.
ref ∷ Word32 → ChunkRef
ref index = chunkRef index 1

-- | The chunk of these instances, routed against these marks.
chunkOf ∷ CutoutMarks → ChunkKind → [Instance] → Chunk
chunkOf marks kind = either (error . ("the chunk was refused: " <>) . show) id . buildChunk marks kind DeriveBounds

-- | The layer of this kind listing these chunks and holding these dynamic
-- instances.
layerOf ∷ ChunkKind → [ChunkRef] → [Instance] → Layer
layerOf = \case
  ChunkWorldDepth → WorldLayerWith DepthEnabled
  ChunkWorldFlat → WorldLayerWith DepthDisabled
  ChunkUi → UiLayerWith

-- | A unit sprite of a texture over pixel (4, 4), whichever space the layer is
-- in: world (0, 0) and UI (4, 4) both land on it.
coverHere ∷ ChunkKind → TextureHandle → Instance
coverHere kind handle = spriteAt handle (case kind of ChunkUi → (4, 4); _ → (0, 0))

keyed ∷ Word32 → Instance → Instance
keyed key candidate = candidate {instanceDepthKey = key}

translucent ∷ Instance → Instance
translucent candidate = candidate {instanceTranslucent = True}

-- | An oracle over one 8 × 8 view of these layers, against these chunks and the
-- cutout marks the dynamic instances are planned with.
over ∷ CutoutMarks → [(ChunkRef, Chunk)] → [Layer] → Oracle
over marks held layers =
  newOracle
    OracleInput
      { inputSnapshot = either (error . ("fixture refused: " <>) . show) id (validateSnapshotWith (chunksFrom held) (Snapshot [offscreenPass noClear [fullView 8 8 layers]]))
      , inputCutoutMarks = marks
      , inputWindow = Nothing
      , inputOffscreen = Map.singleton offscreenRef unorm8
      , inputTextures = \handle → lookup handle [(h, solid False colour) | (h, colour) ← textures]
      }

-- | The value expected at a pixel, if determinate.
valueAt ∷ Oracle → Int → Int → Maybe Rgba8
valueAt oracle x y = case expect oracle (Probe 0 x y) of
  Expected value _ → Just value
  _ → Nothing

pixel ∷ Rgba → Maybe Rgba8
pixel = Just . px

allKinds ∷ [ChunkKind]
allKinds = [minBound .. maxBound]

-- * Examples

spec ∷ Spec
spec = describe "retained chunks" $ do
  orderedSpec
  cutoutSpec
  routingSpec
  repeatSpec
  viewSpec
  inlineSpec

orderedSpec ∷ Spec
orderedSpec = describe "ordered content, in each kind of layer" $ do
  it "draws a chunk before the dynamic instances at an equal key, so a dynamic instance shows over it" $
    sequence_
      [ valueAt (over noCutoutMarks [(ref 1, chunk)] [layerOf kind [ref 1] [dynamic]]) 4 4 `shouldBe` pixel green
      | kind ← allKinds
      , let chunk = chunkOf noCutoutMarks kind [keyed 5 (coverHere kind h1)]
            dynamic = keyed 5 (coverHere kind h2)
      ]
  it "orders by depth key before source: a chunk with the larger key draws after a dynamic instance and shows over it" $
    sequence_
      [ valueAt (over noCutoutMarks [(ref 1, chunk)] [layerOf kind [ref 1] [dynamic]]) 4 4 `shouldBe` pixel red
      | kind ← allKinds
      , let chunk = chunkOf noCutoutMarks kind [keyed 9 (coverHere kind h1)]
            dynamic = keyed 5 (coverHere kind h2)
      ]
  it "draws chunks in the order the layer lists them: the last one listed shows" $
    sequence_
      [ do
          let first = chunkOf noCutoutMarks kind [keyed 3 (coverHere kind h1)]
              second = chunkOf noCutoutMarks kind [keyed 3 (coverHere kind h2)]
              held = [(ref 1, first), (ref 2, second)]
          valueAt (over noCutoutMarks held [layerOf kind [ref 1, ref 2] []]) 4 4 `shouldBe` pixel green
          valueAt (over noCutoutMarks held [layerOf kind [ref 2, ref 1] []]) 4 4 `shouldBe` pixel red
      | kind ← allKinds
      ]
  it "draws a chunk's instances in its build order at an equal key, and by key whatever the build order" $
    sequence_
      [ do
          let build = chunkOf noCutoutMarks kind
              equal = build [keyed 3 (coverHere kind h1), keyed 3 (coverHere kind h2)]
              reversed = build [keyed 4 (coverHere kind h1), keyed 3 (coverHere kind h2)]
          valueAt (over noCutoutMarks [(ref 1, equal)] [layerOf kind [ref 1] []]) 4 4 `shouldBe` pixel green
          valueAt (over noCutoutMarks [(ref 1, reversed)] [layerOf kind [ref 1] []]) 4 4 `shouldBe` pixel red
      | kind ← allKinds
      ]
  it "puts every instance of a world chunk without depth and of a UI chunk on the ordered path, marked or not" $
    sequence_
      [ do
          -- The cutout rule discards a half-transparent texel; the ordered path blends it.
          let half = coverHere kind h1
              chunk = chunkOf allMarked kind [keyed 1 half {instanceTint = Tint 255 255 255 128}]
          valueAt (over allMarked [(ref 1, chunk)] [layerOf kind [ref 1] []]) 4 4 `shouldBe` pixel (255, 0, 0, 128)
      | kind ← [ChunkWorldFlat, ChunkUi]
      ]

cutoutSpec ∷ Spec
cutoutSpec = describe "cutout content in a world layer with depth" $ do
  let build = chunkOf allMarked ChunkWorldDepth
      here = coverHere ChunkWorldDepth
      layer refs dynamic = WorldLayerWith DepthEnabled refs dynamic
  it "lets the later source win among cutouts of an equal key: the dynamic instance after the chunk's, and the later listed chunk" $ do
    let first = build [keyed 7 (here h1)]
        second = build [keyed 7 (here h2)]
        held = [(ref 1, first), (ref 2, second)]
    valueAt (over allMarked [(ref 1, first)] [layer [ref 1] [keyed 7 (here h2)]]) 4 4 `shouldBe` pixel green
    valueAt (over allMarked held [layer [ref 1, ref 2] []]) 4 4 `shouldBe` pixel green
    valueAt (over allMarked held [layer [ref 2, ref 1] []]) 4 4 `shouldBe` pixel red
  it "lets the larger key win whichever source it is in" $ do
    let nearChunk = build [keyed 9 (here h1)]
        nearDynamic = keyed 9 (here h1)
    valueAt (over allMarked [(ref 1, nearChunk)] [layer [ref 1] [keyed 5 (here h2)]]) 4 4 `shouldBe` pixel red
    valueAt (over allMarked [(ref 1, build [keyed 5 (here h2)])] [layer [ref 1] [nearDynamic]]) 4 4 `shouldBe` pixel red
  it "draws an ordered instance of the same key over a cutout, from the chunk or the layer, and hides one behind a nearer cutout" $ do
    let half colour key = (translucent (keyed key (here colour))) {instanceTint = Tint 255 0 0 128}
        chunkCutout = build [keyed 7 (here h2)]
        chunkOrdered = build [half h1 7]
    -- Half red over green at an equal key: red 255, green 127.
    valueAt (over allMarked [(ref 1, chunkCutout)] [layer [ref 1] [half h1 7]]) 4 4 `shouldBe` pixel (255, 127, 0, 255)
    valueAt (over allMarked [(ref 1, chunkOrdered)] [layer [ref 1] [keyed 7 (here h2)]]) 4 4 `shouldBe` pixel (255, 127, 0, 255)
    valueAt (over allMarked [(ref 1, chunkOrdered)] [layer [ref 1] [keyed 8 (here h2)]]) 4 4 `shouldBe` pixel green
    -- Farther than the cutout (a smaller key) it fails the depth test.
    valueAt (over allMarked [(ref 1, build [half h1 6])] [layer [ref 1] [keyed 7 (here h2)]]) 4 4 `shouldBe` pixel green
  it "discards a chunk's cutout below an alpha of a half and writes no depth for it" $ do
    let faint = (here h1) {instanceTint = Tint 255 255 255 255}
        oracle = newOracleOver [(h1, (255, 0, 0, 40)), (h2, green)] [(ref 1, build [keyed 9 faint])] [layer [ref 1] [keyed 1 (here h2)]]
    -- The nearer chunk cutout is transparent over the pixel, so the farther one shows.
    valueAt oracle 4 4 `shouldBe` pixel green

-- | An oracle with its own textures, all marked cutout.
newOracleOver ∷ [(TextureHandle, Rgba)] → [(ChunkRef, Chunk)] → [Layer] → Oracle
newOracleOver own held layers =
  newOracle
    OracleInput
      { inputSnapshot = either (error . ("fixture refused: " <>) . show) id (validateSnapshotWith (chunksFrom held) (Snapshot [offscreenPass noClear [fullView 8 8 layers]]))
      , inputCutoutMarks = allMarked
      , inputWindow = Nothing
      , inputOffscreen = Map.singleton offscreenRef unorm8
      , inputTextures = \handle → lookup handle [(h, solid False colour) | (h, colour) ← own]
      }

routingSpec ∷ Spec
routingSpec = describe "the routing a chunk was built with" $ do
  it "is the chunk's whatever marks the oracle is given: built unmarked it is ordered, built marked it is a cutout" $ do
    let here = coverHere ChunkWorldDepth
        dynamicGreen = keyed 5 (here h2)
        layer refs = WorldLayerWith DepthEnabled refs [dynamicGreen]
        -- Red at the same key as the dynamic green cutout. As a cutout listed
        -- before it, red loses the tie; ordered, red draws after every cutout and wins.
        asOrdered = chunkOf noCutoutMarks ChunkWorldDepth [keyed 5 (here h1)]
        asCutout = chunkOf allMarked ChunkWorldDepth [keyed 5 (here h1)]
    -- The oracle's marks name every handle in both, so only the build decides.
    valueAt (over allMarked [(ref 1, asOrdered)] [layer [ref 1]]) 4 4 `shouldBe` pixel red
    valueAt (over allMarked [(ref 1, asCutout)] [layer [ref 1]]) 4 4 `shouldBe` pixel green
    valueAt (over noCutoutMarks [(ref 1, asCutout)] [layer [ref 1]]) 4 4 `shouldBe` pixel green

repeatSpec ∷ Spec
repeatSpec = describe "a chunk listed twice" $
  it "is drawn at both places: a half-transparent sprite blends twice, as two dynamic copies do" $ do
    let half = (coverHere ChunkUi h1) {instanceTint = Tint 255 255 255 128}
        chunk = chunkOf noCutoutMarks ChunkUi [half]
        twice = over noCutoutMarks [(ref 1, chunk)] [UiLayerWith [ref 1, ref 1] []]
        copies = over noCutoutMarks [] [UiLayer [half, half]]
        once = over noCutoutMarks [(ref 1, chunk)] [UiLayerWith [ref 1] []]
    valueAt twice 4 4 `shouldBe` valueAt copies 4 4
    valueAt twice 4 4 `shouldSatisfy` (/= valueAt once 4 4)

viewSpec ∷ Spec
viewSpec = describe "views" $ do
  it "draws a chunk in each view under that view's camera, and nothing in one that culls it" $ do
    let chunk = chunkOf noCutoutMarks ChunkWorldFlat [spriteAt h1 (0, 0)]
        layer = WorldLayerWith DepthDisabled [ref 1] []
        far = defaultCamera {cameraPosition = V2 500 0}
        views = [fullView 8 8 [layer], mkView far (fullViewport 8 8) defaultViewSettings [layer], mkView defaultCamera (fullViewport 8 8) defaultViewSettings {settingPixelSnap = True} [layer]]
        oracle =
          newOracle
            OracleInput
              { inputSnapshot = either (error . show) id (validateSnapshotWith (chunksFrom [(ref 1, chunk)]) (Snapshot [offscreenPass noClear views]))
              , inputCutoutMarks = noCutoutMarks
              , inputWindow = Nothing
              , inputOffscreen = Map.singleton offscreenRef unorm8
              , inputTextures = \handle → lookup handle [(h, solid False colour) | (h, colour) ← textures]
              }
    -- The first and third views show it, each over pixel (4, 4); the second, 500 units
    -- away, culls it and draws nothing, and no view draws anywhere else.
    valueAt oracle 4 4 `shouldBe` pixel red
    valueAt oracle 3 4 `shouldBe` Just (px (0, 0, 0, 0))
    valueAt oracle 5 4 `shouldBe` Just (px (0, 0, 0, 0))
  it "shows a chunk that pixel snap moves into a pixel its unsnapped position misses" $ do
    -- With the camera at (4, 4) world and target coordinates agree. A 59.7-wide sprite
    -- whose origin is at -59.5 ends at 0.2, short of the centre of pixel 0 at 0.5;
    -- pixel snap rounds its origin to -59, moving it right by half a pixel, so it ends
    -- at 0.7 and covers that centre. The chunk is kept, not culled, and the pixel shows it.
    let wide = (sprite h1 (-59.5, 0) (59.7, 1)) {instanceSampler = SamplerNearest}
        chunk = chunkOf noCutoutMarks ChunkWorldFlat [wide]
        layer = WorldLayerWith DepthDisabled [ref 1] []
        camera = defaultCamera {cameraPosition = V2 4 4}
        oracleFor snap =
          newOracle
            OracleInput
              { inputSnapshot = either (error . show) id (validateSnapshotWith (chunksFrom [(ref 1, chunk)]) (Snapshot [offscreenPass noClear [mkView camera (fullViewport 8 8) defaultViewSettings {settingPixelSnap = snap} [layer]]]))
              , inputCutoutMarks = noCutoutMarks
              , inputWindow = Nothing
              , inputOffscreen = Map.singleton offscreenRef unorm8
              , inputTextures = \handle → lookup handle [(h, solid False colour) | (h, colour) ← textures]
              }
    valueAt (oracleFor True) 0 0 `shouldBe` pixel red
    valueAt (oracleFor False) 0 0 `shouldBe` Just (px (0, 0, 0, 0))

-- * Inline equivalence

-- | A random small fixture: a kind of layer, chunks of random sprites and
-- dynamic sprites, a camera and settings, and the layer that lists the chunks.
data Fixture = Fixture
  { fixtureKind ∷ ChunkKind
  , fixtureChunks ∷ [[Instance]]
  , fixtureListing ∷ [Int]
  , fixtureDynamic ∷ [Instance]
  , fixtureCamera ∷ Camera
  , fixtureSettings ∷ ViewSettings
  }
  deriving (Show)

fixtureGen ∷ Gen Fixture
fixtureGen = do
  kind ← elements allKinds
  chunks ← resize 3 (listOf (resize 4 (nonEmpty (spriteGen kind))))
  listing ← if null chunks then pure [] else resize 4 (listOf (choose (0, length chunks - 1)))
  dynamic ← resize 4 (listOf (spriteGen kind))
  position ← V2 <$> choose (-6, 6) <*> choose (-6, 6)
  zoom ← elements [1, 2]
  snap ← elements [False, True]
  pure
    Fixture
      { fixtureKind = kind
      , fixtureChunks = chunks
      , fixtureListing = listing
      , fixtureDynamic = dynamic
      , fixtureCamera = Camera position zoom Nothing
      , fixtureSettings = defaultViewSettings {settingPixelSnap = snap}
      }
  where
    nonEmpty gen = (:) <$> gen <*> listOf gen

-- | A sprite of whole-pixel position and size on and around the target, with
-- varied handle, key, tint alpha and flags.
spriteGen ∷ ChunkKind → Gen Instance
spriteGen _ = do
  handle ← elements [h1, h2, h3]
  x ← choose (-8, 8)
  y ← choose (-8, 8)
  w ← choose (1, 3)
  h ← choose (1, 3)
  key ← choose (0, 3)
  alpha ← elements [255, 255, 200]
  flagged ← elements [False, False, True]
  pure ((sprite handle (x, y) (w, h)) {instanceDepthKey = key, instanceTint = Tint 255 255 255 alpha, instanceTranslucent = flagged})

-- | What an expectation is for comparison: its value and tolerance when it is
-- determinate, and that it is not otherwise, since the locations that name an
-- indeterminate instance differ between a chunk's and an inlined one.
shape ∷ Expectation → Either () (Rgba8, Tolerance)
shape = \case
  Expected value tolerance → Right (value, tolerance)
  _ → Left ()

inlineSpec ∷ Spec
inlineSpec = describe "a layer that lists chunks" $
  prop "gives the expectation of the layer that holds the same instances itself in source order, at every pixel" $
    checkCoverage $
      forAll fixtureGen $ \fixture →
      let kind = fixtureKind fixture
          built = [chunkOf allMarked kind instances | instances ← fixtureChunks fixture]
          held = [(ref (fromIntegral index), chunk) | (index, chunk) ← zip [0 ∷ Int ..] built]
          listedChunks = [built !! index | index ← fixtureListing fixture]
          refs = [ref (fromIntegral index) | index ← fixtureListing fixture]
          inlined = concatMap chunkInstances listedChunks <> fixtureDynamic fixture
          withChunks = layerOf kind refs (fixtureDynamic fixture)
          plain = layerOf kind [] inlined
          view layer = mkView (fixtureCamera fixture) (fullViewport 8 8) (fixtureSettings fixture) [layer]
          oracle chunks layer =
            newOracle
              OracleInput
                { inputSnapshot = either (error . show) id (validateSnapshotWith (chunksFrom chunks) (Snapshot [offscreenPass noClear [view layer]]))
                , inputCutoutMarks = allMarked
                , inputWindow = Nothing
                , inputOffscreen = Map.singleton offscreenRef unorm8
                , inputTextures = \handle → lookup handle [(h, solid False colour) | (h, colour) ← textures]
                }
          chunked = oracle held withChunks
          reference = oracle [] plain
          drawn = length [() | x ← [0 .. 7], y ← [0 .. 7], Expected value _ ← [expect reference (Probe 0 x y)], value /= Rgba8 0 0 0 0]
       in cover 40 (drawn > 0) "something is drawn in view" $
            cover 20 (not (null (fixtureListing fixture))) "the layer lists chunks" $
              conjoin
                [ counterexample ("pixel " <> show (x, y)) (shape (expect chunked (Probe 0 x y)) === shape (expect reference (Probe 0 x y)))
                | x ← [0 .. 7]
                , y ← [0 .. 7]
                ]
