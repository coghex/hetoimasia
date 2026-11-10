-- | Page ownership against records that pass their checksum and lie.
--
-- The store decides which pages are live, free, pinned or reclaimable from records
-- it wrote itself: the root set (tree roots, the used page space, the loose list), the
-- free extents, the retirement entries and their list pages, and the child references
-- inside the trees. Every one of them can be re-encoded with a valid checksum and name
-- the wrong page. Each test below forges one such record on the disk (or in the root
-- set) and requires a typed refusal /before/ any page is written, so that no page a
-- committed tree or a pinned reader can still reach is ever overwritten or freed.
--
-- == The sites
--
-- Each site is a place the store trusts a persisted record about which pages are live,
-- free, pinned or reclaimable. The test that forges it is named; the proof that stops
-- it is in "Hetoimasia.Terrain.Runtime.Store.Internal.Plan" ('unreachable') and
-- "Hetoimasia.Terrain.Runtime.Store.Internal.Tree" ('load', 'livePageAt').
--
-- * the loose list of the root set: used by the loose-page tests;
-- * free extents: used by the free-extent tests;
-- * retirement entries (version, list page, counts) and their list pages: the
--   retirement tests;
-- * the tree roots and every child reference: the reference tests;
-- * the readers' pinned roots and used space: the pinned-reader tests.
module Test.TerrainRuntime.Store.Ownership (spec) where

import Control.Monad (foldM, forM, forM_, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Child (..), Page (..), encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (be64)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (windowInsert)
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

-- | A store with retired pages, free extents and loose pages: history, a full
-- reclamation, then a few more commits.
fixture ∷ IO (H, Map.Map RecordKey Record, Rng)
fixture = fixtureWith smallSpec

-- | The same over a given specification.
fixtureWith ∷ StoreSpec → IO (H, Map.Map RecordKey Record, Rng)
fixtureWith storeSpec = do
  let st0 = (newH storeSpec ident0, Map.empty, mkRng 15)
  (h1, ref1, g1) ← must (foldM (\s _ → churn s 30) st0 [1 .. 30 ∷ Int])
  (h2, _) ← must (reclaimAll h1)
  must (foldM (\s _ → churn s 30) (h2, ref1, g1) [1 .. 3 ∷ Int])

arenaOf ∷ H → Word64
arenaOf h = let ArenaId a = siArena (hIdent h) in a

sourceOf ∷ H → Word64
sourceOf = siSource . hIdent

-- | The one edit every site test plans: a single new run in an untouched column.
oneEdit ∷ H → Delta
oneEdit h = deltaFor (hStore h) True False 1 [(runKey 90000 0 5, Just (runRec 8))]

-- | Plan the edit through a window filled from the disk, with the readers' pins.
planOn ∷ H → IO Planned
planOn h = must (fillPlan h (oneEdit h) Ordinary)

-- | The same plan as a store that knows no pinned reader.
planUnpinned ∷ H → IO Planned
planUnpinned h = do
  (p, _, _) ← must (fillWith h (\w → planDeltaPinned standardBounds (hCfg h) (hIdent h) (storeRoots (hStore h)) [] w Ordinary (oneEdit h)))
  pure p

page ∷ H → PageNo → IO ByteString
page h p = maybe (expectationFailure ("page " <> show p <> " is not on the disk") >> fail "page") pure (diskRead (hDisk h) p)

parsed ∷ H → PageNo → IO RefPage
parsed h p = do
  bs ← page h p
  either (\e → expectationFailure (show e) >> fail "parse") pure (parsePage (arenaOf h) (sourceOf h) bs)

-- | Overwrite a page with a re-encoded body: a forged page whose checksum is valid.
--
-- A forgery of the ownership records is a *consistent* one: the checksums above the page (its
-- parent's entry, and so on up, and the root record when it is a root) are made to agree with it,
-- as a forger who wants the page read would make them (a forgery that leaves them is refused where the
-- page is loaded, which "Test.TerrainRuntime.Store.Fuzz" and "Test.TerrainRuntime.Store.FuzzTrees"
-- show); 'forgeLoose' leaves the chain as it is.
forge ∷ H → PageNo → Page → IO H
forge h p pg = do
  h1 ← forgeLoose h p pg
  pure (resignChain h1 p)

forgeLoose ∷ H → PageNo → Page → IO H
forgeLoose h p pg = do
  bs ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h) pg)
  pure h {hDisk = diskWrite p bs (hDisk h)}

-- | The same store over other root fields, the live-page counter recomputed so that the
-- counters still agree with each other: a test that forges a page-ownership record is not a
-- test of the counters.
withRoots ∷ H → (Roots → Roots) → H
withRoots h f = withRootsRaw h (agree . f)
  where
    agree r = r {rLivePages = fromInteger (max 0 (toInteger (rHw r) - toInteger (rRetiredPages r) - toInteger (rFreePages r) - toInteger (length (rLoose r))))}

-- | The same store over other root fields, exactly as given.
withRootsRaw ∷ H → (Roots → Roots) → H
withRootsRaw h f = h {hStore = modifyRoots f (hStore h)}

refusedLive ∷ String → Word64 → Planned → Expectation
refusedLive what v out = case out of
  Refused (Integrity (SuppliedPageLive (PageNo q))) | q == v → pure ()
  other → expectationFailure (what <> ": expected the supplied page " <> show v <> " to be refused as live, got " <> take 300 (show other))

refusedCorrupt ∷ String → Planned → Expectation
refusedCorrupt what out = case out of
  Refused (Integrity _) → pure ()
  other → expectationFailure (what <> " was not refused: " <> take 300 (show other))

-- | Every page the committed trees reach, by the independent traversal.
livePages ∷ H → Set.Set Word64
livePages h = Set.fromList (concatMap (twPages . walkOf) [TreeRuns, TreeLinks, TreeTodo, TreeFree, TreeRetire])
  where
    walkOf t = walkTree (arenaOf h) (sourceOf h) (diskRead (hDisk h)) ((\(PageNo p) → p) <$> committedRoot (hStore h) t)

-- | Every retired page with its entry's version, by the independent traversal of the
-- retirement lists.
retiredPagesOf ∷ H → IO [(Word64, [Word64])]
retiredPagesOf h = do
  let walk = walkTree (arenaOf h) (sourceOf h) (diskRead (hDisk h)) ((\(PageNo p) → p) <$> rRetire (storeRoots (hStore h)))
  entries ← pure [(getBe64' k 0, getBe64' v 0) | (k, v) ← twLeaves walk, BS.length k == 8]
  forM entries $ \(ver, lp) → do
    pg ← parsed h (PageNo lp)
    case rpBody pg of
      RefList _ xs → pure (ver, xs)
      other → expectationFailure (show other) >> fail "list"

-- | The live pages worth forging a supply to name: a root of every tree, a page below a
-- root, a leaf and a retirement list page.
victims ∷ H → IO [(String, Word64)]
victims h = do
  let roots = storeRoots (hStore h)
      num (PageNo n) = n
      named what mp = [(what, num p) | Just p ← [mp]]
  runsRoot ← maybe (expectationFailure "a runs root expected" >> fail "runs") pure (rRuns roots)
  runsPage ← parsed h runsRoot
  let (child, grandchild) = case rpBody runsPage of
        RefInner ((_, c, _) : _) → (Just c, Nothing)
        _ → (Nothing, Nothing)
  leafBelow ← case child of
    Just c → do
      pg ← parsed h (PageNo c)
      pure (case rpBody pg of RefInner ((_, g, _) : _) → Just g; _ → Nothing)
    Nothing → pure grandchild
  (_, _, (_, firstValue)) ← firstRetire h
  let lists = [getBe64' firstValue 0]
  pure $
    named "the runs root" (rRuns roots)
      <> named "the links root" (rLinks roots)
      <> named "the todo root" (rTodo roots)
      <> named "the free tree's root" (rFree roots)
      <> named "the retirement tree's root" (rRetire roots)
      <> [("a runs page below the root", c) | Just c ← [child]]
      <> [("a runs page two levels below the root", g) | Just g ← [leafBelow]]
      <> [("a retirement list page", lp) | lp ← lists]

-- | The free tree's root as one extent of one page: the forged allocator record that
-- offers exactly that page to the next plan.
offerOnly ∷ H → Word64 → IO H
offerOnly h v = do
  freeRoot ← maybe (expectationFailure "a free root expected" >> fail "free") pure (rFree (storeRoots (hStore h)))
  pg ← parsed h freeRoot
  case rpBody pg of
    RefLeaf _ → pure ()
    other → expectationFailure ("a free leaf expected: " <> take 100 (show other)) >> fail "free"
  h' ← forge h freeRoot (Page TreeFree 0 freeRoot (Leaf [(be64 v, be64 1)]))
  pure (withRoots h' (\r → r {rLoose = [], rFreePages = 1}))

-- | The retirement tree's leaf holding a key, found by descending from the root by the
-- independent reference parser.
retireLeafFor ∷ H → ByteString → IO (PageNo, [(ByteString, ByteString)])
retireLeafFor h key = do
  root ← maybe (expectationFailure "a retirement root expected" >> fail "retire") pure (rRetire (storeRoots (hStore h)))
  let go p = do
        pg ← parsed h p
        case rpBody pg of
          RefLeaf es → pure (p, es)
          RefInner cs → case reverse (takeWhile (\(k, _, _) → k <= key) cs) of
            ((_, c, _) : _) → go (PageNo c)
            [] → case cs of
              ((_, c, _) : _) → go (PageNo c)
              [] → expectationFailure "empty inner page" >> fail "inner"
          RefList _ _ → expectationFailure "a list in the tree" >> fail "list"
  go root

-- | The leaf of the retirement tree that holds its oldest entry: the leaf, everything in it, and
-- the entry (the entries sort before the index of retired pages).
firstRetire ∷ H → IO (PageNo, [(ByteString, ByteString)], (ByteString, ByteString))
firstRetire h = do
  (leaf, es) ← retireLeafFor h (be64 0)
  case [x | x@(k, _) ← es, BS.length k == 8] of
    (x : _) → pure (leaf, es, x)
    [] → expectationFailure "a retirement entry expected" >> fail "retire"

-- | Forge the retirement tree so that it no longer records a page as retired.
dropIndex ∷ H → Word64 → IO H
dropIndex h v = do
  (leaf, es) ← retireLeafFor h (BS.cons 0xFF (be64 v))
  forge h leaf (Page TreeRetire 0 leaf (Leaf [(k, x) | (k, x) ← es, k /= BS.cons 0xFF (be64 v)]))

spec ∷ Spec
spec = describe "page ownership against forged records with valid checksums" $ do
  describe "free extents (the allocator tree)" $ do
    it "refuses a free extent that offers a live page, whichever live page it is, before writing anything" $ do
      (h, _, _) ← fixture
      vs ← victims h
      length vs `shouldSatisfy` (>= 6)
      forM_ vs $ \(what, v) → do
        forged ← offerOnly h v
        out ← planOn forged
        refusedLive ("a free extent offering " <> what) v out
        -- a maintenance transaction writes bookkeeping pages from the same supply
        (maintenance, _, _) ← must (fillWith forged (planMaintenance (hStore forged)))
        refusedLive ("a free extent offering " <> what <> ", to maintenance") v maintenance
    it "refuses a free extent that offers a page only a pinned reader reaches, by the retirement index and, with the index forged away, by the pinned tree" $ do
      (h0, ref0, g0) ← fixture
      (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h0)))
      let h1 = h0 {hStore = s1}
      (h2, _, _) ← must (foldM (\s _ → churn s 30) (h1, ref0, g0) [1 .. 6 ∷ Int])
      pins ← maybe (expectationFailure "stale token" >> fail "pins") pure (either (const Nothing) Just (pinsOf (hStore h2) tok))
      let walkPinned = walkTree (arenaOf h2) (sourceOf h2) (diskRead (hDisk h2)) ((\(PageNo p) → p) <$> pinRuns pins)
          onlyPinned = [p | p ← twPages walkPinned, not (Set.member p (livePages h2))]
      onlyPinned `shouldSatisfy` (not . null)
      forM_ (take 3 onlyPinned) $ \v → do
        forged ← offerOnly h2 v
        -- the pinned reader's tree reaches it
        refusedLive "a free extent offering a pinned page" v =<< planOn forged
        -- a store that knows no reader still knows it is retired: the retirement index owns it
        retired ← planUnpinned forged
        case retired of
          Refused (Integrity (SuppliedPageRetired (PageNo q) _)) → q `shouldBe` v
          other → expectationFailure ("a retired page offered by the allocator was not refused as retired: " <> take 200 (show other))
        -- with its index record forged away the only thing left that knows is the pinned tree
        unindexed ← dropIndex forged v
        refusedLive "a free extent offering a pinned page, its retirement index record dropped" v =<< planOn unindexed
        -- and a store that also knows no pinned reader would overwrite it
        unpinned ← planUnpinned unindexed
        case unpinned of
          Planned plan → map fst (plPages plan) `shouldSatisfy` (PageNo v `elem`)
          other → expectationFailure ("the unpinned plan should accept the forged extent: " <> take 200 (show other))
    it "refuses a free extent that lies wholly past the used space, where no tail page and no probe would meet it" $ do
      (h, _, _) ← fixture
      let hw = rHw (storeRoots (hStore h))
      forged ← offerOnly h (hw + 100)
      refusedCorrupt "a free extent past the used space" =<< planOn forged
    it "overwrites a free page that holds garbage or nothing a store could read, instead of refusing it" $ do
      (h, _, _) ← fixture
      freeRoot ← maybe (expectationFailure "free root" >> fail "free") pure (rFree (storeRoots (hStore h)))
      pg ← parsed h freeRoot
      firstFree ← case rpBody pg of
        RefLeaf ((k, _) : _) → pure (getBe64' k 0)
        other → expectationFailure (show other) >> fail "free"
      forged ← offerOnly h firstFree
      let garbage = forged {hDisk = diskWrite (PageNo firstFree) (BS.replicate pageSize 0x5a) (hDisk forged)}
      out ← planOn garbage
      case out of
        Planned plan → map fst (plPages plan) `shouldSatisfy` (PageNo firstFree `elem`)
        other → expectationFailure ("a garbage page is not reachable and should be overwritten: " <> take 200 (show other))
  describe "the loose list (the root set)" $ do
    it "refuses a loose page that is live, whichever live page it is" $ do
      (h, _, _) ← fixture
      vs ← victims h
      forM_ vs $ \(what, v) → do
        let forged = withRoots h (\r → r {rLoose = PageNo v : rLoose r})
        refusedLive ("a loose page naming " <> what) v =<< planOn forged
    it "refuses a loose list that holds a page twice among the pages a plan takes" $ do
      (h, _, _) ← fixture
      freeRoot ← maybe (expectationFailure "free root" >> fail "free") pure (rFree (storeRoots (hStore h)))
      pg ← parsed h freeRoot
      let dead = case rpBody pg of
            RefLeaf es → concat [[s .. s + l - 1] | (k, v) ← es, let s = getBe64' k 0, let l = getBe64' v 0]
            _ → []
      length dead `shouldSatisfy` (> 10)
      -- the first loose page listed again straight after itself
      let loose = map PageNo (take 3 dead) <> [PageNo (head' dead)] <> map PageNo (take 50 (drop 3 dead))
      refusedCorrupt "a loose page listed twice" =<< planOn (withRoots h (\r → r {rLoose = loose}))
    it "proves every loose page maintenance hands to the allocator tree, at the first, the middle and the last place of the spill" $ do
      (h, _, _) ← fixture
      let roots = storeRoots (hStore h)
          grow = looseSoftCap + maxSpillPages - length (rLoose roots)
          fresh = [PageNo (rHw roots + fromIntegral i) | i ← [0 .. grow - 1]]
          big = withRoots h (\r → r {rHw = rHw r + fromIntegral grow, rLoose = rLoose r ++ fresh})
          looseBig = rLoose (storeRoots (hStore big))
          start = length looseBig - maxSpillPages
          maintain hh = (\(m, _, _) → m) <$> must (fillWith hh (planMaintenance (hStore hh)))
          at i v = withRoots big (\r → r {rLoose = take i looseBig ++ [PageNo v] ++ drop (i + 1) looseBig})
      grow `shouldSatisfy` (> 0)
      must (checkH big)
      -- the unforged list: maintenance plans, the eight pages leave the loose list for the free tree, the checker agrees
      m0 ← maintain big
      case m0 of
        Planned plan → do
          h1 ← must (commitPlan big plan)
          must (checkH h1)
          (length (rLoose (storeRoots (hStore h1))) < length looseBig) `shouldBe` True
        other → expectationFailure ("a loose list past its soft cap was not maintained: " <> take 200 (show other))
      -- every live page, forged into each place of the spill: refused as live, never published as free
      vs ← victims h
      forM_ [(what, v, pos) | (what, v) ← vs, pos ← [0, 3, maxSpillPages - 1]] $ \(what, v, pos) → do
        out ← maintain (at (start + pos) v)
        case out of
          Refused (Integrity (SuppliedPageLive (PageNo q))) | q == v → pure ()
          other → expectationFailure ("a spilled page naming " <> what <> " at place " <> show pos <> " was not refused as live: " <> take 200 (show other))
      -- a page past the used space, a page the supply takes again, a retired page, a free extent's page
      let lastIx = length looseBig - 1
      beyond ← maintain (at lastIx (rHw (storeRoots (hStore big)) + 5))
      case beyond of
        Refused (Integrity (SuppliedPageLive _)) → pure ()
        other → expectationFailure ("a spilled page past the used space was not refused: " <> take 200 (show other))
      let PageNo firstLoose = head' looseBig
      again ← maintain (at lastIx firstLoose)
      case again of
        Refused (Integrity (SuppliedPageDoubleOwned _)) → pure ()
        other → expectationFailure ("a spilled page the supply also takes was not refused: " <> take 200 (show other))
      retired ← retiredPagesOf h
      -- a page of the newest entry, which the oldest entry's chunk does not free
      case reverse (concatMap snd retired) of
        (rp : _) → do
          out ← maintain (at lastIx rp)
          case out of
            Refused (Integrity (SuppliedPageRetired (PageNo q) _)) | q == rp → pure ()
            Refused (Integrity (SuppliedPageLive (PageNo q))) | q == rp → pure ()
            other → expectationFailure ("a spilled page a retirement entry owns was not refused: " <> take 200 (show other))
        [] → expectationFailure "no retired page in the fixture"
      freeRoot ← maybe (expectationFailure "free root" >> fail "free") pure (rFree roots)
      pg ← parsed h freeRoot
      let freePg = case rpBody pg of
            RefLeaf ((k, _) : _) → getBe64' k 0
            _ → 0
      freeOut ← maintain (at lastIx freePg)
      case freeOut of
        Refused (Integrity (DoubleFree (PageNo q))) | q == freePg → pure ()
        other → expectationFailure ("a spilled page that is a free extent was not refused: " <> take 200 (show other))
    it "refuses a loose page that is also a free extent, even when the extent is not one the plan takes" $ do
      (h, _, _) ← fixture
      freeRoot ← maybe (expectationFailure "free root" >> fail "free") pure (rFree (storeRoots (hStore h)))
      pg ← parsed h freeRoot
      let extents = case rpBody pg of
            RefLeaf es → [(getBe64' k 0, getBe64' v 0) | (k, v) ← es]
            _ → []
      length extents `shouldSatisfy` (> 1)
      -- a page of the last (highest) extent, which the lowest-first supply does not reach
      let (s, _) = last extents
      out ← planOn (withRoots h (\r → r {rLoose = [PageNo s]}))
      case out of
        Refused (Integrity (SuppliedPageDoubleOwned (PageNo q))) → q `shouldBe` s
        other → expectationFailure ("a loose page that is also free was not refused: " <> take 200 (show other))
  describe "retirement entries and their list pages" $ do
    it "refuses a retirement entry whose version was lowered past a pinned reader, with or without its list's stamp" $ do
      (h0, ref0, g0) ← fixture
      (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h0)))
      let pinned = storeVersion s1
      (hA, _) ← must (reclaimAll (h0 {hStore = s1}))
      (h2, ref2, _) ← must (foldM (\s _ → churn s 30) (hA, ref0, g0) [1 .. 4 ∷ Int])
      (leaf, es, (k0, v0)) ← firstRetire h2
      let (lp, cnt, e) = (getBe64' v0 0, getLe16' v0 8, getBe64' k0 0)
      -- the oldest entry still waiting is newer than the reader's version (the reclamation that ran first only
      -- consumed entries it could, and its own commits changed no record page)
      e `shouldSatisfy` (> pinned)
      -- the entry now claims the version the reader pins: nothing newer holds its pages
      let lowerEntry = [(if k == k0 then be64 pinned else k, x) | (k, x) ← es]
      h3 ← forge h2 leaf (Page TreeRetire 0 leaf (Leaf lowerEntry))
      -- the list still carries the true version: the entry and the list contradict each other
      (stampMismatch, _, _) ← must (fillWith h3 (planMaintenance (hStore h3)))
      stampMismatch `shouldBe'` Refused (Integrity MalformedRetirement)
      -- the list is forged to agree with the lowered entry: the retired-page index still says the
      -- pages belong to the true version
      lpage ← parsed h3 (PageNo lp)
      ps ← case rpBody lpage of
        RefList _ xs → pure xs
        other → expectationFailure (show other) >> fail "list"
      length ps `shouldBe` fromIntegral cnt
      h4 ← forge h3 (PageNo lp) (Page TreeRetire 0 (PageNo lp) (List pinned (map PageNo ps)))
      -- the pinned reader's tree reaches the pages the entry now says are free to reclaim
      (pinnedRefusal, _, _) ← must (fillWith h4 (planMaintenance (hStore h4)))
      case pinnedRefusal of
        Refused (Integrity (RetiredPageLive (PageNo q))) → ps `shouldSatisfy` (q `elem`)
        other → expectationFailure ("a lowered version past a pinned reader was not refused as live: " <> take 300 (show other))
      -- without the reader's roots the retired-page index still says the pages belong to the true version
      (indexed, _, _) ← must (fillWith h4 (planReclaimWith standardBounds (hCfg h4) (hIdent h4) (storeRoots (hStore h4)) (Just pinned)))
      case indexed of
        Refused (Integrity (RetiredIndexMismatch (PageNo q))) → ps `shouldSatisfy` (q `elem`)
        other → expectationFailure ("a lowered version contradicting the retired-page index was not refused: " <> take 300 (show other))
      -- the index forged to agree as well: only the reader's tree can say
      let lowerIndex = [(k, if BS.length k == 9 && getBe64' x 0 == e then be64 pinned else x) | (k, x) ← lowerEntry]
      h5 ← forge h4 leaf (Page TreeRetire 0 leaf (Leaf lowerIndex))
      (agreed, _, _) ← must (fillWith h5 (planMaintenance (hStore h5)))
      case agreed of
        Refused (Integrity (RetiredPageLive (PageNo q))) → ps `shouldSatisfy` (q `elem`)
        other → expectationFailure ("a lowered version past a pinned reader, index forged too, was not refused as live: " <> take 300 (show other))
      -- the committed trees alone cannot tell: without the reader's roots the entry is accepted
      (accepted, _, _) ← must (fillWith h5 (planReclaimWith standardBounds (hCfg h5) (hIdent h5) (storeRoots (hStore h5)) (Just pinned)))
      case accepted of
        Planned _ → pure ()
        other → expectationFailure ("the committed-only check should accept the forged entry: " <> take 200 (show other))
      -- and the reader still answers from its version, with its pages in place
      seen ← must (readAll h5 tok)
      Map.fromList seen `shouldBe` ref0
      when (ref2 == ref0) $ expectationFailure "the later commits changed nothing"
    it "refuses to overwrite a retired page the allocator offers while its retirement entry still owns it, with no reader pinned" $ do
      (h, _, _) ← fixture
      retired ← retiredPagesOf h
      length retired `shouldSatisfy` (> 1)
      -- a page of the oldest entry (the one maintenance would reclaim next) and of the newest
      forM_ [("the newest entry", last retired), ("the oldest entry", head' retired)] $ \(what, (ver, pages)) → do
        v ← case pages of
          (x : _) → pure x
          [] → expectationFailure "an empty list" >> fail "list"
        forged ← offerOnly h v
        out ← planOn forged
        case out of
          Refused (Integrity (SuppliedPageRetired (PageNo q) ev)) → (q, ev) `shouldBe` (v, ver)
          other → expectationFailure ("a retired page of " <> what <> " offered by the allocator was not refused: " <> take 200 (show other))
      -- maintenance writes bookkeeping pages from the same supply: offer it a page of the newest entry
      case last retired of
        (ver, v : _) → do
          forged ← offerOnly h v
          (m, _, _) ← must (fillWith forged (planMaintenance (hStore forged)))
          case m of
            Refused (Integrity (SuppliedPageRetired (PageNo q) ev)) → (q, ev) `shouldBe` (v, ver)
            other → expectationFailure ("maintenance was offered a retired page: " <> take 200 (show other))
        _ → expectationFailure "an entry with pages expected"
    it "refuses a loose page that a retirement entry still owns" $ do
      (h, _, _) ← fixture
      retired ← retiredPagesOf h
      case last retired of
        (ver, v : _) → do
          out ← planOn (withRoots h (\r → r {rLoose = PageNo v : rLoose r}))
          case out of
            Refused (Integrity (SuppliedPageRetired (PageNo q) ev)) → (q, ev) `shouldBe` (v, ver)
            other → expectationFailure ("a retired page in the loose list was not refused: " <> take 200 (show other))
        _ → expectationFailure "an entry with pages expected"
    it "refuses a retirement list that names a page the retired-page index holds under another entry" $ do
      (h, _, _) ← fixture
      (_, _, (k0, v0)) ← firstRetire h
      let (lp, cnt, e) = (getBe64' v0 0, getLe16' v0 8, getBe64' k0 0)
      lpage ← parsed h (PageNo lp)
      ps ← case rpBody lpage of
        RefList _ xs → pure xs
        other → expectationFailure (show other) >> fail "list"
      length ps `shouldBe` fromIntegral cnt
      retired ← retiredPagesOf h
      -- a page another, newer entry retired: indexed, but under that entry's version
      dead ← case last retired of
        (ver, v : _) | ver /= e → pure v
        _ → expectationFailure "a newer entry with pages expected" >> fail "retired"
      forged ← forge h (PageNo lp) (Page TreeRetire 0 (PageNo lp) (List e (map PageNo (sortUnique (dead : drop 1 ps)))))
      (out, _, _) ← must (fillWith forged (planMaintenance (hStore forged)))
      case out of
        Refused (Integrity (RetiredIndexMismatch (PageNo q))) → q `shouldBe` dead
        other → expectationFailure ("a list naming an unindexed page was not refused: " <> take 200 (show other))
    it "refuses to retire a page the retired-page index already holds" $ do
      (h, _, _) ← fixture
      roots ← pure (storeRoots (hStore h))
      runsRoot ← maybe (expectationFailure "runs root" >> fail "runs") pure (rRuns roots)
      let PageNo rr = runsRoot
      (leaf, es) ← retireLeafFor h (BS.cons 0xFF (be64 rr))
      -- the live runs root is also indexed as retired under some version: the next commit replaces it
      let withIndex = Map.toAscList (Map.insert (BS.cons 0xFF (be64 rr)) (be64 1) (Map.fromList es))
      forged ← forge h leaf (Page TreeRetire 0 leaf (Leaf withIndex))
      out ← planOn forged
      case out of
        Refused (Integrity (DoubleFree (PageNo q))) → q `shouldBe` rr
        other → expectationFailure ("a page retired twice was not refused: " <> take 200 (show other))
    it "refuses an ordinary plan that would take the retired backlog past its bound, and never maintenance" $ do
      -- a store large enough that the grown used space still leaves the free pool the plan needs
      (h, _, _) ← fixtureWith (specOf (512 * 1024 * 1024) Nothing)
      -- the backlog full, the used space grown by what the extra retired pages count, so the counters still agree
      let full = withRoots h (\r → r {rHw = rHw r + fromIntegral maxRetiredPages - rRetiredPages r, rRetiredPages = fromIntegral maxRetiredPages})
      out ← planOn full
      case out of
        Refused (Capacity (RetirementBacklog _ _)) → pure ()
        other → expectationFailure ("a full backlog was not refused: " <> take 200 (show other))
      (m, _, _) ← must (fillWith full (planMaintenance (hStore full)))
      case m of
        Refused (Capacity (RetirementBacklog _ _)) → expectationFailure "maintenance must never be refused for the backlog it lowers"
        _ → pure ()
      -- one page more than the bound is no state a plan writes: the next plan and the next maintenance transaction refuse it as
      -- corrupt, so the retirement tree (and the window its index edit needs) is bounded by what the store checks
      let over = withRoots h (\r → r {rHw = rHw r + fromIntegral maxRetiredPages + 1 - rRetiredPages r, rRetiredPages = fromIntegral maxRetiredPages + 1})
      outOver ← planOn over
      outOver `shouldBe` Refused (Integrity CorruptCounters)
      (mOver, _, _) ← must (fillWith over (planMaintenance (hStore over)))
      mOver `shouldBe` Refused (Integrity CorruptCounters)
    it "refuses a retirement entry whose progress field was re-sealed past pages that were not reclaimed" $ do
      (h, _, _) ← fixture
      (leaf, entries, (k0, v0)) ← firstRetire h
      let (lp, cnt) = (getBe64' v0 0, getLe16' v0 8)
      cnt `shouldSatisfy` (>= 2)
      lpage ← parsed h (PageNo lp)
      ps ← case rpBody lpage of
        RefList _ xs → pure xs
        other → expectationFailure (show other) >> fail "list"
      -- done 0 -> 1: the first page is skipped, the rest reclaimed, the entry deleted and its list released: the
      -- first page would stay indexed and charged as retired for good
      forM_ [1, cnt - 1] $ \done → do
        forged ← forge h leaf (Page TreeRetire 0 leaf (Leaf [(k, if k == k0 then BS.concat [be64 lp, le16' cnt, le16' done] else x) | (k, x) ← entries]))
        (out, _, _) ← must (fillWith forged (planMaintenance (hStore forged)))
        case out of
          Refused (Integrity (RetiredIndexMismatch (PageNo q))) → ps `shouldSatisfy` (q `elem`)
          other → expectationFailure ("a progress field of " <> show done <> " skipping pages still indexed was not refused: " <> take 200 (show other))
    it "refuses a retirement list that names a bookkeeping page or a page past the used space" $ do
      (h, _, _) ← fixture
      (_, _, (k0, v0)) ← firstRetire h
      let (lp, cnt, e) = (getBe64' v0 0, getLe16' v0 8, getBe64' k0 0)
      lpage ← parsed h (PageNo lp)
      ps ← case rpBody lpage of
        RefList _ xs → pure xs
        other → expectationFailure (show other) >> fail "list"
      length ps `shouldBe` fromIntegral cnt
      -- a bookkeeping page, a page past the used space
      let roots = storeRoots (hStore h)
          hw = rHw roots
          other' = [("the free tree's root", n) | Just (PageNo n) ← [rFree roots]] <> [("a page past the used space", hw)]
      forM_ other' $ \(what, v) → do
        forged ← forge h (PageNo lp) (Page TreeRetire 0 (PageNo lp) (List e (map PageNo (sortUnique (v : drop 1 ps)))))
        (out, _, _) ← must (fillWith forged (planMaintenance (hStore forged)))
        case out of
          Refused (Integrity _) → pure ()
          bad → expectationFailure ("a retirement list naming " <> what <> " was not refused: " <> take 200 (show bad))
    it "refuses a retirement entry whose list page lies past the used space, is not a list, or does not hold the pages it counts" $ do
      (h, _, _) ← fixture
      (leaf, entries, (k0, v0)) ← firstRetire h
      let (e, lp, cnt, done) = (getBe64' k0 0, getBe64' v0 0, getLe16' v0 8, getLe16' v0 10)
      let entryValue list c d = BS.concat [be64 list, le16' c, le16' d]
          retarget v = forge h leaf (Page TreeRetire 0 leaf (Leaf [(k, if k == be64 e then v else x) | (k, x) ← entries]))
          hw = rHw (storeRoots (hStore h))
      runsRoot ← maybe (expectationFailure "runs root" >> fail "runs") pure (rRuns (storeRoots (hStore h)))
      forM_
        [ ("a list page past the used space", entryValue hw cnt done)
        , ("a list that is a record page", entryValue ((\(PageNo n) → n) runsRoot) cnt done)
        , ("a count the list does not hold", entryValue lp (cnt + 1) done)
        , ("a count below what the list holds", entryValue lp (max 1 (cnt - 1)) 0)
        ]
        $ \(what, v) → do
          forged ← retarget v
          (out, _, _) ← must (fillWith forged (planMaintenance (hStore forged)))
          case out of
            Refused (Integrity MalformedRetirement) → pure ()
            bad → expectationFailure ("a retirement entry with " <> what <> " was not refused as malformed: " <> take 200 (show bad))
  describe "child references and the used page space (the trees)" $ do
    it "refuses a re-sealed counter that disagrees with the pages, whatever its sign; a transfer between counters cannot change which page is overwritten" $ do
      (h, _, _) ← fixture
      let roots = storeRoots (hStore h)
          counters ∷ [(String, Integer → Roots → Roots)]
          counters = [("live", \d r → r {rLivePages = fromInteger (toInteger (rLivePages r) + d)}), ("retired", \d r → r {rRetiredPages = fromInteger (toInteger (rRetiredPages r) + d)}), ("free", \d r → r {rFreePages = fromInteger (toInteger (rFreePages r) + d)})]
      -- each counter moved by a little and by a lot, up and down: the partition identity breaks, so the next plan
      -- and the next maintenance transaction are refused as corrupt, never planned on a wrong capacity
      forM_ counters $ \(what, f) →
        forM_ [1, 100, -1] $ \d → do
          let forged = withRootsRaw h (f d)
          out ← planOn forged
          (what, d, out) `shouldBe` (what, d, Refused (Integrity CorruptCounters))
          (m, _, _) ← must (fillWith forged (planMaintenance (hStore forged)))
          (what, d, m) `shouldBe` (what, d, Refused (Integrity CorruptCounters))
      -- a tree with no root and a counter that says it holds pages, and the converse
      refusedCorrupt "a free counter with no free tree" =<< planOn (withRootsRaw h (\r → r {rFree = Nothing}))
      refusedCorrupt "a retired counter with no retirement tree" =<< planOn (withRootsRaw h (\r → r {rRetire = Nothing}))
      -- a consistent transfer (three pages from live to free): the identity holds, the counters are wrong about which
      -- class counts the pages, and the plan can only differ in capacity: every page it writes is dead
      let moved = withRootsRaw h (\r → r {rLivePages = rLivePages r - 3, rFreePages = rFreePages r + 3})
      out ← planOn moved
      retired ← retiredPagesOf moved
      let dead pg = not (Set.member pg (livePages moved)) && pg `notElem` concatMap snd retired
      case out of
        Planned plan → [n | (PageNo n, _) ← plPages plan, n < rHw roots, not (dead n)] `shouldBe` []
        Refused _ → pure ()
        other → expectationFailure ("unexpected outcome: " <> take 200 (show other))
    it "refuses a re-sealed internal page whose separator is no key of its tree, instead of answering that a record that exists is absent" $ do
      (h, _, _) ← fixture
      runsRoot ← maybe (expectationFailure "runs root" >> fail "runs") pure (rRuns (storeRoots (hStore h)))
      rootPage ← parsed h runsRoot
      children ← case rpBody rootPage of
        RefInner cs@(_ : _) → pure cs
        other → expectationFailure ("an inner runs root expected: " <> take 100 (show other)) >> fail "root"
      -- every separator of the root is 24 bytes of 0xFF: well ordered, valid checksum, no decoder accepts it
      let child = case children of ((_, c, crc) : _) → Child (PageNo c) crc; [] → Child runsRoot 0
      forged ← forge h runsRoot (Page TreeRuns (rpLevel rootPage) runsRoot (Inner [(BS.replicate 24 0xFF, child)]))
      bytes ← page forged runsRoot
      case windowInsert (cfgUsablePages (hCfg forged)) runsRoot bytes (storeWindow (hStore forged)) of
        Left MalformedKey → pure ()
        other → expectationFailure ("a malformed separator was accepted into a window: " <> take 200 (show other))
      -- so a reader's lookup of a record that exists is an integrity failure, never an absent answer
      (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore forged)))
      length children `shouldSatisfy` (>= 1)
      case readAll forged {hStore = s1} tok of
        Left msg → msg `shouldContain` "MalformedKey"
        Right found → expectationFailure ("a read through a malformed separator answered: " <> show (length found) <> " records")
    it "refuses a root of a tree the plan visits that lies past the used page space" $ do
      (h, _, _) ← fixture
      let hw = rHw (storeRoots (hStore h))
      forM_ [("runs", \r → r {rRuns = Just (PageNo hw)}), ("free", \r → r {rFree = Just (PageNo hw)}), ("retire", \r → r {rRetire = Just (PageNo hw)})] $ \(what, f) → do
        out ← planOn (withRoots h f)
        case out of
          Refused (Integrity (BadPage (BadReference (PageNo q)) _)) → q `shouldBe` hw
          bad → expectationFailure ("a " <> what <> " root past the used space was followed: " <> take 200 (show bad))

    it "refuses a child reference past the used page space, to a plan, a committed read and a pinned read" $ do
      (h0, ref0, g0) ← fixture
      -- a reader pins a version whose used space is smaller than the store's later one
      (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h0)))
      let hwPinned = rHw (storeRoots s1)
      (h1, _, _) ← must (foldM (\s _ → churn s 30) (h0 {hStore = s1}, ref0, g0) [1 .. 60 ∷ Int])
      when (rHw (storeRoots (hStore h1)) <= hwPinned) $ expectationFailure "the used space did not grow past the pin"
      -- the committed runs root's first child is forged to a page past the used space
      runsRoot ← maybe (expectationFailure "runs root" >> fail "runs") pure (rRuns (storeRoots (hStore h1)))
      rootPage ← parsed h1 runsRoot
      seps ← case rpBody rootPage of
        RefInner cs@(_ : _) → pure (map (\(k, _, _) → k) cs)
        other → expectationFailure ("an inner runs root expected: " <> take 100 (show other)) >> fail "root"
      let past = PageNo (rHw (storeRoots (hStore h1)))
      forgedC ← forge h1 runsRoot (Page TreeRuns (rpLevel rootPage) runsRoot (Inner [(k, Child past 0) | k ← seps]))
      outC ← planOn forgedC
      case outC of
        Refused (Integrity (BadPage (BadReference q) _)) → q `shouldBe` past
        other → expectationFailure ("a plan followed a reference past the used space: " <> take 300 (show other))
      -- a reader pinned before the space grew refuses a reference into the part added since
      pins ← maybe (expectationFailure "stale token" >> fail "pins") pure (either (const Nothing) Just (pinsOf (hStore h1) tok))
      pinnedRoot ← maybe (expectationFailure "pinned root" >> fail "pinned") pure (pinRuns pins)
      pinnedPage ← parsed h1 pinnedRoot
      pseps ← case rpBody pinnedPage of
        RefInner cs@(_ : _) → pure (map (\(k, _, _) → k) cs)
        other → expectationFailure ("an inner pinned root expected: " <> take 100 (show other)) >> fail "pinned root"
      let added = PageNo hwPinned
      forgedP0 ← forge h1 pinnedRoot (Page TreeRuns (rpLevel pinnedPage) pinnedRoot (Inner [(k, Child added 0) | k ← pseps]))
      -- the reader's pin records the checksum of the root it pinned: a forger who wants the page read updates it too
      let PageNo pr = pinnedRoot
          forgedP = case diskRead (hDisk forgedP0) pinnedRoot of
            Just bs → forgedP0 {hStore = modifyPins (\pn → if pinRuns pn == Just pinnedRoot then pn {pinCrcs = [(t', c') | (t', c') ← pinCrcs pn, t' /= TreeRuns] ++ [(TreeRuns, getLe32' bs 4092)]} else pn) (hStore forgedP0)}
            Nothing → forgedP0
      pr `shouldSatisfy` (>= 0)
      case readAll forgedP tok of
        Left msg → msg `shouldContain` "BadReference"
        Right _ → expectationFailure "a pinned read followed a reference past its version's used space"
  where
    shouldBe' ∷ (Eq a, Show a) ⇒ a → a → Expectation
    shouldBe' = shouldBe
    head' xs = case xs of (x : _) → x; [] → error "empty"
    sortUnique = Set.toAscList . Set.fromList
