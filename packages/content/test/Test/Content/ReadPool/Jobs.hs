-- | The read pool's jobs: the exact bytes it returns, the bounds on what runs at once and in what
-- order, the slot reservations that bound its queue, and the transitions of a job under cancel.
--
-- Real temporary trees and the production verified reader throughout. Where a read is gated, the
-- gate wraps the real reader, so the file is still opened and hashed once the gate opens.
module Test.Content.ReadPool.Jobs (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Hetoimasia.Content.Inventory (ReadOutcome (..), readVerified)
import Hetoimasia.Content.Internal.Pool (PoolHooks (..), noHooks, withPoolWith)
import Hetoimasia.Content.Internal.Types (ContentDefect (..), Defect (..))
import Hetoimasia.Content.ReadPool
import Test.Content.ReadPool.Support
import Test.Content.Support (failsWith)
import Test.Hspec

spec ∷ Spec
spec = do
  bytes
  bounds
  order
  slots
  cancelling

-- The bytes -------------------------------------------------------------------------------

samples ∷ [(FilePath, ByteString)]
samples =
  [ ("empty.bin", "")
  , ("nul.bin", BS.pack [0x61, 0x00, 0x62, 0x00])
  , ("not-utf8.bin", BS.pack [0xff, 0xfe, 0x80, 0xc0, 0xaf])
  , ("bom.txt", BS.pack [0xef, 0xbb, 0xbf] <> "hi")
  , ("lines.txt", "a\r\nb\rc\nd\n\r")
  ]

bytes ∷ Spec
bytes = describe "the bytes" $ do
  it "returns each file's exact bytes, whole, through a real verified read" $
    withRealPool (poolOf 2 8) samples $ \inventory pool → do
      outcomes ← newOutcomes
      forM_ samples $ \(path, _) → do
        ticket ← accepted pool (request inventory outcomes OrdinaryRead 4096 (pathBytes path))
        awaitRetired ticket
      seen ← awaitOutcomes outcomes (length samples)
      forM_ samples $ \(path, content) →
        lookup (pathBytes path) seen `shouldBe` Just (SeenBytes content)

  it "repeats the read for every request of the same path and keeps no copy" $ do
    probe ← newProbe
    withInventory [("same.bin", "payload")] $ \root inventory →
      withReadPoolUsing (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        forM_ [1 .. 3 ∷ Int] $ \_ → do
          _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "same.bin")
          pure ()
        seen ← awaitOutcomes outcomes 3
        map snd seen `shouldBe` replicate 3 (SeenBytes "payload")
        readsStarted probe `shouldReturn` 3

-- The bounds -------------------------------------------------------------------------------

bounds ∷ Spec
bounds = describe "the allowance" $ do
  it "refuses a file over the allowance from the inventory, before any read starts" $ do
    probe ← newProbe
    withInventory [("big.bin", BS.replicate 100 7)] $ \root inventory →
      withReadPoolUsing (poolOf 1 2) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        _ ← accepted pool (request inventory outcomes OrdinaryRead 99 "big.bin")
        seen ← awaitOutcomes outcomes 1
        map snd seen `shouldBe` [SeenRefused (ReadTooLarge 100 99)]

  it "returns a file exactly at the allowance, whole" $
    withRealPool (poolOf 1 2) [("edge.bin", BS.replicate 100 7)] $ \inventory pool → do
      outcomes ← newOutcomes
      _ ← accepted pool (request inventory outcomes OrdinaryRead 100 "edge.bin")
      seen ← awaitOutcomes outcomes 1
      map snd seen `shouldBe` [SeenBytes (BS.replicate 100 7)]

  it "answers an absent path as not found without opening anything" $
    withRealPool (poolOf 1 2) [("here.bin", "x")] $ \inventory pool → do
      outcomes ← newOutcomes
      _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "gone.bin")
      seen ← awaitOutcomes outcomes 1
      map snd seen `shouldBe` [SeenRefused ReadNotFound]

-- The order -------------------------------------------------------------------------------

order ∷ Spec
order = describe "what runs, and when" $ do
  it "runs at most the configured number of reads at once and starts the oldest queued job next" $ do
    probe ← newProbe
    mapM_ (closeGate probe) ["a.bin", "b.bin"]
    withInventory [("a.bin", "a"), ("b.bin", "b"), ("c.bin", "c")] $ \root inventory →
      withReadPoolUsing (poolOf 2 4) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        mapM_ (\path → accepted pool (request inventory outcomes OrdinaryRead 64 path)) ["a.bin", "b.bin", "c.bin"]
        awaitStarted probe 2
        awaitStatus pool (\s → statusActive s == 2 && statusQueued s == 1)
        startedPaths probe >>= \started → started `shouldMatchList` ["a.bin", "b.bin"]
        openGate probe "a.bin"
        awaitStarted probe 3
        startedPaths probe >>= \started → last started `shouldBe` "c.bin"
        openGate probe "b.bin"
        _ ← awaitOutcomes outcomes 3
        maxActive probe `shouldReturn` 2

  it "starts dependency progress ahead of unrelated work, each class oldest first" $ do
    probe ← newProbe
    closeGate probe "block.bin"
    withInventory [(path, "x") | path ← ["block.bin", "o1.bin", "o2.bin", "d1.bin", "d2.bin"]] $ \root inventory →
      withReadPoolUsing (poolOf 1 8) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "block.bin")
        awaitStarted probe 1
        _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "o1.bin")
        _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "o2.bin")
        _ ← accepted pool (request inventory outcomes DependencyProgress 64 "d1.bin")
        _ ← accepted pool (request inventory outcomes DependencyProgress 64 "d2.bin")
        openGate probe "block.bin"
        _ ← awaitOutcomes outcomes 5
        startedPaths probe `shouldReturn` ["block.bin", "d1.bin", "d2.bin", "o1.bin", "o2.bin"]

  it "frees the execution slot once the result is handed over, whether or not anyone consumes it" $
    withRealPool (poolOf 1 4) [("first.bin", "1"), ("second.bin", "2")] $ \inventory pool → do
      outcomes ← newOutcomes
      _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "first.bin")
      _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "second.bin")
      seen ← awaitOutcomes outcomes 2
      map snd seen `shouldBe` [SeenBytes "1", SeenBytes "2"]
      -- Both slots are still the consumer's: nothing returned them.
      awaitStatus pool (\s → statusReserved s == 2 && statusLive s == 0 && statusActive s == 0)

-- The slots ---------------------------------------------------------------------------------

slots ∷ Spec
slots = describe "the slot reservations" $ do
  it "hands out exactly the configured capacity and takes a released unit back" $
    withRealPool (poolOf 1 2) [] $ \_ pool → do
      first ← atomically (reserveSlot pool)
      second ← atomically (reserveSlot pool)
      third ← atomically (reserveSlot pool)
      (first, second, third) `shouldBe` (True, True, False)
      atomically (releaseSlot pool)
      atomically (reserveSlot pool) `shouldReturn` True

  it "refuses a job with no reserved slot as a defect, leaving nothing queued" $
    withRealPool (poolOf 1 2) [("a.bin", "a")] $ \inventory pool → do
      outcomes ← newOutcomes
      ExceptionWithContext _ failure ← failsWith (atomically (submit pool (request inventory outcomes OrdinaryRead 64 "a.bin")))
      failure `shouldBe` ContentDefect ReadSubmittedWithoutSlot
      reading ← atomically (status pool)
      (statusQueued reading, statusLive reading) `shouldBe` (0, 0)

  it "refuses a negative allowance as a defect" $
    withRealPool (poolOf 1 2) [("a.bin", "a")] $ \inventory pool → do
      outcomes ← newOutcomes
      _ ← atomically (reserveSlot pool)
      ExceptionWithContext _ failure ← failsWith (atomically (submit pool (request inventory outcomes OrdinaryRead (-1) "a.bin")))
      failure `shouldBe` ContentDefect (BadReadCeiling (-1))

  it "refuses to release a slot a live job still needs, and more slots than were reserved" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    withInventory [("a.bin", "a")] $ \root inventory →
      withReadPoolUsing (poolOf 1 2) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        ticket ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
        ExceptionWithContext _ live ← failsWith (atomically (releaseSlot pool))
        live `shouldBe` ContentDefect ReadSlotReleasedWhileLive
        openGate probe "a.bin"
        awaitRetired ticket
        atomically (releaseSlot pool)
        ExceptionWithContext _ extra ← failsWith (atomically (releaseSlot pool))
        extra `shouldBe` ContentDefect ReadSlotReleasedWhileLive

-- Cancelling -------------------------------------------------------------------------------

cancelling ∷ Spec
cancelling = describe "withdrawing interest" $ do
  it "withdraws a queued job without opening a file and never calls its sink" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    withInventory [("a.bin", "a"), ("b.bin", "b")] $ \root inventory →
      withReadPoolUsing (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        _ ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
        awaitStarted probe 1
        queued ← accepted pool (request inventory outcomes OrdinaryRead 64 "b.bin")
        atomically (cancel queued) `shouldReturn` CancelWithdrawn
        atomically (retired queued) `shouldReturn` True
        atomically (cancel queued) `shouldReturn` CancelTooLate
        openGate probe "a.bin"
        _ ← awaitOutcomes outcomes 1
        awaitStatus pool (\s → statusLive s == 0)
        startedPaths probe `shouldReturn` ["a.bin"]
        map fst <$> seenOutcomes outcomes `shouldReturn` ["a.bin"]

  it "lets a read already started run to its end and suppresses its sink" $ do
    probe ← newProbe
    closeGate probe "a.bin"
    withInventory [("a.bin", "a")] $ \root inventory →
      withReadPoolUsing (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        running ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
        awaitStarted probe 1
        atomically (cancel running) `shouldReturn` CancelInFlight
        atomically (retired running) `shouldReturn` False
        openGate probe "a.bin"
        awaitRetired running
        seenOutcomes outcomes `shouldReturn` []
        atomically (cancel running) `shouldReturn` CancelTooLate

  it "skips the read when interest is withdrawn after issuance and before anything is opened" $ do
    probe ← newProbe
    issued ← newGate
    let hooks = noHooks {hookIssued = \_ → holdAt issued}
    withInventory [("a.bin", "a")] $ \root inventory →
      withPoolWith hooks (poolOf 1 4) (probeReader probe (readVerified inventory root)) $ \pool → do
        outcomes ← newOutcomes
        ticket ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
        awaitHeld issued
        atomically (cancel ticket) `shouldReturn` CancelInFlight
        releaseGate issued
        awaitRetired ticket
        readsStarted probe `shouldReturn` 0
        seenOutcomes outcomes `shouldReturn` []

  it "suppresses the sink for a read verified before interest was withdrawn and before publication" $ do
    published ← newGate
    let hooks = noHooks {hookRead = \_ → holdAt published}
    withInventory [("a.bin", "a")] $ \root inventory →
      withPoolWith hooks (poolOf 1 4) (readVerified inventory root) $ \pool → do
        outcomes ← newOutcomes
        ticket ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
        awaitHeld published
        atomically (cancel ticket) `shouldReturn` CancelInFlight
        releaseGate published
        awaitRetired ticket
        seenOutcomes outcomes `shouldReturn` []

  it "delivers the same read when interest is not withdrawn" $ do
    published ← newGate
    let hooks = noHooks {hookRead = \_ → holdAt published}
    withInventory [("a.bin", "a")] $ \root inventory →
      withPoolWith hooks (poolOf 1 4) (readVerified inventory root) $ \pool → do
        outcomes ← newOutcomes
        ticket ← accepted pool (request inventory outcomes OrdinaryRead 64 "a.bin")
        awaitHeld published
        releaseGate published
        awaitRetired ticket
        map snd <$> seenOutcomes outcomes `shouldReturn` [SeenBytes "a"]
