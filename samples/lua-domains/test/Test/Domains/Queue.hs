-- | The bounded intention queue and its admission seam (requirements 6, 7 and 8), without an
-- owner: each admission is one transaction that answers at once.
module Test.Domains.Queue (spec) where

import Control.Concurrent.STM (atomically)
import Data.Word (Word32, Word64)
import Hetoimasia.Sample.LuaDomains.Bounds
import Hetoimasia.Sample.LuaDomains.Intention
import Hetoimasia.Sample.LuaDomains.Queue
import Test.Hspec

bounds ∷ Bounds
bounds = defaultBounds {boundQueue = 3, boundPlaces = 2}

intention ∷ Int → Intention
intention entity = Intention 1 0 entity 0 1 0

placement ∷ Word64 → Word32 → Placement
placement = Placement

spec ∷ Spec
spec = describe "the intention queue" $ do
  it "takes the UI's intentions for the next unstarted tick, one place after another" $ do
    queue ← newQueue bounds Nothing
    first ← atomically (admitNext queue (intention 0))
    second ← atomically (admitNext queue (intention 1))
    (first, second) `shouldBe` (AdmittedAt (placement 1 0), AdmittedAt (placement 1 1))

  it "answers full at once when the tick's places are taken, and when the queue's bound is" $ do
    queue ← newQueue bounds Nothing
    mapM_ (atomically . admitNext queue . intention) [0, 1]
    -- The tick holds its two places.
    atomically (admitNext queue (intention 2)) `shouldReturn` AtFull
    -- The tick is sealed: its two intentions keep their reservations, so one more fits the bound
    -- of three and the next is full by the queue, not by the tick.
    _ ← atomically (seal queue)
    atomically (admitNext queue (intention 3)) `shouldReturn` AdmittedAt (placement 2 0)
    atomically (admitNext queue (intention 4)) `shouldReturn` AtFull
    atomically (reserved queue) `shouldReturn` 3

  it "gives a tick's reservations back only when the tick is settled, and only once" $ do
    queue ← newQueue bounds Nothing
    mapM_ (atomically . admitNext queue . intention) [0, 1]
    (tick, sealed) ← atomically (seal queue)
    (tick, map fst sealed) `shouldBe` (1, [placement 1 0, placement 1 1])
    atomically (reserved queue) `shouldReturn` 2
    atomically (settle queue tick)
    atomically (reserved queue) `shouldReturn` 0
    atomically (settle queue tick)
    atomically (reserved queue) `shouldReturn` 0

  it "reads the next tick and takes its place in one transaction: a tick that has started is never admitted to" $ do
    queue ← newQueue bounds Nothing
    _ ← atomically (seal queue)
    atomically (nextUnstarted queue) `shouldReturn` 2
    atomically (admitNext queue (intention 0)) `shouldReturn` AdmittedAt (placement 2 0)
    -- The explicit seam refuses the tick that has begun, and never applies it later.
    atomically (admitAt queue (placement 1 0) (intention 0)) `shouldReturn` AtLate

  it "takes an explicit tick and order, applies them in the order of the places, and refuses a duplicate" $ do
    queue ← newQueue bounds {boundQueue = 8, boundPlaces = 4} Nothing
    atomically (admitAt queue (placement 1 3) (intention 3)) `shouldReturn` AdmittedAt (placement 1 3)
    atomically (admitAt queue (placement 1 1) (intention 1)) `shouldReturn` AdmittedAt (placement 1 1)
    atomically (admitAt queue (placement 1 1) (intention 2)) `shouldReturn` AtDuplicate
    atomically (admitAt queue (placement 1 4) (intention 2)) `shouldReturn` AtFull
    -- A tick further ahead is held until its turn.
    atomically (admitAt queue (placement 3 0) (intention 0)) `shouldReturn` AdmittedAt (placement 3 0)
    (_, sealed) ← atomically (seal queue)
    map (placeOrder . fst) sealed `shouldBe` [1, 3]
    map (intentEntity . snd) sealed `shouldBe` [1, 3]
    atomically (seal queue) >>= (`shouldBe` (2, [])) . fmap (map fst)
    (_, third) ← atomically (seal queue)
    map fst third `shouldBe` [placement 3 0]

  it "checks closed before late, late before a duplicate and a duplicate before full" $ do
    queue ← newQueue bounds {boundQueue = 1, boundPlaces = 1} (Just 2)
    atomically (admitAt queue (placement 3 0) (intention 0)) `shouldReturn` AtClosed
    _ ← atomically (seal queue)
    atomically (admitAt queue (placement 1 0) (intention 0)) `shouldReturn` AtLate
    atomically (admitAt queue (placement 2 0) (intention 0)) `shouldReturn` AdmittedAt (placement 2 0)
    atomically (admitAt queue (placement 2 0) (intention 0)) `shouldReturn` AtDuplicate
    atomically (admitAt queue (placement 2 1) (intention 0)) `shouldReturn` AtFull

  it "of a finite session answers closed on the UI's path once the last tick has started" $ do
    queue ← newQueue bounds (Just 2)
    _ ← atomically (seal queue)
    atomically (admitNext queue (intention 0)) `shouldReturn` AdmittedAt (placement 2 0)
    _ ← atomically (seal queue)
    atomically (nextUnstarted queue) `shouldReturn` 3
    atomically (admitNext queue (intention 1)) `shouldReturn` AtClosed
    -- What was accepted for tick two is still held until its settlement.
    atomically (reserved queue) `shouldReturn` 1
