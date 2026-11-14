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

  it "answers a surface dug out below its first window at its true top, reading further down" $
    withService defaultConfig $ \svc → do
      (_, lease) ← openMain svc "main"
      -- soil reaches level 40: remove 40 down to 0, one run longer than the first window
      mapM_ (\z → removeCell' svc lease (tile 7 7 z)) [40, 39 .. 0]
      answer ← okOf (surfaceAt svc lease (column 7 7)) >>= bounded . await svc >>= expectSuccess
      fmap (axisValue . occupiedLevel) (surfaceTop answer) `shouldBe` Just (-1)
