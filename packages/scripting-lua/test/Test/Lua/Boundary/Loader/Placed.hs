-- | The roots a coordinator has placed (LFE-11): the loader starts independent roots by the order
-- the coordinator gave them, whatever order they were admitted or their sources arrived in; a root
-- can be asked to start earlier and never later; and room an application reserved for an accepted
-- root counts against the identity bound until the loader holds a record of it.
--
-- Every example runs a real interpreter through the public owner and the rig of injected seams
-- ("Test.Lua.Boundary.Loader.Support"). Order is what modules marked.
module Test.Lua.Boundary.Loader.Placed (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Owner
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Loader.Support

-- | A root placed at a tick and a sequence.
placed ∷ OwnedVm → Text → Word → Word → Bool → IO RootAdmission
placed owned path tick sequenceNumber reserved =
  admitRootAt owned (RootRequest (ident path) ("game:" <> path)) (RootOrder (fromIntegral tick) (fromIntegral sequenceNumber)) reserved

-- | A module that marks its name.
marking ∷ Text → [Text]
marking name = ["trace.mark('" <> name <> "')", "return { name = '" <> name <> "' }"]

settledIds ∷ AdvanceReport → [ExportIdentity]
settledIds = map fst . advanceSettled

spec ∷ Spec
spec = describe "placed roots" $ do
  describe "the order roots start in" $ do
    it "is the order the coordinator gave them, equal orders in the order admitted, whatever order they were admitted or their sources arrived in" $
      withRig $ \rig owned → do
        mapM_ (\(path, tick, sequenceNumber) → placed owned path tick sequenceNumber False) [("late", 5, 0), ("second", 2, 7), ("first", 2, 3), ("tie_a", 4, 1), ("tie_b", 4, 1)]
        -- Sources arrive in the reverse of every order.
        mapM_ (\path → supply rig owned path (marking path)) ["tie_b", "tie_a", "first", "second", "late"]
        report ← advance owned
        settledIds report `shouldBe` map ident ["first", "second", "tie_a", "tie_b", "late"]
        traced rig >>= (`shouldBe` ["first", "second", "tie_a", "tie_b", "late"])
        ledger owned >>= (`shouldSatisfy` balanced)

    it "never lets a later ready root overtake an earlier one that waits for its source" $
      withRig $ \rig owned → do
        _ ← placed owned "early" 1 0 False
        _ ← placed owned "later" 2 0 False
        _ ← supply rig owned "later" (marking "later")
        held ← advance owned
        advanceBlocked held `shouldBe` BlockedSource (ident "early")
        traced rig >>= (`shouldBe` [])
        _ ← supply rig owned "early" (marking "early")
        done ← advance owned
        advanceBlocked done `shouldBe` BlockedIdle
        traced rig >>= (`shouldBe` ["early", "later"])

    it "keeps the order of roots admitted without one: first in, first out" $
      withRig $ \rig owned → do
        mapM_ (admit owned) ["a", "b", "c"]
        mapM_ (\path → supply rig owned path (marking path)) ["c", "b", "a"]
        _ ← advance owned
        traced rig >>= (`shouldBe` ["a", "b", "c"])

  describe "asking a root to start earlier" $ do
    it "moves a queued root up, keeps the arrival number that breaks ties, and starts it first without a second record, interest or evaluation" $
      withRig $ \rig owned → do
        mapM_ (\(path, tick) → placed owned path tick 0 False) [("a", 3), ("b", 4), ("c", 5)]
        mapM_ (\path → supply rig owned path (marking path)) ["a", "b", "c"]
        promoteRoot owned (ident "c") (RootOrder 1 0) `shouldReturnPromotion` PromotionMoved
        acquiredBefore ← length <$> acquired rig
        _ ← advance owned
        traced rig >>= (`shouldBe` ["c", "a", "b"])
        length <$> acquired rig >>= (`shouldBe` acquiredBefore)
        ledger owned >>= (`shouldSatisfy` balanced)

    it "never moves a root later, and leaves a root that already stands there or earlier alone" $
      withRig $ \_ owned → do
        _ ← placed owned "a" 3 0 False
        promoteRoot owned (ident "a") (RootOrder 3 0) `shouldReturnPromotion` PromotionNotEarlier
        promoteRoot owned (ident "a") (RootOrder 9 0) `shouldReturnPromotion` PromotionNotEarlier
        promoteRoot owned (ident "a") (RootOrder 2 0) `shouldReturnPromotion` PromotionMoved
        promoteRoot owned (ident "a") (RootOrder 2 5) `shouldReturnPromotion` PromotionNotEarlier

    it "queues a dependency of the active chain that was never a root, so it is evaluated within the chain and its own turn finds an outcome" $
      withRig $ \rig owned → do
        _ ← placed owned "main" 1 0 False
        _ ← supply rig owned "main" ["trace.mark('main')", "local dep = import('dep')", "return { dep = dep }"]
        _ ← advance owned
        statusOfName owned "dep" >>= (`shouldBe` ModulePending)
        promoteRoot owned (ident "dep") (RootOrder 5 0) `shouldReturnPromotion` PromotionMoved
        countQueued' owned >>= (`shouldBe` 1)
        _ ← supply rig owned "dep" (marking "dep")
        done ← advance owned
        settledIds done `shouldBe` map ident ["dep", "main"]
        traced rig >>= (`shouldBe` ["main", "dep"])
        -- The queue entry found an outcome and ran nothing.
        countQueued' owned >>= (`shouldBe` 0)
        ledger owned >>= (`shouldSatisfy` balanced)

    it "has nothing to move for the frame of the active chain, an outcome, or an identity the loader does not hold" $
      withRig $ \rig owned → do
        _ ← placed owned "main" 1 0 False
        _ ← supply rig owned "main" ["local dep = import('dep')", "return {}"]
        _ ← advance owned
        promoteRoot owned (ident "main") (RootOrder 0 0) `shouldReturnPromotion` PromotionNothingQueued
        _ ← supply rig owned "dep" (marking "dep")
        _ ← advance owned
        promoteRoot owned (ident "dep") (RootOrder 0 0) `shouldReturnPromotion` PromotionNothingQueued
        promoteRoot owned (ident "nobody") (RootOrder 0 0) `shouldReturnPromotion` PromotionUnknown
        _ ← stopModuleLoader owned
        promoteRoot owned (ident "dep") (RootOrder 0 0) `shouldReturnPromotion` PromotionUnknown

  describe "room reserved for an accepted root" $ do
    it "counts against the identity bound beside the records, so a dependency cannot take the room an accepted root was promised" $ do
      reserved ← newIORef (0 ∷ Int)
      withRigAt (limitedTo 3 reserved) $ \rig owned → do
        -- Two records, and the application promised room for a third.
        mapM_ (admit owned) ["one", "two"]
        writeIORef reserved 1
        _ ← supply rig owned "one" ["local d = import('dep')", "return {}"]
        _ ← supply rig owned "two" (marking "two")
        _ ← advance owned
        failure ← failureOf owned "one"
        reasonIs (ImportCacheFull 3 "game:dep") failure `shouldBe` True
        statusOfName owned "dep" >>= (`shouldBe` ModuleUnknown)
        -- The accepted root is admitted from its reservation, not refused for want of the room it was promised.
        placed owned "accepted" 1 0 True `shouldReturnAdmission` RootQueued
        countPending' owned >>= (`shouldBe` 1)

    it "is not asked of a root admitted from a reservation, and an identity is not counted against itself" $ do
      reserved ← newIORef (0 ∷ Int)
      withRigAt (limitedTo 2 reserved) $ \rig owned → do
        mapM_ (admit owned) ["one", "two"]
        placed owned "three" 1 0 False `shouldReturnAdmission` RootRefused (RootCacheFull 2)
        placed owned "three" 1 0 True `shouldReturnAdmission` RootQueued
        _ ← supply rig owned "one" (marking "one")
        _ ← supply rig owned "two" (marking "two")
        _ ← supply rig owned "three" (marking "three")
        _ ← advance owned
        statusOfName owned "three" >>= \status → status `shouldSatisfy` \case ModuleReady _ → True; _ → False
  where
    shouldReturnPromotion action expected = action >>= (`shouldBe` expected)
    shouldReturnAdmission action expected = action >>= (`shouldBe` expected)
    limitedTo identities reserved config =
      config
        { vmExportLimits = (vmExportLimits config) {exportMaxIdentities = identities}
        , vmLoader = fmap (\loader → loader {loaderReserved = \_ → readIORef reserved}) (vmLoader config)
        }
    countQueued' owned = countQueued <$> moduleLoaderCounts owned
    countPending' owned = countPending <$> moduleLoaderCounts owned
