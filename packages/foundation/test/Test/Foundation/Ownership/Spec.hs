-- | Ownership transactions ("Hetoimasia.Foundation.OwnerTx"), the issuer bridge's composition, the exit classification
-- ("Hetoimasia.Foundation.Exit") and the public boundary, composed under one @Ownership@ group.
--
-- The examples here are the public module's own: owner cells and their read-only capabilities, a reader that waits
-- outside every commit, and revisioned publications.
module Test.Foundation.Ownership.Spec (spec) where

import Control.Concurrent.STM (atomically, check)
import Control.Exception (ErrorCall (ErrorCall), try)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.OwnerTx
import qualified Test.Foundation.Ownership.Composition as Composition
import qualified Test.Foundation.Ownership.Exits as Exits
import qualified Test.Foundation.Ownership.Opacity as Opacity
import Test.Hspec
import Test.Support.Owned (withOwnedThread)

spec ∷ Spec
spec = describe "Ownership" $ do
  describe "owner cells" $ do
    it "commits a value written by its owner, which a later commit observes through the cell's read-only capability" $ do
      cell ← newCellIO (3 ∷ Int)
      commit (readCell cell >>= writeCell cell . (* 2))
      commit (readTx (readOnly cell)) `shouldReturn` 6
      commit (newCell "fresh" >>= \other → writeCell other "replaced" >> readTx (readOnly other)) `shouldReturn` ("replaced" ∷ String)

    it "lets a reader wait on a read-only capability outside every commit, then decide afresh in its own" $ do
      cell ← newCellIO False
      seen ← newCellIO (0 ∷ Int)
      withOwnedThread
        (atomically (watch (readOnly cell) >>= check) >> commit (readCell seen >>= writeCell seen . (+ 1)))
        $ \_ ended → do
          commit (writeCell cell True)
          ended
      commit (readCell seen) `shouldReturn` 1

  describe "publications" $ do
    it "lets a reader see each prepared value with its revision, an equal value and the teardown's included" $ do
      source ← prepare (Just ("open" ∷ String)) >>= newPublisherIO
      let reading = publication source
      commit (readPublication reading) `shouldReturn` (0, Just "open")
      prepare (Just "open") >>= atomically . publish source
      commit (readPublication reading) `shouldReturn` (1, Just "open")
      -- the source's teardown publishes in the transaction that ends the fact
      prepare Nothing >>= atomically . publish source
      commit (readPublication reading) `shouldReturn` (2, Nothing)
      atomically (watchPublication reading) `shouldReturn` (2, Nothing)

    it "keeps the prior value and revision when a replacement's preparation fails, before any transaction" $ do
      source ← prepare [1 ∷ Int] >>= newPublisherIO
      outcome ← try (prepare [2, error "the nested value raised"] >>= atomically . publish source)
      case outcome of
        Left (ErrorCall why) → why `shouldBe` "the nested value raised"
        Right () → expectationFailure "a value whose evaluation raises was published"
      commit (readPublication (publication source)) `shouldReturn` (0, [1])

    it "keeps the prior value and revision when selecting the prepared handle to publish fails, in the source's transaction" $ do
      source ← prepare (1 ∷ Int) >>= newPublisherIO
      prepared ← mapM (\(name, value) → (,) name <$> prepare value) [("one", 1), ("two", 2 ∷ Int)]
      let selected name = maybe (error ("no prepared value is named " <> name)) id (lookup name prepared)
      outcome ← try (atomically (publish source (selected "three")))
      case outcome of
        Left (ErrorCall why) → why `shouldBe` "no prepared value is named three"
        Right () → expectationFailure "a failed selection was published"
      commit (readPublication (publication source)) `shouldReturn` (0, 1)
      -- a selection that succeeds is installed with the next revision
      atomically (publish source (selected "two"))
      commit (readPublication (publication source)) `shouldReturn` (1, 2)

  Composition.spec
  Exits.spec
  Opacity.spec
