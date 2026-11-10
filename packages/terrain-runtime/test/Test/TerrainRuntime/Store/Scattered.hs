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
module Test.TerrainRuntime.Store.Scattered (spec) where

import qualified Data.ByteString as BS
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Control.Monad (forM, forM_)
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Child (..), Page (..), encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (Retire (..), be64, encodeFree, encodeKey, encodeRetire, encodeValue, retiredKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (limitWork)
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
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
scattered = scatteredWith False Nothing

-- | The same store in the layout of round 12: the oldest retirement entry holds 64 dispersed pages (the rest
-- are in lists of 505), and a free extent of 256 pages holds old versions of links leaves with distinct keys,
-- so that the supply of a maintenance transaction (4 pages for each page it frees and the reserve) is made of
-- pages each of which must be proven unreachable by reading the path of its own first key: a transaction
-- that frees 64 pages needs a window of 311 pages, one that frees 32 needs 208.
fragmented ∷ (H, [RecordKey], Map.Map RecordKey Record)
fragmented = scatteredWith True Nothing

-- | The layout of round 13: the oldest entry lists 270 dispersed pages, all but the last consumed (its progress
-- field at 269), and the consumed pages were reused and retired again under a newer entry; every page lies in a
-- different leaf of the retirement index. The transaction that finishes the entry verifies its consumed pages are
-- gone from the index: all 269 of them, in 269 leaves, was a window of 311 pages however little work it did.
finalChunk ∷ Int → (H, [RecordKey], Map.Map RecordKey Record)
finalChunk done = scatteredWith False (Just (done, False))

-- | The same entry with its progress field forged to @done@ while every one of its pages is still indexed under it.
forgedProgress ∷ Int → (H, [RecordKey], Map.Map RecordKey Record)
forgedProgress done = scatteredWith False (Just (done, True))

scatteredWith ∷ Bool → Maybe (Int, Bool) → (H, [RecordKey], Map.Map RecordKey Record)
scatteredWith frag fin = (h, firstKeys, ref)
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
    freeLeaf = Page TreeFree 0 (PageNo (usedHw + 256)) (Leaf [encodeFree usedHw 256])
    livePagesList = linkLeaves ++ linkInners ++ [linkRoot] ++ listPages ++ retireLeaves ++ retireInners ++ [retireRoot] ++ [freeLeaf | frag]
    -- a retired page of a legitimate store holds the old version of a record-tree page (maintenance refuses anything else)
    oldPages = [Page TreeLinks 0 (PageNo q) (Leaf [(k, v) | (k, (_, v, _)) ← take 1 (leafRecs !! oldLeaf q)]) | q ← retiredNos]
    oldLeaf q = case lookup q (zip oldest [0 ∷ Int ..]) of
      Just i → (4 * i + 1) `mod` leavesN
      Nothing → fromIntegral q `mod` leavesN
    writtenPages = livePagesList ++ (if frag then extentPages else []) ++ (if frag || fin /= Nothing then oldPages else [])
    hw = if frag then usedHw + 257 else usedHw
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
        , rFreePages = if frag then 256 else 0
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
spec = specBoundary >> specFragmented >> specFinal >> specBound >> specForged

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
  it "plans without a retry only up to the window: the largest chunk outgrows it (the failure round 12 reproduced)" $ do
    (p, _, _) ← must (fillWith h0 (planMaintenance (hStore h0)))
    case p of
      Refused (Capacity c) → c `shouldSatisfy` (\x → case x of WindowBytesExceeded _ → True; WindowExceeded _ → True; ProbesExceeded _ → True; _ → False)
      Planned pl → expectationFailure ("PLANNED freed " <> show (mFreed (plMeasure pl)) <> " window " <> show (mWindowPages (plMeasure pl)) <> " bk " <> show (mBookkeepingPages (plMeasure pl)) <> " loose " <> show (mLooseTaken (plMeasure pl)) <> " claimed " <> show (mClaimed (plMeasure pl)) <> " steps " <> show (mReadSteps (plMeasure pl)))
      other → expectationFailure ("the largest chunk was expected to outgrow the window: " <> take 200 (show other))
  it "makes progress through the public API with the real limits: a retry with half the work frees a smaller chunk, and the store drains" $ do
    (p, _, _) ← must (fillRetry h0 (planMaintenance (hStore h0)))
    case p of
      Planned pl → do
        let freed = mFreed (plMeasure pl)
        (freed > 0 && freed < 64) `shouldBe` True
        h1 ← must (commitPlan h0 pl)
        must (checkH h1)
      other → expectationFailure ("maintenance made no progress: " <> take 300 (show other))
    -- and every call of a long sequence does work or finds nothing left, never a capacity result that repeats
    let go h n
          | n > (6000 ∷ Int) = Left "the drain did not end"
          | otherwise = do
              (res, _, _) ← fillRetry h (planMaintenance (hStore h))
              case res of
                Planned pl → commitPlan h pl >>= \h' → go h' (n + 1)
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
                (res, _, _) ← fillRetry h (planMaintenance (hStore h))
                case res of
                  Planned pl → commitPlan h pl >>= \h' → go h' (n + 1)
                  NoWork → Right (h, n)
                  other → Left ("maintenance neither did work nor found nothing left: " <> take 200 (show other))
      (drained, _) ← must (go h0 0)
      rRetiredPages (storeRoots (hStore drained)) `shouldBe` 0
      must (checkH drained)

-- | The window a maintenance transaction of one page needs, measured on every store of this suite at work one,
-- against the bound derived in 'workOneWindowPages'.
specBound ∷ Spec
specBound = describe "the window a unit of work of one can need, as a bound" $
  it "stays inside the derived bound on every layout and every progress point, and inside the window's" $ do
    let layouts = [("fragmented", fst3 fragmented)] ++ [("final " <> show d, fst3 (finalChunk d)) | d ← [0, 64, 269]]
        fst3 (a, _, _) = a
    rows ← forM layouts $ \(name, h0) → do
      (p, _, _) ← must (fillFrom h0 (limitWork 1 (storeWindow (hStore h0))) (planMaintenance (hStore h0)))
      case p of
        Planned pl → pure (name, mWindowPages (plMeasure pl))
        NoWork → pure (name, 0)
        other → expectationFailure (name <> ": " <> take 200 (show other)) >> fail "plan"
    putStrLn ("BOUND window pages at work one: " <> show rows <> " against the bound " <> show (workOneWindowPages 3 3 3 0))
    [name | (name, n) ← rows, n > workOneWindowPages 3 3 3 0] `shouldBe` []
    (workOneWindowPages 3 3 3 2 < maxWindowPages) `shouldBe` True

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
