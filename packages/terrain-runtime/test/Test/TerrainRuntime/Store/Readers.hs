-- | Pinned readers, retirement and reclamation.
--
-- Readers pin several committed versions while later writes replace, delete and
-- split pages; each reader, through a fresh window (the caches dropped), keeps
-- answering from exactly the records of its version. Replaced record pages are
-- retired and stay until the last reader of an older version releases; only then
-- does reclamation proceed, incrementally, and the freed pages are reused by later
-- commits. After every step the independent traversal decides, from the bytes, that
-- the live, retired, free and loose pages partition the page space (so freeing a
-- page a root still reaches fails the partition, not a count), and a token for a
-- released reader, another store or another incarnation reads nothing.
module Test.TerrainRuntime.Store.Readers (spec) where

import Control.Monad (foldM, forM_, when)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.List (nub)
import Data.Int (Int64)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..), maxBatchUpdates)
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Child (..), Page (..), decodePage, encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (be64, decodeKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Workload

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | One generated commit of writes against the reference.
churn ∷ (H, Map.Map RecordKey Record, Rng) → Int → Either String (H, Map.Map RecordKey Record, Rng)
churn (h, ref, g) n = do
  let (ws, g') = genWrites g ref n
  (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
  Right (h', applyRef ws ref, g')

spec ∷ Spec
spec = describe "pinned readers, retirement and reclamation" $ do
  it "keeps every pinned version's answers through later writes, eviction and retirement, then reclaims only after the last reader" $ do
    let st0 = (newH smallSpec ident0, Map.empty, mkRng 77)
    (h1, ref1, g1) ← must (foldM (\s _ → churn s 30) st0 [1 .. 40 ∷ Int])
    (r1, s1) ← must (either (Left . show) Right (acquireReader (hStore h1)))
    (h2, ref2, g2) ← must (foldM (\s _ → churn s 30) (h1 {hStore = s1}, ref1, g1) [1 .. 25 ∷ Int])
    (r2, s2) ← must (either (Left . show) Right (acquireReader (hStore h2)))
    (h3, ref3, _) ← must (foldM (\s _ → churn s 30) (h2 {hStore = s2}, ref2, g2) [1 .. 40 ∷ Int])
    seen1 ← must (readAll h3 r1)
    seen2 ← must (readAll h3 r2)
    Map.fromList seen1 `shouldBe` ref1
    Map.fromList seen2 `shouldBe` ref2
    must (compareRecords (Map.toList ref3) h3)
    must (checkH h3)
    -- replaced pages are retired; entries newer than the oldest pin stay until it releases
    (usRetiredBytes (usage (hStore h3)) > 0) `shouldBe` True
    (hBlocked, _) ← must (reclaimAll h3)
    (usRetiredBytes (usage (hStore hBlocked)) > 0) `shouldBe` True
    (blocked, _, _) ← must (fillWith hBlocked (planMaintenance (hStore hBlocked)))
    case blocked of
      BlockedByReader entry pin → (pin < entry) `shouldBe` True
      other → expectationFailure ("expected a block by the reader, got " <> show other)
    again1 ← must (readAll hBlocked r1)
    Map.fromList again1 `shouldBe` ref1
    -- the newer reader's release alone frees nothing: the older one still holds its pages
    let (rel2, s4) = releaseReader r2 (hStore hBlocked)
    rel2 `shouldBe` Applied
    (hStill, n1) ← must (reclaimAll hBlocked {hStore = s4})
    n1 `shouldBe` 0
    again2 ← must (readAll hStill r1)
    Map.fromList again2 `shouldBe` ref1
    -- the last release lets reclamation run, incrementally
    let (rel1, s5) = releaseReader r1 (hStore hStill)
    rel1 `shouldBe` Applied
    (hDone, n2) ← must (reclaimAll hStill {hStore = s5})
    n2 `shouldSatisfy` (> 1)
    usRetiredBytes (usage (hStore hDone)) `shouldBe` 0
    must (checkH hDone)
    must (compareRecords (Map.toList ref3) hDone)
    -- a released token authorises nothing
    case readerLookup (hStore hDone) r1 (storeWindow (hStore hDone)) (KeyTodo 0) of
      ReadStale → pure ()
      other → expectationFailure ("a released token read " <> show other)
    -- the freed pages are reused: more history does not raise the high-water mark first
    let hw0 = rHw (storeRoots (hStore hDone))
    (h4, _, _) ← must (foldM (\s _ → churn s 12) (hDone, ref3, mkRng 9) [1 .. 6 ∷ Int])
    rHw (storeRoots (hStore h4)) `shouldSatisfy` (<= hw0 + 64)
    must (checkH h4)
  it "pins the version it was taken at, shares unchanged pages with the current root and answers floors" $ do
    let st0 = (newH smallSpec ident0, Map.empty, mkRng 31)
    (h1, ref1, g1) ← must (foldM (\s _ → churn s 30) st0 [1 .. 150 ∷ Int])
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h1)))
    readerVersion s1 tok `shouldBe` Right (storeVersion (hStore h1))
    (h2, ref2, _) ← must (foldM (\s _ → churn s 2) (h1 {hStore = s1}, ref1, g1) [1 .. 2 ∷ Int])
    -- the two versions share pages: a small change leaves most of the tree untouched
    let ArenaId a = siArena (hIdent h2)
        pagesAt r = maybe [] (\(PageNo p) → twPages (walkTree a (siSource (hIdent h2)) (diskRead (hDisk h2)) (Just p))) r
        oldPages = pagesAt (committedRoot s1 TreeRuns)
        newPages = pagesAt (committedRoot (hStore h2) TreeRuns)
    length [p | p ← oldPages, p `elem` newPages] `shouldSatisfy` (> 0)
    -- the pinned floor lookup answers from the old version
    let total = cfgUsablePages (hCfg h2)
        runs = [(k, v) | (k@(KeyRun _ _), v) ← Map.toList ref1]
    forM_ (take 8 runs) $ \(k, v) → case k of
      KeyRun c lo → do
        w0 ← must (either (const (Left "stale")) Right (readerWindow (hStore h2) tok))
        let go w (n ∷ Int) = case readerFloorRun (hStore h2) tok w c lo of
              Read r → Right r
              ReadNeeds p | n < 50 → case diskRead (hDisk h2) p of
                Just bs → either (Left . show) (\x → go x (n + 1)) (windowInsert total p bs w)
                Nothing → Left "missing page"
              other → Left (show other)
        r ← must (go w0 0)
        fmap (\(l, _, _) → l) r `shouldBe` Just lo
        fmap (\(_, h, _) → h) r `shouldBe` Just (hiOf v)
      _ → pure ()
    must (compareRecords (Map.toList ref2) h2)
  it "answers exact lookups and bounded ordered range reads from pages, across leaves, from and after a key" $ do
    (h, ref, _) ← must (foldM (\s _ → churn s 30) (newH smallSpec ident0, Map.empty, mkRng 63) [1 .. 120 ∷ Int])
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h)))
    let total = cfgUsablePages (hCfg h)
        runs = [(k, v) | (k@(KeyRun _ _), v) ← Map.toAscList ref]
        go ∷ Show a ⇒ Window → (Window → ReadOutcome a) → Either String a
        go w act = case act w of
          Read r → Right r
          ReadNeeds p → case diskRead (hDisk h) p of
            Just bs → either (Left . show) (\x → go x act) (windowInsert total p bs w)
            Nothing → Left "missing page"
          other → Left (show other)
        win = either (const (error "stale")) id (readerWindow s1 tok)
        range start n = either (\e → error e) id (go win (\w → readerRange s1 tok w TreeRuns start n))
        look key = either (\e → error e) id (go win (\w → readerLookup s1 tok w key))
    length runs `shouldSatisfy` (> 300)
    case runs of
      ((k0, _) : _) → do
        range (RangeFrom k0) 10 `shouldBe` take 10 runs
        range (RangeAfter (fst (runs !! 9))) 10 `shouldBe` take 10 (drop 10 runs)
        -- a limit beyond the bound is cut to it, and the read still starts and ends in order
        let big = range (RangeFrom k0) 100000
        length big `shouldBe` maxRangeRecords
        big `shouldBe` take maxRangeRecords runs
        -- a read that crosses leaves and ends at the tree's last key
        range (RangeAfter (fst (last runs))) 10 `shouldBe` []
        range (RangeFrom (fst (last runs))) 10 `shouldBe` [last runs]
        range (RangeAfter (fst (runs !! (length runs - 4)))) 100 `shouldBe` drop (length runs - 3) runs
        forM_ (take 12 runs) $ \(k, v) → look k `shouldBe` Just v
        -- an absent key is a confirmed absence, not a missing page
        case k0 of
          KeyRun c lo → look (KeyRun c (lo + 1)) `shouldBe` Nothing
          _ → pure ()
      [] → expectationFailure "runs expected"
  it "starts a ranged read at the greatest key at or below a floor: inside a run, at a run's first key, below a column's first key, in an empty column, and across leaves" $ do
    (h, ref, _) ← must (foldM (\s _ → churn s 30) (newH smallSpec ident0, Map.empty, mkRng 63) [1 .. 120 ∷ Int])
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h)))
    let total = cfgUsablePages (hCfg h)
        runs = [(k, v) | (k@(KeyRun _ _), v) ← Map.toAscList ref]
        go ∷ Show a ⇒ Window → (Window → ReadOutcome a) → Either String a
        go w act = case act w of
          Read r → Right r
          ReadNeeds p → case diskRead (hDisk h) p of
            Just bs → either (Left . show) (\x → go x act) (windowInsert total p bs w)
            Nothing → Left "missing page"
          other → Left (show other)
        win = either (const (error "stale")) id (readerWindow s1 tok)
        range start n = either (\e → error e) id (go win (\w → readerRange s1 tok w TreeRuns start n))
        -- the reference: from the greatest key at or below the floor, or from the first key above it
        expected k n = case [key | (key, _) ← runs, key <= k] of
          [] → take n (dropWhile ((< k) . fst) runs)
          atOrBelow → take n (dropWhile ((< last atOrBelow) . fst) runs)
    length runs `shouldSatisfy` (> 300)
    -- at every run's own first key, and just inside every run (ten records on: reads that cross leaves)
    forM_ runs $ \(k, _) → do
      range (RangeFloor k) 10 `shouldBe` expected k 10
      case k of
        KeyRun c lo → range (RangeFloor (KeyRun c (lo + 1))) 10 `shouldBe` expected (KeyRun c (lo + 1)) 10
        _ → pure ()
    case runs of
      (KeyRun c0 lo0, _) : _ → do
        -- below the first key of the tree: from that first key
        range (RangeFloor (KeyRun c0 (lo0 - 1))) 5 `shouldBe` take 5 runs
      _ → expectationFailure "runs expected"
    -- below a column's first key, and in a column with no run: from the greatest key below (another column's)
    let runColumns = nub [c | (KeyRun c _, _) ← runs]
    forM_ (take 40 runColumns) $ \c → do
      let firstLo = minimum [lo | (KeyRun c' lo, _) ← runs, c' == c]
      range (RangeFloor (KeyRun c (firstLo - 1))) 6 `shouldBe` expected (KeyRun c (firstLo - 1)) 6
    let emptyColumn = case [columnAt x y | x ← [0 .. 4096], y ← [0 .. 3], columnAt x y `notElem` runColumns] of
          c : _ → c
          [] → columnAt 0 0
    range (RangeFloor (KeyRun emptyColumn 0)) 6 `shouldBe` expected (KeyRun emptyColumn 0) 6
  it "refuses to free a page that is already free, loose or claimed by the same plan, however its retirement entry came to name it" $ do
    let st0 = (newH smallSpec ident0, Map.empty, mkRng 15)
    (h1, ref1, g1) ← must (foldM (\s _ → churn s 30) st0 [1 .. 30 ∷ Int])
    (h2, _) ← must (reclaimAll h1)
    (h3, _, _) ← must (foldM (\s _ → churn s 30) (h2, ref1, g1) [1 .. 3 ∷ Int])
    let ArenaId a = siArena (hIdent h3)
        o = ownership a (siSource (hIdent h3)) (hStore h3) (diskRead (hDisk h3))
        entries = sortOn' [(getBe64' k 1, (getBe64' v 0, getLe16' v 8)) | (TreeRetire, ls) ← owLeaves o, (k, v) ← ls, BS.length k == 9, BS.index k 0 == 0]
        freeStarts = [getBe64' k 0 | (TreeFree, ls) ← owLeaves o, (k, _) ← ls]
        loosePage = case rLoose (storeRoots (hStore h3)) of
          (PageNo p : _) → [p]
          [] → []
    length freeStarts `shouldSatisfy` (> 1)
    loosePage `shouldSatisfy` (not . null)
    -- the highest free extent (untouched by the plan's own supply), the lowest free page (which the
    -- plan's supply takes first, so it is no longer free once consumed), and a loose page
    forM_ [("a free page", [last freeStarts]), ("the lowest free page, taken by the plan's own supply", take 1 freeStarts), ("a loose page", loosePage)] $ \(what, victim) →
      case (entries, victim) of
        ((ek, (lp, count)) : _, fs : _) → do
          listPage ← maybe (expectationFailure "list page" >> fail "list") pure (diskRead (hDisk h3) (PageNo lp))
          ps ← case parsePage a (siSource (hIdent h3)) listPage of
            Right (RefPage _ _ _ (RefList _ xs) _) → pure xs
            other → expectationFailure (show other) >> fail "list"
          length ps `shouldBe` fromIntegral count
          let tampered = sortOn' (fs : drop 1 ps)
          bytes ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h3) (Page TreeRetire 0 (PageNo lp) (List ek (map PageNo tampered))))
          let h4 = h3 {hDisk = diskWrite (PageNo lp) bytes (hDisk h3)}
          (outcome, _, _) ← must (fillWith h4 (planMaintenance (hStore h4)))
          case outcome of
            Refused (Integrity _) → pure ()
            other → expectationFailure ("a double free of " <> what <> " was not refused: " <> take 200 (show other))
        _ → expectationFailure "expected a retirement entry and a page to name"
  it "refuses to reclaim a page the committed trees still reach, whichever live page a retirement entry names" $ do
    let st0 = (newH smallSpec ident0, Map.empty, mkRng 15)
    (h1, ref1, g1) ← must (foldM (\s _ → churn s 30) st0 [1 .. 30 ∷ Int])
    (h2, _) ← must (reclaimAll h1)
    (h3, _, _) ← must (foldM (\s _ → churn s 30) (h2, ref1, g1) [1 .. 3 ∷ Int])
    let ArenaId a = siArena (hIdent h3)
        roots = storeRoots (hStore h3)
        o = ownership a (siSource (hIdent h3)) (hStore h3) (diskRead (hDisk h3))
        entries = sortOn' [(getBe64' k 1, (getBe64' v 0, getLe16' v 8)) | (TreeRetire, ls) ← owLeaves o, (k, v) ← ls, BS.length k == 9, BS.index k 0 == 0]
        pageOf (PageNo n) = maybe (expectationFailure ("page " <> show n) >> fail "page") pure (diskRead (hDisk h3) (PageNo n))
    runsRoot ← maybe (expectationFailure "a runs root expected" >> fail "runs") pure (rRuns roots)
    rootBytes ← pageOf runsRoot
    -- a live page below the root: a child of the runs root, so a shared subtree, not only a root
    child ← case parsePage a (siSource (hIdent h3)) rootBytes of
      Right (RefPage _ _ _ (RefInner ((_, c, _) : _)) _) → pure c
      other → expectationFailure ("an inner runs root expected: " <> show other) >> fail "child"
    freeRoot ← maybe (expectationFailure "a free root expected" >> fail "free") pure (rFree roots)
    let PageNo rr = runsRoot
        victims = [("the runs root", rr), ("a live page below the runs root", child), ("the free tree's root", (\(PageNo n) → n) freeRoot)]
              <> [("the retirement tree's root", n) | Just (PageNo n) ← [rRetire roots]]
    forM_ victims $ \(what, victim) →
      case entries of
        ((ek, (lp, count)) : _) → do
          listPage ← maybe (expectationFailure "list page" >> fail "list") pure (diskRead (hDisk h3) (PageNo lp))
          ps ← case parsePage a (siSource (hIdent h3)) listPage of
            Right (RefPage _ _ _ (RefList _ xs) _) → pure xs
            other → expectationFailure (show other) >> fail "list"
          length ps `shouldBe` fromIntegral count
          bytes ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h3) (Page TreeRetire 0 (PageNo lp) (List ek (map PageNo (sortOn' (victim : drop 1 ps))))))
          let h4 = h3 {hDisk = diskWrite (PageNo lp) bytes (hDisk h3)}
          (outcome, _, _) ← must (fillWith h4 (planMaintenance (hStore h4)))
          case outcome of
            Refused (Integrity (RetiredPageLive _)) → pure ()
            other → expectationFailure ("reclaiming " <> what <> " was not refused as live: " <> take 200 (show other))
        _ → expectationFailure "expected a retirement entry"
  it "refuses a supply that names a page outside the used space, however the allocator state came to say so" $ do
    let st0 = (newH smallSpec ident0, Map.empty, mkRng 15)
    (h1, ref1, g1) ← must (foldM (\s _ → churn s 30) st0 [1 .. 30 ∷ Int])
    (h2, _) ← must (reclaimAll h1)
    (h3, _, _) ← must (foldM (\s _ → churn s 30) (h2, ref1, g1) [1 .. 3 ∷ Int])
    let ArenaId a = siArena (hIdent h3)
        roots = storeRoots (hStore h3)
        hw = rHw roots
        planOn h = do
          let d = deltaFor (hStore h) True False 1 [(runKey 90000 0 5, Just (runRec 8))]
          (outcome, _, _) ← must (fillWith h (\w → planDelta (hCfg h) (hIdent h) (storeRoots (hStore h)) w Ordinary d))
          pure outcome
        refusedAsCorrupt what outcome = case outcome of
          Refused (Integrity _) → pure ()
          other → expectationFailure (what <> " was not refused: " <> take 200 (show other))
    -- a loose page that is not inside the used page space
    let looseOut = h3 {hStore = storeFromRoots (hCfg h3) (hIdent h3) roots {rLoose = PageNo hw : rLoose roots}}
    planOn looseOut >>= refusedAsCorrupt "a loose page past the used space"
    -- a valid-checksum free-extent page whose only extent reaches past the used space
    freeRoot ← maybe (expectationFailure "a free root expected" >> fail "free") pure (rFree roots)
    raw ← maybe (expectationFailure "free page" >> fail "free") pure (diskRead (hDisk h3) freeRoot)
    firstFree ← case parsePage a (siSource (hIdent h3)) raw of
      Right (RefPage _ _ _ (RefLeaf ((k0, _) : _)) _) → pure (getBe64' k0 0)
      other → expectationFailure ("a free leaf expected: " <> show other) >> fail "free"
    -- a page that is both loose and inside a free extent would be handed out twice
    let looseAndFree = h3 {hStore = storeFromRoots (hCfg h3) (hIdent h3) roots {rLoose = [PageNo firstFree]}}
    planOn looseAndFree >>= refusedAsCorrupt "a page both loose and free"
    let PageNo fr = freeRoot
        beyond = Page TreeFree 0 freeRoot (Leaf [(be64 0, be64 (hw + 1))])
    bytes ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h3) beyond)
    let tampered = h3 {hDisk = diskWrite (PageNo fr) bytes (hDisk h3), hStore = storeFromRoots (hCfg h3) (hIdent h3) roots {rLoose = []}}
    planOn tampered >>= refusedAsCorrupt "a free extent past the used space"
  it "holds at most twice the tree's height of pages when a floor read answers, a neighbour under another parent included" $ do
    -- a runs tree of at least three levels: the first leaf of a parent has its left neighbour under the previous parent, reached from the
    -- root by a path of its own; the window the read fills never holds more than the path to the target and that one
    let keys = [runKey (toInteger (i `div` 50)) (toInteger (i `mod` 50)) 10 | i ← [0 .. 11999 ∷ Int]]
        chunks [] = []
        chunks ks = let (now, later) = splitAt (3 * maxBatchUpdates - 2) ks in now : chunks later
    h ← must (foldM (\hh ks → do (hh', out) ← commitDelta hh Ordinary (deltaFor (hStore hh) True False 1 [(k, Just (runRec 20)) | k ← ks]); case out of Committed _ → Right hh'; other → Left ("history was not built: " <> show other)) (newH smallSpec ident0) (chunks keys))
    let height = heightOf h TreeRuns
    height `shouldSatisfy` (>= 3)
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h)))
    let h1 = h {hStore = s1}
        pagesHeld k = case k of
          KeyRun c lo → do
            w0 ← either (const (Left "stale")) Right (readerWindow (hStore h1) tok)
            let go w (n ∷ Int) = case readerFloorRun (hStore h1) tok w c lo of
                  Read _ → Right (windowSize w)
                  ReadNeeds p | n < 100 → case diskRead (hDisk h1) p of
                    Just bs → either (Left . show) (\x → go x (n + 1)) (windowInsert (cfgUsablePages (hCfg h1)) p bs w)
                    Nothing → Left "missing page"
                  other → Left (show other)
            go w0 0
          _ → Right 0
    sizes ← must (mapM pagesHeld (every 7 keys))
    maximum sizes `shouldSatisfy` (<= readPathPages height)
    -- the old estimate (the path and the two leaves beside the target) was too small for a neighbour under another parent
    maximum sizes `shouldSatisfy` (> height + 2)
  it "holds the pages of two landings when a ranged read starts at a floor, at a deleted separator that sends the floor across the root's children" $ do
    -- the same runs tree, with the records that begin each root child but the first deleted: their separators stay, so a floor read at one
    -- lands in a leaf of its own child (a path of the whole height) and finds its answer in the last leaf of the child before (another path
    -- of its own, sharing only the root), and the scan then starts from that key: the window holds what two landings load
    let keys = [runKey (toInteger (i `div` 50)) (toInteger (i `mod` 50)) 10 | i ← [0 .. 11999 ∷ Int]]
        chunks [] = []
        chunks ks = let (now, later) = splitAt (3 * maxBatchUpdates - 2) ks in now : chunks later
        commit hh ups = do
          (hh', out) ← commitDelta hh Ordinary (deltaFor (hStore hh) True False 1 ups)
          case out of
            Committed _ → Right hh'
            other → Left ("history was not built: " <> show other)
    built ← must (foldM (\hh ks → commit hh [(k, Just (runRec 20)) | k ← ks]) (newH smallSpec ident0) (chunks keys))
    let height = heightOf built TreeRuns
        total = cfgUsablePages (hCfg built)
        decodeAt p = either (const Nothing) Just . decodePage (hIdent built) total p =<< diskRead (hDisk built) p
    height `shouldSatisfy` (>= 3)
    rootNo ← maybe (expectationFailure "a runs root expected" >> fail "root") pure (rootOf (storeRoots (hStore built)) TreeRuns)
    separators ← case decodeAt rootNo of
      Just (Page _ _ _ (Inner es)) → pure [k | key ← drop 1 (map fst es), Just k@(KeyRun _ _) ← [decodeKey TreeRuns key]]
      other → expectationFailure ("an inner root expected: " <> show other) >> fail "root"
    length separators `shouldSatisfy` (>= 1)
    h ← must (commit built [(k, Nothing) | k ← separators])
    (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h)))
    let h1 = h {hStore = s1}
        survivors = filter (`notElem` separators) keys
        floorOf k = last (filter (`elem` survivors) (takeWhile (/= k) keys))
        answer k = do
          w0 ← either (const (Left "stale")) Right (readerWindow (hStore h1) tok)
          let go w (n ∷ Int) = case readerRange (hStore h1) tok w TreeRuns (RangeFloor k) 3 of
                Read rs → Right (map fst rs, windowSize w)
                ReadNeeds p | n < 200 → case diskRead (hDisk h1) p of
                  Just bs → either (Left . show) (\x → go x (n + 1)) (windowInsert (cfgUsablePages (hCfg h1)) p bs w)
                  Nothing → Left "missing page"
                other → Left (show other)
          go w0 0
    answers ← must (mapM (\k → fmap ((,) k) (answer k)) separators)
    -- every answer starts at the record before the deleted one, in the child before the separator's own
    forM_ answers $ \(k, (found, _)) → take 1 found `shouldBe` [floorOf k]
    -- the window holds at most the pages of two landings of a tree of this height, however the two sit
    maximum [n | (_, (_, n)) ← answers] `shouldSatisfy` (<= 2 * readLandingPages height - 1)
  it "proves a page unreachable from each root of distinct pinned versions in the pages of one landing, for a page under an interior child of the root" $ do
    -- a runs tree whose root has at least three children, three readers pinned at three versions that each replace the page under the middle
    -- child (so their roots are distinct), and the probe of that page's first key at its level against every one of those roots and the
    -- committed one: each proof alone holds no more than one landing, however many roots there are (the proof of a root is a unit of its own)
    let keys = [runKey (toInteger (i `div` 100)) (toInteger (i `mod` 100)) 10 | i ← [0 .. 59999 ∷ Int]]
        chunks [] = []
        chunks ks = let (now, later) = splitAt (3 * maxBatchUpdates - 2) ks in now : chunks later
        commit hh ups = do
          (hh', out) ← commitDelta hh Ordinary (deltaFor (hStore hh) True False 1 ups)
          case out of
            Committed _ → Right hh'
            other → Left ("history was not built: " <> show other)
    built ← must (foldM (\hh ks → commit hh [(k, Just (runRec 20)) | k ← ks]) (newH smallSpec ident0) (chunks keys))
    let height = heightOf built TreeRuns
        total = cfgUsablePages (hCfg built)
        decodeAt h p = either (const Nothing) Just . decodePage (hIdent h) total p =<< diskRead (hDisk h) p
        rootOf' h = maybe (expectationFailure "a runs root expected" >> fail "root") pure (rootOf (storeRoots (hStore h)) TreeRuns)
    height `shouldSatisfy` (>= 3)
    root0 ← rootOf' built
    (probed, child) ← case decodeAt built root0 of
      Just (Page _ _ _ (Inner es)) | length es >= 3 → case es !! (length es `div` 2) of
        (k, Child c _) → pure (k, c)
      other → expectationFailure ("a root of three children or more expected: " <> show (fmap (\(Page _ l _ b) → (l, case b of Inner es → length es; _ → 0)) other)) >> fail "root"
    probeKey ← maybe (expectationFailure "a run key expected" >> fail "key") pure (decodeKey TreeRuns probed)
    -- three versions, a reader pinned at each, each replacing the pages under that child by updating the key it starts at
    let pinnedAfter h key value = do
          h1 ← must (commit h [(key, Just (runRec value))])
          (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h1)))
          pure (h1 {hStore = s1}, tok)
    (tok0, s0) ← must (either (Left . show) Right (acquireReader (hStore built)))
    (hA, tokA) ← pinnedAfter built {hStore = s0} probeKey 21
    (hB, tokB) ← pinnedAfter hA probeKey 22
    (hC, tokC) ← pinnedAfter hB probeKey 23
    roots ← mapM rootOf' [built, hA, hB, hC]
    length (nub roots) `shouldBe` 4
    let probeAt h (tok, root) = do
          w0 ← either (const (Left "stale")) Right (readerWindow (hStore h) tok)
          let go w (n ∷ Int) = case runM (livePageAt TreeRuns (Just (Disk root)) probed 1) (newEdit 0 w) of
                Right (found, _) → Right (found, windowSize w)
                Left (Need p) | n < 400 → case diskRead (hDisk h) p of
                  Just bs → either (Left . show) (\x → go x (n + 1)) (windowInsert (cfgUsablePages (hCfg h)) p bs w)
                  Nothing → Left "missing page"
                Left other → Left (show other)
          go w0 0
    answers ← must (mapM (probeAt hC) (zip [tok0, tokA, tokB, tokC] roots))
    -- the oldest root still holds the page under the middle child; the newer roots hold others there
    map (== Just child) (map fst answers) `shouldBe` [True, False, False, False]
    -- each root has a page there, a different one
    length (nub (map fst answers)) `shouldBe` 4
    maximum (map snd answers) `shouldSatisfy` (<= readLandingPages height)
  it "plans an edit's absent-key lookups through a window of the edit and one landing, carrying a memo of each neighbouring chain through a checkpoint, and plans what a wide window plans" $ do
    -- inserts of absent keys into leaves far apart in a tree of three levels: each lookup concludes an absence from the leaf's neighbours,
    -- whose pages no window of the edit's paths and ONE landing can keep for all of them; a checkpoint hands on the memos, and the next window
    -- reads no chain a memo stands for
    let keys = [runKey (toInteger (i `div` 50)) (toInteger (i `mod` 50)) 10 | i ← [0 .. 11999 ∷ Int]]
        chunks [] = []
        chunks ks = let (now, later) = splitAt (3 * maxBatchUpdates - 2) ks in now : chunks later
        commit hh ups = do
          (hh', out) ← commitDelta hh Ordinary (deltaFor (hStore hh) True False 1 ups)
          case out of
            Committed _ → Right hh'
            other → Left ("history was not built: " <> show other)
    h ← must (foldM (\hh ks → commit hh [(k, Just (runRec 20)) | k ← ks]) (newH smallSpec ident0) (chunks keys))
    let hf = max 1 (heightOf h TreeFree)
        hrec = heightOf h TreeRuns
        inserts = [(runKey (toInteger c) 60 10, Just (runRec 20)) | c ← [3, 40, 77, 120, 160, 200 ∷ Int]]
        delta = deltaFor (hStore h) True False 1 inserts
        formula = editWindowPages (length inserts) (max 0 (heightOf h TreeRetire - 1)) hf hrec 0
        bounded n = standardBounds {bdWindowPages = n, bdWindowBytes = n * windowPageBytes}
        planWith bounds = fillCounting h (storeWindow (hStore h)) (\w → planDeltaPinned bounds (hCfg h) (hIdent h) (storeRoots (hStore h)) (pinnedRoots (hStore h)) w Ordinary delta)
        -- the smallest window the plan succeeds in (the formula is the promise: this fixture needs far less), by descent from it
        smallest n = case planWith (bounded (n - 1)) of
          Right (Planned _, _, _, _) | n > 2 → smallest (n - 1)
          _ → n
        lim = smallest formula
        tight = bounded lim
    hrec `shouldSatisfy` (>= 3)
    (wide, wideWindow, _, cpsWide) ← must (planWith standardBounds)
    (narrow, _, _, cps) ← must (planWith tight)
    cpsWide `shouldBe` 0
    case (wide, narrow) of
      (Planned a, Planned b) → do
        -- a plan that ends in one window, with no checkpoint, is charged the facts it holds: the proof that each page it retires is absent from
        -- the index (one for each committed page it replaced) and the memos of its lookups, beside the pages of its window
        (ramDecodedCopies (mRam (plMeasure a)) >= windowBytes wideWindow + windowProbesBytes wideWindow + factBytes * mReplacedRecord (plMeasure a), mReplacedRecord (plMeasure a) > 0) `shouldBe` (True, True)
        -- the same plan, through checkpoints, in a window that held no more than its bound
        plPages b `shouldBe` plPages a
        mPagesWritten (plMeasure b) `shouldBe` mPagesWritten (plMeasure a)
        (mWindowPages (plMeasure b) <= lim) `shouldBe` True
        cps `shouldSatisfy` (> 0)
      other → expectationFailure ("the plans were not both planned: " <> take 300 (show other))
  it "refuses more readers than the bound and a token of another store" $ do
    let h = newH smallSpec ident0
        other = newH smallSpec (identOf 2 7)
    (toks, s1) ← must (foldM (\(ts, s) _ → either (Left . show) (\(t, s') → Right (t : ts, s')) (acquireReader s)) ([], hStore h) [1 .. maxReaders])
    length toks `shouldBe` maxReaders
    either Just (const Nothing) (acquireReader s1) `shouldBe` Just (TooManyReaders maxReaders)
    case toks of
      [] → expectationFailure "tokens expected"
      (t : _) → do
        fst (releaseReader t (hStore other)) `shouldBe` Unknown
        readerVersion (hStore other) t `shouldBe` Left StaleReader
        (usReaders (usage s1), usPinnedVersions (usage s1)) `shouldBe` (maxReaders, 1)
        let (x, s2) = releaseReader t s1
            (y, _) = releaseReader t s2
        (x, y) `shouldBe` (Applied, Duplicate)
        when (controlBytes s1 <= controlBytes s2) $ expectationFailure "a released reader should lower the control bytes"
  where
    every n xs = [x | (i, x) ← zip [0 ∷ Int ..] xs, i `mod` n == 0]
    sortOn' ∷ Ord b ⇒ [b] → [b]
    sortOn' = Map.keys . Map.fromList . map (\x → (x, ()))
    hiOf ∷ Record → Int64
    hiOf (RecRun hi) = hi
    hiOf _ = 0
