-- | TRA-16: the cell-quad planner and the coverage picker, proved against
-- independent references. See "Test.TerrainRender2D.CellFixtures" for the ray
-- oracle and the scenes; nothing here takes an expectation from a production
-- sort key or from the production bit lookup.
--
-- The synthetic planes in "Test.TerrainRender2D.CellsCoverage" are technical
-- test fixtures, labelled as such; they never stand in for the qualified
-- catalog in the all-16-ID, four-facing groups below.
module Test.TerrainRender2D.Cells
  ( spec
  , AScene (..)
  , agreementScenes
  , decidable
  , productionClass
  , classify
  , referenceFront
  , collapse
  ) where

import Control.Monad (forM_)
import Data.Int (Int64)
import Data.Function (on)
import Data.List (sortOn)
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.ByteString as ByteString
import Hetoimasia.Asset.Image.DataMap (NormalEncoding (..), buildBinaryCoverage, coverageAt)
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisValue)
import Hetoimasia.Terrain.MapBake.Catalog (MapKey (..), MapRole (..), catalogKeys, mapFileName)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Camera (camRef)
import Hetoimasia.Terrain.Render2D.CellPick
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts (chunkOfColumn)
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Shape (ShapeId, ViewFacing (..), allViewFacings, mkShapeId)
import System.FilePath ((</>))
import Test.Hspec
import Test.TerrainRender2D.Art (texturesDirectory)
import Test.TerrainRender2D.CellFixtures
import Test.TerrainRender2D.Fixtures (axis, tileAt)

shapeNo ∷ Int → ShapeId
shapeNo n = either (error . show) id (mkShapeId n)

spec ∷ Spec
spec = describe "Cell quads (TRA-16)" $ do
  checkedInputs
  checkedAssets
  beforeAll (loadAssets 5) $ do
    representation
    agreement
    exactOrder
    negativeControls

-- ---------------------------------------------------------------------------
-- Inputs

checkedInputs ∷ Spec
checkedInputs = describe "checked supplied knowledge" $ do
  it "refuses duplicate regions and columns, empty runs and overlapping runs" $ do
    let col = Column (axis 0) (axis 0)
        base = KnowledgeSpec 1 CellDiscovered [] []
    mkKnowledge base {specColumns = [(col, [(0, 1, CellPending)]), (col, [])]} `shouldSatisfy` isLeft
    mkKnowledge base {specColumns = [(col, [(2, 2, CellPending)])]} `shouldSatisfy` isLeft
    mkKnowledge base {specColumns = [(col, [(0, 5, CellPending), (4, 9, CellDiscovered)])]} `shouldSatisfy` isLeft
  it "answers a window as runs, the most specific summary winning, and coalesces equal neighbours" $ do
    let col = Column (axis 3) (axis 4)
        knowledge =
          either (error . show) id $
            mkKnowledge
              KnowledgeSpec
                { specRevision = 9
                , specDefault = CellUndiscovered
                , specRegions = [(chunkOfColumn col, 0, CellDiscovered)]
                , specColumns = [(col, [(10, 12, CellPending), (12, 14, CellPending)])]
                }
    knowledgeRuns knowledge col 0 40
      `shouldBe` [ KnowRun 0 10 CellDiscovered
                 , KnowRun 10 14 CellPending
                 , KnowRun 14 32 CellDiscovered
                 , KnowRun 32 40 CellUndiscovered
                 ]
    knowledgeRevision knowledge `shouldBe` 9
  it "finds the runs of a small window among very many runs elsewhere in the column" $ do
    let col = Column (axis 0) (axis 0)
        near = [(10, 12, CellPending), (13, 20, CellSolidKnown)]
        far = [(2 * k, 2 * k + 1, if even k then CellPending else CellSolidKnown) | k ← [1000 .. 21000]]
        runs = near <> far
        knowledge = either (error . show) id (mkKnowledge (KnowledgeSpec 3 CellUndiscovered [] [(col, runs)]))
        stateAt z = case [s | (a, b, s) ← runs, a <= z, z < b] of
          s : _ → s
          [] → CellUndiscovered
        -- The reference reads each level on its own and joins equal neighbours.
        expected lo hi =
          [ KnowRun (fst (NonEmpty.head g)) (fst (NonEmpty.last g) + 1) (snd (NonEmpty.head g))
          | g ← NonEmpty.groupBy ((==) `on` snd) [(z, stateAt z) | z ← [lo .. hi - 1]]
          ]
    forM_ [(8, 22), (11, 13), (12, 14), (20, 21), (1999, 2005), (2000, 2001), (2001, 2002), (20998, 21012), (41990, 42010), (-5, 3), (0, 0), (9, 8)] $ \(lo, hi) →
      knowledgeRuns knowledge col lo hi `shouldBe` expected lo hi

-- The adopted style is checked before any plan can be asked for.
checkedAssets ∷ Spec
checkedAssets = describe "checked supplied assets" $ do
  let full = planeFromFormula (\_ _ → True)
      short = either (error . show) id (buildBinaryCoverage 96 63 (ByteString.replicate (96 * 63 * 4) 255))
      colour ref = either (error . show) id (mkColourAsset ref 1 1 full)
      mapAsset key = either (error . show) id (mkMapAsset key 1 1 (Just UnitNormalRgbV1) full)
      allMaps = [(key, mapAsset key) | key ← catalogKeys]
  it "refuses a plane that is not 96 x 64, mismatched versions and a map without its checked profile" $ do
    mkColourAsset ColourBlank 1 1 short `shouldSatisfy` isLeft
    mkColourAsset ColourBlank 1 2 full `shouldSatisfy` isLeft
    mkMapAsset (MapKey Ordinary (shapeNo 0)) 1 1 Nothing full `shouldSatisfy` isLeft
    mkMapAsset (MapKey Ordinary (shapeNo 0)) 3 4 (Just UnitNormalRgbV1) full `shouldSatisfy` isLeft
  it "refuses a catalog that lacks an authored map and a duplicate asset, so no plan can be asked for" $ do
    mkAssetSnapshot 1 (colour ColourBlank) [] (drop 1 allMaps) `shouldSatisfy` isLeft
    mkAssetSnapshot 1 (colour ColourBlank) [(stoneId, colour (ColourMaterial stoneId)), (stoneId, colour (ColourMaterial stoneId))] allMaps `shouldSatisfy` isLeft
    mkAssetSnapshot 1 (colour ColourBlank) [] (allMaps <> take 1 allMaps) `shouldSatisfy` isLeft
    mkAssetSnapshot 1 (colour ColourBlank) [(stoneId, colour (ColourMaterial stoneId))] allMaps `shouldSatisfy` (not . isLeft)

isLeft ∷ Either a b → Bool
isLeft (Left _) = True
isLeft _ = False

-- ---------------------------------------------------------------------------
-- The representation table

type QuadSummary = (PartKind, Maybe TileCoord, ColourRef, MapKey)

summary ∷ CellQuad → QuadSummary
summary q = (quadPart q, quadCell q, quadColour q, quadMap q)

representation ∷ SpecWith AssetSnapshot
representation = describe "the whole-cell representation table, 16 identities at four facings" $
  forM_ allViewFacings $ \facing → forM_ [0 .. 15] $ \shape → do
    let view = expectedViewShape facing (shapeNo shape)
        label what = what <> " " <> show shape <> " at " <> show facing
    it (label "draws a discovered shape as its ordinary map:") $ \assets → do
      let plan = planScene assets (sceneOf facing 0 [OCell 0 0 0 shape KnownAll])
      map summary (cellPlanQuads plan)
        `shouldBe` [(PartOrdinary, Just (tileAt 0 0 0), ColourMaterial stoneId, MapKey Ordinary view)]
    it (label "covers an undiscovered shape with generic full fog:") $ \assets → do
      let plan = planScene assets (sceneOf facing 0 [OCell 0 0 0 shape Undisc])
      map summary (cellPlanQuads plan)
        `shouldBe` [(PartFog, Nothing, ColourBlank, MapKey Ordinary (shapeNo 0))]
    it (label "splits a known shape whose void is undiscovered into fog then known:") $ \assets → do
      let plan = planScene assets (sceneOf facing 0 [OCell 0 0 0 shape KnownSolid])
      map summary (cellPlanQuads plan)
        `shouldBe` if shape == 0
          then [(PartOrdinary, Just (tileAt 0 0 0), ColourMaterial stoneId, MapKey Ordinary view)]
          else
            [ (PartFog, Nothing, ColourBlank, MapKey FogPart view)
            , (PartKnown, Just (tileAt 0 0 0), ColourMaterial stoneId, MapKey KnownPart view)
            ]

-- ---------------------------------------------------------------------------
-- Scenes

-- A scene of oracle cells about an anchor column, cut at a level.
data AScene = AScene
  { sceneName ∷ String
  , sceneAnchor ∷ (Integer, Integer)
  , sceneCut ∷ Integer
  , sceneCells ∷ [OCell]
  }

shifted ∷ (Integer, Integer, Integer) → [OCell] → [OCell]
shifted (dx, dy, dz) cells = [OCell (x + dx) (y + dy) (z + dz) s k | OCell x y z s k ← cells]

blockOf ∷ [OCell]
blockOf = [OCell x y z 0 KnownAll | x ← [0 .. 2], y ← [0 .. 2], z ← [0 .. 1], (x, y, z) /= (1, 1, 0)] <> [OCell 1 1 2 0 KnownAll]

agreementScenes ∷ [AScene]
agreementScenes =
  [ AScene "a 4 x 4 grid of every identity, knowledge cycling" (0, 0) 0 [OCell x y 0 (fromInteger (4 * y + x)) (cycleKnow (4 * y + x)) | y ← [0 .. 3], x ← [0 .. 3]]
  , AScene "a roof over a cavity with ramps at the rim" (0, 0) 2 (blockOf <> [OCell 3 1 0 3 KnownAll, OCell 1 3 0 12 KnownSolid, OCell 3 3 0 5 Undisc])
  , AScene "stacked disconnected spans and a steep depth separation" (0, 0) 100 ([OCell 0 0 z s KnownAll | (z, s) ← [(100, 0), (97, 5), (91, 0), (70, 15)]] <> [OCell 1 1 103 0 KnownAll, OCell (-20) (-20) 40 0 KnownAll, OCell (-40) (-40) (-20) 5 KnownAll, OCell (-1) (-1) 97 0 Undisc, OCell 2 0 98 9 KnownSolid])
  , AScene "cutaway through undiscovered air, cut above" (0, 0) 1 [OCell 0 0 0 0 KnownAll, OCell 1 0 0 5 KnownAll, OCell 0 0 1 0 Undisc, OCell 1 0 1 0 Undisc, OCell 0 0 2 0 KnownAll]
  , AScene "cutaway through undiscovered air, cut at the known cells" (0, 0) 0 [OCell 0 0 0 0 KnownAll, OCell 1 0 0 5 KnownAll, OCell 0 0 1 0 Undisc, OCell 1 0 1 0 Undisc, OCell 0 0 2 0 KnownAll]
  , AScene "a known ramp side beside an unrevealed void and fog behind it" (0, 0) 1 [OCell 0 0 0 5 KnownSolid, OCell 1 1 3 0 Undisc, OCell 1 1 1 0 KnownAll, OCell 0 1 0 12 KnownSolid, OCell 1 0 0 3 KnownAll, OCell 0 0 2 0 KnownAll]
  , AScene "a chunk seam in X and Y" (15, 15) 1 (shifted (14, 14, 0) blockOf <> shifted (14, 14, 0) [OCell 3 1 0 3 KnownAll, OCell 1 3 0 12 KnownSolid])
  , AScene "a vertical region seam" (0, 0) 33 [OCell x y z (fromInteger ((x + y + z) `mod` 16)) (cycleKnow (x + y + z)) | z ← [30 .. 33], x ← [0, 1], y ← [0, 1]]
  , AScene "the greatest legal coordinates" (hi - 3, hi - 3) 0 (shifted (hi - 3, hi - 3, 0) (blockOf <> [OCell 3 0 0 5 KnownAll]))
  , AScene "the least legal coordinates" (lo, lo) 0 (shifted (lo, lo, 0) (blockOf <> [OCell 3 0 0 12 KnownSolid, OCell 0 3 0 3 Undisc]))
  ]
  where
    cycleKnow n = [KnownAll, KnownSolid, Undisc] !! fromInteger (n `mod` 3)
    hi = 2 ^ (62 ∷ Int) - 1
    lo = negate (2 ^ (62 ∷ Int))

-- The pixels, with the oracle's answer, where the oracle is decidable.
decidable ∷ CellPlan → ViewFacing → AScene → [((Int, Int), OResult)]
decidable plan facing scene =
  [ (pixel, o)
  | pixel ← stridePixels 6
  , Just o ← [stableOracleAtPixel plan facing (sceneAnchor scene) ref (sceneCut scene) (sceneCells scene) pixel]
  ]
  where
    ref = cameraRef plan scene

cameraRef ∷ CellPlan → AScene → Integer
cameraRef _ scene = camRef (sceneCamera (sceneOfAt FaceSouth (sceneAnchor scene) (sceneCut scene) []))

-- A reference traversal over the plan's public quads: the part and cell of the
-- frontmost quad covering a pixel centre, with the order a caller chooses. Its
-- texel is the integer offset from the quad's drawn left and top at unit scale,
-- computed here by hand, and its coverage is read through the public planes.
referenceFront ∷ AssetSnapshot → [CellQuad] → (Int, Int) → Maybe (PartKind, Maybe TileCoord)
referenceFront assets nearToFar pixel = case coveringQuads assets nearToFar pixel of
  q : _ → Just (quadPart q, quadCell q)
  [] → Nothing

coveringQuads ∷ AssetSnapshot → [CellQuad] → (Int, Int) → [CellQuad]
coveringQuads assets quads (px, py) = [q | q ← quads, covers q]
  where
    cx = toRational px + 1 / 2
    cy = toRational py + 1 / 2
    covers q =
      let TargetRect l t r b = quadTarget q
          tx = floor (cx - l) ∷ Int
          ty = floor (cy - t) ∷ Int
       in l <= cx && cx < r && t <= cy && cy < b && r - l == 96 && b - t == 64 && bit (colourCoverage assets (quadColour q)) tx ty && bit (mapCoverage assets (quadMap q)) tx ty
    bit (Just plane) x y = coverageAt plane (fromIntegral x) (fromIntegral y) == Just True
    bit Nothing _ _ = False

classify ∷ Maybe (PartKind, Maybe TileCoord) → OResult
classify Nothing = ONothing
classify (Just (PartFog, _)) = OFog
classify (Just (_, Just tile)) = OKnown tile
classify (Just (_, Nothing)) = ONothing

productionClass ∷ CellPlan → (Int, Int) → OResult
productionClass plan pixel = case pickPixel plan pixel of
  CellPickHit hit → OKnown (hitCell hit)
  CellPickNoHit → ONothing
  CellPickLoading → ONothing

-- A pick through fog is the same answer as a miss, by design.
collapse ∷ OResult → OResult
collapse OFog = ONothing
collapse o = o

-- The pixels where a classifier disagrees with the oracle.
disagreements ∷ CellPlan → ViewFacing → AScene → ((Int, Int) → OResult) → [((Int, Int), OResult, OResult)]
disagreements plan oracleFacing scene classifier =
  [(p, o, r) | (p, o) ← decidable plan oracleFacing scene, let r = classifier p, o /= r]

-- The same for a classifier that, like the production pick, does not tell fog
-- from a miss.
disagreementsPick ∷ CellPlan → ViewFacing → AScene → ((Int, Int) → OResult) → [((Int, Int), OResult, OResult)]
disagreementsPick plan oracleFacing scene classifier =
  [(p, o, r) | (p, o) ← decidable plan oracleFacing scene, let r = classifier p, collapse o /= r]

agreement ∷ SpecWith AssetSnapshot
agreement = describe "agreement with an independent view-ray oracle" $
  forM_ agreementScenes $ \scene → forM_ allViewFacings $ \facing →
    it (sceneName scene <> ", " <> show facing) $ \assets → do
      let plan = planScene assets (sceneOfAt facing (sceneAnchor scene) (sceneCut scene) (sceneCells scene))
          compared = decidable plan facing scene
          nearToFar = reverse (cellPlanQuads plan)
      -- Enough pixels were decidable that the check is not vacuous.
      length compared `shouldSatisfy` (> 200)
      disagreements plan facing scene (classify . referenceFront assets nearToFar) `shouldBe` []
      disagreementsPick plan facing scene (productionClass plan) `shouldBe` []

-- ---------------------------------------------------------------------------
-- Exact order against the oracle's ray order

-- For every decidable pixel, the known cells whose coverage contains it are in
-- the order the line of sight meets them, nearest first. The expected order is
-- the oracle's ray parameter; no sort key is read.
exactOrder ∷ SpecWith AssetSnapshot
exactOrder = describe "exact cell order against the ray parameter" $
  forM_ agreementScenes $ \scene →
    it (sceneName scene) $ \assets → do
      let perFacing facing =
            let plan = planScene assets (sceneOfAt facing (sceneAnchor scene) (sceneCut scene) (sceneCells scene))
                nearToFar = reverse (cellPlanQuads plan)
                ref = cameraRef plan scene
             in [ (facing, pixel, ours, expected)
                | pixel ← stridePixels 3
                , Just point ← [pixelWorld plan pixel]
                , let ours = [t | q ← coveringQuads assets nearToFar pixel, Just t ← [quadCell q]]
                , length ours >= 2
                , let ray = oracleHits facing (sceneAnchor scene) ref (sceneCut scene) (sceneCells scene) point
                , let expected = [t | t ← ray, t `elem` ours]
                ]
          sequences = concatMap perFacing allViewFacings
      -- Overlaps exist in the scene (the check is not vacuous), and the order
      -- is the ray order wherever it can be decided.
      length sequences `shouldSatisfy` (>= 20)
      [(f, p, a, b) | (f, p, a, b) ← sequences, a /= b] `shouldBe` []

-- ---------------------------------------------------------------------------
-- Negative controls: each independent check must fail on a deliberate defect

negativeControls ∷ SpecWith AssetSnapshot
negativeControls = describe "negative controls" $ do
  let grid = agreementScenes !! 0
  it "a reversed draw order disagrees with the oracle" $ \assets → do
    let plan = planScene assets (sceneOfAt FaceSouth (sceneAnchor grid) (sceneCut grid) (sceneCells grid))
        reversedOrder = cellPlanQuads plan
    length (disagreements plan FaceSouth grid (classify . referenceFront assets reversedOrder)) `shouldSatisfy` (> 0)
  it "the wrong facing disagrees with the oracle" $ \assets → do
    let plan = planScene assets (sceneOfAt FaceSouth (sceneAnchor grid) (sceneCut grid) (sceneCells grid))
    length (disagreementsPick plan FaceWest grid (productionClass plan)) `shouldSatisfy` (> 0)
  it "swapped masks disagree with the oracle" $ \_ → do
    let key n = MapKey Ordinary (shapeNo n)
        load n = catalogPlane (texturesDirectory </> "facemap" </> mapFileName (key n))
    five ← load 5
    nine ← load 9
    swapped ← loadAssetsWith 5 [(AssetMap (key 5), nine), (AssetMap (key 9), five)]
    let plan = planScene swapped (sceneOfAt FaceSouth (sceneAnchor grid) (sceneCut grid) (sceneCells grid))
    length (disagreementsPick plan FaceSouth grid (productionClass plan)) `shouldSatisfy` (> 0)
  it "a floating key x + y + 0.001 z at extreme coordinates orders cells wrongly" $ \assets → do
    let scene = agreementScenes !! 8
        plan = planScene assets (sceneOfAt FaceSouth (sceneAnchor scene) (sceneCut scene) (sceneCells scene))
        known = [q | q ← cellPlanQuads plan, Just _ ← [quadCell q]]
        floatKey q = case quadCell q of
          Just (TileCoord x y z) → (fromIntegral (axisValue x + axisValue y) + 0.001 * fromIntegral (axisValue z)) ∷ Float
          Nothing → 0
        -- The input to a stable sort in an order that is wrong whenever keys tie.
        floatOrder = reverse (sortOn floatKey (reverse known))
        _ = (0 ∷ Int64)
    -- The exact order passes; the floating approximation collapses to ties
    -- and so keeps the (wrong) input order.
    disagreements plan FaceSouth scene (classify . referenceFront assets (reverse known)) `shouldBe` []
    length (disagreements plan FaceSouth scene (classify . referenceFront assets floatOrder)) `shouldSatisfy` (> 0)
