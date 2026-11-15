-- | WHAT A REQUEST KEEPS OF A COLUMN IS BOUNDED BY WHAT IT NEEDS, never by the column's history. In a
-- column of sixty separate removed runs, a cell read keeps at most one, a removal at most three (its
-- cell and the two beside it), and a staged removal's overlay stays within the part of its staging that
-- covers it. A surface whose column was dug out below the first window it reads is answered at its true
-- top, found by reading further down, never at the edge of what was read. Counted, never timed.
--
-- * WHAT A READ KEEPS IS WHAT ITS RANGE CAN HOLD, never cut at the answer's limit: removed runs that
--   meet source air merge with it, so a column of thousands of removed runs may answer one run. A read
--   keeps at most its range's levels / 2 + 1 runs (coalesced runs are a level apart), its window pins
--   the pin credit less those runs' bytes, and keeping more is a defect at any step.
--
-- * A SURFACE READS A WINDOW OF AT MOST 'limitRangeLevels' LEVELS AT A TIME: while the levels read hold
--   no occupied cell, the next read is the window below, and nothing of the one above is kept.
module Test.TerrainRuntime.Backed.Ranges (spec) where

import Control.Concurrent.STM
import Data.List (nub)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Changes (changeColumnBytes, changeIntervalBytes)
import Hetoimasia.Terrain.Coordinate (axisValue)
import Hetoimasia.Terrain.Cell (zRangeHi, zRangeLo)
import Hetoimasia.Terrain.Query (Occupied (..), QueryLimits (..), Run (..), defaultQueryLimits)
import Hetoimasia.Terrain.Source (CellSpec (..), LayerSpec (..), PatchSpec (..), SourceSpec (..))
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Backed.Gather (gatherPinLimit)
import Hetoimasia.Terrain.Runtime.Settlement
import qualified Hetoimasia.Terrain.Runtime.Store.Internal.Admission as A
import Hetoimasia.Terrain.Runtime.Store.Internal.State (windowPageBytes)
import Test.Hspec
import Test.Support.Bounded (bounded)
import Test.TerrainRuntime.Fixtures

spec ∷ Spec
spec = describe "What a request keeps of a column" $ do
  it "keeps at most one run for a cell, at most three for a removal, and a staged removal's overlay within its part, in a column of sixty runs" $ do
    gathered ← newTVarIO Map.empty
    windows ← newTVarIO []
    let probe = Probe $ \case
          PointGatheredRuns rid n → atomically (modifyTVar' gathered (Map.insertWith max rid n))
          PointGatherWindow _ peak pin _ _ _ → atomically (modifyTVar' windows ((peak, pin) :))
          _ → pure ()
    withServiceUsing defaultConfig alwaysAdmitting probe $ \svc → do
      (_, lease) ← openMain svc "main"
      -- sixty separate runs: every other level from -100 to 18
      mapM_ (\z → removeCell' svc lease (tile 5 5 z)) [-100, -98 .. 18]
      atomically (writeTVar gathered Map.empty)
      _ ← bounded (readCell svc lease (tile 5 5 (-99)))
      cellRuns ← Map.elems <$> readTVarIO gathered
      cellRuns `shouldSatisfy` (\ns → not (null ns) && all (<= 1) ns)
      -- what the read pins plus what it keeps stay within the one pin credit: its window may pin fewer
      -- pages than a load's, and it pinned no more than that
      ws ← readTVarIO windows
      ws `shouldSatisfy` (\xs → not (null xs) && all (\(peak, pin) → peak <= pin && pin < gatherPinLimit) xs)
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

  -- stone at the even levels 0 to 22 of one column, every one removed: twelve removed runs, a level
  -- apart, each merging with the source's air around it
  it "keeps every removed run a column query's range holds, inside its pin credit, and answers one air run where an answer may return four" $ do
    windows ← newTVarIO []
    let config = defaultConfig {configQueryLimits = defaultQueryLimits {limitReturnedRuns = 4}}
        source = layered [(Just 0, Just 24, "stone", 0)] [PatchSpec 3 3 (2 * k + 1) (2 * k + 2) SpecAir | k ← [0 .. 11]]
    withServiceUsing config alwaysAdmitting (recordWindows windows) $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "combed" source) >>= await svc >>= expectSuccess
      mapM_ (\z → removeCell' svc lease (tile 3 3 z)) [0, 2 .. 22]
      atomically (writeTVar windows [])
      answer ← okOf (columnAt svc lease (column 3 3) (range 0 24)) >>= bounded . await svc >>= expectSuccess
      [(zRangeLo (runRange r), zRangeHi (runRange r), cellMaterial (runCell r)) | r ← columnAnswerRuns answer] `shouldBe` [(0, 24, Nothing)]
      -- it kept the twelve, within the thirteen its 24 levels can hold, and pinned what the credit leaves
      readTVarIO windows >>= (`shouldBe` [(12, 13, [(0, 24)])]) . map (\(_, _, kept, cap, levels) → (kept, cap, levels))
      readTVarIO windows >>= mapM_ (\(_, pin, _, cap, levels) → contained pin cap (length levels))

  -- stone at the even levels 0 to 46 of one column, those from 8 up removed: the first occupied cell is
  -- at 6, five windows of 8 levels below the source's top (47)
  it "answers a surface whose first occupied cell lies several windows down, reading one window of at most the range limit at a time and keeping at most what it holds" $ do
    windows ← newTVarIO []
    let config = defaultConfig {configQueryLimits = defaultQueryLimits {limitRangeLevels = 8}}
        source = layered [(Just 0, Just 48, "stone", 0)] [PatchSpec 4 4 (2 * k + 1) (2 * k + 2) SpecAir | k ← [0 .. 23]]
    withServiceUsing config alwaysAdmitting (recordWindows windows) $ \svc → do
      client ← okOf (registerClient svc)
      lease ← okOf (openArena svc client "dug" source) >>= await svc >>= expectSuccess
      mapM_ (\z → removeCell' svc lease (tile 4 4 z)) [8, 10 .. 46]
      atomically (writeTVar windows [])
      answer ← okOf (surfaceAt svc lease (column 4 4)) >>= bounded . await svc >>= expectSuccess
      fmap (axisValue . occupiedLevel) (surfaceTop answer) `shouldBe` Just 6
      read' ← reverse <$> readTVarIO windows
      -- the windows slid down 8 levels at a time, and each kept at most the 5 runs 8 levels can hold (the
      -- answer's demand, at 6, differs from the one admitted, at the source's top: the request is admitted
      -- again and reads the same windows once more)
      nub [levels | (_, _, _, _, levels) ← read'] `shouldBe` [[(39, 47)], [(31, 39)], [(23, 31)], [(15, 23)], [(7, 15)], [(-1, 7)]]
      [kept | (_, _, kept, _, _) ← read'] `shouldSatisfy` all (<= 5)
      [cap | (_, _, _, cap, _) ← read'] `shouldSatisfy` all (== 5)
      mapM_ (\(_, pin, _, cap, levels) → contained pin cap (length levels)) read'
  where
    recordWindows windows = Probe $ \case
      PointGatherWindow _ peak pin kept cap levels → atomically (modifyTVar' windows ((peak, pin, kept, cap, levels) :))
      _ → pure ()
    -- the pages a read may pin and the runs it may keep fit its one pin credit together
    contained pin cap columns =
      pin * windowPageBytes + cap * changeIntervalBytes + columns * changeColumnBytes `shouldSatisfy` (<= fromIntegral A.readerPinnedCacheBytes)
    caved =
      SourceSpec
        { specMaterials = ["soil", "stone"]
        , specLayers =
            [ LayerSpec {layerMin = Nothing, layerMax = Just (-10), layerMaterial = "stone", layerShape = 0}
            , LayerSpec {layerMin = Just 0, layerMax = Just 40, layerMaterial = "soil", layerShape = 0}
            ]
        , specPatches = []
        }
