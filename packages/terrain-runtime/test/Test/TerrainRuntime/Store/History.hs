-- | Ownership and reclamation against legitimate history.
--
-- A validator that refuses forged records can also refuse a legitimate one: the last two
-- review rounds each found a check that held for every corrupt record and blocked an honest
-- history (a retirement entry whose reclaimed prefix had been reused and retired again).
-- These examples drive the store through the histories an owner produces: edits that touch
-- a handful of pages and edits that replace more pages than one reclamation transaction
-- frees, partial maintenance, the reuse of the freed pages, their retirement again, and
-- readers pinned and released at random. After every step the independent ownership
-- checker (the partition, the counters, the retired-page index against the lists) must
-- agree with the store, a pinned reader must answer from its own version, and maintenance
-- must make progress whenever no reader holds the oldest entry: it is never refused, and
-- when it plans work the retired pages go down. At the end every reader is released and
-- reclamation drains to nothing.
module Test.TerrainRuntime.Store.History (spec) where

import Control.Monad (foldM, forM_, when)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Test.Hspec
import Test.TerrainRuntime.Store.Bounds (wide)
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | The state of a run: the store and its disk, the reference records, the readers with the
-- records each must keep answering from, and the generator.
data St = St
  { stH ∷ !H
  , stRef ∷ !(Map.Map RecordKey Record)
  , stReaders ∷ [(ReaderToken, Map.Map RecordKey Record)]
  , stRng ∷ !Rng
  }

-- | Replace the value of @n@ keys spread through the history by a stride that divides none of its length.
editOf ∷ [RecordKey] → Map.Map RecordKey Record → Int → Int → Int → [(RecordKey, Maybe Record)]
editOf keys ref start stride n =
  [ (k, Just (if Map.lookup k ref == Just (runRec 20) then runRec 30 else runRec 20))
  | i ← [0 .. n - 1]
  , let k = keys !! ((start + i * stride) `mod` length keys)
  ]

commitEdit ∷ [RecordKey] → St → Int → Int → Int → Either String St
commitEdit keys st start stride n = do
  let ws = editOf keys (stRef st) start stride n
      h = stH st
  (h', out) ← commitDelta h Ordinary (deltaFor (hStore h) True False 1 ws)
  case out of
    Committed _ → Right st {stH = h', stRef = foldl (\m (k, v) → maybe m (\r → Map.insert k r m) v) (stRef st) ws}
    Nothing' → Right st
    -- a bound a big edit may meet is a typed capacity result; anything about integrity is a defect
    Refusal' (Capacity _) → Right st
    Refusal' why → Left ("an edit was refused: " <> show why)

-- | One maintenance step: never refused unless a reader holds the oldest entry (it is then blocked,
-- not refused), and the retired pages go down when it plans work.
maintain ∷ St → Either String St
maintain st = do
  let h = stH st
      retiredBefore = rRetiredPages (storeRoots (hStore h))
  (p, _, _) ← fillWith h (planMaintenance (hStore h))
  case p of
    Planned plan → do
      h' ← commitPlan h plan
      let retiredAfter = rRetiredPages (storeRoots (hStore h'))
      when (mFreed (plMeasure plan) > 0 && retiredAfter >= retiredBefore) (Left "maintenance freed pages but the retired count did not go down")
      Right st {stH = h'}
    NoWork → Right st
    BlockedByReader _ _ → if oldestPin (hStore h) == Nothing then Left "blocked with no reader pinned" else Right st
    Refused why → Left ("maintenance was refused with a consistent store: " <> show why)
    other → Left ("unexpected maintenance result " <> take 100 (show other))

step ∷ [RecordKey] → St → Int → Either String St
step keys st i = do
  let (r, g1) = below 100 (stRng st)
      (start, g2) = below (fromIntegral (length keys)) g1
      (strideIx, g3) = below 6 g2
      (small, g4) = below 8 g3
      (big, g5) = below 40 g4
      stride = [97, 101, 103, 107, 109, 113] !! fromIntegral strideIx
      st1 = st {stRng = g5}
  st2 ←
    if r < 35 then commitEdit keys st1 (fromIntegral start) stride (1 + fromIntegral small)
    else if r < 60 then commitEdit keys st1 (fromIntegral start) stride (70 + fromIntegral big)
    else if r < 85 then maintain st1
    else if r < 93 then
      if length (stReaders st1) >= 3 then Right st1
      else case acquireReader (hStore (stH st1)) of
        Left e → Left (show e)
        Right (tok, s') → Right st1 {stH = (stH st1) {hStore = s'}, stReaders = (tok, stRef st1) : stReaders st1}
    else case stReaders st1 of
      [] → Right st1
      ((tok, _) : rest) → let (_, s') = releaseReader tok (hStore (stH st1)) in Right st1 {stH = (stH st1) {hStore = s'}, stReaders = rest}
  -- the independent traversal agrees with the store after every step
  either (\e → Left ("step " <> show i <> ": " <> e)) Right (checkH (stH st2))
  -- and every few steps each pinned reader still answers from exactly its own version
  when (i `mod` 12 == 0) $
    forM_ (stReaders st2) $ \(tok, snapshot) → do
      seen ← readAll (stH st2) tok
      when (Map.fromList seen /= snapshot) (Left ("step " <> show i <> ": a pinned reader's answers changed"))
  Right st2

-- | Every retired page with the version of the entry that owns it, from the independent reference.
retireIndex ∷ H → [(Word64, Word64)]
retireIndex h =
  [ (getBe64' k 1, getBe64' v 0)
  | (k, v) ← twLeaves (walkTree a (siSource (hIdent h)) (diskRead (hDisk h)) ((\(PageNo p) → p) <$> rRetire (storeRoots (hStore h))))
  , BS.length k == 9
  , BS.index k 0 == 0xFF
  ]
  where
    ArenaId a = siArena (hIdent h)

-- | The lists of the outstanding retirement entries: version and the pages not yet reclaimed.
retireLists ∷ H → Either String [(Word64, [Word64])]
retireLists h = mapM one entries
  where
    ArenaId a = siArena (hIdent h)
    walk = walkTree a (siSource (hIdent h)) (diskRead (hDisk h)) ((\(PageNo p) → p) <$> rRetire (storeRoots (hStore h)))
    entries = [(getBe64' k 1, getBe64' v 0, getLe16' v 10) | (k, v) ← twLeaves walk, BS.length k == 9, BS.index k 0 == 0]
    one (ver, lp, done) = case diskRead (hDisk h) (PageNo lp) >>= either (const Nothing) Just . parsePage a (siSource (hIdent h)) of
      Just pg | RefList _ ps ← rpBody pg → Right (ver, drop (fromIntegral done) ps)
      _ → Left "a retirement list is not readable"

spec ∷ Spec
spec = describe "randomized ownership history: plans, retirements, partial maintenance, reuse and pinned readers" $ do
  (h0, keys) ← runIO (must (wide 12000))
  let ref0 = Map.fromList [(k, runRec 20) | k ← keys]
  it "keeps the ownership checker, the readers and maintenance in agreement through random histories" $
    forM_ [1, 2, 3, 4, 5, 6 ∷ Word64] $ \seed → do
      let start = St h0 ref0 [] (mkRng (1000 + seed))
      end ← must (foldM (\st i → either (\e → Left ("seed " <> show seed <> ": " <> e)) Right (step keys st i)) start [1 .. 45])
      -- release every reader and drain: reclamation reaches nothing, whatever the history reused
      let released = foldl (\h (tok, _) → h {hStore = snd (releaseReader tok (hStore h))}) (stH end) (stReaders end)
      (drained, _) ← must (reclaimAll released)
      rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
      must (checkH drained)
      must (compareRecords (Map.toList (stRef end)) drained)
  it "finishes a retirement entry whose reclaimed prefix was reused and retired again under a newer version" $ do
    -- one edit replaces more pages than a reclamation transaction frees (64)
    st1 ← must (commitEdit keys (St h0 ref0 [] (mkRng 7)) 0 97 100)
    lists1 ← must (retireLists (stH st1))
    (e, pages) ← case [x | x@(_, ps) ← lists1, length ps > maxReclaimPages] of
      (x : _) → pure x
      [] → expectationFailure "an entry holding more pages than one transaction reclaims was expected" >> fail "entry"
    -- maintenance takes the oldest entry first: the entries before it are reclaimed until it is the oldest
    let untilOldest st n
          | n > (900 ∷ Int) = expectationFailure "the entries before it were not reclaimed" >> fail "drain"
          | otherwise = do
              ls ← must (retireLists (stH st))
              case ls of
                ((v, _) : _) | v == e → pure st
                _ → must (maintain st) >>= \st' → untilOldest st' (n + 1)
    st1' ← untilOldest st1 0
    -- one transaction reclaims the first 64 of them
    st2 ← must (maintain st1')
    let prefix = take maxReclaimPages pages
    rRetiredPages (storeRoots (hStore (stH st2))) `shouldBe` rRetiredPages (storeRoots (hStore (stH st1'))) - fromIntegral maxReclaimPages
    -- ordinary edits reuse the freed pages and retire some of them again under newer versions
    let reused h = [(p, v) | (p, v) ← retireIndex h, p `elem` prefix, v > e]
        go st n
          | n > (80 ∷ Int) = expectationFailure "no reclaimed prefix page was reused and retired again" >> fail "reuse"
          | not (null (reused (stH st))) = pure st
          | otherwise = must (commitEdit keys st (n * 131) ([97, 101, 103, 107] !! (n `mod` 4)) 100) >>= \st' → go st' (n + 1)
    st3 ← go st2 0
    must (checkH (stH st3))
    -- the entry finishes, and so does everything after it
    (drained, _) ← must (reclaimAll (stH st3))
    rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
    must (checkH drained)
    must (compareRecords (Map.toList (stRef st3)) drained)
