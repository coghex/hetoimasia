-- | WHAT A REQUEST KEEPS OF A COLUMN IS BOUNDED BY WHAT IT NEEDS, never by the column's history. In a
-- column of sixty separate removed runs, a cell read keeps at most one, a removal at most three (its
-- cell and the two beside it), and a staged removal's overlay stays within the part of its staging that
-- covers it. A surface whose column was dug out below the first window it reads is answered at its true
-- top, found by reading further down, never at the edge of what was read. Counted, never timed.
module Test.TerrainRuntime.Backed.Ranges (spec) where

import Control.Concurrent.STM
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Changes (changeColumnBytes, changeIntervalBytes)
import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.Query (Occupied (..))
import Hetoimasia.Terrain.Source (LayerSpec (..), SourceSpec (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures

spec ∷ Spec
spec = describe "What a request keeps of a column" $ do
  it "keeps at most one run for a cell, at most three for a removal, and a staged removal's overlay within its part, in a column of sixty runs" $ do
    gathered ← newTVarIO Map.empty
    let probe = Probe $ \case
          PointGatheredRuns rid n → atomically (modifyTVar' gathered (Map.insertWith max rid n))
          _ → pure ()
    withServiceUsing defaultConfig alwaysAdmitting probe $ \svc → do
      (_, lease) ← openMain svc "main"
      -- sixty separate runs: every other level from -100 to 18
      mapM_ (\z → removeCell' svc lease (tile 5 5 z)) [-100, -98 .. 18]
      atomically (writeTVar gathered Map.empty)
      _ ← bounded (readCell svc lease (tile 5 5 (-99)))
      cellRuns ← Map.elems <$> readTVarIO gathered
      cellRuns `shouldSatisfy` (\ns → not (null ns) && all (<= 1) ns)
      -- a removal between two runs: it reads them and coalesces with both; its host is not eligible yet,
      -- so it stays staged
      atomically (writeTVar gathered Map.empty)
      host ← newHost False
      _ ← okOf (removeWith svc (hostEndpoint svc Nothing host) lease (tile 5 5 (-99)) Nothing)
      waitFor (readTVar (hostReady host) >>= \n → check (n >= 1))
      removalRuns ← Map.elems <$> readTVarIO gathered
      removalRuns `shouldSatisfy` (\ns → not (null ns) && all (<= 3) ns)
      overlays ← atomically (inspectStagedOverlaySTM svc)
      -- the staged overlay's part of a removal's staging: four runs of one column, and the working interval
      let part = changeColumnBytes + 4 * changeIntervalBytes + changeColumnBytes + changeIntervalBytes
      map snd overlays `shouldSatisfy` (\bs → not (null bs) && all (<= part) bs)
      grant host
      waitFor (readTVar (hostSettled host) >>= \s → check (not (null s)))

  it "answers a surface whose column was dug out below the first window it reads at its true top, reading further down" $
    withService defaultConfig $ \svc → do
      client ← okOf (registerClient svc)
      -- stone below -10, air from -10 to 0, soil from 0 to 40
      lease ← okOf (openArena svc client "caved" caved) >>= await svc >>= expectSuccess
      -- the soil is removed (one run from 0, reaching into the first window), and the stone from -20 to -11
      -- (another run, below the air: no window that ends at the first run's floor reaches it)
      mapM_ (\z → removeCell' svc lease (tile 7 7 z)) ([0 .. 39] <> [-20 .. -11])
      answer ← okOf (surfaceAt svc lease (column 7 7)) >>= bounded . await svc >>= expectSuccess
      fmap (axisValue . occupiedLevel) (surfaceTop answer) `shouldBe` Just (-21)
  where
    caved =
      SourceSpec
        { specMaterials = ["soil", "stone"]
        , specLayers =
            [ LayerSpec {layerMin = Nothing, layerMax = Just (-10), layerMaterial = "stone", layerShape = 0}
            , LayerSpec {layerMin = Just 0, layerMax = Just 40, layerMaterial = "soil", layerShape = 0}
            ]
        , specPatches = []
        }
