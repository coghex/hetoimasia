-- | Generated record workloads: the writes a #661-shaped history makes, against a
-- reference map, for the store specs that need arbitrary history rather than a
-- scene. Runs of one column never touch (the format requires coalesced runs).
module Test.TerrainRuntime.Store.Workload
  ( top
  , bottom
  , columns
  , genWrites
  , valueFor
  , applyRef
  , nodeAt
  , runAt
  , stepDelta
  ) where

import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Discovery (Node (..), Record (..), RecordKey (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference

top, bottom ∷ Integer
top = 2 ^ (62 ∷ Int)
bottom = negate top

-- | The columns the generator uses: ordinary, negative and the extreme legal ones.
columns ∷ [(Integer, Integer)]
columns =
  [(x, y) | x ← [-3 .. 3], y ← [-2 .. 2]]
    ++ [(top - 1, top - 1), (bottom, bottom), (top - 1, bottom), (bottom, top - 1), (0, bottom), (bottom, 0)]

-- | One generated run: a column, the slot in it and a length. Runs of a slot are at
-- least 90 levels from the next slot, so no two runs of a column touch (the format
-- requires coalesced runs).
runAt ∷ (Integer, Integer) → Int → Integer → (RecordKey, Record)
runAt (x, y) slot len =
  let lo = 100 * toInteger slot + (if slot `mod` 7 == 3 then bottom else 0) + (if slot `mod` 11 == 5 then top - 5000 else 0)
      hi = min top (lo + 1 + len)
   in (runKey x y lo, runRec hi)

-- | The links the generator uses.
nodeAt ∷ Int → Node
nodeAt i
  | even i = RunNode (columnAt (toInteger (i `mod` 5) - 2) (toInteger (i `div` 5 `mod` 4))) (fromIntegral (i * 100))
  | otherwise = srcNode (toInteger (i `mod` 9) - 4) (toInteger (i `div` 9 `mod` 6)) (if i `mod` 13 == 0 then top - 1 else toInteger i)

-- | A generated step: a set of writes, each against the reference map.
genWrites ∷ Rng → Map.Map RecordKey Record → Int → ([(RecordKey, Maybe Record)], Rng)
genWrites g0 reference n = go n g0 []
  where
    go 0 g acc = (reverse acc, g)
    go k g acc =
      let (kind, g1) = below 10 g
          (w, g2) = case kind of
            0 → deleteSome g1
            1 → deleteSome g1
            2 → replaceSome g1
            3 → newLink g1
            4 → newLink g1
            5 → newTodo g1
            _ → newRun g1
       in go (k - 1 ∷ Int) g2 (w : acc)
    deleteSome g =
      let keys = Map.keys reference
       in if null keys
            then newRun g
            else let (k, g') = pick keys g in ((k, Nothing), g')
    replaceSome g =
      let keys = Map.keys reference
       in if null keys
            then newRun g
            else
              let (k, g') = pick keys g
                  (v, g'') = valueFor k g'
               in ((k, Just v), g'')
    newRun g =
      let (c, g1) = pick columns g
          (slot, g2) = below 40 g1
          (len, g3) = below 60 g2
          (k, v) = runAt c (fromIntegral slot) (toInteger len)
       in ((k, Just v), g3)
    newLink g =
      let (i, g1) = below 400 g
          node = nodeAt (fromIntegral i)
          (v, g2) = valueFor (KeyLink node) g1
       in ((KeyLink node, Just v), g2)
    newTodo g =
      let (i, g1) = below 5000 g
          (big, g2) = below 20 g1
          sq = if big == 0 then maxBound - i else i
          (v, g3) = valueFor (KeyTodo sq) g2
       in ((KeyTodo sq, Just v), g3)

-- | A legitimate value for a key.
valueFor ∷ RecordKey → Rng → (Record, Rng)
valueFor key g = case key of
  KeyRun _ lo →
    let (len, g') = below 80 g
     in (RecRun (fromInteger (min top (toInteger lo + 1 + toInteger len))), g')
  KeyLink node →
    let (r, g1) = below 3 g
        (sz, g2) = below 1000 g1
        parent = if node == nodeAt 1 then nodeAt 2 else nodeAt 1
     in (if r == 0 then rootRec (sz + 1) (even sz) else RecChild parent, g2)
  KeyTodo i →
    let (d, g') = below 6 g
     in (todoRec (toInteger (i `mod` 17)) (toInteger (i `mod` 5)) 3 (fromIntegral d + 1), g')

applyRef ∷ [(RecordKey, Maybe Record)] → Map.Map RecordKey Record → Map.Map RecordKey Record
applyRef ws m = foldl (\acc (k, v) → maybe (Map.delete k acc) (\r → Map.insert k r acc) v) m ws


-- | A delta of generated writes over a store, advancing the revisions the flag asks.
stepDelta ∷ Store → Int → [(RecordKey, Maybe Record)] → Delta
stepDelta s flag ws = deltaFor s (flag == 0) (flag == 1) (length ws) ws
