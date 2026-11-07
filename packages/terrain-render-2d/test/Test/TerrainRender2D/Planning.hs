-- | Visible-face planning: exposure, shapes in every facing, the cut, the
-- visibility band, unavailable data and demand, bounds and refusals.
module Test.TerrainRender2D.Planning (spec) where

import Control.Monad (forM_)
import Data.Bits (popCount, shiftL, (.&.), (.|.))
import Data.List (nub, sort)
import qualified Data.Set as Set
import Hetoimasia.Terrain.Cell (ZRange, mkZRange, zRangeLo)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), RemoveOutcome (..), emptyChanges, removeCell)
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisMaxValue, axisMinValue, axisValue)
import Hetoimasia.Terrain.Geometry (FaceKind (..))
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection (Rect (..), ViewSetup (..))
import GHC.Stats (RTSStats (allocated_bytes), getRTSStats, getRTSStatsEnabled)
import Control.Exception (evaluate)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), ZoomMode (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot ()
import Hetoimasia.Terrain.Shape (Side (..), ViewFacing (..), shapeIdValue)
import Hetoimasia.Terrain.Source
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.TerrainRender2D.Fixtures
import Test.TerrainRender2D.Ordering (Scene (..), scenes, withFacing)
import Test.TerrainRender2D.Oracle (Cell3, sceneSource)

zr ∷ Integer → Integer → ZRange
zr lo hi = either (\e → error (show e)) id (mkZRange lo hi)

-- | The positive quarter turns a facing applies to a stored mask: South 0,
-- West 3, North 2, East 1 (the shape facings' table).
turnsOf ∷ ViewFacing → Int
turnsOf FaceSouth = 0
turnsOf FaceWest = 3
turnsOf FaceNorth = 2
turnsOf FaceEast = 1

-- | A four-bit mask turned by whole quarter turns: North 1 to East 2 to South 4
-- to West 8 to North.
turnMask ∷ Int → Int → Int
turnMask t m = ((m `shiftL` t) .|. (m `shiftL` t `div` 16)) .&. 15

-- | Expected number of faces of an isolated cell on air, from first
-- principles: one top face per ramp (one for a flat top), plus the East and
-- South walls unless that side is lowered to the base.
expectedFaceCount ∷ Int → Int
expectedFaceCount mask
  | mask == 0 || mask == 15 = 3
  | otherwise = popCount mask + (if mask .&. 2 == 0 then 1 else 0) + (if mask .&. 4 == 0 then 1 else 0)

kinds ∷ Plan → [FaceKind]
kinds = map faceViewKind . planFaces

tilesOf ∷ Plan → [TileCoord]
tilesOf = nub . map faceCell . planFaces

zOf ∷ TileCoord → Integer
zOf = toInteger . axisValue . tileZ

chunkKnown ∷ [ChunkKey] → Integer → Integer → Availability
chunkKnown keys lo hi = mkAvailability [(k, [zr lo hi]) | k ← keys]

view ∷ ViewSetup
view = setup 480 480

-- | Every chunk the test views reach is ready at every level, except the
-- listed chunks, which are ready only below the given unready range (or not at
-- all when the range covers their whole band).
almostEverythingAvail ∷ [ChunkKey] → ZRange → Availability
almostEverythingAvail unready range = mkAvailability ([(k, [zr (-300) 300]) | k ← allChunks, k `notElem` unready] <> [(k, [zr (-300) (max (-300) (min 300 (lo range)))]) | k ← unready, lo range > -300])
  where
    allChunks = [ChunkKey cx cy | cx ← [-8 .. 8], cy ← [-8 .. 8]]
    lo = zRangeLo

spec ∷ Spec
spec = describe "Planning" $ do
  describe "shapes in every facing" $
    forM_ [0 .. 15 ∷ Int] $ \shape →
      forM_ allFacings $ \facing →
        it ("shape " <> show shape <> " seen from " <> show facing <> " plans exactly its camera-facing exposed faces") $ do
          let camera = withFacing facing (manualCamera 0 0 0)
              p = plan (setup 288 144) camera (factsOf (isolated shape))
              viewMask = turnMask (turnsOf facing) shape
          length (planFaces p) `shouldBe` expectedFaceCount viewMask
          -- Nothing faces away: no bottom, North or West wall, and so no ceiling.
          kinds p `shouldSatisfy` all (`elem` [TopFace, WallFace East, WallFace South])
          -- The authored world identity and tile are kept, not the turned mask.
          map faceShape (planFaces p) `shouldSatisfy` all ((== shape) . shapeIdValue)
          tilesOf p `shouldBe` [tileAt 0 0 0]
          map faceRole (planFaces p) `shouldSatisfy` all (== RoleSurface)
          planCompleteness p `shouldBe` Complete

  it "keeps the distinct identities 0 and 15 apart although both are flat" $ do
    let faces s = planFaces (plan (setup 288 144) (manualCamera 0 0 0) (factsOf (isolated s)))
    map faceViewKind (faces 0) `shouldBe` map faceViewKind (faces 15)
    map facePolygon (faces 0) `shouldBe` map facePolygon (faces 15)
    map (shapeIdValue . faceShape) (faces 0) `shouldBe` [0, 0, 0]
    map (shapeIdValue . faceShape) (faces 15) `shouldBe` [15, 15, 15]

  it "plans NS and EW as distinct opposite-direction forms that exchange under a single turn" $ do
    let faces s f = planFaces (plan (setup 288 144) (withFacing f (manualCamera 0 0 0)) (factsOf (isolated s)))
        shapeOf = map facePolygon
    shapeOf (faces 5 FaceSouth) `shouldSatisfy` (/= shapeOf (faces 10 FaceSouth))
    shapeOf (faces 5 FaceEast) `shouldBe` shapeOf (faces 10 FaceSouth)
    shapeOf (faces 10 FaceEast) `shouldBe` shapeOf (faces 5 FaceSouth)

  it "emits no downward or away-facing face in any scene, facing or cut" $
    forM_ scenes $ \scene →
      forM_ allFacings $ \facing → do
        let p = plan (setup 480 320) (withFacing facing (manualCamera 0 0 (sceneCut scene))) (factsOf (sceneSource (sceneCells scene)))
        kinds p `shouldSatisfy` all (`elem` [TopFace, WallFace East, WallFace South])

  describe "contacts between shapes use the shared wall coverage, not full-block occupancy" $ do
    let wallsOf cells = [faceViewKind f | f ← planFaces (plan (setup 288 144) (manualCamera 0 0 0) (factsOf (sceneSource cells))), faceCell f == tileAt 0 0 0]
    it "exposes a flat cell's East wall exactly when the neighbour's West wall does not cover it" $
      forM_ [0 .. 15] $ \s → do
        let covered = s `elem` [0, 2, 15 ∷ Int]
            east = length [() | WallFace East ← wallsOf [(0, 0, 0, 0), (1, 0, 0, s)]]
        (s, east) `shouldBe` (s, if covered then 0 else 1 ∷ Int)
    it "exposes a flat cell's South wall exactly when the neighbour's North wall does not cover it" $
      forM_ [0 .. 15] $ \s → do
        let covered = s `elem` [0, 4, 15 ∷ Int]
            south = length [() | WallFace South ← wallsOf [(0, 0, 0, 0), (0, 1, 0, s)]]
        (s, south) `shouldBe` (s, if covered then 0 else 1 ∷ Int)
    it "never reshapes a neighbour: every face keeps its authored shape" $ do
      let p = plan (setup 288 144) (manualCamera 0 0 0) (factsOf (sceneSource [(0, 0, 0, 0), (1, 0, 0, 1), (0, 1, 0, 6)]))
          shapesOf tile = nub [shapeIdValue (faceShape f) | f ← planFaces p, faceCell f == tile]
      shapesOf (tileAt 0 0 0) `shouldBe` [0]
      shapesOf (tileAt 1 0 0) `shouldBe` [1]
      shapesOf (tileAt 0 1 0) `shouldBe` [6]

  describe "the cutaway" $ do
    let slab = [(x, y, z, 0) | x ← [-2 .. 2], y ← [-2 .. 2], z ← [0 .. 5]] ∷ [Cell3]
        facts = factsOf (sceneSource slab)
        atCut c = plan view (manualCamera 0 0 c) facts
    it "plans no geometry above the selected cut" $
      forM_ [0, 2, 3, 5] $ \c →
        map zOf (tilesOf (atCut c)) `shouldSatisfy` all (<= c)
    it "shows the cut slice's tops as caps, because the cut removed the cell above" $ do
      let p = atCut 2
          tops = [f | f ← planFaces p, faceViewKind f == TopFace]
      tops `shouldSatisfy` (not . null)
      map faceRole tops `shouldSatisfy` all (== RoleCap)
      map (zOf . faceCell) tops `shouldSatisfy` all (== 2)
    it "shows a surface, not a cap, where the cell above is known air" $ do
      let tops = [f | f ← planFaces (atCut 5), faceViewKind f == TopFace]
      map faceRole tops `shouldSatisfy` all (== RoleSurface)
      map (zOf . faceCell) tops `shouldSatisfy` all (== 5)
    it "plans only what the cut reveals when the cut lies above the surface" $
      map zOf (tilesOf (atCut 40)) `shouldSatisfy` all (<= 5)
    it "omits a top that a solid cell covers below the cut" $ do
      let p = atCut 4
      [f | f ← planFaces p, faceViewKind f == TopFace, zOf (faceCell f) < 4] `shouldBe` []

  describe "the visibility band" $ do
    let shaft =
          source
            SourceSpec
              { specMaterials = ["stone"]
              , specLayers = [LayerSpec Nothing (Just 1) "stone" 0]
              , specPatches = [PatchSpec 0 0 (-40) 1 SpecAir]
              }
        shaftPlan depth = either (error . show) id (planWith (\r → r {requestConfig = (requestConfig r) {pcDepth = depth}}) view (manualCamera 0 0 0) (factsOf shaft))
    it "is 250 levels below the clip level by default, a cap and not a floor" $ do
      pcDepth defaultPlanConfig `shouldBe` 250
      let p = shaftPlan 10
      minimum (map zOf (tilesOf p)) `shouldBe` (-10)
      maximum (map zOf (tilesOf p)) `shouldBe` 0
    it "includes exactly the clip level and the configured levels below it" $
      sort (nub (map zOf (tilesOf (shaftPlan 3)))) `shouldBe` [-3, -2, -1, 0]
    it "does not enumerate the volume between the surface and a deep slice" $ do
      let deepFacts = factsOf flatWorld
          shallow = plan view (manualCamera 0 0 (-100)) deepFacts
          deep = plan view (manualCamera 0 0 (-1000000)) deepFacts
      statLevelsEvaluated (planStats deep) `shouldBe` statLevelsEvaluated (planStats shallow)
      statLevelsEvaluated (planStats deep) `shouldSatisfy` (<= 2 * statColumns (planStats deep))
      map zOf (tilesOf deep) `shouldSatisfy` all (== (-1000000))
    it "skips a long gap of air between spans and a long run of removed cells" $ do
      let spans =
            source
              SourceSpec
                { specMaterials = ["stone"]
                , specLayers = [LayerSpec Nothing (Just (-1000)) "stone" 0]
                , specPatches = [PatchSpec x y 0 4 (SpecSolid "stone" 0) | x ← [-1 .. 1], y ← [-1 .. 1]]
                }
          p = plan view (manualCamera 0 0 3) (factsOf spans)
      statLevelsEvaluated (planStats p) `shouldSatisfy` (< 20 * statColumns (planStats p))
      -- The 995 levels of air below the span are never visited.
      map zOf (tilesOf p) `shouldSatisfy` all (>= 0)
      let removed = either (error . show) removeResult (removeCell (ChangeLimits 8) flatWorld (tileAt 0 0 0) emptyChanges)
          q = plan view (manualCamera 0 0 0) (factsWith flatWorld removed AllKnown)
      -- The removed cell is no longer drawn, and its neighbours' walls open onto it.
      tilesOf q `shouldSatisfy` (tileAt 0 0 0 `notElem`)
      [() | f ← planFaces q, faceViewKind f == WallFace East, faceCell f == tileAt (-1) 0 0] `shouldSatisfy` (not . null)
    it "plans an absent column as nothing" $ do
      let hole = source (SourceSpec ["stone"] [LayerSpec Nothing (Just 1) "stone" 0] [PatchSpec 0 0 (-4611686018427387904) 1 SpecAir])
          p = plan view (manualCamera 0 0 0) (factsOf hole)
      [f | f ← planFaces p, tileX (faceCell f) == axis 0, tileY (faceCell f) == axis 0] `shouldBe` []
      planCompleteness p `shouldBe` Complete

  describe "far coordinates" $ do
    let flatAt x y z = (x, y, z, 0) ∷ Cell3
        camAt x y c =
          let fresh = either (error . show) id (newCamera defaultCameraConfig (axis x) (axis y) (axis c))
           in stepCamera (either (error . show) id (applyCommand defaultCameraConfig (factsOf flatWorld) (SelectSlice (axis c)) fresh))
        topOf p tile = case [f | f ← planFaces p, faceCell f == tile, faceViewKind f == TopFace] of
          (f : _) → facePolygon f
          [] → error ("no top face for " <> show tile)
        shift (dx, dy) = map (\(x, y) → (x + dx, y + dy))
    it "keeps adjacent cells distinct at the highest supported coordinate, never wrapping" $ do
      let m = axisMaxValue
          p = plan (setup 288 144) (camAt m 0 0) (factsOf (sceneSource [flatAt (m - 1) 0 0, flatAt m 0 0]))
      sort (tilesOf p) `shouldBe` sort [tileAt (m - 1) 0 0, tileAt m 0 0]
      -- One tile toward -X is 48 pixels left and 24 up.
      topOf p (tileAt (m - 1) 0 0) `shouldBe` shift (-48, -24) (topOf p (tileAt m 0 0))
      -- The world ends at the maximum: the next cell is nothing, so the East wall shows.
      [() | f ← planFaces p, faceCell f == tileAt m 0 0, faceViewKind f == WallFace East] `shouldSatisfy` (not . null)
      [() | f ← planFaces p, faceCell f == tileAt (m - 1) 0 0, faceViewKind f == WallFace East] `shouldBe` []
    it "keeps adjacent cells distinct at the lowest supported coordinate" $ do
      let n = axisMinValue
          p = plan (setup 288 144) (camAt n 0 0) (factsOf (sceneSource [flatAt n 0 0, flatAt (n + 1) 0 0]))
      sort (tilesOf p) `shouldBe` sort [tileAt n 0 0, tileAt (n + 1) 0 0]
      topOf p (tileAt (n + 1) 0 0) `shouldBe` shift (48, 24) (topOf p (tileAt n 0 0))
    it "plans the top level and a far corner in every facing without overflow" $
      forM_ allFacings $ \facing → do
        let m = axisMaxValue
            cells = [flatAt x y m | x ← [m - 1, m], y ← [m - 1, m]]
            p = plan (setup 288 144) (withFacing facing (camAt m m m)) (factsOf (sceneSource cells))
        sort (tilesOf p) `shouldBe` sort [tileAt x y m | x ← [m - 1, m], y ← [m - 1, m]]
        planCompleteness p `shouldBe` Complete

  describe "unavailable data" $ do
    let two = sceneSource [(15, 0, 0, 0), (16, 0, 0, 0)]
        camera = manualCamera 15 0 0
        partial = almostEverything [ChunkKey 1 0] (zr (-300) 300)
        almostEverything unready _ = factsWith two emptyChanges (almostEverythingAvail unready (zr (-300) 300))
    it "does not invent an exposed face against a neighbour nothing is known about" $ do
      let p = plan (setup 288 144) camera partial
          full = plan (setup 288 144) camera (factsOf two)
      planCompleteness p `shouldBe` Incomplete
      [() | f ← planFaces p, faceCell f == tileAt 15 0 0, faceViewKind f == WallFace East] `shouldBe` []
      [() | f ← planFaces p, faceCell f == tileAt 15 0 0, faceViewKind f == TopFace] `shouldSatisfy` (not . null)
      tilesOf p `shouldBe` [tileAt 15 0 0]
      -- Known, the neighbour covers the wall and is itself planned.
      planCompleteness full `shouldBe` Complete
      sort (tilesOf full) `shouldBe` [tileAt 15 0 0, tileAt 16 0 0]
      [() | f ← planFaces full, faceCell f == tileAt 15 0 0, faceViewKind f == WallFace East] `shouldBe` []
    it "names the missing facts as chunk keys, level intervals and region keys, and bounds the unknown cells" $ do
      let p = plan (setup 288 144) camera (almostEverything [ChunkKey 1 0] (zr (-300) 300))
      map demandChunk (demandChunks (planDemand p)) `shouldBe` [ChunkKey 1 0]
      forM_ (demandChunks (planDemand p)) $ \c → do
        demandIntervals c `shouldSatisfy` any (\(lo, hi) → lo <= 0 && 0 < hi)
        demandRegions c `shouldSatisfy` elem 0
        length (demandRegions c) `shouldSatisfy` (<= limitRegionsPerChunk defaultPlanLimits)
      planUnknown p `shouldSatisfy` (not . null)
    it "does not treat an unready level as air: the cell above a top is asked for, not assumed" $ do
      -- Everything is ready except the levels from 1 up in the chunk of the cell.
      let facts = factsWith (sceneSource [(0, 0, 0, 0)]) emptyChanges (almostEverythingAvail [ChunkKey 0 0] (zr 1 300))
          p = plan (setup 288 144) (manualCamera 0 0 5) facts
      [() | f ← planFaces p, faceViewKind f == TopFace] `shouldBe` []
      map demandChunk (demandChunks (planDemand p)) `shouldBe` [ChunkKey 0 0]
      forM_ (demandChunks (planDemand p)) $ \c → demandIntervals c `shouldSatisfy` any (\(lo, _) → lo == 1)
      planCompleteness p `shouldBe` Incomplete
    it "plans nothing, and says so, where a cell itself is not ready" $ do
      let facts = factsWith (sceneSource [(0, 0, 0, 0)]) emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-10) 0])])
          p = plan (setup 288 144) (manualCamera 0 0 0) facts
      tilesOf p `shouldBe` []
      planCompleteness p `shouldBe` Incomplete
      demandChunks (planDemand p) `shouldSatisfy` any (any (\(lo, hi) → lo <= 0 && 0 < hi) . demandIntervals)
    it "produces the same known geometry across a vertical region seam as one unified input" $ do
      let world = sceneSource ([(x, y, z, 0) | x ← [-2 .. 2], y ← [-2 .. 2], z ← [0 .. 3]] <> [(1, 1, 4, 3)])
          keys = [ChunkKey cx cy | cx ← [-8 .. 8], cy ← [-8 .. 8]]
          unified = chunkKnown keys (-300) 300
          split = mkAvailability ([(k, [zr (-300) 2, zr 2 300]) | k ← keys])
          p a = plan view (manualCamera 0 0 4) (factsWith world emptyChanges a)
      planFaces (p split) `shouldBe` planFaces (p unified)
      planFaces (p split) `shouldBe` planFaces (p AllKnown)
    it "produces the same known geometry across a chunk seam as one unified input, without duplicates or cracks" $ do
      let world = sceneSource ([(x, y, 0, 0) | x ← [12 .. 20], y ← [-2 .. 2]] <> [(16, 0, 1, 0), (15, 1, 1, 4)])
          keys = [ChunkKey cx cy | cx ← [-8 .. 8], cy ← [-8 .. 8]]
          p a = plan view (manualCamera 15 0 2) (factsWith world emptyChanges a)
          ids ps = [(faceCell f, faceViewKind f, faceIndex f) | f ← planFaces ps]
      planFaces (p (chunkKnown keys (-300) 300)) `shouldBe` planFaces (p AllKnown)
      length (nub (ids (p AllKnown))) `shouldBe` length (ids (p AllKnown))

  describe "demand for the camera" $ do
    let known = factsWith flatWorld emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-2000) 2000])])
        req = request view (manualCamera 0 0 0)
    it "is empty when everything the view and its margin need is ready" $
      cameraDemand req (factsOf flatWorld) `shouldBe` Right emptyDemand
    it "names the visible chunks and one chunk of margin that are not ready, with bounded vertical regions" $ do
      let demand = demandOf req known
          chunks = map demandChunk (demandChunks demand)
      chunks `shouldSatisfy` (not . null)
      chunks `shouldSatisfy` (ChunkKey 0 0 `notElem`)
      -- Every demanded chunk is within the visible chunks plus one margin ring.
      Set.fromList chunks `shouldSatisfy` all (\(ChunkKey cx cy) → abs cx <= 8 && abs cy <= 8) . Set.toList
      forM_ (demandChunks demand) $ \c → do
        length (demandRegions c) `shouldSatisfy` (<= limitRegionsPerChunk defaultPlanLimits)
        -- Within the band below the clip level and the cell above it.
        demandIntervals c `shouldSatisfy` all (\(lo, hi) → lo >= -250 && hi <= 2)
    it "refuses an oversized margin at once, before generating its ring" $ do
      let big = req {requestConfig = (requestConfig req) {pcChunkMargin = 1000000, pcLimits = (pcLimits (requestConfig req)) {limitDemandChunks = 0}}}
          big' = req {requestConfig = (requestConfig req) {pcChunkMargin = 1000000}}
      cameraDemand big known `shouldBe` Left (PlanInsufficient LimitDemandChunks)
      cameraDemand big' known `shouldBe` Left (PlanInsufficient LimitDemandChunks)
    it "includes the lowest supported chunk in the margin ring" $ do
      let low = axisMinValue + 24
          r = (request (setup 1 1) (manualCamera low low 0)) {requestConfig = defaultPlanConfig {pcDepth = 0}}
          facts' = factsWith flatWorld emptyChanges (mkAvailability [])
          chunks = map demandChunk (demandChunks (demandOf r facts'))
          lowest = fromInteger (negate (2 ^ (58 ∷ Int)))
      chunks `shouldSatisfy` (ChunkKey lowest lowest `elem`)
      -- And the highest supported chunk keeps its bound: nothing beyond it.
      let high = axisMaxValue - 24
          rh = (request (setup 1 1) (manualCamera high high 0)) {requestConfig = defaultPlanConfig {pcDepth = 0}}
          top = fromInteger (2 ^ (58 ∷ Int) - 1)
          highChunks = map demandChunk (demandChunks (demandOf rh facts'))
      highChunks `shouldSatisfy` (ChunkKey top top `elem`)
      highChunks `shouldSatisfy` all (\(ChunkKey x y) → x <= top && y <= top)
    it "adds exactly the margin ring around the visible chunks" $ do
      let narrow = req {requestConfig = (requestConfig req) {pcChunkMargin = 0}}
          wide = demandOf req known
          tight = demandOf narrow known
      length (demandChunks wide) `shouldSatisfy` (> length (demandChunks tight))

  describe "bounds and refusals" $ do
    let facts = factsOf (isolated 0)
        camera = manualCamera 0 0 0
        limited f = planWith (\r → r {requestConfig = (requestConfig r) {pcLimits = f (pcLimits (requestConfig r))}}) (setup 288 144) camera facts
    it "refuses rather than truncates when a bound would be exceeded" $ do
      limited (\l → l {limitColumns = 10}) `shouldBe'` PlanInsufficient LimitColumns
      limited (\l → l {limitLevels = 0}) `shouldBe'` PlanInsufficient LimitLevels
      limited (\l → l {limitFaces = 2}) `shouldBe'` PlanInsufficient LimitFaces
      limited (\l → l {limitPairs = 0}) `shouldBe'` PlanInsufficient LimitPairs
      limited (\l → l {limitKeys = 2}) `shouldBe'` PlanInsufficient LimitDepthKeys
    it "stops collecting overlap pairs at the bound instead of finishing the enumeration" $ do
      -- n floating cells along the line of sight project to the same place: 3n
      -- faces in one region and about 4.5 n^2 overlapping pairs. Refusing at one
      -- pair must cost work that grows with the faces, not with the pairs: doubling
      -- n roughly doubles the allocation (a full enumeration would quadruple it).
      let stackRun n =
            planWith
              (\r → r {requestConfig = (requestConfig r) {pcLimits = (pcLimits (requestConfig r)) {limitPairs = 1}}})
              (setup 480 480)
              (manualCamera (n - 1) (n - 1) (3 * (n - 1)))
              (factsOf (sceneSource [(k, k, 3 * k, 0) | k ← [0 .. n - 1]]))
      small ← allocatedBy (stackRun 125)
      large ← allocatedBy (stackRun 250)
      stackRun 250 `shouldBe'` PlanInsufficient LimitPairs
      large `shouldSatisfy` (< 3 * small)
    it "accepts exactly at a bound" $ do
      limited (\l → l {limitFaces = 3, limitKeys = 3}) `shouldSatisfy` isRight'
      let examined = statLevelsEvaluated (planStats (plan (setup 288 144) camera facts))
      limited (\l → l {limitLevels = examined}) `shouldSatisfy` isRight'
      limited (\l → l {limitLevels = examined - 1}) `shouldBe'` PlanInsufficient LimitLevels
    it "refuses a demand that exceeds its bounds" $ do
      let partialFacts = factsWith (sceneSource [(15, 0, 0, 0), (16, 0, 0, 0)]) emptyChanges (mkAvailability [(ChunkKey 0 0, [zr (-10) 10])])
          lim f = planWith (\r → r {requestConfig = (requestConfig r) {pcLimits = f (pcLimits (requestConfig r))}}) (setup 288 144) (manualCamera 15 0 0) partialFacts
      lim (\l → l {limitDemandChunks = 0}) `shouldBe'` PlanInsufficient LimitDemandChunks
      lim (\l → l {limitDemandIntervals = 0}) `shouldBe'` PlanInsufficient LimitDemandIntervals
      lim (\l → l {limitRegionsPerChunk = 0}) `shouldBe'` PlanInsufficient LimitRegionsPerChunk
    it "refuses a negative configured depth or margin" $ do
      planWith (\r → r {requestConfig = (requestConfig r) {pcDepth = -1}}) (setup 288 144) camera facts `shouldBe'` InvalidPlanConfig
    it "enforces the approved visibility depth of 250 levels on a caller's configuration" $ do
      let withDepth d = planWith (\r → r {requestConfig = (requestConfig r) {pcDepth = d}}) (setup 288 144) camera facts
      withDepth 250 `shouldSatisfy` isRight'
      withDepth 251 `shouldBe'` InvalidPlanConfig
    it "plans nothing when the framebuffer or logical extent is zero, whatever the viewport says" $ do
      let base = setup 288 144
          zeroFramebuffer = base {setupMetrics = (setupMetrics base) {metricsFramebuffer = PixelExtent 0 0}}
          zeroWidth = base {setupMetrics = (setupMetrics base) {metricsLogical = PixelExtent 0 144}}
      forM_ [zeroFramebuffer, zeroWidth] $ \vs → do
        let p = plan vs camera (factsWith (sceneSource [(0, 0, 0, 0)]) emptyChanges (mkAvailability []))
        planFaces p `shouldBe` []
        planDemand p `shouldBe` emptyDemand
        planCompleteness p `shouldBe` Complete
    it "refuses a face the view's mapping cannot place in the target, rather than planning it" $ do
      let tiny = (setup 288 144) {setupSettings = defaultViewSettings {settingZoomMode = FixedHalfHeight 7.2e-37}}
      planWith id tiny camera facts `shouldSatisfy` isLeft'
    it "refuses mixed versions and carries one coherent identity" $ do
      let mixed = planWith (\r → r {requestVersions = Versions 1 2 1}) (setup 288 144) camera facts
      mixed `shouldBe'` MixedVersions (Versions 1 2 1) versions
      planWith (\r → r {requestVersions = Versions 2 1 1}) (setup 288 144) camera facts `shouldBe'` MixedVersions (Versions 2 1 1) versions
      planWith (\r → r {requestVersions = Versions 1 1 2}) (setup 288 144) camera facts `shouldBe'` MixedVersions (Versions 1 1 2) versions
      let p = plan (setup 288 144) camera facts
      identityVersions (planIdentity p) `shouldBe` versions
      identityMaterialVersion (planIdentity p) `shouldBe` 7
      (identityFacing (planIdentity p), axisValue (identityCut (planIdentity p)), identityReference (planIdentity p)) `shouldBe` (FaceSouth, 0, 1)
      identityCameraRevision (planIdentity p) `shouldBe` camRevision camera
    it "rebuilds as a whole new value and leaves a retained older plan unchanged" $ do
      let before = plan (setup 288 144) camera (factsOf flatWorld)
          snapshot = before
          removed = either (error . show) removeResult (removeCell (ChangeLimits 8) flatWorld (tileAt 0 0 0) emptyChanges)
          after = plan (setup 288 144) camera (factsWith flatWorld removed AllKnown)
      after `shouldSatisfy` (/= before)
      before `shouldBe` snapshot
      before `shouldBe` plan (setup 288 144) camera (factsOf flatWorld)
    it "bounds every face by the plan's bounds and ascends the keys" $ do
      let p = plan view (manualCamera 0 0 3) (factsOf (sceneSource (sceneCells (scenes !! 1))))
          Rect x1 x2 y1 y2 = maybe (error "a plan with faces has bounds") id (planBounds p)
      map faceDepthKey (planFaces p) `shouldBe` [0 .. fromIntegral (length (planFaces p)) - 1]
      forM_ (planFaces p) $ \f → forM_ (facePolygon f) $ \(x, y) →
        (x1 <= x && x <= x2 && y1 <= y && y <= y2) `shouldBe` True

demandOf ∷ PlanRequest → TerrainFacts → Demand
demandOf r f = either (error . show) id (cameraDemand r f)

shouldBe' ∷ Either PlanError Plan → PlanError → IO ()
shouldBe' (Left e) expected = e `shouldBe` expected
shouldBe' (Right _) expected = fail ("expected the refusal " <> show expected <> " but a plan was returned")

isLeft' ∷ Either a b → Bool
isLeft' (Left _) = True
isLeft' _ = False

allocatedBy ∷ Either PlanError Plan → IO Int
allocatedBy value = do
  enabled ← getRTSStatsEnabled
  if not enabled then fail "the suite must run with -T" else pure ()
  before ← getRTSStats
  _ ← evaluate (either (const 0) (length . planFaces) value)
  after ← getRTSStats
  pure (fromIntegral (allocated_bytes after - allocated_bytes before))

isRight' ∷ Either a b → Bool
isRight' (Right _) = True
isRight' _ = False
