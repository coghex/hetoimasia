-- | Scenes, assets and an independent visibility oracle for the cell-quad
-- planner and picker (TRA-16).
--
-- Everything here is built from the public terrain, camera and cell interfaces.
-- The oracle is the important part: it classifies a render-world point by casting
-- an exact ray through the shared terrain solids (the cells' presentation
-- volumes), with its own facing rotation and its own mixed-cell rule. It shares
-- no code with the planner or the picker: it never projects a quad, never
-- orders by a sort key and never reads a coverage plane.
module Test.TerrainRender2D.CellFixtures
  ( -- * Assets
    loadAssets
  , loadAssetsWith
  , loadAssetsExtra
  , loadAtlasParents
  , loadAtlasAssets
  , planeFromFormula
  , wholeImageView
  , stoneId
  , soilId
  , catalogPlane

    -- * Scenes
  , Know (..)
  , OCell (..)
  , Scene (..)
  , sceneOf
  , sceneOfAt
  , sourceOf
  , stateOf
  , sceneFrom
  , knowledgeOf
  , camera0
  , inputsOf
  , planScene
  , planSceneWith
  , viewport
  , pickPixel
  , pickPixelRaw
  , allPixels
  , stridePixels

    -- * The oracle
  , OResult (..)
  , oracleAt
  , oracleHits
  , turn
  , oracleAtPixel
  , pixelWorld
  , stableOracleAtPixel
  , turnsOf
  , expectedViewShape
  ) where

import Control.Monad (forM)
import qualified Data.ByteString as ByteString
import Data.List (minimumBy, sortOn)
import Data.Ord (comparing)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, NormalEncoding (..), buildBinaryCoverage)
import Hetoimasia.Asset.Image.Region (RegionView, fullImageView)
import Hetoimasia.Terrain.Atlas.Manifest (AtlasManifest)
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), loadAtlasStyle)
import Hetoimasia.Terrain.Render2D.AtlasAssets (ParentAtlas (..), atlasAssetSnapshot)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (targetToWorld)
import Hetoimasia.Terrain.Cell (Column (..), MaterialId, mkMaterialId)
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Geometry (V3 (..), castRay, hitParameter, mkRay, shapeSolid)
import Hetoimasia.Terrain.MapBake.Catalog (catalogKeys, mapFileName)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.CellPick
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..), rvMapping)
import Hetoimasia.Terrain.Shape
  ( ShapeId
  , Side (..)
  , ViewFacing (..)
  , mkShapeId
  , shapeFromSides
  , shapeSides
  , viewShape
  )
import Hetoimasia.Terrain.MapGen.Png (decodeRgba)
import Hetoimasia.Terrain.Source
import System.FilePath ((</>))
import Test.TerrainRender2D.Art (loadFile, texturesDirectory)
import Test.TerrainRender2D.Fixtures (axis, factsOf, flatWorld, manualCamera, setup, source, tileAt)

-- ---------------------------------------------------------------------------
-- Assets

stoneId, soilId ∷ MaterialId
stoneId = either (error . show) id (mkMaterialId "stone")
soilId = either (error . show) id (mkMaterialId "soil")

-- | A plane of the committed catalog's map, or of the approved artwork.
catalogPlane ∷ FilePath → IO CoveragePlane
catalogPlane relative = do
  bytes ← loadFile relative
  case decodeRgba bytes of
    Right (96, 64, texels) → either (\e → fail (relative <> ": " <> show e)) pure (buildBinaryCoverage 96 64 texels)
    other → fail (relative <> ": not a 96x64 RGBA PNG: " <> either id (const "wrong size") other)

-- | The whole-image view of a plane: a single image is a one-region atlas, and the per-image
-- fixtures are exactly that, at the given parent version.
wholeImageView ∷ Word64 → CoveragePlane → RegionView
wholeImageView version plane = either (\e → error ("wholeImageView: " <> show e)) id (fullImageView version plane)

-- | The plane of a formula: a texel is covered where it is true. A technical
-- test fixture, labelled as such; it never stands in for the catalog in the
-- all-16-ID, four-facing acceptance cases.
planeFromFormula ∷ (Int → Int → Bool) → CoveragePlane
planeFromFormula covered = case buildBinaryCoverage 96 64 (ByteString.pack (concat [pixel (covered x y) | y ← [0 .. 63], x ← [0 .. 95]])) of
  Right plane → plane
  Left e → error ("planeFromFormula: " <> show e)
  where
    pixel on = [255, 255, 255, if on then 255 else 0]

-- | The adopted style of the committed catalog and artwork at one version.
loadAssets ∷ Word64 → IO AssetSnapshot
loadAssets version = loadAssetsWith version []

-- | The same, with listed assets replaced by synthetic technical fixtures.
loadAssetsWith ∷ Word64 → [(AssetKey, CoveragePlane)] → IO AssetSnapshot
loadAssetsWith version overrides = do
  blankPlane ← override (AssetColour ColourBlank) <$> catalogPlane (texturesDirectory </> "blanktexture.png")
  loam ← override (AssetColour (ColourMaterial stoneId)) <$> catalogPlane (texturesDirectory </> "loam.png")
  granite ← override (AssetColour (ColourMaterial soilId)) <$> catalogPlane (texturesDirectory </> "granite.png")
  maps ← forM catalogKeys $ \key → do
    plane ← override (AssetMap key) <$> catalogPlane (texturesDirectory </> "facemap" </> mapFileName key)
    asset ← orFail (mkMapAsset key version version (Just UnitNormalRgbV1) (wholeImageView version plane))
    pure (key, asset)
  blank ← orFail (mkColourAsset ColourBlank version version (wholeImageView version blankPlane))
  stone ← orFail (mkColourAsset (ColourMaterial stoneId) version version (wholeImageView version loam))
  soil ← orFail (mkColourAsset (ColourMaterial soilId) version version (wholeImageView version granite))
  orFail (mkAssetSnapshot version blank [(stoneId, stone), (soilId, soil)] maps)
  where
    override key plane = maybe plane id (lookup key overrides)
    orFail = either (\e → fail ("fixture assets: " <> show e)) pure

-- | The committed atlases as the runtime loads them: the manifest and, for each parent image,
-- its decoded RGBA, one coverage plane for the whole image and the profile its opaque texels
-- were checked against (the normal atlas as @unit-normal-rgb-v1@). The decode is JuicyPixels'
-- and the validation and coverage are the generic data-map functions the texture pipeline
-- calls, so no plane is built by hand.
loadAtlasParents ∷ Word64 → IO (AtlasManifest, ParentAtlas, ParentAtlas)
loadAtlasParents version = do
  style ← loadAtlasStyle version []
  pure (styleManifest style, styleColour style, styleNormal style)

-- | The adopted style of the committed packed atlases at one version: stone is the loam region,
-- soil the granite region, exactly as 'loadAssets' draws them from the per-image files.
loadAtlasAssets ∷ Word64 → IO AssetSnapshot
loadAtlasAssets version = do
  (manifest, colour, normal) ← loadAtlasParents version
  either (\e → fail ("atlas assets: " <> show e)) pure (atlasAssetSnapshot version manifest colour normal [(stoneId, "colour.loam"), (soilId, "colour.granite")])

-- | The adopted style with @n@ further material colours nothing uses, each a copy
-- of the loam artwork: the asset-count growth the work-meter property uses.
loadAssetsExtra ∷ Word64 → Int → IO AssetSnapshot
loadAssetsExtra version n = do
  blankPlane ← catalogPlane (texturesDirectory </> "blanktexture.png")
  loam ← catalogPlane (texturesDirectory </> "loam.png")
  granite ← catalogPlane (texturesDirectory </> "granite.png")
  maps ← forM catalogKeys $ \key → do
    plane ← catalogPlane (texturesDirectory </> "facemap" </> mapFileName key)
    asset ← orFail (mkMapAsset key version version (Just UnitNormalRgbV1) (wholeImageView version plane))
    pure (key, asset)
  blank ← orFail (mkColourAsset ColourBlank version version (wholeImageView version blankPlane))
  stone ← orFail (mkColourAsset (ColourMaterial stoneId) version version (wholeImageView version loam))
  soil ← orFail (mkColourAsset (ColourMaterial soilId) version version (wholeImageView version granite))
  extras ← forM [1 .. n] $ \i → do
    let material = either (error . show) id (mkMaterialId ("unused" <> show i))
    asset ← orFail (mkColourAsset (ColourMaterial material) version version (wholeImageView version loam))
    pure (material, asset)
  orFail (mkAssetSnapshot version blank ([(stoneId, stone), (soilId, soil)] <> extras) maps)
  where
    orFail = either (\e → fail ("fixture assets: " <> show e)) pure

-- ---------------------------------------------------------------------------
-- Scenes

-- | What the oracle's cell knows.
data Know
  = -- | Discovered whole: ordinary.
    KnownAll
  | -- | The solid is known, its empty component is not: mixed for a shaped solid.
    KnownSolid
  | -- | Confirmed undiscovered: fog, whatever the truth holds.
    Undisc
  deriving stock (Eq, Show)

-- | A cell of a scene: world tile, world shape identity and what is known.
data OCell = OCell !Integer !Integer !Integer !Int !Know
  deriving stock (Eq, Show)

-- | Everything one plan is a function of, minus the assets.
data Scene = Scene
  { sceneFacts ∷ !TerrainFacts
  , sceneKnowledge ∷ !Knowledge
  , sceneCamera ∷ !CameraState
  , sceneSetup ∷ !ViewSetup
  , sceneConfig ∷ !CellConfig
  }

-- | The knowledge of a scene's cells: each listed cell its state, everything
-- else discovered (so known air is absent and unlisted terrain is ordinary).
knowledgeOf ∷ Word64 → CellKnowledge → [(Integer, Integer, Integer, CellKnowledge)] → Knowledge
knowledgeOf revision def entries =
  either (\e → error ("fixture knowledge: " <> show e)) id $
    mkKnowledge
      KnowledgeSpec
        { specRevision = revision
        , specDefault = def
        , specRegions = []
        , specColumns =
            [ (Column (axis x) (axis y), [(z, z + 1, state) | (x', y', z, state) ← entries, (x', y') == (x, y)])
            | (x, y) ← Set.toAscList (Set.fromList [(x, y) | (x, y, _, _) ← entries])
            ]
        }

camera0 ∷ ViewFacing → Integer → Integer → Integer → CameraState
camera0 facing x y level = case applyCommand defaultCameraConfig (factsOf flatWorld) (SetFacing facing) (manualCamera x y level) of
  Left e → error (show e)
  Right step → stepCamera step

-- | A scene of oracle cells: the terrain holds each cell's shape (a fog cell's
-- truth is its own, which is never read), the knowledge their states, and the
-- camera looks from a facing, cut at a level, at the origin column.
sceneOf ∷ ViewFacing → Integer → [OCell] → Scene
sceneOf facing = sceneOfAt facing (0, 0)

-- | The same about an anchor column.
sceneOfAt ∷ ViewFacing → (Integer, Integer) → Integer → [OCell] → Scene
sceneOfAt facing (ax, ay) cut cells = sceneFrom facing cut ax ay (sourceOf cells) (knowledgeOf 1 CellDiscovered (concatMap entry cells)) AllKnown
  where
    entry (OCell x y z _ know) = [(x, y, z, stateOf know)]

stateOf ∷ Know → CellKnowledge
stateOf KnownAll = CellDiscovered
stateOf KnownSolid = CellSolidKnown
stateOf Undisc = CellUndiscovered

sourceOf ∷ [OCell] → Source
sourceOf cells =
  source
    SourceSpec
      { specMaterials = ["stone"]
      , specLayers = []
      , specPatches = [PatchSpec x y z (z + 1) (SpecSolid "stone" shape) | OCell x y z shape _ ← cells]
      }

-- | A scene from a source, knowledge and availability, looking at a column.
sceneFrom ∷ ViewFacing → Integer → Integer → Integer → Source → Knowledge → Availability → Scene
sceneFrom facing cut x y src knowledge availability =
  Scene
    { sceneFacts = factsWith' src availability
    , sceneKnowledge = knowledge
    , sceneCamera = camera0 facing x y cut
    , sceneSetup = setup 320 240
    , sceneConfig = defaultCellConfig
    }
  where
    factsWith' s a = TerrainFacts (Versions 1 1 1) s emptyChanges a

inputsOf ∷ AssetSnapshot → Scene → CellInputs
inputsOf assets scene =
  CellInputs
    { inputsRequest =
        CellRequest
          { crVersions = Versions 1 1 1
          , crCamera = sceneCamera scene
          , crSetup = sceneSetup scene
          , crConfig = sceneConfig scene
          }
    , inputsFacts = sceneFacts scene
    , inputsKnowledge = sceneKnowledge scene
    , inputsAssets = assets
    }

planScene ∷ AssetSnapshot → Scene → CellPlan
planScene assets scene = either (\e → error ("fixture plan refused: " <> show e)) id (planSceneWith assets scene)

planSceneWith ∷ AssetSnapshot → Scene → Either CellError CellPlan
planSceneWith assets scene = planCells (inputsOf assets scene)

-- | The viewport extents of the standard scene.
viewport ∷ (Int, Int)
viewport = (320, 240)

-- | Pick the pixel whose centre is at integer pixel @(px, py)@ of the
-- framebuffer (logical equals framebuffer in the standard scene).
pickPixel ∷ CellPlan → (Int, Int) → CellPickResult
pickPixel plan pixel = either (\e → error ("fixture pick refused: " <> show e)) id (pickPixelRaw plan pixel)

pickPixelRaw ∷ CellPlan → (Int, Int) → Either CellPickError CellPickResult
pickPixelRaw plan (px, py) =
  pickCells plan (CellPickQuery (cellPlanIdentity plan) (V2 (fromIntegral px + 0.5) (fromIntegral py + 0.5)))

allPixels ∷ [(Int, Int)]
allPixels = [(x, y) | y ← [0 .. snd viewport - 1], x ← [0 .. fst viewport - 1]]

-- | A strided subset of the pixels, offset so it does not follow the lattice.
stridePixels ∷ Int → [(Int, Int)]
stridePixels step = [(x, y) | y ← [3, 3 + step .. snd viewport - 1], x ← [5, 5 + step .. fst viewport - 1]]

-- ---------------------------------------------------------------------------
-- The oracle

-- | What a line of sight meets first.
data OResult
  = ONothing
  | OFog
  | OKnown !TileCoord
  deriving stock (Eq, Show)

-- | The positive quarter turns of a facing, as the design states them.
turnsOf ∷ ViewFacing → Int
turnsOf FaceSouth = 0
turnsOf FaceWest = 3
turnsOf FaceNorth = 2
turnsOf FaceEast = 1

-- One positive quarter turn of an integer offset takes (dx, dy) to (-dy, dx).
turn ∷ Int → (Integer, Integer) → (Integer, Integer)
turn n offset = iterate (\(dx, dy) → (negate dy, dx)) offset !! (n `mod` 4)

-- | The shape a facing presents for a world shape, by rotating its sides: North
-- to East to South to West.
expectedViewShape ∷ ViewFacing → ShapeId → ShapeId
expectedViewShape facing world = shapeFromSides (map rot (shapeSides world))
  where
    rot side = iterate next side !! turnsOf facing
    next North = East
    next East = South
    next South = West
    next West = North

-- | The first thing a line of sight meets at a render-world point, in the
-- relative frame about an anchor column and a reference elevation, for cells at
-- or below a cut. A discovered cell is its shape's solid; an undiscovered cell
-- is the whole cube; a known solid whose empty component is undiscovered is the
-- solid where the line meets it first and the cube's cover otherwise.
oracleAt ∷ ViewFacing → (Integer, Integer) → Integer → Integer → [OCell] → (Rational, Rational) → OResult
oracleAt facing anchor ref cut cells point = case rawHits facing anchor ref cut cells point of
  [] → ONothing
  hits → let (_, result) = minimumBy (comparing fst) hits in result

-- | Every known cell the line of sight meets, nearest first: the independent
-- order the picker's keys are held to.
oracleHits ∷ ViewFacing → (Integer, Integer) → Integer → Integer → [OCell] → (Rational, Rational) → [TileCoord]
oracleHits facing anchor ref cut cells point =
  [tile | (_, OKnown tile) ← sortOn fst (rawHits facing anchor ref cut cells point)]

rawHits ∷ ViewFacing → (Integer, Integer) → Integer → Integer → [OCell] → (Rational, Rational) → [(Rational, OResult)]
rawHits facing (ax, ay) ref cut cells (sx, sy) = hits
  where
    a = (sx / 48 + sy / 24) / 2
    b = (sy / 24 - sx / 48) / 2
    far = 400
    origin = V3 (a + far) (b + far) (3 * far)
    direction = V3 (-1) (-1) (-3)
    fullShape = either (error . show) id (mkShapeId 0)
    hits =
      [ (t, result)
      | OCell x y z shape know ← cells
      , z <= cut
      , let (vx, vy) = turn (turnsOf facing) (x - ax, y - ay)
      -- Only cells whose canvas can contain the point can be met: a necessary
      -- condition, so it changes no answer, only the work.
      , abs (sx - 48 * fromInteger (vx - vy)) <= 49
      , let top = 24 * fromInteger (vx + vy - 1) - 16 * fromInteger (z - ref) - 16
      , sy >= top - 1 && sy <= top + 65
      , let V3 ox oy oz = origin
      , let local = V3 (ox - (fromInteger vx - 1 / 2)) (oy - (fromInteger vy - 1 / 2)) (oz - fromInteger (z - ref))
      , Right ray ← [mkRay local direction]
      , let world = either (error . show) id (mkShapeId shape)
      , let tileHere = tileAt x y z
      , let cast s = hitParameter <$> castRay (shapeSolid s) ray
      , let cubeHit = cast fullShape
      , let solidHit = cast (viewShape facing world)
      , (t, result) ← case know of
          KnownAll → [(t', OKnown tileHere) | Just t' ← [solidHit]]
          Undisc → [(t', OFog) | Just t' ← [cubeHit]]
          KnownSolid
            | shape == 0 → [(t', OKnown tileHere) | Just t' ← [solidHit]]
            | otherwise → case (cubeHit, solidHit) of
                (Just c, Just s) | c == s → [(c, OKnown tileHere)]
                (Just c, _) → [(c, OFog)]
                _ → []
      ]

-- | The oracle at the centre of a target pixel, through the plan's own view
-- mapping (render-2d's, verified elsewhere): the render-world point whose
-- classification the picker must agree with.
oracleAtPixel ∷ CellPlan → ViewFacing → (Integer, Integer) → Integer → Integer → [OCell] → (Rational, Rational) → (Int, Int) → Maybe OResult
oracleAtPixel plan facing anchor ref cut cells (jx, jy) (px, py) = do
  V2 wx wy ← targetToWorld (rvMapping (cellPlanView plan)) (V2 (fromIntegral px + 0.5) (fromIntegral py + 0.5))
  pure (oracleAt facing anchor ref cut cells (toRational wx + jx, toRational wy + jy))

-- | The oracle's answer, only where it is stable under a small jitter of the
-- sample point (so a sample on a facet or mask edge is skipped, not guessed).
stableOracleAtPixel ∷ CellPlan → ViewFacing → (Integer, Integer) → Integer → Integer → [OCell] → (Int, Int) → Maybe OResult
stableOracleAtPixel plan facing anchor ref cut cells pixel = case traverse (\j → oracleAtPixel plan facing anchor ref cut cells j pixel) jitters of
  Just (r : rs) | all (== r) rs → Just r
  _ → Nothing
  where
    jitters = [(0, 0), (1 / 32, 0), (0, 1 / 32), (-1 / 32, -1 / 32)]

-- | The render-world point at the centre of a target pixel, through the plan's
-- own view mapping.
pixelWorld ∷ CellPlan → (Int, Int) → Maybe (Rational, Rational)
pixelWorld plan (px, py) = do
  V2 wx wy ← targetToWorld (rvMapping (cellPlanView plan)) (V2 (fromIntegral px + 0.5) (fromIntegral py + 0.5))
  pure (toRational wx, toRational wy)
