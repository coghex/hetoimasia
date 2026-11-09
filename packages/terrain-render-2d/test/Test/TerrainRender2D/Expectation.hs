-- | TRA-17: the independent hand model of "Hetoimasia.Terrain.Render2D.Evidence" agrees with the
-- planner and the picker, pixel by pixel, over the named scenes.
--
-- The model states the cell-quad contract by hand (geometry, texel classification from the
-- independently decoded source images, painter order, lighting), sharing no code with the planner,
-- its keys, the picker, the atlas adaptation or the material. Here its frontmost covered quad at
-- every pixel it can decide is compared with what the picker finds, for every shape in every
-- facing, roofs and cavities, disconnected spans, ramps and corners, cutaways, and mixed and fog
-- cells. A pixel the model calls ambiguous (within 1/1000 texel of a texel threshold or a canvas edge) is counted and
-- never compared; a scene whose compared or covered count is zero fails, so no scene passes
-- without judging anything.
module Test.TerrainRender2D.Expectation (spec) where

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
    forM_ scenes $ \scene → do
      verdict ← judge manifest assets art scene
      (sceneName scene, jMismatches verdict) `shouldBe` (sceneName scene, [])
      (sceneName scene, jCompared verdict > 0, jCovered verdict > 0) `shouldBe` (sceneName scene, True, True)
  it "decides most pixels: ambiguity is a thin band at texel boundaries, not the common case" $ do
    (manifest, assets, art) ← setupAll
    verdict ← judge manifest assets art (shapeMatrix FaceSouth 1)
    (jAmbiguous verdict * 5 < jCompared verdict + jAmbiguous verdict) `shouldBe` True
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

judge ∷ AtlasManifest → AssetSnapshot → ArtSource → Scene → IO Judged
judge _ assets art scene = do
  plan ← either (\e → fail ("plan refused: " <> show e)) pure (scenePlan assets scene)
  let camera = sceneCameraFollowed scene
      (w, h) = sceneTarget scene
      pixels = [(x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
      step acc pixel = case expectedAt art defaultHandLight scene camera plan pixel of
        Ambiguous _ → acc {jAmbiguous = jAmbiguous acc + 1}
        expected →
          let found = pickPixel plan pixel
              problem = disagreement expected found
              covered = case expected of ExpectedHit {} → 1; _ → 0
           in acc
                { jCompared = jCompared acc + 1
                , jCovered = jCovered acc + covered
                , jMismatches = take 6 (jMismatches acc <> [show pixel <> ": " <> why | Just why ← [problem]])
                }
  pure (foldl' step (Judged 0 0 0 []) pixels)

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
