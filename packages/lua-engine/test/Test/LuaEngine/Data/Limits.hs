{-# LANGUAGE OverloadedStrings #-}

-- | The byte bank and the data ceiling: each limit at its edge and one past, busy that does no file
-- work and leaks nothing, requests that fail without payload while the bank is full, concurrent
-- admissions that cannot overbook, checked arithmetic, files that change before they are read, and
-- the fixed profile's exact 8 MiB.
module Test.LuaEngine.Data.Limits (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException, tryWithContext, SomeException)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (..))
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), Profile, fixedM1Profile)
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..))
import Test.Hspec
import Test.LuaEngine.Data.Support
import Test.LuaEngine.Request.Profiles (bytesOf)

spec ∷ Spec
spec = describe "limits" $ do
  bank
  ceiling'
  changing
  eightMiB

-- | 64 bytes of data per file, 128 retained per VM; the copied-value ceiling leaves room for the
-- record around a result.
small ∷ Profile
small = bytesOf [(DataBytes, 64), (RetainedDataBytesPerVm, 128), (CopiedValueBytes, 512), (SceneInputBytes, 256)]

files ∷ Layout
files =
  Layout
    [ ("f1.bin", BS.replicate 64 1)
    , ("f2.bin", BS.replicate 64 2)
    , ("f3.bin", BS.replicate 64 3)
    , ("at.bin", BS.replicate 64 4)
    , ("over.bin", BS.replicate 65 5)
    , ("empty.bin", "")
    ]

startKey ∷ Session → Vm → Text → Text → IO ()
startKey session vm key path = do
  commandWith session vm "i" "start" key (Just (fetch path) {fetchOptional = True})
  _ ← lineStarting session ("cmd start " <> key <> " ")
  pure ()

bank ∷ Spec
bank = describe "the byte bank" $ do
  it "answers busy naming the bank when the next file does not fit, doing no file work and leaving nothing reserved; a later call succeeds" $
    withSession small (2, 8) realReader files $ \session _ runtime → do
      vm ← startVm session runtime "bank" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "f1.bin"
      closeGate (ssProbe session) "f2.bin"
      startKey session vm "a" "f1.bin"
      startKey session vm "b" "f2.bin"
      awaitStarted (ssProbe session) 2
      charged vm `shouldReturn` 128
      reserved0 ← poolReading session
      startKey session vm "c" "f3.bin"
      line ← lineStarting session "cmd start c "
      line `shouldBe` "cmd start c busy:busy:request capacity is not available: the provider has no room in data bytes"
      -- No third read, no byte or slot kept, and the busy was no failure of the instance.
      readsStarted (ssProbe session) `shouldReturn` 2
      charged vm `shouldReturn` 128
      reserved1 ← poolReading session
      (statusReserved reserved1, statusQueued reserved1) `shouldBe` (statusReserved reserved0, statusQueued reserved0)
      d ← vmDiagnostics vm
      (rdBusy d, rdLatched d) `shouldBe` (1, 0)
      -- Taking a result and its provider retiring gives the bytes back; the same call now works.
      openGate (ssProbe session) "f1.bin"
      command session vm "i" "wait_take" "a"
      _ ← lineStarting session "cmd wait_take a "
      awaitCharged vm 64
      startKey session vm "d" "f3.bin"
      awaitNote session "cmd start d started"

  it "accepts a missing path and an oversized file while the bank is full, failing them without a worker, a read or a byte" $
    withSession small (2, 8) realReader files $ \session _ runtime → do
      vm ← startVm session runtime "full" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "f1.bin"
      closeGate (ssProbe session) "f2.bin"
      startKey session vm "a" "f1.bin"
      startKey session vm "b" "f2.bin"
      awaitStarted (ssProbe session) 2
      mapM_
        ( \(key, path, code) → do
            startKey session vm key path
            awaitNote session ("cmd start " <> key <> " started")
            command session vm "i" "wait_take" key
            line ← lineStarting session ("cmd wait_take " <> key)
            line `shouldSatisfy` Text.isInfixOf ("code=" <> code)
        )
        [("m", "missing.bin", "not_found"), ("o", "over.bin", "too_large")]
      readsStarted (ssProbe session) `shouldReturn` 2
      charged vm `shouldReturn` 128

  it "charges nothing but a record for a zero-byte file, which still takes a queue slot" $
    withSession small (1, 1) realReader files $ \session _ runtime → do
      vm ← startVm session runtime "zero" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "empty.bin"
      startKey session vm "a" "empty.bin"
      awaitStarted (ssProbe session) 1
      charged vm `shouldReturn` 0
      poolReading session >>= \reading → statusReserved reading `shouldBe` 1
      -- The one slot is taken: the next read is busy on the queue, not on bytes.
      startKey session vm "b" "f1.bin"
      line ← lineStarting session "cmd start b "
      line `shouldBe` "cmd start b busy:busy:request capacity is not available: the provider has no room in io queue"

  it "cannot be overbooked by VMs asking at once: of two requests for the pool's one slot exactly one is accepted and the other leaves no byte charged" $
    withSession small (1, 1) realReader files $ \session _ runtime → do
      first ← startVm session runtime "first" OnArrival
      second ← startVm session runtime "second" OnArrival
      admitDriver session first "i"
      admitDriver session second "j"
      closeGate (ssProbe session) "f1.bin"
      closeGate (ssProbe session) "f2.bin"
      commandWith session first "i" "start" "a" (Just (fetch "f1.bin") {fetchOptional = True})
      commandWith session second "j" "start" "b" (Just (fetch "f2.bin") {fetchOptional = True})
      _ ← lineStarting session "cmd start a "
      _ ← lineStarting session "cmd start b "
      seen ← history session
      let started = length [() | line ← seen, line `elem` ["cmd start a started", "cmd start b started"]]
          busy = length [() | line ← seen, Text.isInfixOf "busy:busy:" line]
      (started, busy) `shouldBe` (1, 1)
      total ← (+) <$> charged first <*> charged second
      total `shouldBe` 64

  it "checks its arithmetic: a request larger than the room left is refused without wrapping, and a return of more than was charged is a defect" $
    withSession small (1, 1) realReader files $ \session _ runtime → do
      vm ← startVm session runtime "arith" OnArrival
      let account = vmBank vm
      atomically (reserveBytes account 100) `shouldReturn` True
      atomically (reserveBytes account maxBound) `shouldReturn` False
      atomically (reserveBytes account 29) `shouldReturn` False
      atomically (reserveBytes account 28) `shouldReturn` True
      atomically (byteBankCharged account) `shouldReturn` 128
      atomically (returnBytes account 128)
      outcome ← tryWithContext @SomeException (atomically (returnBytes account 1))
      case outcome of
        Left (ExceptionWithContext _ failure) → (fromException failure ∷ Maybe ByteBankDefect) `shouldSatisfy` (/= Nothing)
        Right () → expectationFailure "returning bytes that were not charged should be a defect"

ceiling' ∷ Spec
ceiling' = describe "the data ceiling" $ do
  it "returns a file of exactly the ceiling and fails one byte over as too_large, with the sizes in the message, never truncated" $
    withSession small (1, 4) realReader files $ \session _ runtime → do
      vm ← startVm session runtime "ceiling" OnArrival
      admitDriver session vm "i"
      startKey session vm "a" "at.bin"
      awaitNote session "cmd start a started"
      command session vm "i" "length" "a"
      awaitNote session "cmd length a success 64 04040404 04040404"
      startKey session vm "b" "over.bin"
      awaitNote session "cmd start b started"
      command session vm "i" "wait_take" "b"
      awaitNote session "cmd wait_take b {error={code=too_large,message=the file is 65 bytes, over the data limit of 64,path=over.bin,root=data-test},status=failure}"
      readsStarted (ssProbe session) `shouldReturn` 1

changing ∷ Spec
changing = describe "a file that changes before its read" $ do
  it "is content_changed when it grew or changed after the job was queued, and nothing partial reaches Lua" $
    withSession small (1, 4) realReader files $ \session _ runtime → do
      vm ← startVm session runtime "changing" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "f1.bin"
      closeGate (ssProbe session) "f2.bin"
      startKey session vm "a" "f1.bin"
      startKey session vm "b" "f2.bin"
      awaitStarted (ssProbe session) 1
      rewrite session "f1.bin" (BS.replicate 65 9)
      rewrite session "f2.bin" (BS.replicate 64 9)
      openGate (ssProbe session) "f1.bin"
      openGate (ssProbe session) "f2.bin"
      command session vm "i" "wait_take" "a"
      command session vm "i" "wait_take" "b"
      a ← lineStarting session "cmd wait_take a "
      b ← lineStarting session "cmd wait_take b "
      a `shouldSatisfy` Text.isInfixOf "code=content_changed,message=the length changed from 64 to 65"
      b `shouldSatisfy` Text.isInfixOf "code=content_changed,message=the bytes are not the ones the inventory pinned"
      mapM_ (\line -> line `shouldSatisfy` (not . Text.isInfixOf "value=")) [a, b]
      awaitCharged vm 0

eightMiB ∷ Spec
eightMiB = describe "the fixed profile's 8 MiB" $ do
  it "delivers exactly 8 MiB inside the 16 MiB crossing, and refuses one byte more as too_large" $ do
    let eight = 8 * 1024 * 1024
        content = BS.concat [BS.pack [1, 2, 3, 4], BS.replicate (eight - 8) 7, BS.pack [5, 6, 7, 8]]
    withSession fixedM1Profile (2, 8) realReader (Layout [("big.bin", content), ("bigger.bin", content <> "x")]) $ \session _ runtime → do
      vm ← startVm session runtime "eight" OnArrival
      admitDriver session vm "i"
      startKey session vm "a" "big.bin"
      awaitNote session "cmd start a started"
      command session vm "i" "length" "a"
      awaitNote session "cmd length a success 8388608 01020304 05060708"
      startKey session vm "b" "bigger.bin"
      awaitNote session "cmd start b started"
      command session vm "i" "wait_take" "b"
      line ← lineStarting session "cmd wait_take b "
      line `shouldSatisfy` Text.isInfixOf "code=too_large"
      awaitCharged vm 0
