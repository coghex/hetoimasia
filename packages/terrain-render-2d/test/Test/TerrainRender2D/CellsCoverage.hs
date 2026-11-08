-- | TRA-16: the coverage conventions of the picker, proved with synthetic
-- planes whose expectation is a formula written here.
--
-- Every plane in this module is a technical test fixture, labelled as such
-- (AGENTS.md: asset placeholders used for an explicit technical experiment are
-- labelled). None stands in for #656's qualified catalog, which the
-- all-16-identity, four-facing acceptance cases in "Test.TerrainRender2D.Cells"
-- use. The texel an expectation selects is computed here with exact
-- rationals from the drawn rectangle; the production bit lookup is not called.
module Test.TerrainRender2D.CellsCoverage (spec) where

import Control.Monad (forM_)
import Data.Ratio (denominator)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, coverageAt)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.MapBake.Catalog (MapKey (..), MapRole (..), mapFileName)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.CellPick
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Shape (ViewFacing (..), mkShapeId)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Source
import System.FilePath ((</>))
import Test.Hspec
import Test.TerrainRender2D.Art (texturesDirectory)
import Test.TerrainRender2D.CellFixtures
import Test.TerrainRender2D.Fixtures (factsOf, flatWorld, source, tileAt)

spec ∷ Spec
spec = describe "Cell picking coverage conventions (TRA-16)" $ do
  texelClassification
  rearCandidates
  rasterEdges
  viewportAndScale
  fractionalOcclusion

fullShape ∷ MapKey
fullShape = MapKey Ordinary (either (error . show) id (mkShapeId 0))

stoneColour ∷ AssetKey
stoneColour = AssetColour (ColourMaterial stoneId)

allOn ∷ CoveragePlane
allOn = planeFromFormula (\_ _ → True)

-- A single full block at the origin.
oneBlock ∷ Scene
oneBlock = sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll]

onlyQuad ∷ CellPlan → CellQuad
onlyQuad plan = case cellPlanQuads plan of
  [q] → q
  other → error ("expected one quad, found " <> show (length other))

rectOf ∷ CellQuad → (Rational, Rational, Rational, Rational)
rectOf q = case quadTarget q of TargetRect l t r b → (l, t, r, b)

isHit ∷ CellPickResult → Bool
isHit (CellPickHit _) = True
isHit _ = False

hitCellOf ∷ CellPickResult → Maybe TileCoord
hitCellOf (CellPickHit h) = Just (hitCell h)
hitCellOf _ = Nothing

planeBit ∷ CoveragePlane → Int → Int → Bool
planeBit plane x y = coverageAt plane (fromIntegral x) (fromIntegral y) == Just True

withCamera ∷ (CameraState → CameraState) → Scene → Scene
withCamera f scene = scene {sceneCamera = f (sceneCamera scene)}

command ∷ Command → CameraState → CameraState
command c camera = case applyCommand defaultCameraConfig (factsOf flatWorld) c camera of
  Right step → stepCamera step
  Left e → error (show e)

-- The camera moved so that quad edges and the texel boundaries fall on pixel
-- centres: half a pixel in x and in y.
halfPixelPan ∷ CameraState → CameraState
halfPixelPan = command (Pan (1 / 64) (1 / 192))

-- ---------------------------------------------------------------------------

texelClassification ∷ Spec
texelClassification = describe "colour and map coverage are independent and multiply" $ do
  let colourFormula x y = not (x >= 20 && x < 40 && y >= 10 && y < 30)
      mapFormula x y = (x + y) `mod` 3 /= 0
      cases =
        [ ("a colour hole alone", planeFromFormula colourFormula, allOn, colourFormula)
        , ("a map hole alone", allOn, planeFromFormula mapFormula, mapFormula)
        , ("both together", planeFromFormula colourFormula, planeFromFormula mapFormula, \x y → colourFormula x y && mapFormula x y)
        ]
  forM_ cases $ \(name, colour, mapPlane, expected) →
    it ("classifies every texel of " <> name) $ do
      assets ← loadAssetsWith 5 [(stoneColour, colour), (AssetMap fullShape, mapPlane)]
      let plan = planScene assets oneBlock
          (l, t, r, b) = rectOf (onlyQuad plan)
          pixelOf x y = (floor l + x, floor t + y)
      denominator l `shouldBe` 1
      (r - l, b - t) `shouldBe` (96, 64)
      [ (x, y)
        | y ← [0 .. 63]
        , x ← [0 .. 95]
        , isHit (pickPixel plan (pixelOf x y)) /= expected x y
        ]
        `shouldBe` []
      -- One pixel beyond every edge is no hit, whatever the planes say.
      [ p
        | (x, y) ← [(x, y) | x ← [-1 .. 96], y ← [-1, 64]] <> [(x, y) | x ← [-1, 96], y ← [-1 .. 64]]
        , let p = pixelOf x y
        , isHit (pickPixel plan p)
        ]
        `shouldBe` []
  it "is not affected by lighting-like state: the planes alone decide, whatever the style version" $ do
    first ← loadAssetsWith 5 [(stoneColour, planeFromFormula (\x _ → even x))]
    second ← loadAssetsWith 6 [(stoneColour, planeFromFormula (\x _ → even x))]
    let hits assets =
          let plan = planScene assets oneBlock
              (l, t, _, _) = rectOf (onlyQuad plan)
           in [isHit (pickPixel plan (floor l + x, floor t + 32)) | x ← [0 .. 95]]
    hits first `shouldBe` hits second
    hits first `shouldBe` [even x | x ← [0 .. 95 ∷ Int]]

rearCandidates ∷ Spec
rearCandidates = describe "a hole lets a rearward candidate be considered" $ do
  let twoMaterials =
        source
          SourceSpec
            { specMaterials = ["stone", "soil"]
            , specLayers = []
            , specPatches = [PatchSpec 0 0 0 1 (SpecSolid "stone" 0), PatchSpec 1 1 3 4 (SpecSolid "soil" 0)]
            }
      scene = sceneFrom FaceSouth 3 0 0 twoMaterials (knowledgeOf 1 CellDiscovered []) AllKnown
      inHole x y = x >= 30 && x < 60 && y >= 20 && y < 40
  it "picks the cell behind a transparent colour hole and the front cell elsewhere" $ do
    assets ← loadAssetsWith 5 [(AssetColour (ColourMaterial soilId), planeFromFormula (\x y → not (inHole x y)))]
    let plan = planScene assets scene
        front = tileAt 1 1 3
        rear = tileAt 0 0 0
        quadOf tile = case [q | q ← cellPlanQuads plan, quadCell q == Just tile] of
          q : _ → q
          [] → error "no quad"
        (l, t, _, _) = rectOf (quadOf front)
        pixel x y = (floor l + x, floor t + y)
    rectOf (quadOf front) `shouldBe` rectOf (quadOf rear)
    [ (x, y)
      | y ← [0 .. 63]
      , x ← [0 .. 95]
      , planeBit (planeFromFormula (\a b → a >= 0 && b >= 0)) x y
      , let expected = if inHole x y then Just rear else Just front
      , let got = hitCellOf (pickPixel plan (pixel x y))
      , got /= expected
      , got /= Nothing
      ]
      `shouldBe` []
    hitCellOf (pickPixel plan (pixel 40 30)) `shouldBe` Just rear
    hitCellOf (pickPixel plan (pixel 10 30)) `shouldBe` Just front
  it "picks the cell behind a map hole where a nearer ramp's cutout leaves the cell uncovered" $ do
    assets ← loadAssets 5
    full ← catalogPlane (texturesDirectory </> "facemap" </> mapFileName fullShape)
    ramp ← catalogPlane (texturesDirectory </> "facemap" </> mapFileName (MapKey Ordinary (either (error . show) id (mkShapeId 5))))
    let rampOver = source SourceSpec {specMaterials = ["stone"], specLayers = [], specPatches = [PatchSpec 0 0 0 1 (SpecSolid "stone" 0), PatchSpec 1 1 3 4 (SpecSolid "stone" 5)]}
        plan = planScene assets (sceneFrom FaceSouth 3 0 0 rampOver (knowledgeOf 1 CellDiscovered []) AllKnown)
        quadOf tile = case [q | q ← cellPlanQuads plan, quadCell q == Just tile] of
          q : _ → q
          [] → error "no quad"
        (l, t, _, _) = rectOf (quadOf (tileAt 1 1 3))
        pixel x y = (floor l + x, floor t + y)
        behindOnly = [(x, y) | y ← [0 .. 63], x ← [0 .. 95], planeBit full x y, not (planeBit ramp x y)]
        both = [(x, y) | y ← [0 .. 63], x ← [0 .. 95], planeBit full x y, planeBit ramp x y]
    length behindOnly `shouldSatisfy` (> 0)
    length both `shouldSatisfy` (> 0)
    [p | (x, y) ← behindOnly, let p = pixel x y, hitCellOf (pickPixel plan p) /= Just (tileAt 0 0 0)] `shouldBe` []
    [p | (x, y) ← both, let p = pixel x y, hitCellOf (pickPixel plan p) /= Just (tileAt 1 1 3)] `shouldBe` []

-- ---------------------------------------------------------------------------

-- Two full quads side by side, drawn at half-pixel positions so that pixel
-- centres lie exactly on their shared edge, their top and bottom edges, their
-- diagonals and their texel boundaries.
rasterEdges ∷ Spec
rasterEdges = describe "raster edge ownership on exact boundaries" $ do
  let pair = withCamera halfPixelPan (sceneOf FaceSouth 0 [OCell 1 0 0 0 KnownAll, OCell 0 1 0 0 KnownAll])
      left = tileAt 0 1 0
      right = tileAt 1 0 0
      stripes = planeFromFormula (\x _ → even x)
      quadOf plan tile = case [q | q ← cellPlanQuads plan, quadCell q == Just tile] of
        q : _ → q
        [] → error "no quad"
  it "gives a centre on a shared outer edge to exactly one quad, the one whose left edge it is" $ do
    assets ← loadAssetsWith 5 [(stoneColour, allOn), (AssetMap fullShape, allOn)]
    let plan = planScene assets pair
        (ll, lt, lr, lb) = rectOf (quadOf plan left)
        (rl, rt, rr, rb) = rectOf (quadOf plan right)
    lr `shouldBe` rl
    (lt, lb) `shouldBe` (rt, rb)
    denominator rl `shouldBe` 2
    denominator rt `shouldBe` 2
    ll `shouldBe` rl - 96
    rr `shouldBe` rl + 96
    let edgePixel = floor (rl - 1 / 2) ∷ Int
        rowPixel k = floor (rt - 1 / 2) + k
    -- The centre of the edge pixel is exactly the shared edge.
    toRational edgePixel + 1 / 2 `shouldBe` rl
    [ k | k ← [0 .. 63], hitCellOf (pickPixel plan (edgePixel, rowPixel k)) /= Just right ] `shouldBe` []
    [ k | k ← [0 .. 63], hitCellOf (pickPixel plan (edgePixel - 1, rowPixel k)) /= Just left ] `shouldBe` []
    -- The centre on the top edge is inside; the centre on the bottom edge is outside.
    hitCellOf (pickPixel plan (edgePixel + 5, rowPixel 0)) `shouldBe` Just right
    hitCellOf (pickPixel plan (edgePixel + 5, rowPixel (-1))) `shouldBe` Nothing
    hitCellOf (pickPixel plan (edgePixel + 5, rowPixel 63)) `shouldBe` Just right
    hitCellOf (pickPixel plan (edgePixel + 5, rowPixel 64)) `shouldBe` Nothing
    -- The far outer edge is outside the quad.
    hitCellOf (pickPixel plan (edgePixel + 96, rowPixel 20)) `shouldBe` Nothing
    hitCellOf (pickPixel plan (edgePixel + 95, rowPixel 20)) `shouldBe` Just right
  it "covers a centre on a quad's internal triangle diagonal" $ do
    assets ← loadAssetsWith 5 [(stoneColour, allOn), (AssetMap fullShape, allOn)]
    let plan = planScene assets pair
        (rl, rt, _, _) = rectOf (quadOf plan right)
        centreAt m = (floor (rl + 3 * m - 1 / 2) ∷ Int, floor (rt + 2 * m - 1 / 2) ∷ Int)
    -- (3m, 2m) from the corner is on the diagonal of a 96 x 64 quad.
    [m | m ← [1 .. 31], hitCellOf (pickPixel plan (centreAt m)) /= Just right] `shouldBe` []
  it "selects the higher texel at an exact interior texel boundary" $ do
    assets ← loadAssetsWith 5 [(stoneColour, stripes), (AssetMap fullShape, allOn)]
    let plan = planScene assets pair
        (rl, rt, _, _) = rectOf (quadOf plan right)
        row = floor (rt + 20 - 1 / 2) ∷ Int
    -- Pixel k has its centre exactly on the boundary between texels k - 1 and k.
    [ k
      | k ← [0 .. 95 ∷ Int]
      , isHit (pickPixel plan (floor (rl + fromIntegral k - 1 / 2), row)) /= even k
      ] `shouldBe` []

-- ---------------------------------------------------------------------------

-- A window of full blocks to pick through.
lattice ∷ [OCell]
lattice = [OCell x y 0 0 KnownAll | x ← [-6 .. 6], y ← [-6 .. 6]]

viewportAndScale ∷ Spec
viewportAndScale = describe "viewport, scale, snapping and extents" $ do
  it "excludes centres outside the viewport and includes its left and top edges" $ do
    assets ← loadAssets 5
    let scene = (sceneOf FaceSouth 0 lattice) {sceneSetup = (sceneSetup (sceneOf FaceSouth 0 []) ) {setupViewport = Viewport (V2 40 30) (V2 200 150)}}
        plan = planScene assets scene
    pickPixel plan (39, 100) `shouldBe` CellPickNoHit
    isHit (pickPixel plan (40, 100)) `shouldBe` True
    isHit (pickPixel plan (239, 100)) `shouldBe` True
    pickPixel plan (240, 100) `shouldBe` CellPickNoHit
    pickPixel plan (100, 29) `shouldBe` CellPickNoHit
    isHit (pickPixel plan (100, 30)) `shouldBe` True
    isHit (pickPixel plan (100, 179)) `shouldBe` True
    pickPixel plan (100, 180) `shouldBe` CellPickNoHit
  it "treats a fractional viewport edge by the pixel centre" $ do
    assets ← loadAssets 5
    let scene = (sceneOf FaceSouth 0 lattice) {sceneSetup = (sceneSetup (sceneOf FaceSouth 0 [])) {setupViewport = Viewport (V2 40.5 30.25) (V2 200.5 150)}}
        plan = planScene assets scene
    pickPixel plan (39, 100) `shouldBe` CellPickNoHit
    -- Pixel 40 has its centre at 40.5, exactly the left edge: inside.
    isHit (pickPixel plan (40, 100)) `shouldBe` True
    isHit (pickPixel plan (240, 100)) `shouldBe` True
    pickPixel plan (241, 100) `shouldBe` CellPickNoHit
  it "maps a cursor through the framebuffer scale to its physical pixel and tests that pixel's centre" $ do
    assets ← loadAssetsWith 5 [(stoneColour, planeFromFormula (\x _ → even x)), (AssetMap fullShape, allOn)]
    let base = sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll]
        scaled = base {sceneSetup = (sceneSetup base) {setupMetrics = TargetMetrics (PixelExtent 160 120) (PixelExtent 320 240) 2 2}}
        plan = planScene assets scaled
        (l, t, _, _) = rectOf (onlyQuad plan)
        cursor fx fy = V2 (fx / 2) (fy / 2)
        at fx fy = pickCells plan (CellPickQuery (cellPlanIdentity plan) (cursor fx fy))
        row = fromRational (t + 20) ∷ Float
        x0 = fromRational l ∷ Float
    -- Two cursors in one physical pixel are one answer; the next pixel is the next texel.
    at (x0 + 0.01) row `shouldBe` at (x0 + 0.99) row
    at (x0 + 0.5) row `shouldSatisfy` (\r → fmap isHit r == Right True)
    fmap isHit (at (x0 + 1.5) row) `shouldBe` Right False
    fmap isHit (at (x0 + 2.5) row) `shouldBe` Right True
  it "samples an enlarged quad by exact proportion at zoom 2 and at a fractional zoom" $ do
    forM_ [2, 1.5, 0.5] $ \zoom → do
      assets ← loadAssetsWith 5 [(stoneColour, planeFromFormula (\x _ → x < 48)), (AssetMap fullShape, allOn)]
      let scene = withCamera (command (SetZoom zoom)) oneBlock
          plan = planScene assets scene
          (l, t, r, b) = rectOf (onlyQuad plan)
          row = floor (t + (b - t) / 2) ∷ Int
          columns = [floor l - 1 .. ceiling r] ∷ [Int]
          inside px = l <= toRational px + 1 / 2 && toRational px + 1 / 2 < r
          texelX px = floor ((toRational px + 1 / 2 - l) * 96 / (r - l)) ∷ Int
      [ px
        | px ← columns
        , isHit (pickPixel plan (px, row)) /= (inside px && texelX px < 48)
        ] `shouldBe` []
  it "places quads on whole pixels when the view snaps" $ do
    assets ← loadAssetsWith 5 [(stoneColour, allOn), (AssetMap fullShape, allOn)]
    let snapped = (withCamera halfPixelPan oneBlock) {sceneSetup = (sceneSetup oneBlock) {setupSettings = (setupSettings (sceneSetup oneBlock)) {settingPixelSnap = True}}}
        plan = planScene assets snapped
        (l, t, r, b) = rectOf (onlyQuad plan)
    (denominator l, denominator t) `shouldBe` (1, 1)
    (r - l, b - t) `shouldBe` (96, 64)
    isHit (pickPixel plan (floor l, floor t)) `shouldBe` True
    pickPixel plan (floor l - 1, floor t) `shouldBe` CellPickNoHit
  it "has no hit in a zero extent and refuses a non-finite point and a stale identity" $ do
    assets ← loadAssets 5
    let zero = (sceneOf FaceSouth 0 [OCell 0 0 0 0 KnownAll]) {sceneSetup = (setupZero (sceneSetup oneBlock))}
        plan = planScene assets zero
        full = planScene assets oneBlock
    cellPlanQuads plan `shouldBe` []
    pickCells plan (CellPickQuery (cellPlanIdentity plan) (V2 10 10)) `shouldBe` Right CellPickNoHit
    pickCells full (CellPickQuery (cellPlanIdentity full) (V2 (0 / 0) 1)) `shouldBe` Left CellPickInvalidPoint
    pickCells full (CellPickQuery (cellPlanIdentity plan) (V2 10 10)) `shouldBe` Left CellPickStale
  where
    setupZero s = s {setupViewport = Viewport (V2 0 0) (V2 0 0)}
    _unused = (emptyChanges, factsOf flatWorld, ViewSettings, source, Versions, mkKnowledge, MapKey, knowledgeRuns)

-- ---------------------------------------------------------------------------

-- A cell is omitted as hidden only when its neighbours' drawn rectangles are
-- exact translates of its own, because only then does the translation of the
-- texel proof hold for the pixels actually sampled. Each quad's rectangle is
-- rounded through 32-bit floats on its own, so at a fractional zoom or pan the
-- rectangles can miss by a unit of the last place and a pixel centre can fall
-- on the wrong side of a shared edge.
fractionalOcclusion ∷ Spec
fractionalOcclusion = describe "omission of hidden cells under the transforms as drawn" $ do
  let cluster = sceneOf FaceSouth 1 [OCell 0 0 0 0 KnownAll, OCell 0 0 1 0 KnownAll, OCell 1 0 0 0 KnownAll, OCell 0 1 0 0 KnownAll]
      rear = tileAt 0 0 0
      tilesOf plan = Set.fromList [t | q ← cellPlanQuads plan, Just t ← [quadCell q]]
      zoomed z = withCamera (command (SetZoom z))
      panned dx dy = withCamera (command (Pan dx dy))
      snapped scene = scene {sceneSetup = (sceneSetup scene) {setupSettings = (setupSettings (sceneSetup scene)) {settingPixelSnap = True}}}
  it "keeps the rear block where a pixel centre falls on a rounded shared edge, as a retained quad would answer" $ do
    assets ← loadAssets 5
    let scene = panned (5 / 48) (5 / 144) (zoomed 0.15 cluster)
        plan = planScene assets scene
    tilesOf plan `shouldSatisfy` Set.member rear
    hitCellOf (pickPixel plan (159, 125)) `shouldBe` Just rear
  it "answers every sampled pixel exactly as the plan that omits nothing does, across zooms, pans and snapping" $ do
    assets ← loadAssets 5
    -- A style whose catalog holds a map that reaches outside the full block proves
    -- nothing, so its plan keeps every cell; the planes the scene draws are the same.
    unproved ← loadAssetsWith 5 [(AssetMap (MapKey Ordinary (either (error . show) id (mkShapeId 5))), allOn)]
    mapCoversHexagon unproved fullShape `shouldBe` False
    let variants =
          [ (zoom, (dx, dy), snap)
          | zoom ← [0.15, 0.3, 0.5, 1, 1.1, 1.5, 2, 2.5]
          , (dx, dy) ← [(0, 0), (5 / 48, 5 / 144), (1 / 64, 1 / 192), (0.3, 0.2)]
          , snap ← [False, True]
          , not snap || zoom `elem` [0.5, 1, 2]
          ]
        build snap zoom (dx, dy) = (if snap then snapped else id) (panned dx dy (zoomed zoom cluster))
        outcome (zoom, pan, snap) =
          let scene = build snap zoom pan
              kept = planScene unproved scene
              plan = planScene assets scene
           in ( [px | px ← stridePixels 6 <> [(159, 125)], pickPixel plan px /= pickPixel kept px]
              , Set.member rear (tilesOf plan)
              )
        outcomes = map outcome variants
    [v | (v, (differences, _)) ← zip variants outcomes, not (null differences)] `shouldBe` []
    -- The shortcut still works where the rectangles are exact, and still declines elsewhere.
    any (not . snd) outcomes `shouldBe` True
    any snd outcomes `shouldBe` True
