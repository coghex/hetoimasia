-- | TRA-16: the cell-quad planner and the coverage picker, proved against
-- independent references. See "Test.TerrainRender2D.CellFixtures" for the ray
-- oracle and the scenes; nothing here takes an expectation from a production
-- sort key or from the production bit lookup.
--
-- The synthetic planes in the texel groups are technical test fixtures, labelled
-- as such; they never stand in for the qualified catalog in the all-16-ID,
-- four-facing groups.
module Test.TerrainRender2D.Cells (spec) where

import Control.Monad (forM_, unless)
import Hetoimasia.Asset.Image.DataMap (coverageAt)
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.MapBake.Catalog (MapKey (..), MapRole (..))
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Camera (camRef)
import Hetoimasia.Terrain.Render2D.CellPick
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts (chunkOfColumn)
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Shape (ShapeId, allViewFacings, mkShapeId)
import Test.Hspec
import Test.TerrainRender2D.CellFixtures
import Test.TerrainRender2D.Fixtures (axis, tileAt)

shapeNo ∷ Int → ShapeId
shapeNo n = either (error . show) id (mkShapeId n)

spec ∷ Spec
spec = describe "Cell quads (TRA-16)" $ do
  checkedInputs
  beforeAll (loadAssets 5) $ do
    representation
    agreement

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
-- Agreement with the ray oracle

-- A reference traversal over the plan's public quads: the part and cell of the
-- frontmost quad covering a pixel centre, with the order a caller chooses. Its
-- texel is the integer offset from the quad's drawn left and top at unit scale,
-- computed here by hand, and its coverage is read through the public planes.
referenceFront ∷ AssetSnapshot → [CellQuad] → (Int, Int) → Maybe (PartKind, Maybe TileCoord)
referenceFront assets nearToFar (px, py) = case [q | q ← nearToFar, covers q] of
  q : _ → Just (quadPart q, quadCell q)
  [] → Nothing
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

-- Scenes for the agreement checks: each exercises a different occlusion shape.
agreementScenes ∷ [(String, Integer, [OCell])]
agreementScenes =
  [ ("a 4 x 4 grid of every identity, knowledge cycling", 0, [OCell x y 0 (fromInteger (4 * y + x)) (cycleKnow (fromInteger (4 * y + x))) | y ← [0 .. 3], x ← [0 .. 3]])
  , ("a roof over a cavity with ramps at the rim", 2, roofAndCavity)
  , ("stacked disconnected spans and a steep depth separation", 40, [OCell 0 0 z s KnownAll | (z, s) ← [(0, 0), (3, 5), (9, 0), (30, 15), (40, 0)]] <> [OCell 1 1 5 0 Undisc, OCell 2 0 20 9 KnownSolid])
  ]
  where
    cycleKnow n = [KnownAll, KnownSolid, Undisc] !! (n `mod` 3)
    roofAndCavity =
      [OCell x y 0 0 KnownAll | x ← [0 .. 2], y ← [0 .. 2], (x, y) /= (1, 1)]
        <> [OCell x y 1 0 KnownAll | x ← [0 .. 2], y ← [0 .. 2], (x, y) /= (1, 1)]
        <> [OCell 1 1 2 0 KnownAll, OCell 3 1 0 3 KnownAll, OCell 1 3 0 12 KnownSolid, OCell 3 3 0 5 Undisc]

agreement ∷ SpecWith AssetSnapshot
agreement = describe "agreement with an independent view-ray oracle" $
  forM_ agreementScenes $ \(name, cut, cells) → forM_ allViewFacings $ \facing →
    it (name <> ", " <> show facing) $ \assets → do
      let scene = sceneOf facing cut cells
          plan = planScene assets scene
          ref = camRef (sceneCamera scene)
          oracle pixel = stableOracleAtPixel plan facing (0, 0) ref cut cells pixel
          compared = [(pixel, o) | pixel ← stridePixels 6, Just o ← [oracle pixel]]
          nearToFar = reverse (cellPlanQuads plan)
          reference = [(pixel, o, classify (referenceFront assets nearToFar pixel)) | (pixel, o) ← compared]
          production = [(pixel, o, productionClass plan pixel) | (pixel, o) ← compared]
      -- Enough pixels were decidable that the check is not vacuous, and both
      -- kinds of target are present in it.
      length compared `shouldSatisfy` (> 300)
      unless (all ((== ONothing) . snd) compared) (pure ())
      [(p, o, r) | (p, o, r) ← reference, o /= r] `shouldBe` []
      [(p, o, r) | (p, o, r) ← production, collapse o /= r] `shouldBe` []
  where
    -- A pick through fog is the same answer as a miss, by design.
    collapse OFog = ONothing
    collapse o = o

productionClass ∷ CellPlan → (Int, Int) → OResult
productionClass plan pixel = case pickPixel plan pixel of
  CellPickHit hit → OKnown (hitCell hit)
  CellPickNoHit → ONothing
  CellPickLoading → ONothing
