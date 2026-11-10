-- | The boundary of round 11 at the real reserve of 68 bookkeeping pages.
--
-- A valid store, built page by page with real checksums: a three-level links tree of 270 leaves, a
-- three-level retirement tree holding 14,580 retired pages in 29 lists, and the page space laid out so that
-- the live leaves of the links tree are scattered between the retired pages, one in every 54 pages. The
-- retirement index has 271 leaves of 54 records (the least a legitimate leaf holds), and every live leaf
-- lies in a different index leaf. An update of 64 dispersed links replaces 64 leaves, 3 internal pages and
-- the root of the links tree (68 record pages), and indexing them takes one path in the retirement tree each:
-- 69 bookkeeping pages against the reserve of 68. The plan used to number them from a supply of 68 and
-- fail as 'BrokenInvariant'; it must now commit (taking a larger supply), and a batch that is too big must be
-- shrinkable, and the halved batch must make progress.
module Test.TerrainRuntime.Store.Scattered (spec, scattered, fragmented) where

import qualified Data.ByteString as BS
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Control.Monad (forM, forM_)
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Child (..), Page (..), decodePage, encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (Retire (..), be64, encodeFree, encodeKey, encodeRetire, encodeValue, retiredKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Fact (..), Facts (..), limitWork, noReadFacts, windowCheckpoint, windowFactCount, windowFactsFor, windowKnows)
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Test.TerrainRuntime.Store.Reference

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | Link @i@: its key and its two values.
linkOf ∷ Int → (RecordKey, Record, Record)
linkOf i =
  let x = toInteger (i `mod` 100) - 50
      y = toInteger (i `div` 100 `mod` 100) - 50
   in (linkKey (srcNode x y 0), childRec (srcNode x y 1), childRec (srcNode x y 2))

leavesN, perLeaf, groupN ∷ Int
leavesN = 270
perLeaf = 25
groupN = 54

-- | The store, the keys of the first link of each leaf of the links tree (in tree order), and the links' reference.
scattered ∷ (H, [RecordKey], Map.Map RecordKey Record)
scattered = scatteredWith False Nothing False

-- | The same store in the layout of round 12: the oldest retirement entry holds 64 dispersed pages (the rest
-- are in lists of 505), and a free extent of 256 pages holds old versions of links leaves with distinct keys,
-- so that the supply of a maintenance transaction (4 pages for each page it frees and the reserve) is made of
-- pages each of which must be proven unreachable by reading the path of its own first key: a transaction
-- that frees 64 pages needs a window of 311 pages, one that frees 32 needs 208.
fragmented ∷ (H, [RecordKey], Map.Map RecordKey Record)
fragmented = scatteredWith True Nothing False

-- | The fragmented layout on a store with NO tail: the free extent runs to the end of the usable pages, so every
-- page the allocator hands out lies below the used space and must be proven unreachable.
fragmentedNoTail ∷ (H, [RecordKey], Map.Map RecordKey Record)
fragmentedNoTail = scatteredWith True Nothing True

-- | The layout of round 13: the oldest entry lists 270 dispersed pages, all but the last consumed (its progress
-- field at 269), and the consumed pages were reused and retired again under a newer entry; every page lies in a
-- different leaf of the retirement index. The transaction that finishes the entry verifies its consumed pages are
-- gone from the index: all 269 of them, in 269 leaves, was a window of 311 pages however little work it did.
finalChunk ∷ Int → (H, [RecordKey], Map.Map RecordKey Record)
finalChunk done = scatteredWith False (Just (done, False)) False

-- | The same entry with its progress field forged to @done@ while every one of its pages is still indexed under it.
forgedProgress ∷ Int → (H, [RecordKey], Map.Map RecordKey Record)
forgedProgress done = scatteredWith False (Just (done, True)) False

scatteredWith ∷ Bool → Maybe (Int, Bool) → Bool → (H, [RecordKey], Map.Map RecordKey Record)
scatteredWith frag fin noTail = (h, firstKeys, ref)
  where
    -- the links tree: the records sorted by their encoded keys, 40 to a leaf
    recs = sortOn fst [(encodeKey k, (k, encodeValue a, a)) | i ← [0 .. leavesN * perLeaf - 1], let (k, a, _) = linkOf i]
    leafRecs = chunk perLeaf recs
    ref = Map.fromList [(k, a) | (_, (k, _, a)) ← recs]
    firstKeys = [k | ((_, (k, _, _)) : _) ← leafRecs]
    chunk _ [] = []
    chunk n xs = let (a, b) = splitAt n xs in a : chunk n b
    -- groups of nearly equal size, none past @n@ (so none under-full when the total allows)
    balanced n xs = let g = (length xs + n - 1) `div` n in chunkInto g xs
    chunkInto g xs = [take (len i) (drop (start i) xs) | i ← [0 .. g - 1]]
      where
        len i = length xs `div` g + (if i < length xs `mod` g then 1 else 0)
        start i = sum [len j | j ← [0 .. i - 1]]
    -- the page space: groups of 54 retired pages, each followed by one live leaf of the links tree
    leafPageNo j = fromIntegral (j * (groupN + 1) + groupN) ∷ Word64
    retiredNos = [fromIntegral p ∷ Word64 | p ← [0 .. leavesN * (groupN + 1) - 1], p `mod` fromIntegral (groupN + 1) /= fromIntegral groupN]
    retiredCount = length retiredNos
    base = fromIntegral (leavesN * (groupN + 1)) ∷ Word64
    -- links tree pages: leaves, then 5 internal pages of 54 and the root, at the top of the space
    linkLeaf j (lr) = Page TreeLinks 0 (PageNo (leafPageNo j)) (Leaf [(k, v) | (k, (_, v, _)) ← lr])
    linkLeaves = zipWith linkLeaf [0 ..] leafRecs
    crcOf pg = getLe32' (either (error . show) id (encodePage ident0 pg)) 4092
    childOf pg = Child (pgNo pg) (crcOf pg)
    innerFan = if frag then 18 else 54
    innerGroups = if frag then balanced innerFan linkLeaves else chunk innerFan linkLeaves
    linkInners = [Page TreeLinks 1 (PageNo (base + fromIntegral n)) (Inner [(firstKeyOf pg, childOf pg) | pg ← grp]) | (n, grp) ← zip [0 ∷ Int ..] innerGroups]
    firstKeyOf (Page _ _ _ (Leaf ((k, _) : _))) = k
    firstKeyOf (Page _ _ _ (Inner ((k, _) : _))) = k
    firstKeyOf _ = BS.empty
    linkRoot = Page TreeLinks 2 (PageNo (base + fromIntegral (length linkInners))) (Inner [(firstKeyOf pg, childOf pg) | pg ← linkInners])
    -- the retirement lists: 29 entries of up to 505 retired pages
    oldest = [retiredNos !! (i * (retiredCount `div` 64)) | i ← [0 .. 63]]
    finPages = [retiredNos !! (i * groupN) | i ← [0 .. 269]]
    listsOf = if frag then oldest : chunk 505 [q | q ← retiredNos, q `notElem` oldest] else chunk 505 retiredNos
    -- the retirement entries: version, the pages of its list and its progress
    entries ∷ [(Word64, [Word64], Int)]
    entries
      | Just (d, forged) ← fin = (1, finPages, d) : [(2, take d finPages, 0) | d > 0, not forged] ++ [(fromIntegral n + 3, ps, 0) | (n, ps) ← zip [0 ∷ Int ..] (chunk 505 [q | q ← retiredNos, q `notElem` finPages])]
      | otherwise = [(fromIntegral n + 1, ps, 0) | (n, ps) ← zip [0 ∷ Int ..] listsOf]
    nLists = length entries
    listBase = base + fromIntegral (length linkInners) + 1
    listPages = [Page TreeRetire 0 (PageNo (listBase + fromIntegral n)) (List v (map PageNo ps)) | (n, (v, ps, _)) ← zip [0 ∷ Int ..] entries]
    versionRecs = [encodeRetire v (Retire (PageNo (listBase + fromIntegral n)) (fromIntegral (length ps)) (fromIntegral dn)) | (n, (v, ps, dn)) ← zip [0 ∷ Int ..] entries]
    versionOf p = maximum (0 : [v | (v, ps, _) ← entries, p `elem` ps]) ∷ Word64
    indexRecs = [(retiredKey (PageNo p), be64 (versionOf p)) | p ← retiredNos]
    -- the retirement tree: leaves of 54 index records (the first also holds the 29 entries)
    idxGroups = chunk groupN indexRecs
    idxLeafRecs = case idxGroups of
      (g0 : gs) → (versionRecs ++ g0) : gs
      [] → []
    retireLeafBase = listBase + fromIntegral nLists
    retireLeaves = [Page TreeRetire 0 (PageNo (retireLeafBase + fromIntegral n)) (Leaf rs) | (n, rs) ← zip [0 ∷ Int ..] idxLeafRecs]
    retireInnerBase = retireLeafBase + fromIntegral (length retireLeaves)
    retireInners = [Page TreeRetire 1 (PageNo (retireInnerBase + fromIntegral n)) (Inner [(firstKeyOf pg, childOf pg) | pg ← grp]) | (n, grp) ← zip [0 ∷ Int ..] (if frag then balanced 60 retireLeaves else chunk 136 retireLeaves)]
    retireRoot = Page TreeRetire 2 (PageNo (retireInnerBase + fromIntegral (length retireInners))) (Inner [(firstKeyOf pg, childOf pg) | pg ← retireInners])
    usedHw = retireInnerBase + fromIntegral (length retireInners) + 1
    -- the free extent of the fragmented layout: 256 pages past the used space of the rest, each an old version of a
    -- links leaf, and the leaf of the allocator tree that names it
    extentPages = [Page TreeLinks 0 (PageNo (usedHw + fromIntegral i)) (Leaf [(k, v) | (k, (_, v, _)) ← take 1 lr]) | (i, lr) ← [(i, leafRecs !! ((4 * i + 2) `mod` leavesN)) | i ← [0 .. 255]]]
    extentLen = if noTail then cfgUsablePages (hCfg h0) - usedHw - 1 else 256
    freeLeaf = Page TreeFree 0 (PageNo (usedHw + extentLen)) (Leaf [encodeFree usedHw extentLen])
    livePagesList = linkLeaves ++ linkInners ++ [linkRoot] ++ listPages ++ retireLeaves ++ retireInners ++ [retireRoot] ++ [freeLeaf | frag]
    -- a retired page of a legitimate store holds the old version of a record-tree page (maintenance refuses anything else)
    oldPages = [Page TreeLinks 0 (PageNo q) (Leaf [(k, v) | (k, (_, v, _)) ← take 1 (leafRecs !! oldLeaf q)]) | q ← retiredNos]
    oldLeaf q = case lookup q (zip oldest [0 ∷ Int ..]) of
      Just i → (4 * i + 1) `mod` leavesN
      Nothing → fromIntegral q `mod` leavesN
    writtenPages = livePagesList ++ (if frag then extentPages else []) ++ (if frag || fin /= Nothing then oldPages else [])
    hw = if frag then usedHw + extentLen + 1 else usedHw
    h0 = newH (specOf (128 * 1024 * 1024) Nothing) ident0
    disk = foldl (\dk pg → diskWrite (pgNo pg) (either (error . show) id (encodePage ident0 pg)) dk) (hDisk h0) writtenPages
    roots0 = storeRoots (hStore h0)
    roots =
      roots0
        { rVersion = 100
        , rLinks = Just (pgNo linkRoot)
        , rRetire = Just (pgNo retireRoot)
        , rHw = hw
        , rLivePages = fromIntegral (length livePagesList)
        , rRetiredPages = fromIntegral retiredCount
        , rRootCrcs = [(TreeLinks, crcOf linkRoot), (TreeRetire, crcOf retireRoot)] ++ [(TreeFree, crcOf freeLeaf) | frag]
        , rFree = if frag then Just (pgNo freeLeaf) else Nothing
        , rFreePages = if frag then extentLen else 0
        }
    h = h0 {hStore = storeFromRoots (hCfg h0) ident0 roots, hDisk = disk}

-- | Dispersed updates: one link in each of @k@ leaves spread over the links tree.
dispersed ∷ [RecordKey] → Int → [(RecordKey, Maybe Record)]
dispersed firstKeys k =
  [ (key, Just v)
  | j ← [0 .. k - 1]
  , let key = firstKeys !! (1 + j * (leavesN `div` max 1 k))
  , let v = maybe (error "link") (\(_, _, b) → b) (lookupLink key)
  ]
  where
    lookupLink key = case [x | i ← [0 .. leavesN * perLeaf - 1], let x@(k', _, _) = linkOf i, k' == key] of
      (x : _) → Just x
      [] → Nothing

spec ∷ Spec
spec = specBoundary >> specFragmented >> specFinal >> specBound >> specForged >> specAtOnce >> specFingerprint >> specSparse >> specLoose

specBoundary ∷ Spec
specBoundary = describe "the round-11 boundary at the real reserve: 64 dispersed link updates need more bookkeeping than 68" $ do
  let (h0, firstKeys, ref0) = scattered
      plan bounds ws = do
        (p, _, _) ← fillWith h0 (\w → planDeltaPinned bounds (hCfg h0) (hIdent h0) (storeRoots (hStore h0)) [] w Ordinary (deltaFor (hStore h0) True False 1 ws))
        pure p
      ws64 = dispersed firstKeys 64
  it "is a valid store the independent checker accepts, three levels deep, scattered" $ do
    must (checkH h0)
    rRetiredPages (storeRoots (hStore h0)) `shouldBe` fromIntegral (leavesN * groupN)
  it "needs more than 68 bookkeeping pages for 64 dispersed updates: with the old reserve it is refused as capacity, never as corruption" $ do
    -- the supply fixed at 68, as it was: a shrinkable capacity result that names the need (the old plan failed to number)
    p ← must (plan (standardBounds {bdReserve = 68, bdReserveMax = 68}) ws64)
    case p of
      Refused (Capacity (BookkeepingExceeded n)) → (n > 68) `shouldBe` True
      other → expectationFailure ("a need past the reserve was not the shrinkable bookkeeping result: " <> take 200 (show other))
  it "commits 64 dispersed updates at the real reserve by taking the larger supply, and every record reads as expected" $ do
    p ← must (plan standardBounds ws64)
    case p of
      Planned pl → do
        (mBookkeepingPages (plMeasure pl) > bookkeepingReserve) `shouldBe` True
        h1 ← must (commitPlan h0 pl)
        must (checkH h1)
        let ref1 = foldl (\m (k, v) → maybe m (\x → Map.insert k x m) v) ref0 ws64
        must (compareRecords (Map.toList ref1) h1)
      other → expectationFailure ("64 dispersed updates were not planned: " <> take 300 (show other))
  it "never reports a batch of any size as corruption: committed or shrinkable, and the halved batch commits" $ do
    outcomes ← must (mapM (\k → (\p → (k, p)) <$> plan standardBounds (dispersed firstKeys k)) [1, 2, 4, 8, 16, 32, 48, 64, 80, 100, 128, 200])
    putStrLn ("SCATTERED outcomes: " <> show [(k, case p of Planned pl → "planned bk " <> show (mBookkeepingPages (plMeasure pl)); other → take 60 (show other)) | (k, p) ← outcomes])
    [(k, why) | (k, Refused why@(Integrity _)) ← outcomes] `shouldBe` []
    [k | (k, Refused why) ← outcomes, not (shrinkable why)] `shouldBe` []
    [k | (k, Planned _) ← outcomes] `shouldSatisfy` (not . null)

-- | The fragmented layout: maintenance through the public API with the real limits.
specFragmented ∷ Spec
specFragmented = describe "round 12: maintenance on a fragmented valid store whose largest chunk outgrows the window" $ do
  let (h0, _, _) = fragmented
  it "is a valid store the independent checker accepts, with an oldest entry of 64 dispersed pages and a free extent of 256" $ do
    must (checkH h0)
    rFreePages (storeRoots (hStore h0)) `shouldBe` 256
  it "plans the largest chunk through checkpoints: the window never holds the whole proof, and no work limit is needed" $ do
    (p, _, steps, checkpoints) ← must (fillCounting h0 (storeWindow (hStore h0)) (planMaintenance (hStore h0)))
    case p of
      Planned pl → do
        -- the 64-page chunk of the reviewer's layout (a window of 311 pages in one piece) is planned whole
        mFreed (plMeasure pl) `shouldBe` 64
        (mWindowPages (plMeasure pl) <= maxWindowBytes `div` windowPageBytes) `shouldBe` True
        putStrLn ("SCATTERED fragmented chunk: window " <> show (mWindowPages (plMeasure pl)) <> ", " <> show checkpoints <> " checkpoints, " <> show steps <> " pages and probes fetched")
      other → expectationFailure ("the largest chunk was not planned: " <> take 200 (show other))
  it "makes progress through the public API with the real limits, and the store drains" $ do
    (p, _, _) ← must (fillRetry h0 (planMaintenance (hStore h0)))
    case p of
      Planned pl → do
        let freed = mFreed (plMeasure pl)
        (freed > 0) `shouldBe` True
        h1 ← must (commitPlan h0 pl)
        must (checkH h1)
      other → expectationFailure ("maintenance made no progress: " <> take 300 (show other))
    -- and every call of a long sequence does work or finds nothing left, never a capacity result that repeats
    let go h n
          | n > (6000 ∷ Int) = Left "the drain did not end"
          | otherwise = do
              (res, _, _, cps) ← fillRetryCounting h (planMaintenance (hStore h))
              case res of
                Planned pl
                  -- progress is enforced: a checkpoint carries a new fact, and a transaction proves at most the pages it writes
                  -- and the span it verifies
                  | cps > mPagesWritten (plMeasure pl) + maxReclaimPages → Left ("more checkpoints (" <> show cps <> ") than facts a transaction can make")
                  | otherwise → commitPlan h pl >>= \h' → go h' (n + 1)
                NoWork → Right (h, n)
                other → Left ("maintenance neither did work nor found nothing left: " <> take 200 (show other))
    (drained, passes) ← must (go h0 0)
    putStrLn ("SCATTERED fragmented drain: " <> show passes <> " transactions")
    rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
    must (checkH drained)

-- | Round 13: the transaction that finishes a partially consumed entry verifies the pages its earlier chunks
-- consumed are gone from the retirement index. That verification now covers the last 'maxReclaimPages' of them
-- in every transaction, so a transaction's window depends on the tree heights and not on how much of the entry
-- was consumed before.
specFinal ∷ Spec
specFinal = describe "round 13: a partially consumed entry at every progress point, with its consumed pages reused and retired again" $ do
  it "finishes the reviewer's entry (270 dispersed pages, all but the last consumed) inside the window, at work one too" $ do
    let (h0, _, _) = finalChunk 269
    must (checkH h0)
    -- the verification of the consumed pages lies in 64 index leaves at most, not 269
    (p, _, _) ← must (fillWith h0 (planMaintenance (hStore h0)))
    case p of
      Planned pl → do
        mFreed (plMeasure pl) `shouldBe` 1
        (mWindowPages (plMeasure pl) < 200) `shouldBe` True
      other → expectationFailure ("the final chunk was not planned: " <> take 200 (show other))
    (q, _, _) ← must (fillFrom h0 (limitWork 1 (storeWindow (hStore h0))) (planMaintenance (hStore h0)))
    case q of
      Planned pl → (mWindowPages (plMeasure pl) < 200) `shouldBe` True
      other → expectationFailure ("the final chunk at work one was not planned: " <> take 200 (show other))
  it "makes progress at every progress point of a long entry, at work one first, and drains" $
    forM_ [0, 63, 64, 128, 269] $ \done → do
      let (h0, _, _) = finalChunk done
      must (checkH h0)
      (first, _, _) ← must (fillFrom h0 (limitWork 1 (storeWindow (hStore h0))) (planMaintenance (hStore h0)))
      case first of
        Planned pl → (mWindowPages (plMeasure pl) < 250) `shouldBe` True
        other → expectationFailure ("no progress at work one with " <> show done <> " consumed: " <> take 200 (show other))
      let go h n
            | n > (6000 ∷ Int) = Left "the drain did not end"
            | otherwise = do
                (res, _, _, cps) ← fillRetryCounting h (planMaintenance (hStore h))
                case res of
                  Planned pl
                    | cps > mPagesWritten (plMeasure pl) + maxReclaimPages → Left ("more checkpoints (" <> show cps <> ") than facts a transaction can make")
                    | otherwise → commitPlan h pl >>= \h' → go h' (n + 1)
                  NoWork → Right (h, n)
                  other → Left ("maintenance neither did work nor found nothing left: " <> take 200 (show other))
      (drained, _) ← must (go h0 0)
      rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
      must (checkH drained)

-- | The window a maintenance transaction of one page holds, on every layout and progress point: inside the window's
-- bound, and the transaction still makes progress when the window is cut to the at-once bound, the pages it edits
-- and ONE proof ('workOneWindowPages'): every proof beyond one is a fact it carries through a checkpoint.
specBound ∷ Spec
specBound = describe "the window a unit of work of one can need, as a bound" $
  it "stays inside the window's bound on every layout and every progress point, and proceeds when cut to the at-once bound" $ do
    let layouts = [("fragmented", fst3 fragmented)] ++ [("final " <> show d, fst3 (finalChunk d)) | d ← [0, 64, 269]]
        fst3 (a, _, _) = a
        limit = maxWindowBytes `div` windowPageBytes
    rows ← forM layouts $ \(name, h0) → do
      (p, _, _, _) ← must (fillCounting h0 (limitWork 1 (storeWindow (hStore h0))) (planMaintenance (hStore h0)))
      let hr = heightOf h0 TreeRetire
          hf = max 1 (heightOf h0 TreeFree)
          hrec = max 1 (maximum [heightOf h0 t | t ← [TreeRuns, TreeLinks, TreeTodo]])
          lim = workOneWindowPages hr hf hrec 0
          tight = standardBounds {bdWindowPages = lim, bdWindowBytes = lim * windowPageBytes}
      (q, _, _, cps) ← must (fillCounting h0 (limitWork 1 (storeWindow (hStore h0))) (planMaintenanceWith tight (hStore h0)))
      held ← case (p, q) of
        (Planned a, Planned b) → do
          (mWindowPages (plMeasure b) <= lim) `shouldBe` True
          pure (mWindowPages (plMeasure a), lim, mWindowPages (plMeasure b), cps)
        (NoWork, NoWork) → pure (0, lim, 0, cps)
        other → expectationFailure (name <> ": " <> take 200 (show other)) >> fail "plan"
      pure (name, held)
    putStrLn ("BOUND window pages at work one (held in the byte limit, at-once bound, held when cut to it, checkpoints): " <> show rows <> " against the byte limit " <> show limit)
    [name | (name, (n, _, _, _)) ← rows, n > limit] `shouldBe` []

-- | The protection the span of every transaction keeps: a progress field forged forward past pages that are still
-- indexed under the entry is refused by the first transaction after the forgery, whatever the length of the jump.
specForged ∷ Spec
specForged = describe "round 13: a progress field forged forward is refused by the next transaction, for every length of jump" $
  it "refuses jumps shorter and longer than the span checked in every transaction" $
    forM_ [1, 10, 63, 64, 65, 128, 200, 269] $ \done → do
      let (h0, _, _) = forgedProgress done
      (p, _, _) ← must (fillWith h0 (planMaintenance (hStore h0)))
      case p of
        Refused (Integrity (RetiredIndexMismatch _)) → pure ()
        other → expectationFailure ("a progress field of " <> show done <> " over pages still indexed was not refused: " <> take 200 (show other))

windowResult ∷ CapacityWhy → Bool
windowResult c = case c of
  WindowExceeded _ → True
  WindowBytesExceeded _ → True
  _ → False

specAtOnce ∷ Spec
specAtOnce = describe "round 13: the window a unit of work holds at once, under checkpoints" $ do
  let (hNo, firstKeys, _) = fragmentedNoTail
      limitBounds lim = standardBounds {bdWindowPages = lim, bdWindowBytes = lim * windowPageBytes}
  it "property: a unit of one page needs at most the byte limit for every tree height 1..8 and every number of pinned readers 0..maxReaders" $ do
    let bad =
          [ (hr, hf, hrec, pins)
          | hr ← [1 .. maxLevel + 1]
          , hf ← [1 .. maxLevel + 1]
          , hrec ← [1 .. maxLevel + 1]
          , pins ← [0 .. maxReaders]
          , workOneWindowPages hr hf hrec pins * windowPageBytes + workOneProbeBytes hr hf > maxWindowBytes
          ]
    bad `shouldBe` []
    -- the loose list: a unit of one adds at most 'looseGrowthUnit' net once the list is at the soft cap or below (above it the
    -- transaction is a spill, which lowers it), an ordinary plan or a removal none while it holds what the plan claims and at
    -- most the claim and 'looseGrowthOrdinary' below that: neither can reach the cap
    [(hr, hf) | hr ← [1 .. maxLevel + 1], hf ← [1 .. maxLevel + 1], looseSoftCap + looseGrowthUnit hr hf > looseCap] `shouldBe` []
    [hf | hf ← [1 .. maxLevel + 1], maxClaimPages + looseGrowthOrdinary hf > looseCap] `shouldBe` []
    putStrLn ("ATONCE loose list: soft " <> show looseSoftCap <> " + unit of one at (8,8) " <> show (looseGrowthUnit 8 8) <> " <= cap " <> show looseCap <> "; ordinary " <> show (maxClaimPages + looseGrowthOrdinary 8))
    -- and the standalone removal, which cannot shrink, for every record and allocator height and pin count, with the
    -- retirement tree at the minimum fill the store enforces and the backlog bound it checks (at most 17 internal pages)
    let badRemoval = [(hf, hrec, pins) | hf ← [1 .. maxLevel + 1], hrec ← [1 .. maxLevel + 1], pins ← [0 .. maxReaders], removalWindowPages maxRetireInternals hf hrec pins * windowPageBytes + 188 * probeBytes > maxWindowBytes]
    badRemoval `shouldBe` []
    putStrLn ("ATONCE bounds: unit of one at (8,8,8,16) = " <> show (workOneWindowPages 8 8 8 16) <> " pages, removal at (8,8,16) = " <> show (removalWindowPages maxRetireInternals 8 8 16) <> " pages, limit " <> show (maxWindowBytes `div` windowPageBytes))
  it "makes progress at work one with a window of exactly the at-once bound, with 1 to 16 distinct pinned versions, on a store with no tail, and again after the readers release" $ do
    must (checkH hNo)
    (rFree (storeRoots (hStore hNo)) /= Nothing && rHw (storeRoots (hStore hNo)) == fromIntegral (cfgUsablePages (hCfg hNo)) ) `shouldBe` True
    forM_ [1, 2, 4, 8, 16] $ \pins → do
      (hP, toks) ← must (withPins (\i → (firstKeys !! ((7 * i + 3) `mod` length firstKeys), childRec (srcNode (toInteger i + 20) 0 9))) pins hNo)
      let hr = heightOf hP TreeRetire
          hf = heightOf hP TreeFree
          hrec = max (heightOf hP TreeLinks) (heightOf hP TreeRuns)
          lim = workOneWindowPages hr hf hrec pins
          bounds = limitBounds lim
      (p, _, _, cps) ← must (fillCounting hP (limitWork 1 (storeWindow (hStore hP))) (planMaintenanceWith bounds (hStore hP)))
      case p of
        Planned pl → do
          (mWindowPages (plMeasure pl) <= lim) `shouldBe` True
          putStrLn ("ATONCE pins " <> show pins <> " heights " <> show (hr, hf, hrec) <> ": window bound " <> show lim <> ", window held " <> show (mWindowPages (plMeasure pl)) <> ", " <> show cps <> " checkpoints, freed " <> show (mFreed (plMeasure pl)))
          h1 ← must (commitPlan hP pl)
          must (checkH h1)
        other → expectationFailure ("no progress with " <> show pins <> " pinned versions and a window of " <> show lim <> " pages: " <> take 300 (show other))
      -- the readers release: the same store proceeds under the smaller bound of no readers
      let released = hP {hStore = foldl (\st t → snd (releaseReader t st)) (hStore hP) toks}
          lim0 = workOneWindowPages hr hf hrec 0
      (q, _, _, _) ← must (fillCounting released (limitWork 1 (storeWindow (hStore released))) (planMaintenanceWith (limitBounds lim0) (hStore released)))
      case q of
        Planned pl → (mWindowPages (plMeasure pl) <= lim0) `shouldBe` True
        other → expectationFailure ("no progress after the readers released, window " <> show lim0 <> ": " <> take 300 (show other))
  it "answers the typed window result, never a checkpoint with no new fact, for every window too small to hold the edit and one proof" $ do
    let (h0, _, _) = fragmented
    -- every size from 3 pages up to past the at-once bound: planned, or the typed window result; never a loop of checkpoints
    results ← forM [3 .. 40] $ \lim → do
      let tight = standardBounds {bdWindowPages = lim, bdWindowBytes = lim * windowPageBytes}
      (p, _, _, cps) ← must (fillCounting h0 (limitWork 1 (storeWindow (hStore h0))) (planMaintenanceWith tight (hStore h0)))
      case p of
        Planned _ → pure (lim, True, cps)
        Refused (Capacity c) | windowResult c → pure (lim, False, cps)
        other → expectationFailure ("window " <> show lim <> ": " <> take 200 (show other)) >> fail "plan"
    putStrLn ("ATONCE window sizes (pages, planned, checkpoints): " <> show [(l, ok, c) | (l, ok, c) ← results, l `mod` 4 == 3])
    -- a window too small is refused as the typed result, and one big enough plans
    [l | (l, ok, _) ← results, l == 3, ok] `shouldBe` []
    [l | (l, ok, _) ← results, l == 40, not ok] `shouldBe` []
  it "plans through checkpoints exactly the plan one window would give, and takes at most as many checkpoints as pages it proves" $ do
    let (h0, _, _) = fragmented
        big = standardBounds {bdWindowPages = 100000, bdWindowBytes = 1000000000}
    (a, _, _, cpsA) ← must (fillCounting h0 (storeWindow (hStore h0)) (planMaintenanceWith standardBounds (hStore h0)))
    (b, _, _, cpsB) ← must (fillCounting h0 (storeWindow (hStore h0)) (planMaintenanceWith big (hStore h0)))
    cpsB `shouldBe` 0
    case (a, b) of
      (Planned pa, Planned pb) → do
        -- the facts changed nothing: the same pages, the same bytes, the same measure of freed and written pages
        plPages pa `shouldBe` plPages pb
        mFreed (plMeasure pa) `shouldBe` mFreed (plMeasure pb)
        mPagesWritten (plMeasure pa) `shouldBe` mPagesWritten (plMeasure pb)
        -- progress is enforced: a checkpoint carries a fact each, and a transaction proves at most the pages it writes plus its span
        (cpsA <= mPagesWritten (plMeasure pa) + maxReclaimPages) `shouldBe` True
      other → expectationFailure ("the plans differ in kind: " <> take 300 (show other))

-- | Facts are RAM a window carries, trusted only for the state they were proven against.
specFingerprint ∷ Spec
specFingerprint = describe "round 13: the facts a window carries are trusted only for the state they were proven against" $ do
  it "keeps facts for the same state and drops them for any other: another version, another root, a reader acquired in between" $ do
    let (h0, firstKeys, _) = fragmented
        roots = storeRoots (hStore h0)
        fp = fingerprintOf (hIdent h0) roots []
        facts = Facts fp [FactUnreachable (PageNo 9), FactGone 3 (PageNo 11)] noReadFacts
        w1 = windowCheckpoint facts (storeWindow (hStore h0))
    windowFactCount w1 `shouldBe` 2
    windowKnows (FactUnreachable (PageNo 9)) (windowFactsFor fp w1) `shouldBe` True
    -- a reader acquired between two calls changes what the facts were proven against
    (_, s1) ← either (\e → expectationFailure (show e) >> fail "reader") pure (acquireReader (hStore h0))
    let fpPinned = fingerprintOf (hIdent h0) (storeRoots s1) (pinnedRoots s1)
    (fpPinned /= fp) `shouldBe` True
    windowFactCount (windowFactsFor fpPinned w1) `shouldBe` 0
    -- a commit changes the version and the roots
    (h1, out) ← either (\e → expectationFailure e >> fail "commit") pure (commitDelta h0 Ordinary (deltaFor (hStore h0) True False 1 [(firstKeys !! 5, Just (childRec (srcNode 3 3 9)))]))
    case out of
      Committed _ → pure ()
      other → expectationFailure (show other)
    let fpAfter = fingerprintOf (hIdent h1) (storeRoots (hStore h1)) []
    (fpAfter /= fp) `shouldBe` True
    windowFactCount (windowFactsFor fpAfter w1) `shouldBe` 0
    -- facts proven against another state replace the ones a window carries, never merge with them
    let other = Facts fpAfter [FactUnreachable (PageNo 20)] noReadFacts
    windowFactCount (windowCheckpoint other w1) `shouldBe` 1

-- | A sparse retirement tree is corruption, not a window result: a non-root page of the retirement tree below a quarter
-- of a payload, re-sealed with every checksum above it, is refused when a plan descends to it; before the rule a
-- store accepted it, and the one operation that cannot shrink (it indexes every replaced page) could answer the window
-- result for good.
specSparse ∷ Spec
specSparse = describe "round 13: a sparse retirement tree fails closed as corruption" $
  it "answers an integrity result, never a window result, for an under-full inner page and an under-full leaf of the retirement tree" $ do
    let (h0, firstKeys, _) = fragmented
        total = cfgUsablePages (hCfg h0)
        ArenaId a = siArena (hIdent h0)
        retirePages = twPages (walkTree a (siSource (hIdent h0)) (diskRead (hDisk h0)) ((\(PageNo r) → r) <$> rootOf (storeRoots (hStore h0)) TreeRetire))
        rootNo = (\(PageNo r) → r) <$> rootOf (storeRoots (hStore h0)) TreeRetire
        decodeAt q = either (const Nothing) Just . decodePage (hIdent h0) total (PageNo q) =<< diskRead (hDisk h0) (PageNo q)
        inners = [(q, es) | q ← retirePages, Just q /= rootNo, Just (Page _ 1 _ (Inner es@(_ : _ : _ : _))) ← [decodeAt q]]
        leavesOf = [(q, es) | q ← retirePages, Just (Page _ 0 _ (Leaf es@(_ : _ : _ : _))) ← [decodeAt q]]
        commitOne h = commitDelta h Ordinary (deltaFor (hStore h) True False 1 [(firstKeys !! 40, Just (childRec (srcNode 7 7 9)))])
    forgedInner ← case inners of
      ((q, es) : _) → must (forgePage h0 (PageNo q) (Page TreeRetire 1 (PageNo q) (Inner (take 2 es))))
      [] → expectationFailure "no non-root inner page of the retirement tree" >> fail "inner"
    forgedLeaf ← case leavesOf of
      ((q, es) : _) → must (forgePage h0 (PageNo q) (Page TreeRetire 0 (PageNo q) (Leaf (take 3 es))))
      [] → expectationFailure "no leaf of the retirement tree" >> fail "leaf"
    forM_ [("inner", forgedInner), ("leaf", forgedLeaf)] $ \(what, hf) → do
      -- an ordinary plan, which indexes every page it replaces, and maintenance, which unindexes: Integrity either way
      (_, out) ← must (commitOne hf)
      case out of
        Refusal' (Integrity (BadPage (UnderFull _) _)) → pure ()
        other → expectationFailure ("a commit through an under-full " <> what <> " of the retirement tree was not refused as corruption: " <> take 200 (show other))
      (m, _, _) ← must (fillWith hf (planMaintenance (hStore hf)))
      case m of
        Refused (Integrity (BadPage (UnderFull _) _)) → pure ()
        Planned _ → pure () -- the oldest entry's pages may not lie in the forged page
        other → expectationFailure ("maintenance through an under-full " <> what <> " was not refused as corruption: " <> take 200 (show other))

-- | The same store with its loose list padded to exactly @n@ pages of the unwritten space past the used space: a valid
-- store (the pages are dead and counted), the state of one that has accumulated them.
paddedLoose ∷ Int → H → H
paddedLoose n h =
  let roots = storeRoots (hStore h)
      extra = n - length (rLoose roots)
      fresh = [PageNo (rHw roots + fromIntegral i) | i ← [0 .. extra - 1]]
   in h {hStore = modifyRoots (\r → r {rHw = rHw r + fromIntegral extra, rLoose = rLoose r ++ fresh}) (hStore h)}

-- | A loose list at exactly its cap, and the units that cannot shrink: a maintenance transaction of one page finishing an entry
-- whose deletions merge nodes, which must never answer that the list is full on a valid store.
specLoose ∷ Spec
specLoose = describe "round 14: a loose list at exactly its cap" $
  it "drains by spilling first, then finishes an entry whose deletes merge nodes, every call Planned or NoWork" $ do
    let (h0, _, _) = finalChunk 269
        h1 = paddedLoose looseCap h0
    must (checkH h1)
    length (rLoose (storeRoots (hStore h1))) `shouldBe` looseCap
    let go h n
          | n > (3000 ∷ Int) = Left "the drain did not end"
          | otherwise = do
              (res, _, _, _) ← fillRetryCounting h (planMaintenance (hStore h))
              let looseBefore = length (rLoose (storeRoots (hStore h)))
              case res of
                Planned pl → do
                  h' ← commitPlan h pl
                  let looseAfter = length (rLoose (storeRoots (hStore h')))
                  -- above the soft cap the transaction is a spill: it frees nothing and strictly lowers the list
                  if looseBefore > looseSoftCap
                    then
                      if mFreed (plMeasure pl) == 0 && looseAfter < looseBefore then go h' (n + 1) else Left ("a spill above the soft cap did not lower the list: " <> show (looseBefore, looseAfter, mFreed (plMeasure pl)))
                    else
                      if looseAfter > looseCap then Left "the list outgrew its cap" else go h' (n + 1)
                NoWork → Right (h, n)
                other → Left ("maintenance neither did work nor found nothing left: " <> take 200 (show other))
    (drained, passes) ← must (go h1 0)
    putStrLn ("LOOSE at the cap: " <> show passes <> " transactions to drain; loose list " <> show (length (rLoose (storeRoots (hStore drained)))))
    rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
    (length (rLoose (storeRoots (hStore drained))) <= looseSoftCap) `shouldBe` True
    must (checkH drained)
