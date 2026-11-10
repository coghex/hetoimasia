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
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Child (..), Page (..), encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (Retire (..), be64, encodeKey, encodeRetire, encodeValue, retiredKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
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
scattered = (h, firstKeys, ref)
  where
    -- the links tree: the records sorted by their encoded keys, 40 to a leaf
    recs = sortOn fst [(encodeKey k, (k, encodeValue a, a)) | i ← [0 .. leavesN * perLeaf - 1], let (k, a, _) = linkOf i]
    leafRecs = chunk perLeaf recs
    ref = Map.fromList [(k, a) | (_, (k, _, a)) ← recs]
    firstKeys = [k | ((_, (k, _, _)) : _) ← leafRecs]
    chunk _ [] = []
    chunk n xs = let (a, b) = splitAt n xs in a : chunk n b
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
    innerGroups = chunk 54 linkLeaves
    linkInners = [Page TreeLinks 1 (PageNo (base + fromIntegral n)) (Inner [(firstKeyOf pg, childOf pg) | pg ← grp]) | (n, grp) ← zip [0 ∷ Int ..] innerGroups]
    firstKeyOf (Page _ _ _ (Leaf ((k, _) : _))) = k
    firstKeyOf (Page _ _ _ (Inner ((k, _) : _))) = k
    firstKeyOf _ = BS.empty
    linkRoot = Page TreeLinks 2 (PageNo (base + 5)) (Inner [(firstKeyOf pg, childOf pg) | pg ← linkInners])
    -- the retirement lists: 29 entries of up to 505 retired pages
    listsOf = chunk 505 retiredNos
    nLists = length listsOf
    listBase = base + 6
    listPages = [Page TreeRetire 0 (PageNo (listBase + fromIntegral n)) (List (fromIntegral n + 1) (map PageNo ps)) | (n, ps) ← zip [0 ∷ Int ..] listsOf]
    versionRecs = [encodeRetire (fromIntegral n + 1) (Retire (PageNo (listBase + fromIntegral n)) (fromIntegral (length ps)) 0) | (n, ps) ← zip [0 ∷ Int ..] listsOf]
    versionOf p = fromIntegral (length (takeWhile (/= p) [q | ps ← listsOf, q ← ps]) `div` 505) + 1 ∷ Word64
    indexRecs = [(retiredKey (PageNo p), be64 (versionOf p)) | p ← retiredNos]
    -- the retirement tree: leaves of 54 index records (the first also holds the 29 entries)
    idxGroups = chunk groupN indexRecs
    idxLeafRecs = case idxGroups of
      (g0 : gs) → (versionRecs ++ g0) : gs
      [] → []
    retireLeafBase = listBase + fromIntegral nLists
    retireLeaves = [Page TreeRetire 0 (PageNo (retireLeafBase + fromIntegral n)) (Leaf rs) | (n, rs) ← zip [0 ∷ Int ..] idxLeafRecs]
    retireInnerBase = retireLeafBase + fromIntegral (length retireLeaves)
    retireInners = [Page TreeRetire 1 (PageNo (retireInnerBase + fromIntegral n)) (Inner [(firstKeyOf pg, childOf pg) | pg ← grp]) | (n, grp) ← zip [0 ∷ Int ..] (chunk 136 retireLeaves)]
    retireRoot = Page TreeRetire 2 (PageNo (retireInnerBase + fromIntegral (length retireInners))) (Inner [(firstKeyOf pg, childOf pg) | pg ← retireInners])
    livePagesList = linkLeaves ++ linkInners ++ [linkRoot] ++ listPages ++ retireLeaves ++ retireInners ++ [retireRoot]
    hw = retireInnerBase + fromIntegral (length retireInners) + 1
    h0 = newH (specOf (128 * 1024 * 1024) Nothing) ident0
    disk = foldl (\dk pg → diskWrite (pgNo pg) (either (error . show) id (encodePage ident0 pg)) dk) (hDisk h0) livePagesList
    roots0 = storeRoots (hStore h0)
    roots =
      roots0
        { rVersion = 100
        , rLinks = Just (pgNo linkRoot)
        , rRetire = Just (pgNo retireRoot)
        , rHw = hw
        , rLivePages = fromIntegral (length livePagesList)
        , rRetiredPages = fromIntegral retiredCount
        , rRootCrcs = [(TreeLinks, crcOf linkRoot), (TreeRetire, crcOf retireRoot)]
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
spec = describe "the round-11 boundary at the real reserve: 64 dispersed link updates need more bookkeeping than 68" $ do
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
