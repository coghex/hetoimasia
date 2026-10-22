{-# LANGUAGE OverloadedStrings #-}

-- | The shared pool's workers seen from Lua: how many reads run at once and in what order, that a
-- finished read frees its worker while its result is still charged, and that completion order
-- never decides what a logical script sees.
module Test.LuaEngine.Data.Workers (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, tryReadMVar, readMVar)
import Control.Monad (forM_)
import qualified Data.ByteString as BS
import Data.List (elemIndex)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (..))
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..))
import Test.Hspec
import Test.LuaEngine.Data.Support

spec ∷ Spec
spec = describe "workers and timing" $ do
  pool
  timing
  ordering

layout ∷ Layout
layout = Layout [(name, BS.replicate 64 (fromIntegral n)) | (n, name) <- zip [1 ∷ Int ..] ["f1.bin", "f2.bin", "f3.bin", "f4.bin"]]

startAt ∷ Session → Vm → Text → Text → Text → Maybe Int → IO ()
startAt session vm name key path offset = do
  commandWith session vm name "start" key (Just (fetch path) {fetchOffset = offset, fetchOptional = True})
  _ ← lineStarting session ("cmd start " <> key <> " ")
  pure ()

-- | Ask whether the request is ready, tagged so each answer is its own line.
readyIs ∷ Session → Vm → Text → Text → Text → Bool → IO ()
readyIs session vm name key tag expected = do
  commandWith session vm name "ready" key (Just (fetch tag))
  awaitNote session ("cmd ready " <> key <> " " <> (if expected then "true" else "false") <> " #" <> tag)

pool ∷ Spec
pool = describe "the pool" $ do
  it "runs two reads at once, queues the third, starts it when one finishes, and frees a worker for a read while earlier results are still held and charged" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime → do
      vm ← startVm session runtime "pool" AtAssignedTick
      admitDriver session vm "i"
      let probe = ssProbe session
      mapM_ (closeGate probe) ["f1.bin", "f2.bin", "f3.bin"]
      startAt session vm "i" "a" "f1.bin" (Just 5)
      startAt session vm "i" "b" "f2.bin" (Just 5)
      startAt session vm "i" "c" "f3.bin" (Just 5)
      awaitStarted probe 2
      awaitPool session (\s → statusActive s == 2 && statusQueued s == 1)
      startedPaths probe >>= \started → started `shouldMatchList` ["f1.bin", "f2.bin"]
      openGate probe "f1.bin"
      awaitStarted probe 3
      startedPaths probe >>= \started → last started `shouldBe` "f3.bin"
      mapM_ (openGate probe) ["f2.bin", "f3.bin"]
      awaitPool session (\s → statusLive s == 0 && statusActive s == 0)
      maxActive probe `shouldReturn` 2
      -- Three results wait for tick 5, unseen; their bytes are still the VM's.
      charged vm `shouldReturn` 192
      readyIs session vm "i" "a" "early" False
      -- A fourth read runs on a freed worker while those results are held.
      startAt session vm "i" "d" "f4.bin" (Just 5)
      awaitStarted probe 4
      awaitPool session (\s → statusLive s == 0)
      charged vm `shouldReturn` 256
      forM_ [1 .. 5 ∷ Int] (const (grantOne control vm))
      mapM_
        ( \key → do
            command session vm "i" "wait_take" key
            line ← lineStarting session ("cmd wait_take " <> key <> " ")
            line `shouldSatisfy` Text.isInfixOf "status=success"
        )
        ["a", "b", "c", "d"]
      awaitCharged vm 0
      awaitPool session (\s → statusReserved s == 0)

timing ∷ Spec
timing = describe "assigned positions" $ do
  it "hides a finished read until its due tick: the default offset is one, an explicit offset is exact, an early failure waits too" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime → do
      vm ← startVm session runtime "due" AtAssignedTick
      admitDriver session vm "i"
      startAt session vm "i" "a" "f1.bin" Nothing
      startAt session vm "i" "b" "f2.bin" (Just 3)
      startAt session vm "i" "c" "missing.bin" (Just 2)
      awaitPool session (\s → statusLive s == 0)
      readyIs session vm "i" "a" "t0a" False
      readyIs session vm "i" "c" "t0c" False
      grantOne control vm
      readyIs session vm "i" "a" "t1a" True
      readyIs session vm "i" "b" "t1b" False
      readyIs session vm "i" "c" "t1c" False
      grantOne control vm
      readyIs session vm "i" "c" "t2c" True
      readyIs session vm "i" "b" "t2b" False
      grantOne control vm
      readyIs session vm "i" "b" "t3b" True

  it "fails a required instance at the due tick of a failure that arrived long before it, not at arrival" $
    withSession fixedM1Profile (1, 4) realReader layout $ \session control runtime → do
      vm ← startVm session runtime "late failure" AtAssignedTick
      admitDriver session vm "i"
      commandWith session vm "i" "start" "a" (Just (fetch "missing.bin") {fetchOffset = Just 2})
      awaitNote session "cmd start a started"
      awaitPool session (\s → statusLive s == 0)
      grantOne control vm
      (rdLatched <$> vmDiagnostics vm) `shouldReturn` 0
      grantOne control vm
      failure ← awaitFailure session "i"
      fmap fst (requestFailureOf failure) `shouldBe` Just "data"

  it "holds the due tick until a slow read completes, then runs it" $
    withSession fixedM1Profile (1, 4) realReader layout $ \session control runtime → do
      vm ← startVm session runtime "slow" AtAssignedTick
      admitDriver session vm "i"
      closeGate (ssProbe session) "f1.bin"
      startAt session vm "i" "a" "f1.bin" Nothing
      awaitStarted (ssProbe session) 1
      finished ← newEmptyMVar
      _ ← forkIO (grantOne control vm >> putMVar finished ())
      -- The grant that would reach tick one is held while the read is outstanding.
      awaitVmDiagnostic vm (\d → rdAdmitted d == 1)
      tryReadMVar finished `shouldReturn` Nothing
      openGate (ssProbe session) "f1.bin"
      readMVar finished
      readyIs session vm "i" "a" "after" True

  it "settles on arrival for an owner on elapsed time, and refuses a tick offset there before any work" $
    withSession fixedM1Profile (1, 4) realReader layout $ \session _ runtime → do
      vm ← startVm session runtime "arrival" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "f1.bin"
      startAt session vm "i" "a" "f1.bin" Nothing
      awaitStarted (ssProbe session) 1
      readyIs session vm "i" "a" "pending" False
      openGate (ssProbe session) "f1.bin"
      command session vm "i" "wait_take" "a"
      line ← lineStarting session "cmd wait_take a "
      line `shouldSatisfy` Text.isInfixOf "status=success"
      commandWith session vm "i" "pstart" "b" (Just (fetch "f2.bin") {fetchOffset = Just 2})
      refused ← lineStarting session "cmd pstart b "
      refused `shouldSatisfy` Text.isPrefixOf "cmd pstart b error data.fetch: request refused"
      readsStarted (ssProbe session) `shouldReturn` 1

ordering ∷ Spec
ordering = describe "completion order" $
  it "never decides the order a logical script sees: of two reads that finish in reverse, the one asked first is delivered first" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime → do
      vm ← startVm session runtime "order" AtAssignedTick
      admitDriver session vm "i"
      admitDriver session vm "j"
      closeGate (ssProbe session) "f1.bin"
      startAt session vm "i" "a" "f1.bin" Nothing
      startAt session vm "j" "b" "f2.bin" Nothing
      command session vm "i" "wait_take" "a"
      command session vm "j" "wait_take" "b"
      awaitNote session "waiting a"
      awaitNote session "waiting b"
      -- The later request's read finishes first; the earlier one's after.
      awaitPool session (\s → statusLive s == 1)
      openGate (ssProbe session) "f1.bin"
      awaitPool session (\s → statusLive s == 0)
      grantOne control vm
      _ ← lineStarting session "cmd wait_take a "
      _ ← lineStarting session "cmd wait_take b "
      seen ← history session
      let at prefix = elemIndex True (map (Text.isPrefixOf prefix) seen)
      (at "cmd wait_take a ", at "cmd wait_take b") `shouldSatisfy` (\(first, second) → first < second)
