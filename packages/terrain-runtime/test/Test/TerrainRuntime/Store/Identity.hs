-- | Windows, transaction tokens and header accounting bound to what they belong to.
--
-- A window is made for one store and one version: a reader of another arena, a
-- version the window was not filled for and a plan for another store refuse it before
-- any data is returned, and a page of another arena cannot be inserted. A transaction
-- token carries its store, so another store's outcome for the same serial and page
-- number changes nothing. The discovery header's accounted bytes (the retained
-- history's size, which lives in pages) are not resident transaction memory, so a
-- history of any size plans like an empty one. A floor lookup that stops on a deleted
-- separator names the previous leaf it waits for.
module Test.TerrainRuntime.Store.Identity (spec) where

import Control.Monad (forM_)
import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Header (..), RecordKey (..))
import Hetoimasia.Terrain.Residency (ArenaId (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.Records (decodeKey)
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree
import Test.Hspec
import Test.TerrainRuntime.Store.Harness
import Test.TerrainRuntime.Store.Reference
import Test.TerrainRuntime.Store.Bounds (wide)

must ∷ Either String a → IO a
must = either (\e → expectationFailure e >> fail e) pure

-- | A store of an arena holding one run, so version 1 differs by the run's end.
oneRun ∷ Word64 → Integer → H
oneRun arena hi =
  let h0 = newH smallSpec (identOf arena 7)
      d = deltaFor (hStore h0) True False 1 [(runKey 0 0 1, Just (runRec hi))]
   in either (error . show) fst (commitDelta h0 Ordinary d)

firstPage ∷ H → PageNo
firstPage h = case committedRoot (hStore h) TreeRuns of
  Just p → p
  Nothing → error "no runs root"

windowWith ∷ H → Either String Window
windowWith h = case diskRead (hDisk h) (firstPage h) of
  Nothing → Left "no page"
  Just bs → either (Left . show) Right (windowInsert (cfgUsablePages (hCfg h)) (firstPage h) bs (storeWindow (hStore h)))

spec ∷ Spec
spec = describe "windows, tokens and accounting bound to their store" $ do
  it "refuses a window of another arena or version at every read and planning entry" $ do
    let hA = oneRun 1 7
        hB = oneRun 2 3
    wA ← must (windowWith hA)
    wB ← must (windowWith hB)
    (tok, sB) ← must (either (Left . show) Right (acquireReader (hStore hB)))
    -- the reader's own window answers its own record; a window of arena A (same version) reads nothing
    readerLookup sB tok wB (runKey 0 0 1) `shouldBe` Read (Just (runRec 3))
    readerLookup sB tok wA (runKey 0 0 1) `shouldBe` ReadWrongWindow WindowOfAnotherStore
    readerFloorRun sB tok wA (columnAt 0 0) 5 `shouldBe` ReadWrongWindow WindowOfAnotherStore
    readerRange sB tok wA TreeRuns (RangeFrom (runKey 0 0 0)) 10 `shouldBe` ReadWrongWindow WindowOfAnotherStore
    -- a window filled for another version is refused too, not answered from stale pages
    let w999 = emptyWindow (identOf 2 7) 999
    readerLookup sB tok w999 (runKey 0 0 1) `shouldBe` ReadWrongWindow (WindowOfAnotherVersion 999 1)
    either Just (const Nothing) (readerProviderFor sB tok wA) `shouldBe` Just (PinWindow WindowOfAnotherStore)
    either Just (const Nothing) (readerMissing sB tok w999 (runKey 0 0 1)) `shouldBe` Just (PinWindow (WindowOfAnotherVersion 999 1))
    either Just (const Nothing) (providerAt (hStore hB) wA) `shouldBe` Just WindowOfAnotherStore
    either Just (const Nothing) (providerAt (hStore hB) w999) `shouldBe` Just (WindowOfAnotherVersion 999 1)
    -- a plan refuses them before reading a page
    let d = deltaFor (hStore hB) True False 1 [(runKey 0 0 1, Just (runRec 9))]
        plan w = planDelta (hCfg hB) (hIdent hB) (storeRoots (hStore hB)) w Ordinary d
    plan wA `shouldBe` Refused (Stale ForeignWindow)
    plan w999 `shouldBe` Refused (Stale (StaleWindow 999 1))
    -- and a page of arena A cannot enter arena B's window
    case diskRead (hDisk hA) (firstPage hA) of
      Just bs → windowInsert (cfgUsablePages (hCfg hB)) (firstPage hA) bs (storeWindow (hStore hB)) `shouldBe'` WrongArena
      Nothing → expectationFailure "page"
  it "binds a transaction token to its store, so a foreign outcome changes nothing" $ do
    let hA = newH smallSpec (identOf 1 7)
        hB = newH smallSpec (identOf 2 7)
        d h = deltaFor (hStore h) True False 1 [(runKey 0 0 1, Just (runRec 7))]
    PlannedPlan planA ← must (planned hA (d hA))
    PlannedPlan planB ← must (planned hB (d hB))
    (tidA, sA) ← must (either (Left . show) Right (admit planA (hStore hA)))
    (tidB, sB) ← must (either (Left . show) Right (admit planB (hStore hB)))
    -- both are the first transaction of their store: the serial is equal, the token is not
    txnSerial tidA `shouldBe` txnSerial tidB
    (tidA == tidB) `shouldBe` False
    let pg = case plPages planA of ((p, _) : _) → p; [] → PageNo 0
        pgB = case plPages planB of ((p, _) : _) → p; [] → PageNo 0
    pg `shouldBe` pgB
    forM_ [dispatchWrite tidA pg sB, completeWrite tidA pg WriteDone sB, requestCancel tidA sB] $ \(r, s') → do
      r `shouldBe` Unknown
      activeView s' `shouldBe` activeView sB
    eligibility tidA sB `shouldBe` NoSuchTransaction
    either Just (const Nothing) (abortTransaction tidA sB) `shouldBe` Just AbortNoSuchTransaction
    either Just (const Nothing) (publish tidA sB) `shouldBe` Just PublishNoSuchTransaction
    activePages tidA sB `shouldBe` Nothing
    -- the owner's own token still works on its own store
    fst (dispatchWrite tidA pg sA) `shouldBe` Applied
  it "does not charge the retained history's size to a transaction's memory" $ do
    let h0 = newH smallSpec ident0
        hdr = storeHeader (hStore h0)
        base = deltaFor (hStore h0) True False 1 [(runKey 0 0 1, Just (runRec 7))]
        big = base {dlNext = (dlNext base) {hBytes = 6000000}}
    case fillPlan h0 big Ordinary of
      Right (Planned p) → do
        ramRootControl (mRam (plMeasure p)) `shouldBe` rootRecordBytes + activeRecordBytes + 128
        ramTotal (mRam (plMeasure p)) `shouldSatisfy` (< 1024 * 1024)
        h1 ← must (commitPlan h0 p)
        -- the control records are the same size at any history size
        controlBytes (hStore h1) `shouldBe` controlBytes (hStore h0)
        hBytes (storeHeader (hStore h1)) `shouldBe` 6000000
        -- and the next plan is as cheap as the first
        case fillPlan h1 (deltaFor (hStore h1) True False 1 [(runKey 0 0 1, Just (runRec 8))]) Ordinary of
          Right (Planned p2) → ramRootControl (mRam (plMeasure p2)) `shouldBe` ramRootControl (mRam (plMeasure p))
          other → expectationFailure (show other)
      other → expectationFailure (show other)
    _ ← pure hdr
    pure ()
  it "names the previous leaf a floor lookup waits for when a separator was left below its leaf's first key" $ do
    (h0, keys) ← must (wide 2000)
    let ArenaId a = siArena (hIdent h0)
        rootNo = firstPage h0
    rootBytes ← maybe (expectationFailure "root" >> fail "root") pure (diskRead (hDisk h0) rootNo)
    root ← either (\e → expectationFailure (show e) >> fail "root") pure (parsePage a (siSource (hIdent h0)) rootBytes)
    case rpBody root of
      RefInner ((_, c0) : (sep1, c1) : _) → do
        -- the first key of the second leaf is its separator; delete that key
        sepKey ← maybe (expectationFailure "separator" >> fail "key") pure (decodeKey TreeRuns sep1)
        (h1, _) ← must (commitDelta h0 Ordinary (deltaFor (hStore h0) True False 1 [(sepKey, Nothing)]))
        let s1 = hStore h1
            root1 = case committedRoot s1 TreeRuns of Just p → p; Nothing → PageNo 0
            total = cfgUsablePages (hCfg h1)
            rootFor t = if t == TreeRuns then Just root1 else Nothing
            addP w p = case diskRead (hDisk h1) p of
              Just bs → either (error . show) id (windowInsert total p bs w)
              Nothing → error "page"
        (KeyRun col lo) ← pure sepKey
        -- the committed tree's root is a new page; its separator for the second leaf is still sep1
        newRootBytes ← maybe (expectationFailure "new root" >> fail "root") pure (diskRead (hDisk h1) root1)
        newRoot ← either (\e → expectationFailure (show e) >> fail "root") pure (parsePage a (siSource (hIdent h1)) newRootBytes)
        case rpBody newRoot of
          RefInner ((_, n0) : (s', n1) : _) → do
            s' `shouldBe` sep1
            let wRootLeaf1 = addP (addP (storeWindow s1) root1) (PageNo n1)
            -- an exact lookup that finds nothing is not answered (absent) from the root and the second leaf alone: the
            -- previous leaf is checked against the separator it shares first, and the lookup waits for it
            case lookupRecord wRootLeaf1 rootFor sepKey of
              Left (Need (PageNo p)) → p `shouldBe` n0
              other → expectationFailure ("an absence needs the previous leaf: " <> show other)
            -- the floor lookup needs the previous leaf, and says so
            case floorRun wRootLeaf1 rootFor col lo of
              Left (Need (PageNo p)) → p `shouldBe` n0
              other → expectationFailure ("floor lookup should need the previous leaf: " <> show other)
            -- the suspension names it, instead of reporting a corrupt counter
            missingPage wRootLeaf1 rootFor sepKey `shouldBe` Right (Just (PageNo n0))
            -- with it, the floor answers: the previous leaf's last run is in another column,
            -- so this column has no run at or below the level
            let wAll = addP wRootLeaf1 (PageNo n0)
            -- (the lookup then waits for the leaf on the other side, too, and answers once it has it)
            let fillFor ∷ ∀ b. Window → (Window → Either Stop b) → Either Stop b
                fillFor w f = case f w of
                  Left (Need q) → fillFor (addP w q) f
                  Left e → Left e
                  Right r → Right r
            fillFor wAll (\w → lookupRecord w rootFor sepKey) `shouldSatisfy` either (const False) (== Nothing)
            fillFor wAll (\w → floorRun w rootFor col lo) `shouldSatisfy` either (const False) (== Nothing)
          _ → expectationFailure "expected an internal root"
        _ ← pure (c0, c1, keys)
        pure ()
      _ → expectationFailure "expected an internal root with two leaves"
  where
    shouldBe' r e = either id (error "accepted") r `shouldBe` e

-- | A planned transaction.
data PlannedPlan = PlannedPlan Plan

planned ∷ H → Delta → Either String PlannedPlan
planned h d = do
  p ← fillPlan h d Ordinary
  case p of
    Planned plan → Right (PlannedPlan plan)
    other → Left (show other)
