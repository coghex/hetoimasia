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

import Control.Monad (foldM, forM_, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Record (..), RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Page (..), encodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (be64)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
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
fixture = do
  let st0 = (newH smallSpec ident0, Map.empty, mkRng 15)
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
forge ∷ H → PageNo → Page → IO H
forge h p pg = do
  bs ← either (\e → expectationFailure (show e) >> fail "encode") pure (encodePage (hIdent h) pg)
  pure h {hDisk = diskWrite p bs (hDisk h)}

-- | The same store over other root fields.
withRoots ∷ H → (Roots → Roots) → H
withRoots h f = h {hStore = modifyRoots f (hStore h)}

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
        RefInner ((_, c) : _) → (Just c, Nothing)
        _ → (Nothing, Nothing)
  leafBelow ← case child of
    Just c → do
      pg ← parsed h (PageNo c)
      pure (case rpBody pg of RefInner ((_, g) : _) → Just g; _ → Nothing)
    Nothing → pure grandchild
  retireRoot ← maybe (expectationFailure "a retirement root expected" >> fail "retire") pure (rRetire roots)
  rr ← parsed h retireRoot
  let lists = case rpBody rr of
        RefLeaf ((_, v) : _) → [getBe64' v 0]
        _ → []
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
  pure (withRoots h' (\r → r {rLoose = []}))

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
    it "refuses a free extent that offers a page only a pinned reader reaches, and the same plan unpinned would overwrite it" $ do
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
        refusedLive "a free extent offering a pinned page" v =<< planOn forged
        -- without the reader's roots the page looks free and is overwritten: the pinned
        -- roots are what stop it
        unpinned ← planUnpinned forged
        case unpinned of
          Planned plan → map fst (plPages plan) `shouldSatisfy` (PageNo v `elem`)
          other → expectationFailure ("the unpinned plan should accept the forged extent: " <> take 200 (show other))
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
    it "refuses a loose list that holds a page twice, wherever the second one sits" $ do
      (h, _, _) ← fixture
      freeRoot ← maybe (expectationFailure "free root" >> fail "free") pure (rFree (storeRoots (hStore h)))
      pg ← parsed h freeRoot
      let dead = case rpBody pg of
            RefLeaf es → concat [[s .. s + l - 1] | (k, v) ← es, let s = getBe64' k 0, let l = getBe64' v 0]
            _ → []
      length dead `shouldSatisfy` (> 100)
      -- more loose pages than any plan takes (at most 17 + 1 + 68), the first of them listed again at the end
      let loose = map PageNo (take 100 dead) <> [PageNo (head' dead)]
      refusedCorrupt "a loose page listed twice" =<< planOn (withRoots h (\r → r {rLoose = loose}))
  describe "retirement entries and their list pages" $ do
    it "refuses a retirement entry whose version was lowered past a pinned reader, with or without its list's stamp" $ do
      (h0, ref0, g0) ← fixture
      (tok, s1) ← must (either (Left . show) Right (acquireReader (hStore h0)))
      let pinned = storeVersion s1
      (hA, _) ← must (reclaimAll (h0 {hStore = s1}))
      (h2, ref2, _) ← must (foldM (\s _ → churn s 30) (hA, ref0, g0) [1 .. 4 ∷ Int])
      retireRoot ← maybe (expectationFailure "retire root" >> fail "retire") pure (rRetire (storeRoots (hStore h2)))
      rr ← parsed h2 retireRoot
      (entries, lp, cnt, e) ← case rpBody rr of
        RefLeaf es@((k, v) : _) → pure (es, getBe64' v 0, getLe16' v 8, getBe64' k 0)
        other → expectationFailure ("a retirement leaf expected: " <> take 100 (show other)) >> fail "retire"
      -- the oldest entry still waiting is newer than the reader's version (the reclamation that ran first only
      -- consumed entries it could, and its own commits changed no record page)
      e `shouldSatisfy` (> pinned)
      -- the entry now claims the version the reader pins: nothing newer holds its pages
      let lowered = (be64 pinned, snd (head' entries)) : drop 1 entries
      h3 ← forge h2 retireRoot (Page TreeRetire 0 retireRoot (Leaf lowered))
      -- the list still carries the true version: the entry and the list contradict each other
      (stampMismatch, _, _) ← must (fillWith h3 (planMaintenance (hStore h3)))
      stampMismatch `shouldBe'` Refused (Integrity MalformedRetirement)
      -- the list is forged to agree with the lowered entry: only the reader's tree can say
      lpage ← parsed h3 (PageNo lp)
      ps ← case rpBody lpage of
        RefList _ xs → pure xs
        other → expectationFailure (show other) >> fail "list"
      length ps `shouldBe` fromIntegral cnt
      h4 ← forge h3 (PageNo lp) (Page TreeRetire 0 (PageNo lp) (List pinned (map PageNo ps)))
      (agreed, _, _) ← must (fillWith h4 (planMaintenance (hStore h4)))
      case agreed of
        Refused (Integrity (RetiredPageLive (PageNo q))) → ps `shouldSatisfy` (q `elem`)
        other → expectationFailure ("a lowered version past a pinned reader was not refused as live: " <> take 300 (show other))
      -- the committed trees alone cannot tell: without the reader's roots the entry is accepted
      (accepted, _, _) ← must (fillWith h4 (planReclaimWith standardBounds (hCfg h4) (hIdent h4) (storeRoots (hStore h4)) (Just pinned)))
      case accepted of
        Planned _ → pure ()
        other → expectationFailure ("the committed-only check should accept the forged entry: " <> take 200 (show other))
      -- and the reader still answers from its version, with its pages in place
      seen ← must (readAll h4 tok)
      Map.fromList seen `shouldBe` ref0
      when (ref2 == ref0) $ expectationFailure "the later commits changed nothing"
    it "refuses a retirement list that names a bookkeeping page or a page past the used space" $ do
      (h, _, _) ← fixture
      retireRoot ← maybe (expectationFailure "retire root" >> fail "retire") pure (rRetire (storeRoots (hStore h)))
      rr ← parsed h retireRoot
      (lp, cnt, e) ← case rpBody rr of
        RefLeaf ((k, v) : _) → pure (getBe64' v 0, getLe16' v 8, getBe64' k 0)
        other → expectationFailure (show other) >> fail "retire"
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
      retireRoot ← maybe (expectationFailure "retire root" >> fail "retire") pure (rRetire (storeRoots (hStore h)))
      rr ← parsed h retireRoot
      (entries, e, lp, cnt, done) ← case rpBody rr of
        RefLeaf es@((k, v) : _) → pure (es, getBe64' k 0, getBe64' v 0, getLe16' v 8, getLe16' v 10)
        other → expectationFailure (show other) >> fail "retire"
      let entryValue list c d = BS.concat [be64 list, le16' c, le16' d]
          retarget v = forge h retireRoot (Page TreeRetire 0 retireRoot (Leaf ((be64 e, v) : drop 1 entries)))
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
        RefInner cs@(_ : _) → pure (map fst cs)
        other → expectationFailure ("an inner runs root expected: " <> take 100 (show other)) >> fail "root"
      let past = PageNo (rHw (storeRoots (hStore h1)))
      forgedC ← forge h1 runsRoot (Page TreeRuns (rpLevel rootPage) runsRoot (Inner [(k, past) | k ← seps]))
      outC ← planOn forgedC
      case outC of
        Refused (Integrity (BadPage (BadReference q) _)) → q `shouldBe` past
        other → expectationFailure ("a plan followed a reference past the used space: " <> take 300 (show other))
      -- a reader pinned before the space grew refuses a reference into the part added since
      pins ← maybe (expectationFailure "stale token" >> fail "pins") pure (either (const Nothing) Just (pinsOf (hStore h1) tok))
      pinnedRoot ← maybe (expectationFailure "pinned root" >> fail "pinned") pure (pinRuns pins)
      pinnedPage ← parsed h1 pinnedRoot
      pseps ← case rpBody pinnedPage of
        RefInner cs@(_ : _) → pure (map fst cs)
        other → expectationFailure ("an inner pinned root expected: " <> take 100 (show other)) >> fail "pinned root"
      let added = PageNo hwPinned
      forgedP ← forge h1 pinnedRoot (Page TreeRuns (rpLevel pinnedPage) pinnedRoot (Inner [(k, added) | k ← pseps]))
      case readAll forgedP tok of
        Left msg → msg `shouldContain` "BadReference"
        Right _ → expectationFailure "a pinned read followed a reference past its version's used space"
  where
    shouldBe' ∷ (Eq a, Show a) ⇒ a → a → Expectation
    shouldBe' = shouldBe
    head' xs = case xs of (x : _) → x; [] → error "empty"
    sortUnique = Set.toAscList . Set.fromList
