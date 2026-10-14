-- | What publication refuses because the snapshot can never be recorded, and what
-- the adapter reports of the rest (GUIDE-1): a depth-enabled world layer where the
-- host gives no window depth, tables larger than the renderer's storage window,
-- and a published scene whose frame needs a region larger than it.
--
-- __Where the expected values come from.__ Never from the code under test. Each
-- size is worked out by hand from the layout and written beside the snapshot
-- that has it: a clip entry is 16 bytes, a record is the words its layout
-- declares, the clip tables of a view come once for each space a layer selects a
-- clip from, and a frame block is a directory of a word for each table rounded up
-- to four, then for each table four header words and four for each frame, on a
-- 16-byte boundary. The same snapshot's region is also read from the recorder's
-- own layout ('recordRegion'), as a cross-check that the bound is the size the
-- recorder writes when every view draws.
module Test.Render.TwoD.Vulkan.Publication (spec) where

import Control.Concurrent.STM (readTVarIO)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording (ImageFormat (..), NativeCommand (..))
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.TwoD.Clip (ClipEntry (..), ClipRect (..))
import Hetoimasia.Render.TwoD.DrawPlan (noCutoutMarks)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord (..), MaterialRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (..), ChunkKind (..), ChunkRef)
import Hetoimasia.Render.TwoD.Validation (Location (..), validateSnapshot)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks (buildRetainedChunkWith)
import Hetoimasia.Render.TwoD.Vulkan.Frame
  ( Attachment (..)
  , FrameInput (..)
  , FrameRefusal (..)
  , frameWork
  , recordRegion
  , regionBound
  , regionBytes
  )
import Hetoimasia.Render.TwoD.Vulkan.Textures
import Hetoimasia.Render.TwoD.Vulkan.Window
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Render.TwoD.Vulkan.Environment
import Test.Render.TwoD.Vulkan.Materials.Layouts (wordsOnlyMaterial)
import Test.Render.TwoD.Vulkan.StandIn

spec ∷ Spec
spec = describe "Publication" $ do
  depthSpec
  boundSpec
  representabilitySpec
  overflowSpec

-- ---------------------------------------------------------------------------
-- Window depth (requirements 1 and 2)

-- | A window snapshot of a UI layer (layer 0) and a depth-enabled world layer
-- (layer 1) in one view of this size.
deepIn ∷ Api.TextureHandle → (Float, Float) → Snapshot
deepIn art extent' =
  Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (uncurry V2 extent')) defaultViewSettings [] [UiLayer [sprite art], WorldLayer DepthEnabled [sprite art]]]]

noDepth ∷ Options
noDepth = defaultOptions {optionWindowDepth = False}

depthSpec ∷ Spec
depthSpec = describe "a host that gives no window depth" $ do
  it "refuses a snapshot holding a depth-enabled world layer, naming the layer, and never reaches the host" $
    withEnvWith noDepth [1] $ \env → do
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (deepIn art (16, 16)) >>= (`shouldBe` Left (WindowDepthMissing (AtLayer 0 0 1)))
      length <$> readTVarIO (fakePublished (envFake env)) >>= (`shouldBe` 0)

  it "refuses it whether or not the layer's view leaves it any pixel: a zero-size viewport is named too" $
    withEnvWith noDepth [1] $ \env → do
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (deepIn art (0, 0)) >>= (`shouldBe` Left (WindowDepthMissing (AtLayer 0 0 1)))
      publish2DSnapshot (envAdapter env) 1 (deepIn art (16, 0)) >>= (`shouldBe` Left (WindowDepthMissing (AtLayer 0 0 1)))
      length <$> readTVarIO (fakePublished (envFake env)) >>= (`shouldBe` 0)

  it "names the first such layer in snapshot order" $
    withEnvWith noDepth [1] $ \env → do
      art ← registered env 1 True DefaultMark
      let view' layers = View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] layers
          snapshot = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [view' [UiLayer [sprite art]], view' [WorldLayer DepthDisabled [sprite art], WorldLayer DepthEnabled [sprite art], WorldLayer DepthEnabled [sprite art]]]]
      publish2DSnapshot (envAdapter env) 1 snapshot >>= (`shouldBe` Left (WindowDepthMissing (AtLayer 0 1 1)))

  it "publishes the same snapshot where the host gives window depth" $
    withEnv [1] $ \env → do
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (deepIn art (16, 16)) >>= (`shouldBe` Right 1)
      publish2DSnapshot (envAdapter env) 1 (deepIn art (0, 0)) >>= (`shouldBe` Right 2)

  it "publishes a snapshot without a depth-enabled world layer either way" $ do
    mapM_
      ( \options → withEnvWith options [1] $ \env → do
          art ← registered env 1 True DefaultMark
          let flat = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] [UiLayer [sprite art], WorldLayer DepthDisabled [sprite art]]]]
          publish2DSnapshot (envAdapter env) 1 flat >>= (`shouldBe` Right 1)
      )
      [defaultOptions, noDepth]

  it "keeps WorldDepthRefused's precedence over a missing window depth" $
    withEnvWith noDepth {optionOffered = [Depth24, Depth16]} [1] $ \env → do
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (deepIn art (16, 16)) >>= (`shouldBe` Left (WorldDepthRefused (AtLayer 0 0 1) (Just Depth24)))

-- ---------------------------------------------------------------------------
-- The tables a snapshot owns (requirement 3)

frameTable ∷ Int → FrameTable
frameTable count = FrameTable count 1 [UvRect (fromIntegral k) 0 (fromIntegral k + 1) 1 | k ← [0 .. count - 1]]

-- | A view of this viewport that selects clips in both spaces, reads records of a
-- material and holds two frame tables: a table of this many clip entries (two of
-- them selected, entry 0 by the world layer and entry 1 by the UI layer, so
-- the space of neither is mixed), this many one-word records, and frame tables of
-- three and two frames.
--
-- Its tables are 'clipCount' entries once for each of the two spaces, 16 bytes
-- each; 'recordCount' words; and a frame block of a directory of four words and
-- records of 16 and 12, so 32 words.
tabledView ∷ ((Float, Float), (Float, Float)) → Int → Int → MaterialRef → Api.TextureHandle → View
tabledView (origin, extent') clipCount recordCount material art =
  ViewWith
    (Camera (V2 0 0) 1 Nothing)
    (Viewport (uncurry V2 origin) (uncurry V2 extent'))
    defaultViewSettings
    [ClipEntry (ClipRect (V2 0 0) (V2 8 8)) Nothing | _ ← [1 .. clipCount]]
    (Map.singleton material (MaterialData [MaterialRecord [] [fromIntegral k] | k ← [1 .. recordCount]] ByteString.empty))
    [frameTable 3, frameTable 2]
    0
    [ WorldLayer DepthDisabled [(sprite art) {instanceClip = 1, instanceFrameTable = 1}]
    , UiLayer [(sprite art) {instanceClip = 2, instanceFrameTable = 2, instanceMaterial = material, instanceParameter = 0}]
    ]

windowOf ∷ [View] → Snapshot
windowOf views = Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) views]

onScreen, offScreen, zeroSize ∷ ((Float, Float), (Float, Float))
onScreen = ((0, 0), (16, 16))
offScreen = ((1000, 1000), (16, 16))
zeroSize = ((0, 0), (0, 0))

-- | An environment whose storage window is this many bytes.
windowed ∷ Integer → Options
windowed bytes = defaultOptions {optionStorageWindow = bytes}

-- | The region the recorder writes for this snapshot under a 16 by 16 target with
-- metrics of this logical extent and content scale, read from its own layout.
recordedRegion ∷ Snapshot → (Word32, Word32) → (Word32, Word32) → Float → IO Int
recordedRegion snapshot (width, height) (logicalWidth, logicalHeight) scale = do
  valid ← either (fail . show) pure (validateSnapshot snapshot)
  let metrics = TargetMetrics (PixelExtent (fromIntegral logicalWidth) (fromIntegral logicalHeight)) (PixelExtent (fromIntegral width) (fromIntegral height)) scale scale
  case frameWork (FrameInput valid noCutoutMarks (const Nothing) (Just (Attachment 50 width height metrics)) Nothing (const Nothing) Set.empty) of
    Right passes → pure (maybe 0 (ByteString.length . regionBytes) (recordRegion passes))
    Left refusal → fail ("the frame was refused: " <> show refusal)

-- | Whether the renderer prepares the snapshot for a frame of this target and
-- metrics, which it does only when the clip tables and the whole region are
-- within its window.
prepares ∷ Env → Snapshot → (Word32, Word32) → (Word32, Word32) → Float → IO (Either FrameRefusal ())
prepares env snapshot (width, height) (logicalWidth, logicalHeight) scale = do
  valid ← either (fail . show) pure (validateSnapshot snapshot)
  let metrics = TargetMetrics (PixelExtent (fromIntegral logicalWidth) (fromIntegral logicalHeight)) (PixelExtent (fromIntegral width) (fromIntegral height)) scale scale
  fmap (const ()) <$> Render.prepareSnapshot (builders (envRig env)) (envRenderer env) (FrameInput valid noCutoutMarks (const Nothing) (Just (Attachment 50 width height metrics)) Nothing (const Nothing) Set.empty)

boundSpec ∷ Spec
boundSpec = describe "the tables a snapshot owns" $ do
  -- One view: 100 clip entries in each of two spaces (200 × 16 = 3200 bytes, 800
  -- words), 10 one-word records (10 words) so the frame block is asked for at word
  -- 810 and begins at 812, two words of padding, and is 32 words: 844 words, 3376
  -- bytes.
  let one material art = windowOf [tabledView onScreen 100 10 material art]

  it "is counted with every header, directory word and pad, and is the size the recorder writes when every view draws" $
    withEnvWith (windowed 3376) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      recordedRegion (one material art) (16, 16) (16, 16) 1 >>= (`shouldBe` 3376)
      publish2DSnapshot (envAdapter env) 1 (one material art) >>= (`shouldBe` Right 1)

  it "refuses a snapshot one byte over the window, naming the exact size and the window, and publishes nothing" $
    withEnvWith (windowed 3375) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (one material art) >>= (`shouldBe` Left (TablesTooLarge 3376 3375))
      length <$> readTVarIO (fakePublished (envFake env)) >>= (`shouldBe` 0)

  it "is sensitive to the padding before the frame block: nine to twelve records end at word 844, thirteen at 848" $ do
    mapM_
      ( \(records, bytes) → withEnvWith (windowed bytes) [1] $ \env → do
          material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
          art ← registered env 1 True DefaultMark
          let snapshot = windowOf [tabledView onScreen 100 records material art]
          recordedRegion snapshot (16, 16) (16, 16) 1 >>= (`shouldBe` fromIntegral bytes)
          publish2DSnapshot (envAdapter env) 1 snapshot >>= (`shouldBe` Right 1)
      )
      [(9, 3376), (10, 3376), (11, 3376), (12, 3376), (13, 3392)]
    withEnvWith (windowed 3376) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (windowOf [tabledView onScreen 100 13 material art]) >>= (`shouldBe` Left (TablesTooLarge 3392 3376))

  it "records a snapshot just inside the window under every metrics tried, with neither ClipTablesTooLarge nor RecordsTooLarge" $
    withEnvWith (windowed 3376) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      let snapshot = one material art
      publish2DSnapshot (envAdapter env) 1 snapshot >>= (`shouldBe` Right 1)
      answers ←
        mapM
          (\(extent', logical, scale) → prepares env snapshot extent' logical scale)
          [ ((16, 16), (16, 16), 1)
          , ((32, 32), (16, 16), 2)
          , ((64, 64), (16, 16), 4)
          , ((8, 8), (8, 8), 1)
          , ((4, 4), (8, 8), 0.5)
          , ((640, 480), (320, 240), 2)
          , ((1, 1), (1, 1), 1)
          ]
      answers `shouldBe` replicate 7 (Right ())
      -- However little of it a frame draws, its region is no larger than the bound.
      regions ← mapM (\(extent', logical, scale) → recordedRegion snapshot extent' logical scale) [((16, 16), (16, 16), 1), ((8, 8), (16, 16), 0.5), ((4, 4), (16, 16), 0.25), ((640, 480), (320, 240), 2)]
      regions `shouldSatisfy` all (<= 3376)

  it "counts every view that has a run as if it drew: a view wholly off the target adds its tables" $ do
    -- Two views of 3376 bytes' tables each: 400 clip entries (1600 words), two
    -- tables of ten records (20 words), then two blocks of 32 words from word 1620.
    withEnvWith (windowed 6736) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      let both = windowOf [tabledView onScreen 100 10 material art, tabledView offScreen 100 10 material art]
      publish2DSnapshot (envAdapter env) 1 both >>= (`shouldBe` Right 1)
      -- A frame that draws only the first view writes only its tables.
      recordedRegion both (16, 16) (16, 16) 1 >>= (`shouldBe` 3376)
      prepares env both (16, 16) (16, 16) 1 >>= (`shouldBe` Right ())
    withEnvWith (windowed 6735) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (windowOf [tabledView onScreen 100 10 material art, tabledView offScreen 100 10 material art])
        >>= (`shouldBe` Left (TablesTooLarge 6736 6735))
    withEnvWith (windowed 3376) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (windowOf [tabledView onScreen 100 10 material art, tabledView offScreen 100 10 material art])
        >>= (`shouldBe` Left (TablesTooLarge 6736 3376))

  it "counts nothing for a view that can never draw, a zero-size viewport, however large its tables" $
    withEnvWith (windowed 3376) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (windowOf [tabledView onScreen 100 10 material art, tabledView zeroSize 5000 500 material art]) >>= (`shouldBe` Right 1)

  it "counts a single zero clip entry for a snapshot that draws but selects no clip, and nothing for one that cannot draw" $ do
    let plain art = windowOf [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] [UiLayer [sprite art]]]
        nothing art = windowOf [View (Camera (V2 0 0) 1 Nothing) (Viewport (V2 0 0) (V2 0 0)) defaultViewSettings [] [UiLayer [sprite art]]]
    withEnvWith (windowed 16) [1] $ \env → do
      art ← registered env 1 True DefaultMark
      recordedRegion (plain art) (16, 16) (16, 16) 1 >>= (`shouldBe` 16)
      publish2DSnapshot (envAdapter env) 1 (plain art) >>= (`shouldBe` Right 1)
    withEnvWith (windowed 15) [1] $ \env → do
      art ← registered env 1 True DefaultMark
      publish2DSnapshot (envAdapter env) 1 (plain art) >>= (`shouldBe` Left (TablesTooLarge 16 15))
      publish2DSnapshot (envAdapter env) 1 (nothing art) >>= (`shouldBe` Right 1)

  it "leaves a chunk's records out of the bound, which depend on the frame" $
    withEnvWith (windowed 16) [1] $ \env → do
      material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
      art ← registered env 1 True DefaultMark
      marks ← registeredMarks (envTextures env)
      reference ←
        buildRetainedChunkWith (builders (envRig env)) (envRetained env) marks ChunkWorldFlat DeriveBounds (Map.fromList [(material, [MaterialRecord [] [fromIntegral k] | k ← [1 .. 100 ∷ Int]])]) [recorded art material 0]
          >>= either (fail . show) pure
      -- 400 bytes of records beside the 16 of the fallback entry: far over a 16-byte window, yet published.
      publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (0, 0)) >>= (`shouldBe` Right 1)

-- | The pure arithmetic, from counts, so that its boundaries are reached without
-- allocating what they would hold.
representabilitySpec ∷ Spec
representabilitySpec = describe "sizes and offsets that cannot be represented" $ do
  let limit = 2 ^ (32 ∷ Int) - 1 ∷ Integer
  it "accepts the largest block whose end is the last word of the 32-bit range, and refuses one more frame, with the exact size" $ do
    -- From word 0 the directory is 4 words and the record 4 + 4 count: the end is 8 + 4 count.
    regionBound 0 [(0, 0, [1073741821])] `shouldBe` Right (4 * (8 + 4 * 1073741821))
    regionBound 0 [(0, 0, [1073741822])] `shouldBe` Left (0, 0, 4 * (8 + 4 * 1073741822))
    (regionBound 0 [(0, 0, [1073741822])] == Left (0, 0, 17179869184)) `shouldBe` True

  it "refuses a count below one or above the 32-bit range, whatever the offset, naming the view" $ do
    regionBound 0 [(0, 0, [0])] `shouldBe` Left (0, 0, 4 * 8)
    regionBound 0 [(0, 0, [1]), (2, 5, [limit + 1])] `shouldBe` Left (2, 5, 4 * (8 + 4 * (limit + 1)))

  it "refuses an offset that passes the range once the earlier blocks and the records are counted, and not before" $ do
    -- 2³² − 8 words before a block of one frame (directory 4, record 8): the end is 2³² + 4.
    regionBound (limit - 7) [(0, 0, [1])] `shouldBe` Left (0, 0, 4 * 12)
    regionBound (limit - 15) [(0, 0, [1])] `shouldBe` Right (4 * (limit - 15 + 12))
    -- The second block starts where the first ends: both fit from 2³² − 28, only the first from 2³² − 24.
    regionBound (limit - 27) [(0, 0, [1]), (0, 1, [1])] `shouldBe` Right (4 * (limit - 3))
    regionBound (limit - 23) [(0, 0, [1]), (0, 1, [1])] `shouldBe` Left (0, 1, 4 * 12)

  it "carries a size larger than any Word64 exactly into the refusal, never narrowed" $ do
    let huge = 2 ^ (70 ∷ Int) ∷ Integer
    tablesRefusal maxBound (Right huge) `shouldBe` Just (TablesTooLarge huge maxBound)
    tablesRefusal 100 (Right 100) `shouldBe` Nothing
    tablesRefusal 100 (Right 101) `shouldBe` Just (TablesTooLarge 101 100)
    tablesRefusal 100 (Left (3, 4, huge)) `shouldBe` Just (FrameTablesNotRepresentableInSnapshot 3 4 huge)

-- ---------------------------------------------------------------------------
-- The remainder that depends on the frame (requirement 4)

-- | A chunk instance that reads this record of the material.
recorded ∷ Api.TextureHandle → MaterialRef → Word32 → Instance
recorded art material parameter = (sprite art) {instanceMaterial = material, instanceParameter = parameter}

-- | A snapshot of one flat world layer listing the chunk, seen by a camera at this
-- point: at the origin the chunk is in view, far away it is culled.
chunkSnapshot ∷ ChunkRef → (Float, Float) → Snapshot
chunkSnapshot reference (x, y) =
  Snapshot [Pass WindowTarget (ClearColour 0 0 0 1) [View (Camera (V2 x y) 1 Nothing) (Viewport (V2 0 0) (V2 16 16)) defaultViewSettings [] [WorldLayerWith DepthDisabled [reference] []]]]

overflowSpec ∷ Spec
overflowSpec = describe "a published scene whose frame needs a region larger than the storage window" $ do
  let info revision = FrameInfo (64, 64) 50 (Just (32, 32)) (Just (2, 2)) Nothing revision
      renderIn env window frame scene = windowFrameOnce (envRig env) (renderWindowFrame (envAdapter env) (builders (envRig env)) window frame scene)
      sceneAt env window revision = do
        published ← readTVarIO (fakePublished (envFake env))
        case [scene | (w, r, scene) ← published, w == window, r == revision] of
          scene : _ → pure scene
          [] → fail ("revision " <> show revision <> " of window " <> show window <> " was never published")
      -- A hundred one-word records of the material, 400 bytes, beside the 16 of the
      -- fallback clip entry: 416 bytes of region while the chunk is in view.
      chunkIn' env = do
        material ← Render.registerMaterial (envRenderer env) wordsOnlyMaterial
        art ← registered env 1 True DefaultMark
        marks ← registeredMarks (envTextures env)
        reference ←
          buildRetainedChunkWith (builders (envRig env)) (envRetained env) marks ChunkWorldFlat DeriveBounds (Map.fromList [(material, [MaterialRecord [] [fromIntegral k] | k ← [1 .. 100 ∷ Int]])]) [recorded art material 0, recorded art material 99]
            >>= either (fail . show) pure
        settleUploads (envRig env)
        pure reference
      overflowing = (windowed 256) {optionWindowed = True}
      observed env window = regionOverflow (envAdapter env) window

  it "refuses its frame as it does now, records nothing, and names the revision, the region and the window for the application" $
    withEnvWith overflowing [1] $ \env → do
      reference ← chunkIn' env
      revision ← publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (0, 0)) >>= either (fail . show) pure
      adopt env 1 revision
      scene ← sceneAt env 1 revision
      resetJournal (envRig env)
      answer ← renderIn env 1 (info revision) scene
      case answer of
        Left _ → pure ()
        Right () → expectationFailure "the frame was recorded"
      observed env 1 >>= (`shouldBe` Just (RegionOverflow revision 416 256))
      -- Nothing was drawn.
      commandsRecorded (envRig env) >>= (`shouldSatisfy` (not . any isDraw))
      ringOffsets (envRig env) >>= (`shouldBe` [])

  it "clears the observation when a later frame of the window records, after a publication that culls the chunk" $
    withEnvWith overflowing [1] $ \env → do
      reference ← chunkIn' env
      first ← publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (0, 0)) >>= either (fail . show) pure
      adopt env 1 first
      firstScene ← sceneAt env 1 first
      _ ← renderIn env 1 (info first) firstScene
      observed env 1 >>= (`shouldBe` Just (RegionOverflow first 416 256))
      -- Publishing and adopting leave it as it was.
      second ← publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (90000, 0)) >>= either (fail . show) pure
      adopt env 1 second
      observed env 1 >>= (`shouldBe` Just (RegionOverflow first 416 256))
      secondScene ← sceneAt env 1 second
      renderIn env 1 (info second) secondScene >>= (`shouldBe` Right ())
      observed env 1 >>= (`shouldBe` Nothing)

  it "leaves the observation through a refusal of another kind, and through the window's other revisions" $
    withEnvWith overflowing [1] $ \env → do
      reference ← chunkIn' env
      first ← publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (0, 0)) >>= either (fail . show) pure
      adopt env 1 first
      scene ← sceneAt env 1 first
      _ ← renderIn env 1 (info first) scene
      -- A frame whose request names no logical extent is refused for that reason alone.
      renderIn env 1 ((info first) {frameLogical = Nothing}) scene >>= (`shouldSatisfy` either (const True) (const False))
      observed env 1 >>= (`shouldBe` Just (RegionOverflow first 416 256))

  it "keeps one window's observation when another window's frame records" $
    withEnvWith overflowing [1, 2] $ \env → do
      reference ← chunkIn' env
      near ← publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (0, 0)) >>= either (fail . show) pure
      far ← publish2DSnapshot (envAdapter env) 2 (chunkSnapshot reference (90000, 0)) >>= either (fail . show) pure
      adopt env 1 near
      adopt env 2 far
      nearScene ← sceneAt env 1 near
      farScene ← sceneAt env 2 far
      _ ← renderIn env 1 (info near) nearScene
      renderIn env 2 (info far) farScene >>= (`shouldBe` Right ())
      (,) <$> observed env 1 <*> observed env 2 >>= (`shouldBe` (Just (RegionOverflow near 416 256), Nothing))
      -- Another window's overflow is its own.
      _ ← renderIn env 2 (info far) nearScene
      (,) <$> observed env 1 <*> observed env 2 >>= (`shouldBe` (Just (RegionOverflow near 416 256), Just (RegionOverflow far 416 256)))

  it "drops a window's observation when the host reports its last revision released, and not before" $
    withEnvWith overflowing [1] $ \env → do
      reference ← chunkIn' env
      first ← publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (0, 0)) >>= either (fail . show) pure
      adopt env 1 first
      scene ← sceneAt env 1 first
      _ ← renderIn env 1 (info first) scene
      second ← publish2DSnapshot (envAdapter env) 1 (chunkSnapshot reference (90000, 0)) >>= either (fail . show) pure
      adopt env 1 second
      releaseRevision env 1 first
      observed env 1 >>= (`shouldBe` Just (RegionOverflow first 416 256))
      releaseRevision env 1 second
      observed env 1 >>= (`shouldBe` Nothing)

  where
    isDraw = \case
      CommandDraw {} → True
      _ → False
