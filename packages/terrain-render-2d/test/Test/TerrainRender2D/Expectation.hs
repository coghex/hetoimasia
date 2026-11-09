-- | TRA-17: the independent hand model of "Hetoimasia.Terrain.Render2D.Evidence" agrees with the
-- planner and the picker, pixel by pixel, over the named scenes.
--
-- The model states the cell-quad contract by hand (geometry, texel classification from the
-- independently decoded source images, painter order, lighting), sharing no code with the planner,
-- its keys, the picker, the atlas adaptation or the material. Here its frontmost covered quad at
-- every pixel it can decide is compared with what the picker finds, for every shape in every
-- facing, roofs and cavities, disconnected spans, ramps and corners, cutaways, and mixed and fog
-- cells. Every pixel is compared, exactly; a pixel the device would be allowed to read differently
-- (an unsnapped scene within 1/1000 texel of an interior threshold) is only counted as banded; a scene whose compared or covered count is zero fails, so no scene passes
-- without judging anything.
module Test.TerrainRender2D.Expectation (spec, setupAll) where

import Control.Monad (forM, forM_)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Atlas.Manifest (AtlasManifest, findRegion, regionSourcePath)
import Hetoimasia.Terrain.Cell (mkMaterialId)
import Hetoimasia.Terrain.Render2D.Assets (AssetSnapshot)
import Hetoimasia.Terrain.Render2D.AtlasAssets (atlasAssetSnapshot)
import Hetoimasia.Terrain.Render2D.CellPick (CellHit (..), CellPickResult (..))
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Scenes
import Hetoimasia.Terrain.MapGen.Png (decodeRgba)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Test.Hspec
import Test.TerrainRender2D.Art (loadFile)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), holedStyle, loadAtlasStyle)
import Test.TerrainRender2D.CellFixtures (loadAtlasParents, pickPixel)
import Test.TerrainRender2D.Fixtures (tileAt)

spec ∷ Spec
spec = describe "Expectation" $ do
  it "agrees with the picker for every shape in every facing, roofs, spans, ramps, cutaways, mixed and fog cells" $ do
    (manifest, assets, art) ← setupAll
    let scenes =
          [shapeMatrix facing 1 | facing ← facings]
            <> [roofOverCavity cut facing | cut ← [1, 2], facing ← [FaceSouth, FaceEast]]
            <> [disconnectedSpans facing | facing ← [FaceSouth, FaceNorth]]
            <> [rampsCorners facing | facing ← facings]
            <> [staircase cut facing | cut ← [0, 2], facing ← [FaceSouth, FaceWest]]
            <> [mixedScene facing | facing ← facings]
            -- Pixel centres exactly on a quad's edges and shared diagonal, and snapped scenes at the
            -- fractional scales: the picker agrees with the exact hand model at every pixel.
            <> [edgeScene zoom shape facing | (zoom, shape, facing) ← [(0.125, 0, FaceSouth), (0.125, 15, FaceEast), (0.5, 0, FaceSouth), (0.5, 9, FaceWest), (1, 0, FaceSouth), (1, 5, FaceNorth)]]
            <> [snapped {sceneName = "snapped@1", sceneZoom = 1}]
            <> [snappedAt (show zoom) zoom | zoom ← [0.125, 1.125, 1.25, 7.875, 8]]
            -- Seams across the region lattice, the zero seam and the legal coordinate extremes.
            <> [pendingScene facing | facing ← facings]
            -- Every applicable mixed known/fog map in every facing, and full fog.
            <> [atZoom 0.25 (mixedShapeCell shape facing) | shape ← [1 .. 15], facing ← facings]
            <> [fogShapes facing | facing ← facings]
            <> [seamScene facing | facing ← facings]
            <> [seamScenesNegative facing | facing ← facings]
            <> [extremeScene high facing | high ← [True, False], facing ← [FaceSouth, FaceWest]]
    forM_ scenes $ \scene → do
      verdict ← judge manifest assets art scene
      (sceneName scene, jMismatches verdict) `shouldBe` (sceneName scene, [])
      (sceneName scene, jCompared verdict > 0, jCovered verdict > 0) `shouldBe` (sceneName scene, True, True)
  it "picks and models colour-alpha holes independently of the map's holes, and the holes change the answer" $ do
    (manifest, assets, art) ← setupAll
    style ← loadAtlasStyle 7 [("loam", "colour.loam"), ("granite", "colour.granite")]
    holed ← either fail pure (holedStyle style)
    let scenes = [shapeMatrix FaceSouth 1, rampsCorners FaceSouth, rampsCorners FaceEast, mixedScene FaceSouth]
    forM_ scenes $ \scene → do
      verdict ← judge manifest (styleAssets holed) (styleArt holed) scene
      (sceneName scene, jMismatches verdict) `shouldBe` (sceneName scene, [])
      jCovered verdict `shouldSatisfy` (> 0)
      -- Where the colour art has a hole the map does not, a pixel that the plain art draws is not drawn.
      plan ← either (\e → fail (show e)) pure (scenePlan assets scene)
      holedPlan ← either (\e → fail (show e)) pure (scenePlan (styleAssets holed) scene)
      let camera = sceneCameraFollowed scene
          (w, h) = sceneTarget scene
          differing =
            length
              [ ()
              | y ← [0 .. h - 1], x ← [0 .. w - 1]
              , let plain = expectedAt art defaultHandLight scene camera plan (x, y)
                    withHoles = expectedAt (styleArt holed) defaultHandLight scene camera holedPlan (x, y)
              , plain /= withHoles
              ]
      differing `shouldSatisfy` (> 50)
  it "sets the device's undecided band from the vertex quantisation and exempts only unsnapped scenes with an off-grid vertex" $ do
    (_, assets, _) ← setupAll
    -- delta = 2^-(b+1) / s + 1/1000 texel, with s the pass's ACTUAL view scale (its world transform):
    -- at scale 3/16 and b = 4 it is 1/6 + 1/1000.
    let band bits scene = do
          plan ← either (\e → fail (show e)) pure (scenePlan assets scene)
          pure (undecidedBand bits plan)
    band 4 (atZoom 0.1875 (rampsCorners FaceSouth)) >>= (`shouldBe` (1 / 6 + 1 / 1000))
    band 4 (snappedAt "8" 8) >>= (`shouldBe` (1 / 256 + 1 / 1000))
    band 8 (atZoom 0.5 (rampsCorners FaceSouth)) >>= (`shouldBe` (1 / 256 + 1 / 1000))
    -- A non-unit content scale changes the window-to-target conversion, not the world transform: the scale
    -- of a pass at zoom 1/8 and content scale 2 is 1/8, so delta at b = 8 is 0.016625, not the 0.0088125 a
    -- zoom-times-content-scale product would give.
    band 8 scaledTarget {sceneZoom = 0.125} >>= (`shouldBe` (1 / 512 / (1 / 8) + 1 / 1000))
    -- At zoom 1 and content scale 2 the world scale is 1, not 2: delta = 2^-9 + 1/1000.
    band 8 scaledTarget >>= (`shouldBe` (1 / 512 + 1 / 1000))
    -- An eligible pass has an established margin even when the viewport is offset from the corner.
    offsetPlan ← either (\e → fail (show e)) pure (scenePlan assets (viewportOffset 0.125))
    case rasterMargin 8 (viewportOffset 0.125) (sceneCameraFollowed (viewportOffset 0.125)) offsetPlan of
      Margin _ _ → pure ()
      other → expectationFailure ("the offset-viewport pass has no established raster margin: " <> (case other of NotEligible → "not eligible"; _ → "uncomputable"))
    let eligible bits scene = do
          plan ← either (\e → fail (show e)) pure (scenePlan assets scene)
          pure (deviceEligible bits scene (sceneCameraFollowed scene) plan)
    -- Eligible: an unsnapped scene whose vertices are off the 2^-b pixel grid (a fractional pan or scale).
    eligible 4 (atZoom 0.1875 (rampsCorners FaceSouth)) >>= (`shouldBe` True)
    eligible 4 (atZoom 0.125 (rampsCorners FaceEast)) >>= (`shouldBe` True)
    -- Fully decided: snapped scenes, and scenes whose every vertex is on the grid (whole or half pixels).
    mapM_ (\sc → eligible 4 sc >>= (`shouldBe` False)) [snappedAt "9-8" 1.125, snappedAt "63-8" 7.875, snappedAt "8" 8]
    mapM_ (\(zoom, shape, facing) → eligible 4 (edgeScene zoom shape facing) >>= (`shouldBe` False)) [(0.125, 0, FaceSouth), (0.5, 0, FaceSouth), (1, 5, FaceNorth)]
  it "answers loading exactly where a pending cell could lie in front, and not where it is proved behind" $ do
    (manifest, assets, art) ← setupAll
    verdicts ← forM facings $ \facing → judge manifest assets art (pendingScene facing)
    forM_ verdicts $ \verdict → do
      jMismatches verdict `shouldBe` []
      jLoading verdict `shouldSatisfy` (> 0)
  it "decides most pixels: ambiguity is a thin band at texel boundaries, not the common case" $ do
    (manifest, assets, art) ← setupAll
    verdict ← judge manifest assets art (shapeMatrix FaceSouth 1)
    (jAmbiguous verdict * 5 < jCompared verdict) `shouldBe` True
  where
    facings = [FaceSouth, FaceWest, FaceNorth, FaceEast]

-- | Cells of fog and of a known solid beside an undiscovered void, in a row with ordinary ones.
mixedScene ∷ ViewFacing → Scene
mixedScene facing =
  fitScene 8 $
    (newScene ("mixed-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneAnchor = (1, 1)
      , sceneKnow = [((0, 0, 0), KnownSolid), ((2, 0, 0), Undisc), ((1, 2, 0), KnownSolid)]
      , sceneFogOnly = [(3, 1, 0)]
      }
  where
    cells = [Cell 0 0 0 1 5 "loam", Cell 1 0 0 1 9 "granite", Cell 2 0 0 1 3 "loam", Cell 1 2 0 1 12 "granite", Cell 1 1 0 1 0 "loam"]

data Judged = Judged
  { jCompared ∷ !Int
  , jAmbiguous ∷ !Int
  , jCovered ∷ !Int
  , jLoading ∷ !Int
  , jMismatches ∷ ![String]
  }

setupAll ∷ IO (AtlasManifest, AssetSnapshot, ArtSource)
setupAll = do
  (manifest, colour, normal) ← loadAtlasParents 7
  loam ← either (fail . show) pure (mkMaterialId "loam")
  granite ← either (fail . show) pure (mkMaterialId "granite")
  assets ← either (fail . show) pure (atlasAssetSnapshot 7 manifest colour normal [(loam, "colour.loam"), (granite, "colour.granite")])
  art ← loadArt manifest
  pure (manifest, assets, art)

-- | The independently decoded source canvases, by the identifiers the model uses.
loadArt ∷ AtlasManifest → IO ArtSource
loadArt manifest = do
  let load identity = case findRegion manifest identity of
        Nothing → fail ("no region " <> identity)
        Just (_, region) → do
          bytes ← loadFile (regionSourcePath region)
          either (\why → fail (identity <> ": " <> why)) (\(_, _, texels) → pure texels) (decodeRgba bytes)
      colourIds = [("loam", "colour.loam"), ("granite", "colour.granite"), ("blanktexture", "colour.blanktexture")]
  colours ← forM colourIds $ \(name, identity) → (,) name <$> load identity
  maps ← forM mapIdentifiers $ \identity → (,) identity <$> load identity
  let colourMap = Map.fromList colours
      mapMap = Map.fromList maps
      texelOf canvases name x y = case Map.lookup name canvases of
        Nothing → (0, 0, 0, 0)
        Just bytes →
          let base = 4 * (y * 96 + x)
              at i = ByteString.index bytes (base + i)
           in (at 0, at 1, at 2, at 3)
  pure ArtSource {artColour = texelOf colourMap, artMap = texelOf mapMap}

mapIdentifiers ∷ [String]
mapIdentifiers =
  ["shape." <> two n | n ← [0 .. 15 ∷ Int]]
    <> concat [["mixed." <> two n <> ".known", "mixed." <> two n <> ".fog"] | n ← [1 .. 15 ∷ Int]]
  where
    two n = (if n < 10 then "0" else "") <> show n

-- | The sub-pixel precision bits this CPU check assumes only to COUNT the pixels the device's band would
-- leave undecided; the device scenario queries the real value and never uses this.
testSubPixelBits ∷ Int
testSubPixelBits = 4

judge ∷ AtlasManifest → AssetSnapshot → ArtSource → Scene → IO Judged
judge _ assets art scene = do
  plan ← either (\e → fail ("plan refused: " <> show e)) pure (scenePlan assets scene)
  let camera = sceneCameraFollowed scene
      (w, h) = sceneTarget scene
      pixels = [(x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
      -- The pure picker is compared with the exact expectation at EVERY pixel, including those the
      -- device's own exemption ('expectedForDevice') would leave undecided; those are only counted.
      step acc pixel =
        let expected = expectedAt art defaultHandLight scene camera plan pixel
            found = pickPixel plan pixel
            loading = loadingAt art defaultHandLight scene camera plan pixel
            problem = case loading of
              Just True → if found == CellPickLoading then Nothing else Just ("expected loading but " <> show found)
              Just False → disagreement expected found
              Nothing → Nothing
            covered = case expected of ExpectedHit {} → 1; _ → 0
            banded = case expectedForDevice testSubPixelBits 3 art defaultHandLight scene camera plan pixel of Ambiguous _ → 1; _ → 0
         in acc
              { jCompared = jCompared acc + 1
              , jAmbiguous = jAmbiguous acc + banded
              , jCovered = jCovered acc + covered
              , jLoading = jLoading acc + (if loading == Just True then 1 else 0)
              , jMismatches = take 6 (jMismatches acc <> [show pixel <> ": " <> why | Just why ← [problem]])
              }
  pure (foldl' step (Judged 0 0 0 0 []) pixels)

-- | Why the model and the picker disagree at a pixel, if they do.
disagreement ∷ Expected → CellPickResult → Maybe String
disagreement expected found = case (expected, found) of
  (ExpectedClear, CellPickNoHit) → Nothing
  (ExpectedHit {expectedFront = q}, _)
    | hqRole q `elem` [FullFog, MixedFog] → if found == CellPickNoHit then Nothing else Just ("fog " <> show (hqCell q) <> " but " <> short found)
    | otherwise → case found of
        CellPickHit hit
          | hitCell hit == tileOf (hqCell q) && hitPart hit == partOf (hqRole q) → Nothing
        _ → Just ("expected " <> show (hqRole q) <> " " <> show (hqCell q) <> " but " <> short found)
  _ → Just ("expected " <> show expected <> " but " <> short found)
  where
    tileOf (x, y, z) = tileAt x y z
    partOf = \case
      MixedKnown → PartKnown
      _ → PartOrdinary
    short = \case
      CellPickHit hit → "hit " <> show (hitCell hit) <> " " <> show (hitPart hit)
      other → show other
