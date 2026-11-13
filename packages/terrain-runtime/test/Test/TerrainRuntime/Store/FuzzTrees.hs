-- | A re-sealed byte of a live page, in every one of the five trees.
--
-- "Test.TerrainRuntime.Store.Fuzz" does this to the runs tree through the readers. The five
-- trees share one descent but not their key formats, their validators or their separators:
-- the links tree's keys are 25 or 52 bytes and carry a tag, the todo tree's are sequence numbers,
-- the free tree's are page numbers, and the retirement tree holds two kinds of key (a version,
-- and a marker and a retired page's number). Here a store with every tree several leaves
-- deep (records of all three kinds, a retirement tree with its retired-page index, a free tree
-- of many extents after a partial reclamation) has one byte of one live page of one tree
-- changed and its checksum recomputed, and the tree's own operations (a lookup, a floor, a
-- ceiling, a ranged read and the reachability of a page) are judged against the independent
-- traversal of the unchanged disk: each answer is the reference's or an integrity failure
-- (an answer about a record of a changed leaf is excused as data). Fixed seeds, bounded.
module Test.TerrainRuntime.Store.FuzzTrees (spec, fullSpec, richStore, referenceOf, through) where

import Control.Monad (foldM, forM)
import qualified Data.ByteString as BS
import Data.List (isInfixOf, sortOn)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Child (..), Page (..), decodePage, encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.TerrainRuntime.Output (printLine)
import Test.Hspec
import Test.TerrainRuntime.Store.Depth (Depth (..), atDepth, newFixture, readFixture)
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

data Verdict = IntegrityError | EqualAnswer | Excused | Defect String

data Tally = Tally {tMutations ∷ !Int, tReads ∷ !Int, tIntegrity ∷ !Int, tEqual ∷ !Int, tExcused ∷ !Int, tDefects ∷ !Int}
  deriving stock (Show)

instance Semigroup Tally where
  Tally a b c d e f <> Tally a' b' c' d' e' f' = Tally (a + a') (b + b') (c + c') (d + d') (e + e') (f + f')

instance Monoid Tally where
  mempty = Tally 0 0 0 0 0 0

tallyOf ∷ [Verdict] → Tally
tallyOf vs = Tally 1 (length vs) (length [() | IntegrityError ← vs]) (length [() | EqualAnswer ← vs]) (length [() | Excused ← vs]) (length [() | Defect _ ← vs])

-- | A store whose five trees are each several leaves deep: records of the three kinds written
-- and rewritten over many commits (so there is retirement), then reclaimed in part (so there
-- are many free extents and an unfinished retirement tree with its index).
richStore ∷ Either String H
richStore = do
  let commit h c = do
        let fresh =
              [ (runKey (toInteger c) (toInteger i) 10, Just (runRec 20)) | i ← [0 .. 19 ∷ Int]]
                ++ [(linkKey (srcNode (toInteger c) (toInteger i) 1), Just (rootRec (fromIntegral (i + 1)) (even i))) | i ← [0 .. 19 ∷ Int]]
                ++ [(todoKey (fromIntegral (c * 20 + i)), Just (todoRec (toInteger c) (toInteger i) 2 (fromIntegral (1 + i `mod` 6)))) | i ← [0 .. 19 ∷ Int]]
            -- earlier records rewritten, so pages are replaced and retired
            rewrites =
              if c == 0 then [] else
                [(runKey (toInteger (c - 1)) (toInteger i) 10, Just (runRec (if odd c then 30 else 20))) | i ← [0, 3 .. 19 ∷ Int]]
                  ++ [(linkKey (srcNode (toInteger (c - 1)) (toInteger i) 1), Just (rootRec (fromIntegral (i + 2)) (odd i))) | i ← [0, 5 .. 19 ∷ Int]]
        (h', out) ← commitDelta h Ordinary (deltaFor (hStore h) True False 1 (fresh ++ rewrites))
        case out of
          Committed _ → Right h'
          other → Left ("a commit did not land: " <> show other)
  h1 ← foldM commit (newH smallSpec ident0) [0 .. 359 ∷ Int]
  -- reclaim about half of what is retired
  let target = rRetiredPages (storeRoots (hStore h1)) `div` 5
      drain h n
        | n > (3000 ∷ Int) = Left "reclamation did not progress"
        | rRetiredPages (storeRoots (hStore h)) <= target = Right h
        | otherwise = do
            (p, _, _) ← fillWith h (planMaintenance (hStore h))
            case p of
              Planned plan → commitPlan h plan >>= \h' → drain h' (n + 1)
              _ → Right h
  drain h1 0

-- | Run a tree operation through a window filled from a disk: a refused page, or any stop that is
-- not a missing page, is an integrity failure.
through ∷ H → Disk → M a → Either String a
through h disk act = go (windowTrust (rootTrust (storeRoots (hStore h))) (windowBelow (rHw (storeRoots (hStore h))) (storeWindow (hStore h)))) (0 ∷ Int)
  where
    total = cfgUsablePages (hCfg h)
    go w n
      | n > 4000 = Left "did not settle"
      | otherwise = case runM act (newEdit 0 w) of
          Right (a, _) → Right a
          Left (Need p) → case diskRead disk p of
            Nothing → Left ("page not on disk " <> show p)
            Just bs → case windowInsert total p bs w of
              Left e → Left ("refused " <> show e)
              Right w' → go w' (n + 1)
          Left stop' → Left (show stop')

reseal ∷ BS.ByteString → BS.ByteString
reseal bs = let body = BS.take 4092 bs in BS.append body (le32' (refCrc32c body))

-- | The entries of a tree's leaves in key order, and its pages, from the independent traversal.
referenceOf ∷ H → TreeId → ([(BS.ByteString, BS.ByteString)], [Word64])
referenceOf h tree =
  let ArenaId a = siArena (hIdent h)
      walk = walkTree a (siSource (hIdent h)) (diskRead (hDisk h)) ((\(PageNo p) → p) <$> rootOf (storeRoots (hStore h)) tree)
   in (sortOn fst (twLeaves walk), twPages walk)

-- | One mutation of one page of a tree, every operation judged.
judge ∷ H → TreeId → [(BS.ByteString, BS.ByteString)] → [Word64] → Word64 → Int → BS.ByteString → (Tally, [String])
judge h tree ref pagesOfTree page offset mutated = (tallyOf verdicts, ["page " <> show page <> " at " <> show offset <> ": " <> d <> " | new children " <> show [(q, describePg q) | q ← Set.toList (childrenOf mutated `Set.difference` childrenOf original)] | Defect d ← take 1 verdicts'])
  where
    total = cfgUsablePages (hCfg h)
    ident = hIdent h
    original = fromMaybe BS.empty (diskRead (hDisk h) (PageNo page))
    disk' = diskWrite (PageNo page) mutated (hDisk h)
    rootRef = Disk (fromMaybe (PageNo 0) (rootOf (storeRoots (hStore h)) tree))
    keysOfLeaf bs = case decodePage ident total (PageNo page) bs of
      Right (Page _ 0 _ (Leaf es)) → map fst es
      _ → []
    isLeaf = case decodePage ident total (PageNo page) original of
      Right (Page _ 0 _ (Leaf _)) → True
      _ → False
    allowed = if isLeaf then Set.fromList (keysOfLeaf original ++ keysOfLeaf mutated) else Set.empty
    refKeys = map fst ref
    n = length ref
    sample = [refKeys !! ((offset * 31 + i * 197) `mod` n) | i ← [0 .. 29]] ++ [refKeys !! i | i ← [0, 7 .. 150], i < n] ++ Set.toList allowed
    -- keys that are in no leaf: a sample key with its last byte moved
    absent = [BS.snoc (BS.init k) (BS.last k + 1) | k ← take 12 sample, not (BS.null k)]
    probes = sample ++ absent
    floorRef k = lastMaybe [e | e ← ref, fst e <= k]
    ceilRef k = case [e | e ← ref, fst e >= k] of
      (e : _) → Just e
      [] → Nothing
    lastMaybe xs = if null xs then Nothing else Just (last xs)
    touches es = any (\e → Set.member (fst e) allowed) es
    judgeLookup k = case through h disk' (lookupKey tree (Just rootRef) k) of
      Left _ → [IntegrityError]
      Right got
        | Set.member k allowed → [Excused]
        | got == lookup k ref → [EqualAnswer]
        | otherwise → [Defect ("lookup " <> show k)]
    judgeFloor k = case through h disk' (floorKey tree (Just rootRef) k) of
      Left _ → [IntegrityError]
      Right got
        | got == floorRef k → [EqualAnswer]
        | touches (maybe [] pure got ++ maybe [] pure (floorRef k)) || Set.member k allowed → [Excused]
        | otherwise → [Defect ("floor " <> show k)]
    judgeCeil k = case through h disk' (ceilKey tree False (Just rootRef) k) of
      Left _ → [IntegrityError]
      Right got
        | got == ceilRef k → [EqualAnswer]
        | touches (maybe [] pure got ++ maybe [] pure (ceilRef k)) || Set.member k allowed → [Excused]
        | otherwise → [Defect ("ceiling " <> show k)]
    judgeRange k = case through h disk' (rangeKeys tree (Just rootRef) False k Nothing 12) of
      Left _ → [IntegrityError]
      Right got →
        let want = take 12 [e | e ← ref, fst e >= k]
         in if got == want then [EqualAnswer]
            else if touches (got ++ want) then [Excused]
            else [Defect ("range from " <> show k)]
    firstKeyOf q = case decodePage ident total (PageNo q) =<< maybe (Left BadMagic) Right (diskRead (hDisk h) (PageNo q)) of
      Right (Page _ lv _ (Leaf ((kb, _) : _))) → Just (kb, lv)
      Right (Page _ lv _ (Inner ((kb, _) : _))) → Just (kb, lv)
      _ → Nothing
    childrenOf bs = case decodePage ident total (PageNo page) bs of
      Right (Page _ _ _ (Inner cs)) → Set.fromList (map (childPage . snd) cs)
      _ → Set.empty
    orphaned = childrenOf original `Set.difference` childrenOf mutated
    judgeLive = concat
      [ case through h disk' (livePageAt tree (Just rootRef) kb lvl) of
          Left _ → [IntegrityError]
          Right Nothing → [Defect ("live page " <> show q <> " declared unreachable")]
          Right (Just found) → if found == PageNo q then [EqualAnswer] else [Defect ("page " <> show q <> " found as " <> show found)]
      | (i, q) ← zip [0 ∷ Int ..] pagesOfTree
      , i `mod` 4 == 0
      , q /= page
      , not (Set.member (PageNo q) orphaned)
      , Just (kb, lvl) ← [firstKeyOf q]
      ]
    describePg (PageNo q) = (case decodePage ident total (PageNo q) =<< maybe (Left BadMagic) Right (diskRead (hDisk h) (PageNo q)) of
      Right (Page t lv _ (Leaf es)) → "leaf of " <> show t <> " level " <> show lv <> " " <> show (length es) <> " entries"
      Right (Page t lv _ (Inner es)) → "inner of " <> show t <> " level " <> show lv <> " " <> show (length es) <> " entries"
      Right (Page t lv _ (List _ _)) → "list of " <> show t <> " level " <> show lv
      Left e → "undecodable " <> show e, PageNo q `elem` rLoose (storeRoots (hStore h)), q `elem` pagesOfTree)
    verdicts' = [v | v@(Defect _) ← verdicts]
    verdicts =
      concatMap judgeLookup probes
        ++ concatMap judgeFloor (take 40 probes)
        ++ concatMap judgeCeil (take 40 probes)
        ++ concatMap judgeRange (take 14 probes)
        ++ judgeLive

-- | The routine depth, and every family at its original depth (the optional full-depth probe).
spec, fullSpec ∷ Spec
spec = specAt Routine
fullSpec = specAt Full

specAt ∷ Depth → Spec
specAt depth = describe "a re-sealed byte of a live page, in each of the five trees" $ do
  fixture ← runIO (newFixture "FuzzTrees.richStore" (must richStore))
  it "has every tree several pages deep, with the retired-page index and many free extents" $ do
    h ← readFixture fixture
    let sizes = [(t, length (snd (referenceOf h t))) | t ← [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire]]
    printLine ("FUZZTREES pages " <> show sizes)
    forM_' sizes $ \(t, k) → (t, k) `shouldSatisfy` ((>= 4) . snd)
    let retireKeys = map fst (fst (referenceOf h TreeRetire))
    length [() | k ← retireKeys, BS.index k 0 == 0xFF] `shouldSatisfy` (> 50)
    length [() | k ← retireKeys, BS.index k 0 == 0] `shouldSatisfy` (> 1)
    -- one key length in the tree
    (all ((== 9) . BS.length) retireKeys) `shouldBe` True
    must (checkH h)
  it "refuses a pointer that names a stale valid page of the same tree and level, where it used to answer from the stale page" $ do
    h ← readFixture fixture
    let total = cfgUsablePages (hCfg h)
        hw = rHw (storeRoots (hStore h))
        decodeAt p = either (const Nothing) Just . decodePage (hIdent h) total (PageNo p) =<< diskRead (hDisk h) (PageNo p)
        staleLeaves tree lo hi =
          [ (q, ls)
          | PageNo q ← rLoose (storeRoots (hStore h))
          , q < hw
          , Just (Page t 0 _ (Leaf ls@(_ : _))) ← [decodeAt q]
          , t == tree
          , all (\(k, _) → maybe True (<= k) lo && maybe True (k <) hi) ls
          ]
        -- every internal page above leaves, every child of it, and a stale leaf of the same tree that fits its bounds
        candidates tree =
          [ (p, i, es, q, ls)
          | p ← snd (referenceOf h tree)
          , Just (Page _ 1 _ (Inner es)) ← [decodeAt p]
          , (i, (k, Child c _)) ← zip [0 ∷ Int ..] es
          , let hi = if i + 1 < length es then Just (fst (es !! (i + 1))) else Nothing
          , (q, ls) ← take 1 (filter (\(qq, _) → PageNo qq /= c) (staleLeaves tree (Just k) hi))
          ]
    results ← forM [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire] $ \tree → do
      let ref = fst (referenceOf h tree)
          rootRef = Disk (fromMaybe (PageNo 0) (rootOf (storeRoots (hStore h)) tree))
      fmap concat $ forM (take 6 (candidates tree)) $ \(p, i, es, q, staleEntries) → forM [False, True] $ \ownCrc → do
        -- the parent now names the stale page. Either with the checksum it recorded for the page that was there, or (the
        -- one-page forgery) with the stale page's own checksum, so that the check of the child passes and only the record
        -- above the forged page (its parent's entry, or the root record when it is the root) can tell
        let staleCrc = maybe 0 (\bs → getLe32' bs 4092) (diskRead (hDisk h) (PageNo q))
            es' = [if j == i then (k, Child (PageNo q) (if ownCrc then staleCrc else crc)) else (k, Child c crc) | (j, (k, Child c crc)) ← zip [0 ∷ Int ..] es]
            lv = maybe 1 pgLevel (decodeAt p)
        bytes ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h) (Page tree lv (PageNo p) (Inner es')))
        let disk' = diskWrite (PageNo p) bytes (hDisk h)
            -- keys the stale page holds that the reference answers differently
            differing = [k | (k, v) ← staleEntries, lookup k ref /= Just v]
            isRoot = rootOf (storeRoots (hStore h)) tree == Just (PageNo p)
        -- a lookup of any key in the stale page's range either fails as corrupt or is the reference's answer: never the stale answer
        let verdicts = [through h disk' (lookupKey tree (Just rootRef) k) | k ← map fst staleEntries]
            stale = [k | (k, Right got) ← zip (map fst staleEntries) verdicts, got /= lookup k ref]
        stale `shouldBe` []
        pure (tree, ownCrc, isRoot, length differing, length [() | Left _ ← verdicts])
    let flat = concat results
    printLine ("FUZZTREES stale pointers (tree, with the stale page's own checksum, parent is the root, records the stale page would have answered differently, integrity failures) " <> show flat)
    -- the retirement tree, whose pages are rewritten every commit, has such pages; the stale ones differ from the reference
    [d | (TreeRetire, _, _, d, _) ← flat] `shouldSatisfy` (any (> 0))
    [e | (_, _, _, _, e) ← flat] `shouldSatisfy` (any (> 0))
    -- the forgery that records the stale page's own checksum is refused where the forged page is itself the root: the root record tells
    [e | (_, True, True, _, e) ← flat] `shouldSatisfy` (any (> 0))
  it "refuses a re-sealed under-full non-root leaf and inner page when the store descends to it, in each tree kind, and answers the page it was" $ do
    h ← readFixture fixture
    let total = cfgUsablePages (hCfg h)
        decodeAt q = either (const Nothing) Just . decodePage (hIdent h) total (PageNo q) =<< diskRead (hDisk h) (PageNo q)
    rows ← forM [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire] $ \tree → do
      let (_, treePages) = referenceOf h tree
          rootNo = (\(PageNo r) → r) <$> rootOf (storeRoots (hStore h)) tree
          rootRef = Disk (fromMaybe (PageNo 0) (rootOf (storeRoots (hStore h)) tree))
          nonRoot = [q | q ← treePages, Just q /= rootNo]
          leaves = [(q, es) | q ← nonRoot, Just (Page _ 0 _ (Leaf es@(_ : _ : _))) ← [decodeAt q]]
          inners = [(q, lv, es) | q ← nonRoot, Just (Page _ lv _ (Inner es@(_ : _ : _ : _))) ← [decodeAt q]]
          refused forged firstKey = do
            hf ← must (forgePage h (pgNo forged) forged)
            -- the forgery is consistent (every checksum above agrees), and a read that descends to it is refused
            pure (through hf (hDisk hf) (lookupKey tree (Just rootRef) firstKey))
      leafRes ← case leaves of
        ((q, es@((k0, _) : _)) : _) → (\r → [("leaf" ∷ String, r)]) <$> refused (Page tree 0 (PageNo q) (Leaf (take 1 es))) k0
        _ → pure []
      innerRes ← case inners of
        ((q, lv, es@((k0, _) : _)) : _) → (\r → [("inner" ∷ String, r)]) <$> refused (Page tree lv (PageNo q) (Inner (take 2 es))) k0
        _ → pure []
      pure (tree, leafRes ++ innerRes)
    printLine ("FUZZTREES under-full pages refused at descent: " <> show [(t, [(kind, either (take 60) (const "ANSWERED") r) | (kind, r) ← rs]) | (t, rs) ← rows])
    -- every tree kind has a non-root leaf, and the trees with a non-root inner page are refused there too
    [t | (t, rs) ← rows, null [() | ("leaf", _) ← rs]] `shouldBe` []
    [(t, k) | (t, rs) ← rows, (k, r) ← rs, either (not . ("UnderFull" `isInfixOf`)) (const True) r] `shouldBe` []
    length [() | (_, rs) ← rows, ("inner", _) ← rs] `shouldSatisfy` (>= 2)
  forM_' [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire] $ \tree →
    it ("a mutated root record never changes what a read answers, " <> show tree) $ do
      h ← readFixture fixture
      let roots = storeRoots (hStore h)
          (ref, treePages) = referenceOf h tree
          setRoot p r = r {rRuns = pick' TreeRuns (Just p) (rRuns r), rLinks = pick' TreeLinks (Just p) (rLinks r), rTodo = pick' TreeTodo (Just p) (rTodo r), rFree = pick' TreeFree (Just p) (rFree r), rRetire = pick' TreeRetire (Just p) (rRetire r)}
          pick' t v old = if tree == t then v else old
          setCrc f r = r {rRootCrcs = [(t, if t == tree then f c else c) | (t, c) ← rRootCrcs r]}
          dead = [PageNo q | PageNo q ← rLoose roots, q < rHw roots]
          rootNo = fromMaybe (PageNo 0) (rootOf roots tree)
          -- one field of the root record: its checksum moved, or the page it names replaced by another page of the tree or a
          -- dead page (the record's checksum left as it was)
          variants =
            [("checksum flipped", setCrc (\c → c + 1), rootNo)]
              ++ [("the root replaced by page " <> show q, setRoot q, q) | q ← take 4 [PageNo q' | q' ← treePages, PageNo q' /= rootNo] ++ take 4 dead]
          keysToRead = [fst e | (i, e) ← zip [0 ∷ Int ..] ref, i `mod` 7 == 0]
          judgeVariant (what, f, newRoot) =
            let h' = h {hStore = modifyRoots f (hStore h)}
                verdicts = [ through h' (hDisk h') (lookupKey tree (Just (Disk newRoot)) k) | k ← take 30 keysToRead ]
                wrong = [k | (k, Right got) ← zip keysToRead verdicts, got /= lookup k ref]
             in (what, length [() | Left _ ← verdicts], length [() | Right _ ← verdicts], wrong)
          results = map judgeVariant variants
      printLine ("FUZZTREES root record " <> show tree <> " " <> show [(w, e, q) | (w, e, q, _) ← results])
      -- never another answer; and a root that names another page, or whose checksum was moved, is refused
      [w | (w, _, _, _ : _) ← results] `shouldBe` []
      [w | (w, e, _, _) ← results, e == 0] `shouldBe` []
  forM_' [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire] $ \tree →
    it ("reads exactly as the reference or fails as corrupt, " <> show tree) $ do
      h ← readFixture fixture
      let (ref, treePages) = referenceOf h tree
          parsedAt p = either (const Nothing) Just . decodePage (hIdent h) (cfgUsablePages (hCfg h)) (PageNo p) =<< diskRead (hDisk h) (PageNo p)
          inner = [p | p ← treePages, Just (Page _ lv _ (Inner _)) ← [parsedAt p], lv >= 1]
          leaves = [p | p ← treePages, Just (Page _ 0 _ (Leaf _)) ← [parsedAt p]]
          runSeed seed = forM (take 50 (iterate (snd . nextWord) (mkRng seed))) $ \g → do
            let (w1, g1) = nextWord g
                (w2, g2) = nextWord g1
                (w3, g3) = nextWord g2
                (w4, _) = nextWord g3
                pick' xs w = xs !! fromIntegral (w `mod` fromIntegral (length xs))
                page
                  | w1 `mod` 10 < 6 && not (null inner) = pick' inner (w1 `div` 10)
                  | otherwise = pick' leaves (w1 `div` 10)
                original = fromMaybe BS.empty (diskRead (hDisk h) (PageNo page))
                offset = if w2 `mod` 2 == 0 then 40 + fromIntegral ((w2 `div` 2) `mod` 120) else 24 + fromIntegral ((w2 `div` 2) `mod` 4000)
                byteMutation = reseal (BS.concat [BS.take offset original, BS.singleton (fromIntegral (w3 `mod` 256)), BS.drop (offset + 1) original])
                -- a third of the mutations of internal pages retarget one child pointer to a page that was
                -- replaced and is dead (the loose pages) or to another page of the tree: still one field
                retarget = case parsedAt page of
                  Just (Page _ lv _ (Inner es)) | lv >= 1, not (null es) →
                    let i = fromIntegral (w3 `mod` fromIntegral (length es))
                        at = 40 + sum [1 + BS.length k + 12 | (k, _) ← take i es] + 1 + BS.length (fst (es !! i))
                        targets = [q | PageNo q ← rLoose (storeRoots (hStore h))] ++ treePages
                        t = pick' targets w4
                     in Just (at, reseal (BS.concat [BS.take at original, le64' t, BS.drop (at + 8) original]))
                  _ → Nothing
                -- the one-page forgery: the entry names a dead page and records that page's own checksum, so the
                -- check of the child passes and only the record above the forged page can tell
                retargetCrc = case retarget of
                  Just (at, _) →
                    let t = pick' ([q | PageNo q ← rLoose (storeRoots (hStore h))] ++ treePages) w4
                        tcrc = maybe 0 (\bs → getLe32' bs 4092) (diskRead (hDisk h) (PageNo t))
                     in Just (at, reseal (BS.concat [BS.take at original, le64' t, le32' tcrc, BS.drop (at + 12) original]))
                  Nothing → Nothing
                (offset', mutated) = case (retarget, retargetCrc) of
                  (_, Just r) | w1 `mod` 3 == 1 → r
                  (Just r, _) | w1 `mod` 3 == 0 → r
                  _ → (offset, byteMutation)
            pure (judge h tree ref treePages page offset' mutated)
      treePages `shouldSatisfy` (not . null)
      let seeds = atDepth depth [11] [11, 22, 33, 44, 55]
      tallies ← mapM runSeed seeds
      let tally = mconcat (map fst (concat tallies))
          defects = concatMap snd (concat tallies)
      printLine ("FUZZTREES " <> show tree <> " " <> show tally)
      tMutations tally `shouldBe` 50 * length seeds
      if null defects then pure () else expectationFailure (unlines (take 12 defects) <> show (length defects) <> " mutations with defects")
      tDefects tally `shouldBe` 0
      tIntegrity tally `shouldSatisfy` (> 0)
      tEqual tally `shouldSatisfy` (> 0)
  where
    forM_' xs f = mapM_ f xs
