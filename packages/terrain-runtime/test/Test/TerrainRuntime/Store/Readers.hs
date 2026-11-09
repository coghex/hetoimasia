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
import qualified Data.Map.Strict as Map
import Data.Int (Int64)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Page (..), encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
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
        fmap fst r `shouldBe` Just lo
        fmap snd r `shouldBe` Just (hiOf v)
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
  it "refuses to free a page that is already free, however its retirement entry came to name it" $ do
    let st0 = (newH smallSpec ident0, Map.empty, mkRng 15)
    (h1, ref1, g1) ← must (foldM (\s _ → churn s 30) st0 [1 .. 30 ∷ Int])
    (h2, _) ← must (reclaimAll h1)
    (h3, _, _) ← must (foldM (\s _ → churn s 30) (h2, ref1, g1) [1 .. 3 ∷ Int])
    let ArenaId a = siArena (hIdent h3)
        o = ownership a (siSource (hIdent h3)) (hStore h3) (diskRead (hDisk h3))
        entries = sortOn' [(getBe64' k 0, (getBe64' v 0, getLe16' v 8)) | (TreeRetire, ls) ← owLeaves o, (k, v) ← ls]
        freeStarts = [getBe64' k 0 | (TreeFree, ls) ← owLeaves o, (k, _) ← ls]
    -- the highest free extent is not among the lowest pages the plan itself takes
    case (entries, reverse freeStarts) of
      ((_, (lp, count)) : _, fs : _) → do
        listPage ← maybe (expectationFailure "list page" >> fail "list") pure (diskRead (hDisk h3) (PageNo lp))
        ps ← case parsePage a (siSource (hIdent h3)) listPage of
          Right (RefPage _ _ _ (RefList xs) _) → pure xs
          other → expectationFailure (show other) >> fail "list"
        length ps `shouldBe` fromIntegral count
        -- the entry now also names a page the allocator already holds free
        let tampered = sortOn' (fs : drop 1 ps)
        bytes ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h3) (Page TreeRetire 0 (PageNo lp) (List (map PageNo tampered))))
        let h4 = h3 {hDisk = diskWrite (PageNo lp) bytes (hDisk h3)}
        (outcome, _, _) ← must (fillWith h4 (planMaintenance (hStore h4)))
        case outcome of
          Refused (Integrity (DoubleFree _)) → pure ()
          other → expectationFailure ("a double free was not refused: " <> take 200 (show other))
      _ → expectationFailure "expected a retirement entry and a free extent"
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
    sortOn' ∷ Ord b ⇒ [b] → [b]
    sortOn' = Map.keys . Map.fromList . map (\x → (x, ()))
    hiOf ∷ Record → Int64
    hiOf (RecRun hi) = hi
    hiOf _ = 0
