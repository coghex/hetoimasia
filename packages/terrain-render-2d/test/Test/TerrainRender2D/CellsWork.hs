-- | TRA-16: the one work meter of the planner.
--
-- Everything a step examines of the caller's inputs is charged to one meter
-- ('cellStatStepWork'), and a step never charges more than 'clStepWork'. The
-- meter counts what the planner reads, so it cannot by itself show that nothing
-- is read outside it: the growth property below therefore also measures the
-- bytes a step allocates, which a walk over off-band input would grow.
--
-- For every input dimension (unused materials, knowledge runs, columns and
-- regions, readiness intervals and chunks, terrain patches, retained removals,
-- viewport and margin) the same scene is built with the dimension grown by 1,
-- 10 and 100 (its content placed far from the viewing band and, where it can be,
-- in the very column the first step examines) and one step under tiny limits is
-- run. The meter reading must not change and the allocation must stay within a
-- tolerance of the smallest.
module Test.TerrainRender2D.CellsWork (spec) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Int (Int64)
import Hetoimasia.Terrain.Cell (Column (..), mkZRange)
import Hetoimasia.Terrain.Changes (ChangeLimits (..), changesFromIntervals)
import Hetoimasia.Terrain.Render2D.Assets
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Knowledge
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source
import System.Mem (getAllocationCounter)
import Test.Hspec
import Test.TerrainRender2D.CellFixtures
import Test.TerrainRender2D.Fixtures (axis, setup, source)

spec ∷ Spec
spec = describe "Cell planning work meter (TRA-16)" $ beforeAll (loadAssets 5) $ do
  meterBound
  growth

-- ---------------------------------------------------------------------------
-- The meter bounds every step

meterBound ∷ SpecWith AssetSnapshot
meterBound = describe "the meter" $ do
  let cells = [OCell x y z 0 KnownAll | x ← [0 .. 3], y ← [0 .. 3], z ← [-3 .. 0]]
      scene = sceneOf FaceSouth 0 cells
      withWork n s = s {sceneConfig = (sceneConfig s) {ccLimits = (ccLimits (sceneConfig s)) {clStepWork = n}}}
      stepsOf inputs prep acc = case cellPrepProgress prep of
        Working → either (error . show) (\next → stepsOf inputs next (next : acc)) (stepCells inputs prep)
        _ → reverse (prep : acc)
      workOf inputs prep = cellStatStepWork (cellPlanStats (either (error . show) id (cellPlanOf inputs prep)))
  it "never charges a step more than clStepWork, and the plan is the same at every budget" $ \assets → do
    let once = planScene assets scene
    forM_ [8192, 20000, 100000] $ \n → do
      let inputs = inputsOf assets (withWork n scene)
          start = either (error . show) id (startCells inputs)
          trail = stepsOf inputs start [start]
      map (workOf inputs) trail `shouldSatisfy` all (<= n)
      map (workOf inputs) trail `shouldSatisfy` any (> 0)
      cellPrepProgress (last trail) `shouldBe` Settled
      map quadKey (cellPlanQuads (either (error . show) id (cellPlanOf inputs (last trail)))) `shouldBe` map quadKey (cellPlanQuads once)
    -- The smallest budget needs more steps than a generous one: the meter binds.
    let stepCount n = let inputs = inputsOf assets (withWork n scene) in length (stepsOf inputs (either (error . show) id (startCells inputs)) [])
    stepCount 8192 `shouldSatisfy` (> stepCount 8388608)
  it "refuses a step budget below the most one column can charge" $ \assets →
    startCells (inputsOf assets (withWork 8191 scene)) `shouldSatisfy` (\r → case r of Left CellInvalidConfig → True; _ → False)

-- ---------------------------------------------------------------------------
-- Growth of every input dimension

-- One reading of one step.
data Reading = Reading
  { readWork ∷ !Int
  , readBytes ∷ !Int64
  , readInstances ∷ !Int
  }

-- A step under tiny limits on a scene, with what it charged and allocated.
measure ∷ AssetSnapshot → Scene → IO Reading
measure assets scene = do
  let tiny = scene {sceneConfig = (sceneConfig scene) {ccLimits = (ccLimits (sceneConfig scene)) {clStepCandidates = 1, clStepLevels = 1}}}
      inputs = inputsOf assets tiny
  counterBefore ← getAllocationCounter
  let prep = either (error . show) id (startCells inputs >>= stepCells inputs)
      plan = either (error . show) id (cellPlanOf inputs prep)
      stats = cellPlanStats plan
  _ ← evaluate (length (show (stats, map quadKey (cellPlanQuads plan), cellPlanDemand plan)))
  counterAfter ← getAllocationCounter
  pure Reading {readWork = cellStatStepWork stats, readBytes = counterBefore - counterAfter, readInstances = cellStatInstances stats}

-- The world column the first step examines: the view offset of the first
-- candidate (the cursor holds its row sum and its difference, in that order),
-- turned back by the south facing, which is no turn.
firstColumn ∷ AssetSnapshot → Scene → (Integer, Integer)
firstColumn assets scene = case startCells inputs >>= cellPlanOf inputs of
  Right plan | Just unresolved ← cellPlanUnresolved plan →
    let (v, u) = unresolvedCursor unresolved in ((u + v) `div` 2, (v - u) `div` 2)
  other → error ("no first column: " <> either show (const "settled") other)
  where
    inputs = inputsOf assets scene

-- A dimension: how to build the assets and scene with it grown to a size.
data Dimension = Dimension
  { dimName ∷ String
  , dimBuild ∷ AssetSnapshot → Int → IO (AssetSnapshot, Scene)
  , dimExercised ∷ Bool
  -- ^ Whether the first step draws a quad from the column the dimension fills.
  }

-- Levels far below any viewing band, two apart, distinct for each index.
far ∷ Int → Integer
far i = negate 1000000 - 4 * toInteger i

-- The scene every dimension starts from: a shallow band over an empty source.
base ∷ Scene
base = (sceneFrom FaceSouth 0 0 0 (sourceOf []) (knowledgeOf 1 CellDiscovered []) AllKnown) {sceneConfig = defaultCellConfig {ccDepth = 8}}

-- The source with a solid column through the whole band at the first examined
-- column, so that the step draws from it, and some further patches.
markedSource ∷ (Integer, Integer) → [PatchSpec] → Source
markedSource (x, y) extra =
  source
    SourceSpec
      { specMaterials = ["stone"]
      , specLayers = []
      , specPatches = PatchSpec x y (-8) 1 (SpecSolid "stone" 0) : extra
      }

-- A scene with a solid column where the first step looks, over the given facts.
markedScene ∷ AssetSnapshot → (Source → Scene → Scene) → [PatchSpec] → Scene
markedScene assets adjust extra = adjust (markedSource column extra) base
  where
    column = firstColumn assets base

withSource ∷ Source → Scene → Scene
withSource src scene = scene {sceneFacts = (sceneFacts scene) {factsSource = src}}

dimensions ∷ [Dimension]
dimensions =
  [ Dimension "unused materials" materialsDimension True
  , Dimension "knowledge runs, columns and regions" knowledgeDimension True
  , Dimension "readiness intervals and chunks" availabilityDimension True
  , Dimension "terrain patches" patchesDimension True
  , Dimension "retained removals" removalsDimension True
  , Dimension "viewport and margin" viewportDimension False
  ]

materialsDimension, knowledgeDimension, availabilityDimension, patchesDimension, removalsDimension, viewportDimension ∷ AssetSnapshot → Int → IO (AssetSnapshot, Scene)
materialsDimension _ g = do
  assets ← loadAssetsExtra 5 (40 * g)
  pure (assets, markedScene assets withSource [])

knowledgeDimension assets g = pure (assets, scene)
  where
    n = 100 * g
    (x, y) = firstColumn assets base
    column = Column (axis x) (axis y)
    runs = [(far i, far i + 2, CellUndiscovered) | i ← [0 .. n - 1]]
    knowledge =
      either (error . show) id $
        mkKnowledge
          KnowledgeSpec
            { specRevision = 1
            , specDefault = CellDiscovered
            , specRegions = [(ChunkKey (fromIntegral (50 + i)) 0, 0, CellUndiscovered) | i ← [0 .. n - 1]]
            , specColumns = (column, runs) : [(Column (axis (100 + toInteger i)) (axis (100 + toInteger i)), [(0, 1, CellPending)]) | i ← [0 .. n - 1]]
            }
    scene = (markedScene assets withSource []) {sceneKnowledge = knowledge}

availabilityDimension assets g = pure (assets, scene)
  where
    n = 100 * g
    (x, y) = firstColumn assets base
    key = chunkOfColumn (Column (axis x) (axis y))
    ready lo hi = either (error . show) id (mkZRange lo hi)
    availability =
      mkAvailability
        ( (key, ready (-300) 300 : [ready (far i) (far i + 2) | i ← [0 .. n - 1]])
            : [(ChunkKey (fromIntegral (50 + i)) 0, [ready 0 5]) | i ← [0 .. n - 1]]
        )
    scene = let s = markedScene assets withSource [] in s {sceneFacts = (sceneFacts s) {factsAvailability = availability}}

patchesDimension assets g = pure (assets, scene)
  where
    -- The source refuses a definition of more than 262,144 bytes, so this dimension
    -- stops at 5,000 patches (2,500 in the examined column and 2,500 elsewhere).
    n = 25 * g
    (x, y) = firstColumn assets base
    patches =
      [PatchSpec x y (far i) (far i + 2) (SpecSolid "stone" 0) | i ← [0 .. n - 1]]
        <> [PatchSpec (100 + toInteger i) (100 + toInteger i) 0 1 (SpecSolid "stone" 0) | i ← [0 .. n - 1]]
    scene = markedScene assets withSource patches

removalsDimension assets g = pure (assets, scene)
  where
    n = 100 * g
    (x, y) = firstColumn assets base
    ready lo hi = either (error . show) id (mkZRange lo hi)
    changes =
      either (error . show) id $
        changesFromIntervals
          (ChangeLimits 100000000)
          ( [(Column (axis x) (axis y), ready (far i) (far i + 2)) | i ← [0 .. n - 1]]
              <> [(Column (axis (100 + toInteger i)) (axis (100 + toInteger i)), ready 0 1) | i ← [0 .. n - 1]]
          )
    scene = let s = markedScene assets withSource [] in s {sceneFacts = (sceneFacts s) {factsChanges = changes}}

viewportDimension assets g = pure (assets, scene)
  where
    scene = base {sceneSetup = setup (320 * g) (240 * g), sceneConfig = (sceneConfig base) {ccMargin = fromIntegral (2 * g)}}

growth ∷ SpecWith AssetSnapshot
growth = describe "growing every input dimension by 10 and 100" $
  forM_ dimensions $ \dim →
    it ("does not grow a step's work with " <> dimName dim) $ \assets → do
      -- Each size is read twice on the same scene: the first reading forces the lazily
      -- built input and every table, the second is a step on built input alone.
      let reading g = do
            (style, scene) ← dimBuild dim assets g
            _ ← measure style scene
            measure style scene
      readings ← mapM reading [1, 10, 100]
      let small = case readings of r : _ → r; [] → error "no readings"
          within r = readBytes r <= readBytes small + readBytes small `div` 10 + 16384
          same xs = case xs of x : rest → all (== x) rest; [] → True
      -- The meter is the same at every size and inside its limit (a dimension that moves
      -- the examined column is only held to the most one column can charge).
      map readWork readings `shouldSatisfy` (\ws → (not (dimExercised dim) || same ws) && all (<= 8192) ws)
      -- The step did what it was meant to, so the dimension was read.
      if dimExercised dim then readInstances small `shouldSatisfy` (>= 1) else pure ()
      if dimExercised dim then map readInstances readings `shouldSatisfy` same else pure ()
      -- Nothing walked the grown input: the allocation does not follow it.
      map within readings `shouldBe` [True, True, True]
