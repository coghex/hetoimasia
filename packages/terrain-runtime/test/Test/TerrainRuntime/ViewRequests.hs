-- | A view's sealed requests ("Hetoimasia.Terrain.Runtime.Transactions"): the service builds the endpoint, the view's
-- box holds the one settlement its arbitration made, and the view takes or retires the request by its handle alone, in
-- its own commit. A borrow is handed over or released exactly once, whichever of the view and the lease's closure is
-- first.
module Test.TerrainRuntime.ViewRequests (spec) where

import Control.Concurrent.STM (atomically, check, retry)
import Data.Maybe (isJust)
import Hetoimasia.Foundation.OwnerTx (commit)
import Hetoimasia.Terrain.Runtime
import Hetoimasia.Terrain.Runtime.Settlement (TakeOutcome (..))
import Hetoimasia.Terrain.Runtime.Transactions
import Test.Hspec
import Test.TerrainRuntime.Fixtures

spec ∷ Spec
spec = describe "a view's sealed requests" $ do
  it "settles through the arbitration once, into the view's own box, and hands the borrow over once on the take, until the view releases it" $
    withService defaultConfig $ \svc → do
      (_, lease) ← openMain svc "view"
      request ← okOf (requestViewRegions svc lease [region 0 0 0])
      settlement ← waitFor (viewRequestSettled request >>= maybe retry pure)
      borrow ← case settlement of
        Succeeded (ARegions borrow) → pure borrow
        other → expectationFailure ("expected a regional snapshot, got " <> show other) >> fail "unreachable"
      -- one settlement: the box keeps it, and a second reading is the same
      atomically (fmap (const ()) <$> viewRequestSettled request) `shouldReturn` Just ()
      commit (takeViewRequestTx svc request) `shouldReturn` Taken
      -- handed over once: the request is gone, and a second take finds nothing to hand over
      commit (takeViewRequestTx svc request) `shouldReturn` TakeReleased
      charged ← atomically (fst <$> inspectRetainedChargesSTM svc)
      charged `shouldSatisfy` (> 0)
      commit (releaseRegionBorrowTx svc borrow)
      atomically (fst <$> inspectRetainedChargesSTM svc) `shouldReturn` 0
      -- released once: a second release changes nothing
      commit (releaseRegionBorrowTx svc borrow)
      atomically (fst <$> inspectRetainedChargesSTM svc) `shouldReturn` 0
      settleChecks svc

  it "releases a borrow nobody took when the view retires its request, once" $
    withService defaultConfig $ \svc → do
      (_, lease) ← openMain svc "view"
      request ← okOf (requestViewRegions svc lease [region 0 0 0])
      _ ← waitFor (viewRequestSettled request >>= maybe retry pure)
      atomically (fst <$> inspectRetainedChargesSTM svc) >>= (`shouldSatisfy` (> 0))
      commit (retireViewRequestTx svc request)
      atomically (fst <$> inspectRetainedChargesSTM svc) `shouldReturn` 0
      commit (retireViewRequestTx svc request)
      commit (takeViewRequestTx svc request) `shouldReturn` TakeReleased
      atomically (fst <$> inspectRetainedChargesSTM svc) `shouldReturn` 0
      settleChecks svc

  it "discards a settled request whose lease closed before the view's take: the borrow is released with the lease and never handed over" $
    withService defaultConfig $ \svc → do
      (_, lease) ← openMain svc "view"
      request ← okOf (requestViewRegions svc lease [region 0 0 0])
      settlement ← waitFor (viewRequestSettled request >>= maybe retry pure)
      isJust (borrowOf settlement) `shouldBe` True
      -- the closure first
      _ ← releaseLease svc lease
      commit (takeViewRequestTx svc request) `shouldReturn` TakeReleased
      waitFor (fst <$> inspectRetainedChargesSTM svc >>= check . (== 0))
      settleChecks svc

  it "keeps a borrow the view took before its lease closed charged until the view releases it, once" $
    withService defaultConfig $ \svc → do
      (_, lease) ← openMain svc "view"
      request ← okOf (requestViewRegions svc lease [region 0 0 0])
      settlement ← waitFor (viewRequestSettled request >>= maybe retry pure)
      borrow ← maybe (expectationFailure "expected a regional snapshot" >> fail "unreachable") pure (borrowOf settlement)
      -- the take first
      commit (takeViewRequestTx svc request) `shouldReturn` Taken
      _ ← releaseLease svc lease
      atomically (fst <$> inspectRetainedChargesSTM svc) >>= (`shouldSatisfy` (> 0))
      commit (releaseRegionBorrowTx svc borrow)
      atomically (fst <$> inspectRetainedChargesSTM svc) `shouldReturn` 0
      commit (releaseRegionBorrowTx svc borrow)
      atomically (fst <$> inspectRetainedChargesSTM svc) `shouldReturn` 0
      settleChecks svc
  it "decides an attachment in full before writing: an attach under another client's lease, on an arena nobody watches yet, writes nothing — no view, no identity, no mark cell" $
    withService defaultConfig $ \svc → do
      (client, lease) ← openMain svc "view"
      (_, theirs) ← openMain svc "other"
      first ← commit (attachViewTx svc client lease) >>= either (\why → expectationFailure ("refused: " <> show why) >> fail "unreachable") (pure . fst)
      (count, watched) ← atomically ((,) <$> inspectViewCountSTM svc <*> inspectWatchedArenasSTM svc)
      commit (attachViewTx svc client theirs) >>= \case
        Left RefusedAuthority → pure ()
        Left other → expectationFailure ("refused otherwise: " <> show other)
        Right _ → expectationFailure "another client's lease was accepted"
      atomically ((,) <$> inspectViewCountSTM svc <*> inspectWatchedArenasSTM svc) `shouldReturn` (count, watched)
      -- the next attachment takes the identity the refused one would have
      second ← commit (attachViewTx svc client lease) >>= either (\why → expectationFailure ("refused: " <> show why) >> fail "unreachable") (pure . fst)
      numberOf second `shouldBe` numberOf first + 1
      settleChecks svc

  where
    -- a view shows as View#n
    numberOf view = read (drop 5 (show view)) ∷ Int
    borrowOf = \case
      Succeeded (ARegions borrow) → Just borrow
      _ → Nothing
