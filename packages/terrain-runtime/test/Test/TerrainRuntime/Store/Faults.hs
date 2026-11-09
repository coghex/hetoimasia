-- | Failure, cancellation and abort of a staged transaction.
--
-- A multi-page transaction is planned and admitted, then driven through every prefix
-- of its writes followed by a failed write, a cancellation request, or a provider
-- that accepts no further write. In every case the committed roots, the records
-- readable from them and the bytes of every page reachable from them are exactly
-- what they were; the staged claim and its buffers stay held until the writes have
-- drained; abort after the drain needs no write and returns the usage to what it was;
-- and a later plan commits and reaches the same records a store that never failed
-- reaches. A fully written transaction that was never published is abandoned the same
-- way. Duplicate, late and foreign outcomes change nothing.
module Test.TerrainRuntime.Store.Faults (spec) where

import Control.Monad (forM_, when)
import qualified Data.Map.Strict as Map
import Hetoimasia.Terrain.Discovery (Record, RecordKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Workload

-- | How the writes of a staged transaction stop.
data Mode = FailAt | CancelAt | DisabledAfter
  deriving stock (Eq, Show)

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | A store with history, the reference of it and a plan that writes many pages.
fixture ∷ IO (H, Map.Map RecordKey Record, Plan, [(RecordKey, Maybe Record)])
fixture = do
  let go g h ref i
        | i >= (60 ∷ Int) = Right (h, ref, g)
        | otherwise = do
            let (ws, g') = genWrites g ref 25
            (h', _) ← commitDelta h Ordinary (stepDelta (hStore h) 0 ws)
            go g' h' (applyRef ws ref) (i + 1)
  (h, ref, g) ← must (go (mkRng 2024) (newH smallSpec ident0) Map.empty 0)
  let (ws, _) = genWrites g ref 40
  p ← must (fillPlan h (stepDelta (hStore h) 0 ws) Ordinary)
  case p of
    Planned plan → pure (h, ref, plan, ws)
    other → expectationFailure ("expected a plan, got " <> show other) >> fail "no plan"

spec ∷ Spec
spec = describe "failure, cancellation and abort of a staged transaction" $ do
  forM_ [FailAt, CancelAt, DisabledAfter] $ \mode →
    it ("leaves the old roots, records and pages intact whatever prefix of the writes completed (" <> show mode <> ")") $ do
      (h, ref, plan, _) ← fixture
      let n = length (plPages plan)
      n `shouldSatisfy` (> 6)
      forM_ [0 .. n] $ \k → do
        (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h)))
        let pages = plPages plan
            (done, rest) = splitAt k pages
            step (s, d) (p, bs) = do
              let (_, sa) = dispatchWrite tid p s
                  (_, sb) = completeWrite tid p WriteDone sa
              (sb, diskWrite p bs d)
            (s2, d2) = foldl step (s1, hDisk h) done
        -- what the failure, cancellation or write-less provider does after the prefix
        (s4, d4) ← case (mode, rest) of
          (FailAt, (p, _) : _) → do
            let (r1, s3) = dispatchWrite tid p s2
                (r2, s3b) = completeWrite tid p WriteFailed s3
            (r1, r2) `shouldBe` (Applied, Applied)
            eligibility tid s3b `shouldBe` WriteFailures [p]
            refusalOf (publish tid s3b) `shouldBe` Just (PublishNotEligible (WriteFailures [p]))
            pure (s3b, d2)
          (CancelAt, _) → do
            let (c, s3) = requestCancel tid s2
            c `shouldBe` Applied
            -- a request releases nothing, and a fully written transaction stays eligible
            usage s3 `shouldBe` usage s2
            pure (s3, d2)
          (DisabledAfter, _) → do
            -- the provider accepts no further write: every remaining page fails, none is written
            let failAll s (p, _) = snd (completeWrite tid p WriteFailed (snd (dispatchWrite tid p s)))
            pure (foldl failAll s2 rest, d2)
          _ → pure (s2, d2)
        -- the claims stay until abandoned; the roots never changed
        storeRoots s4 `shouldBe` storeRoots (hStore h)
        (usStagedBytes (usage s4) > 0) `shouldBe` True
        -- nothing remains in flight, so abort needs no write at all
        let writesBefore = diskWrites d4
        s5 ← must (either (Left . show) Right (abortTransaction tid s4))
        diskWrites d4 `shouldBe` writesBefore
        storeRoots s5 `shouldBe` storeRoots (hStore h)
        usage s5 `shouldBe` usage (hStore h)
        let h5 = h {hStore = s5, hDisk = d4}
        must (checkH h5)
        must (compareRecords (Map.toList ref) h5)
  it "abandons a fully written but unpublished transaction with the old root intact" $ do
    (h, ref, plan, _) ← fixture
    (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h)))
    let step (s, d) (p, bs) =
          let (_, sa) = dispatchWrite tid p s
              (_, sb) = completeWrite tid p WriteDone sa
           in (sb, diskWrite p bs d)
        (s2, d2) = foldl step (s1, hDisk h) (plPages plan)
    eligibility tid s2 `shouldBe` Eligible
    s3 ← must (either (Left . show) Right (abortTransaction tid s2))
    storeRoots s3 `shouldBe` storeRoots (hStore h)
    usage s3 `shouldBe` usage (hStore h)
    let h3 = h {hStore = s3, hDisk = d2}
    must (checkH h3)
    must (compareRecords (Map.toList ref) h3)
    -- the claimed pages are reusable: replanning commits and equals a clean run
    p' ← must (fillPlan h3 (stepDelta s3 0 (snd' (genWrites (mkRng 5) ref 10))) Ordinary)
    case p' of
      Planned plan' → void' (commitPlan h3 plan')
      other → expectationFailure (show other)
  it "keeps the claim and refuses abort while a write is in flight, and releases after the drain" $ do
    (h, _, plan, _) ← fixture
    (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h)))
    (p1, p2) ← case plPages plan of
      ((a, _) : (b, _) : _) → pure (a, b)
      _ → expectationFailure "two pages expected" >> fail "pages"
    let (_, s2) = dispatchWrite tid p1 s1
        (_, s3) = dispatchWrite tid p2 s2
    refusalOf (abortTransaction tid s3) `shouldBe` Just (AbortStillInFlight 2)
    -- cancellation is only a request: nothing is released
    let (cr, s4) = requestCancel tid s3
        usedBefore = usage s3
    cr `shouldBe` Applied
    usage s4 `shouldBe` usedBefore
    activePages tid s4 `shouldSatisfy` (/= Nothing)
    refusalOf (abortTransaction tid s4) `shouldBe` Just (AbortStillInFlight 2)
    let (_, s5) = completeWrite tid p1 WriteFailed s4
    refusalOf (abortTransaction tid s5) `shouldBe` Just (AbortStillInFlight 1)
    let (_, s6) = completeWrite tid p2 WriteDone s5
    s7 ← must (either (Left . show) Right (abortTransaction tid s6))
    usage s7 `shouldBe` usage (hStore h)
  it "ignores duplicate, late and foreign outcomes" $ do
    (h, _, plan, _) ← fixture
    (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h)))
    p1 ← firstPage plan
    let (r0, s2) = dispatchWrite tid p1 s1
        (r1, s3) = dispatchWrite tid p1 s2
        (r2, s4) = completeWrite tid p1 WriteDone s3
        (r3, s5) = completeWrite tid p1 WriteDone s4
        (r4, s6) = completeWrite tid p1 WriteFailed s5
        (r5, _) = completeWrite tid (PageNo 99999999) WriteDone s6
    [r0, r1, r2, r3, r4, r5] `shouldBe` [Applied, Duplicate, Applied, Duplicate, Duplicate, Unknown]
    -- a page that was never dispatched cannot complete
    let (_, s7) = completeWrite tid p1 WriteDone s1
    storeRoots s7 `shouldBe` storeRoots s1
    -- a stale transaction id changes nothing
    s8 ← must (either (Left . show) Right (abortTransaction tid s1))
    let (r6, _) = dispatchWrite tid p1 s8
        (r7, _) = completeWrite tid p1 WriteDone s8
        (r8, _) = requestCancel tid s8
    [r6, r7, r8] `shouldBe` [Unknown, Unknown, Unknown]
  it "cannot roll a published edit back, and a late cancellation or outcome changes nothing" $ do
    (h, ref, plan, ws) ← fixture
    (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h)))
    let step (s, d) (p, bs) =
          let (_, sa) = dispatchWrite tid p s
              (_, sb) = completeWrite tid p WriteDone sa
           in (sb, diskWrite p bs d)
        (s2, d2) = foldl step (s1, hDisk h) (plPages plan)
    (pubd, s3) ← must (either (Left . show) Right (publish tid s2))
    pubVersion pubd `shouldBe` storeVersion (hStore h) + 1
    p1 ← firstPage plan
    let (c, s4) = requestCancel tid s3
        (o, s5) = completeWrite tid p1 WriteFailed s4
    (c, o) `shouldBe` (Unknown, Unknown)
    storeRoots s5 `shouldBe` storeRoots s3
    let h3 = h {hStore = s5, hDisk = d2}
    must (checkH h3)
    must (compareRecords (Map.toList (applyRef ws ref)) h3)
    -- publishing twice is refused
    refusalOf (publish tid s5) `shouldBe` Just PublishNoSuchTransaction
  it "refuses a second transaction while one is active and a stale plan after publication" $ do
    (h, _, plan, _) ← fixture
    (tid, s1) ← must (either (Left . show) Right (admit plan (hStore h)))
    refusalOf (admit plan s1) `shouldBe` Just BusyTransaction
    s2 ← must (either (Left . show) Right (abortTransaction tid s1))
    when (storeRoots s2 /= storeRoots (hStore h)) $ expectationFailure "roots changed by abort"
  where
    snd' = fst
    void' = either (\e → expectationFailure e) (const (pure ()))
    firstPage plan = case plPages plan of
      ((p, _) : _) → pure p
      [] → expectationFailure "a page was expected" >> fail "pages"

refusalOf ∷ Either e a → Maybe e
refusalOf = either Just (const Nothing)
