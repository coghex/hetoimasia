-- | Offload and reload: removals survive eviction and reconstruction from the arena's store,
-- and an acknowledged removal leaves nothing of itself in RAM.
module Test.TerrainRuntime.Offload (spec) where

import Control.Monad (foldM_, forM_)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model (Usage (..))
import Hetoimasia.Terrain.Coordinate (RegionCoord (..), decomposeTile)
import Hetoimasia.Terrain.Residency
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Source (CellSpec (..), PatchSpec (..), SourceSpec)
import Test.Hspec
import Test.TerrainRuntime.Fixtures

-- | Two materials with a boundary on a region seam, an authored air gap, a buried
-- slope and a column deep below: stone under level 32, soil from 32 to 34.
terrainSpec ∷ SourceSpec
terrainSpec =
  layered
    [(Nothing, Just 32, "stone", 0), (Just 32, Just 34, "soil", 0)]
    [ PatchSpec 1 0 0 2 SpecAir
    , PatchSpec 0 0 (-64) (-62) (SpecSolid "stone" 5)
    , PatchSpec 16 0 32 34 (SpecSolid "soil" 5)
    ]

-- | Every removal below sits in one of these regions; negative coordinates and a
-- deep shaft are among them.
touched ∷ [RegionCoord]
touched = [region rx 0 rz | rx ← [-1, 0, 1], rz ← [-2, -1, 0, 1]] <> [region 0 (-1) 0]

removals ∷ [(Integer, Integer, Integer)]
removals =
  [ (0, 0, 33), (0, 0, 32), (0, 0, 1), (0, 0, 0)
  , (0, 0, -31), (0, 0, -32), (0, 0, -63), (0, 0, -64)
  , (16, 0, 32), (16, 0, 33), (1, 0, 0), (1, 0, 2 - 1)
  , (-16, 0, 1), (-15, 0, 0), (0, -16, 1), (1, 0, 33)
  ]

spec ∷ Spec
spec = describe "Offload and reload" $ do
  it "keeps every retained removal across repeated eviction and reconstruction" $
    withService (tightConfig (2, 1, 2) 2 4096) $ \svc → do
      client <- okOf (registerClient svc)
      lease <- okOf (openArena svc client "deep" terrainSpec) >>= await svc >>= expectSuccess
      let removeAndCheck revision (n, at) = do
            let (x, y, z) = at
                earlier = take n removals
                done = take (n + 1) removals
                wasSolid = expectedMaterial terrainSpec earlier at /= Nothing
            answer <- removeCell' svc lease (tile x y z)
            -- Removing a cell that was air already (the authored gap) changes nothing.
            let revision' = if wasSolid then revision + 1 else revision
            (removeChangedFlag answer, removeRevision answer) `shouldBe` (wasSolid, Revision revision')
            -- Every cell of every touched region agrees with the independent model.
            forM_ touched $ \r → forM_ (localCells r) $ \place → do
              let (cx, cy, cz) = place
              found <- readCell svc lease (tile cx cy cz)
              cellMaterial (cellValue found) `shouldBe` expectedMaterial terrainSpec done place
              cellRevision found `shouldBe` Revision revision'
            pure revision'
      foldM_ removeAndCheck 0 (zip [0 ..] removals)
      model <- inspectModel svc
      -- Eviction happened: fewer regions are resident than were touched.
      length (modelRegions model) `shouldSatisfy` (< length touched)
      -- The removals are in the arena's store and nothing of them is retained in RAM.
      view <- inspectArena svc lease >>= maybe (fail "arena vanished") pure
      usLiveBytes (viewUsage view) `shouldSatisfy` (> 0)
      [arenaRetainedBytes a | a ← modelArenas model] `shouldBe` [0]
      settleChecks svc

  it "removes an air cell as a no-op and a slope as a whole cell, leaving neighbours alone" $
    withService defaultConfig $ \svc → do
      client <- okOf (registerClient svc)
      lease <- okOf (openArena svc client "slopes" terrainSpec) >>= await svc >>= expectSuccess
      -- Level 100 is air above the soil.
      air <- removeCell' svc lease (tile 0 0 100)
      air `shouldSatisfy` \a → not (removeChangedFlag a) && removeRevision a == Revision 0
      -- A slope (shape 5) at (16, 0, 32) goes entirely; its sloped neighbour above stays.
      slope <- removeCell' svc lease (tile 16 0 32)
      (removeChangedFlag slope, removeRevision slope) `shouldBe` (True, Revision 1)
      removed <- readCell svc lease (tile 16 0 32)
      cellIs removed `shouldBe` True
      above <- readCell svc lease (tile 16 0 33)
      cellMaterial (cellValue above) `shouldBe` Just ("soil", 5)
      beside <- readCell svc lease (tile 17 0 32)
      cellMaterial (cellValue beside) `shouldBe` expectedMaterial terrainSpec [] (17, 0, 32)
      -- Removing it again is a no-op at the same revision.
      again <- removeCell' svc lease (tile 16 0 32)
      (removeChangedFlag again, removeRevision again) `shouldBe` (False, Revision 1)
      settleChecks svc

  it "keeps nothing of an acknowledged removal in RAM: its region is a cache again at once, and eviction and reload reconstruct it from the store" $
    withService (tightConfig (2, 1, 2) 2 4096) $ \svc → do
      client <- okOf (registerClient svc)
      lease <- okOf (openArena svc client "transfer" terrainSpec) >>= await svc >>= expectSuccess
      let (held, _) = decomposeTile (tile 0 0 33)
      _ <- removeCell' svc lease (tile 0 0 33)
      -- The removal is backed when it is acknowledged: its region is not dirty and no transfer
      -- is pending, so its detail can be evicted like any cache.
      model <- inspectModel svc
      [(regionDirty r, regionHandoff r) | r ← modelRegions model, regionCoord r == held] `shouldBe` [(False, Nothing)]
      [arenaRetainedBytes a | a ← modelArenas model] `shouldBe` [0]
      -- Pressure evicts the region; reading it again reconstructs the removal from the store.
      forM_ [(16, 0, 0), (32, 0, 0), (-16, 0, 0), (0, 16, 0), (0, -16, 0), (16, 0, -32)] $ \(x, y, z) → readCell svc lease (tile x y z)
      regions <- map regionCoord . modelRegions <$> inspectModel svc
      held `elem` regions `shouldBe` False
      found <- readCell svc lease (tile 0 0 33)
      cellIs found `shouldBe` True
      settleChecks svc
