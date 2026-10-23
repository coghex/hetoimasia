{-# LANGUAGE OverloadedStrings #-}

-- | Cancellation, retirement and teardown of data requests: the windows between a queued job and its
-- issuance, a read and its publication, an early logical result and a cancel; instances and VMs that
-- end while their reads are outstanding; and a pool that is down when a request is handed to it.
-- Every race is gated, never slept.
module Test.LuaEngine.Data.Lifecycle (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, fromException, rethrowIO, tryWithContext)
import qualified Data.ByteString as BS
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool (PoolStatus (..))
import Hetoimasia.LuaEngine.Profile (CountLimit (..), fixedM1Profile)
import Hetoimasia.Scripting.Lua.Instance (InstanceTicket, pollInstance, waitInstance)
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..))
import Hetoimasia.Scripting.Lua.Provider (Completion (..), RequestEndpoint (..), Submission (..))
import Hetoimasia.Scripting.Lua.Scheduled (retireScheduled)
import Test.Hspec
import Test.LuaEngine.Data.Support
import Test.LuaEngine.Request.Profiles (counts)

spec ∷ Spec
spec = describe "lifecycle" $ do
  cancelling
  teardown
  failing

layout ∷ Layout
layout = Layout [(name, BS.replicate 64 (fromIntegral n)) | (n, name) <- zip [1 ∷ Int ..] ["f1.bin", "f2.bin", "f3.bin", "f4.bin"]]

start ∷ Session → Vm → Text → Text → Text → Maybe Int → IO ()
start session vm name key path offset = do
  commandWith session vm name "start" key (Just (fetch path) {fetchOffset = offset, fetchOptional = True})
  awaitNote session ("cmd start " <> key <> " started")

cancelling ∷ Spec
cancelling = describe "cancelling" $ do
  it "withdraws a queued read before issuance and keeps a read in progress charged until it has actually retired" $
    withSession fixedM1Profile (1, 8) realReader layout $ \session _ runtime → do
      vm ← startVm session runtime "cancel" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "f1.bin"
      start session vm "i" "a" "f1.bin" Nothing
      awaitStarted (ssProbe session) 1
      start session vm "i" "b" "f2.bin" Nothing
      command session vm "i" "cancel" "b"
      awaitNote session "cmd cancel b cancelled"
      -- The cancellation is a result to take; once it is taken, and the withdrawn job has retired,
      -- the queued read's bytes and slot come back at the owner's boundary. No file was opened.
      command session vm "i" "take" "b"
      awaitNote session "cmd take b {status=cancelled}"
      awaitCharged vm 64
      startedBefore ← startedPaths (ssProbe session)
      startedBefore `shouldBe` ["f1.bin"]
      -- The read in progress is cancelled too: that is no evidence it ended.
      command session vm "i" "cancel" "a"
      awaitNote session "cmd cancel a cancelled"
      command session vm "i" "take" "a"
      awaitNote session "cmd take a {status=cancelled}"
      charged vm `shouldReturn` 64
      (rdHeld <$> vmDiagnostics vm) `shouldReturn` 1
      poolReading session >>= \reading → (statusActive reading, statusReserved reading) `shouldBe` (1, 1)
      openGate (ssProbe session) "f1.bin"
      awaitCharged vm 0
      awaitPool session (\s → statusReserved s == 0 && statusLive s == 0)
      awaitVmDiagnostic vm (\d → rdHeld d == 0)
      readsStarted (ssProbe session) `shouldReturn` 1

  it "lets a cancel before the due tick win over an early finished result, discarding it, freeing the tick, and returning its bytes" $
    withSession fixedM1Profile (1, 4) realReader layout $ \session control runtime → do
      vm ← startVm session runtime "early" AtAssignedTick
      admitDriver session vm "i"
      start session vm "i" "a" "f1.bin" (Just 3)
      awaitPool session (\s → statusLive s == 0 && statusActive s == 0)
      charged vm `shouldReturn` 64
      command session vm "i" "cancel" "a"
      awaitNote session "cmd cancel a cancelled"
      command session vm "i" "take" "a"
      awaitNote session "cmd take a {status=cancelled}"
      awaitCharged vm 0
      -- The tick it would have held begins at once.
      grantOne control vm

  it "returns the bytes only after the result was taken and the work retired, whichever the order, and keeps the taken string" $
    withSession fixedM1Profile (1, 4) realReader layout $ \session _ runtime → do
      vm ← startVm session runtime "release" OnArrival
      admitDriver session vm "i"
      start session vm "i" "a" "f1.bin" Nothing
      awaitPool session (\s → statusLive s == 0 && statusActive s == 0)
      -- Retired and settled, but not taken: still charged.
      charged vm `shouldReturn` 64
      poolReading session >>= \reading → statusReserved reading `shouldBe` 1
      command session vm "i" "keep" "a"
      awaitNote session "cmd keep a {status=success,value=bytes(64)=010101010101010101010101010101010101010101010101}"
      awaitCharged vm 0
      awaitPool session (\s → statusReserved s == 0)
      command session vm "i" "kept" "a"
      awaitNote session "cmd kept a bytes(64)=010101010101010101010101010101010101010101010101"

  it "accounts a taken result at the owner's boundary even while its worker is still inside the sink: the claim on the slot has ended, retirement is the worker's own (a wrapper holds the worker after the reply was accepted)" $
    withSession fixedM1Profile (1, 2) realReader layout $ \session _ runtime → do
      let holding endpoint =
            endpoint
              { endpointSubmit = \submission →
                  endpointSubmit
                    endpoint
                    submission
                      { submissionCompletion = Completion $ \reply → do
                          answer ← completeRequest (submissionCompletion submission) reply
                          note session "published"
                          holdUntilReleased session "worker" >> pure answer
                      }
              }
      vm ← startVmWith session holding runtime "held worker" OnArrival
      admitDriver session vm "i"
      start session vm "i" "a" "f1.bin" Nothing
      awaitNote session "published"
      -- The reply was accepted and the worker is held inside the sink: the request can be taken.
      command session vm "i" "wait_take" "a"
      line ← lineStarting session "cmd wait_take a "
      line `shouldSatisfy` textInfix "status=success"
      -- The bytes and the slot are accounted at the owner's boundary though the job is not done.
      awaitCharged vm 0
      awaitPool session (\s → statusReserved s == 0 && statusActive s == 1 && statusLive s == 0)
      releaseHeld session "worker"
      awaitPool session (\s → statusActive s == 0)

  it "still completes and cancels with every place of the instance held: completions need no free request slot" $
    withSession (counts [(RequestsPerInstance, 2)]) (1, 4) realReader layout $ \session _ runtime → do
      vm ← startVm session runtime "full" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "f1.bin"
      closeGate (ssProbe session) "f2.bin"
      start session vm "i" "a" "f1.bin" Nothing
      start session vm "i" "b" "f2.bin" Nothing
      commandWith session vm "i" "start" "c" (Just (fetch "f3.bin"))
      _ ← lineStarting session "cmd start c busy"
      openGate (ssProbe session) "f1.bin"
      openGate (ssProbe session) "f2.bin"
      command session vm "i" "wait_take" "a"
      line ← lineStarting session "cmd wait_take a "
      line `shouldSatisfy` textInfix "status=success"
      -- b has settled too before it is cancelled: nothing orders its read against a's take.
      command session vm "i" "wait" "b"
      awaitNote session "cmd wait b 0"
      command session vm "i" "cancel" "b"
      awaitNote session "cmd cancel b already_settled"

teardown ∷ Spec
teardown = describe "teardown" $ do
  it "keeps a stopping instance waiting for its read to retire, then returns its bytes and leaves its peer's alone" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session _ runtime → do
      vm ← startVm session runtime "share" OnArrival
      admitDriver session vm "i"
      admitDriver session vm "j"
      closeGate (ssProbe session) "f1.bin"
      start session vm "i" "a" "f1.bin" Nothing
      awaitStarted (ssProbe session) 1
      start session vm "i" "b" "f2.bin" Nothing
      start session vm "j" "c" "f3.bin" Nothing
      awaitPool session (\s → statusLive s == 1)
      charged vm `shouldReturn` 192
      stopInstance session vm "i"
      ticket ← instanceTicket session "i"
      -- Its read is still inside the reader: the instance has not settled.
      awaitVmDiagnostic vm (\d → rdHeld d >= 1)
      pollInstance ticket >>= (`shouldSatisfy` isNothing)
      charged vm `shouldReturn` 192
      -- What the work of a request borrowed is disposed of once that work is over: the two finished
      -- requests' disposals have run, and the disposal of the read still inside the reader has not.
      awaitHistory session (\seen → length (filter (== "disposed") seen) >= 2)
      length . filter (== "disposed") <$> history session `shouldReturn` 2
      openGate (ssProbe session) "f1.bin"
      awaitSettled ticket
      awaitHistory session (\seen → length (filter (== "disposed") seen) == 3)
      -- The instance's pending and unconsumed data are gone; its peer's result is untouched.
      awaitCharged vm 64
      command session vm "j" "wait_take" "c"
      line ← lineStarting session "cmd wait_take c "
      line `shouldSatisfy` textInfix "status=success"
      awaitCharged vm 0
      awaitPool session (\s → statusReserved s == 0)

  it "retires one VM with results outstanding while the other VM and the shared pool carry on, each bank its own" $
    withSession fixedM1Profile (2, 8) realReader layout $ \session control runtime → do
      first ← startVm session runtime "first" OnArrival
      second ← startVm session runtime "second" OnArrival
      admitDriver session first "i"
      admitDriver session second "j"
      start session first "i" "a" "f1.bin" Nothing
      start session second "j" "b" "f2.bin" Nothing
      awaitPool session (\s → statusLive s == 0 && statusActive s == 0)
      (,) <$> charged first <*> charged second `shouldReturn` (64, 64)
      retireScheduled (vmOwner first)
      _ ← awaitEnd control first
      awaitCharged first 0
      charged second `shouldReturn` 64
      -- The pool still serves the other VM, and the other VM's result is intact.
      start session second "j" "c" "f3.bin" Nothing
      command session second "j" "wait_take" "c"
      line ← lineStarting session "cmd wait_take c "
      line `shouldSatisfy` textInfix "status=success"
      command session second "j" "wait_take" "b"
      awaitNote session "cmd wait_take b {status=success,value=bytes(64)=020202020202020202020202020202020202020202020202}"
      awaitCharged second 0
      awaitPool session (\s → statusReserved s == 0 && not (statusFailed s))

  it "releases each owned record once however often the owner is stopped" $
    withSession fixedM1Profile (1, 4) realReader layout $ \session control runtime → do
      vm ← startVm session runtime "twice" OnArrival
      admitDriver session vm "i"
      start session vm "i" "a" "f1.bin" Nothing
      awaitPool session (\s → statusLive s == 0 && statusActive s == 0)
      retireScheduled (vmOwner vm)
      retireScheduled (vmOwner vm)
      _ ← awaitEnd control vm
      awaitCharged vm 0
      awaitPool session (\s → statusReserved s == 0)
      retireScheduled (vmOwner vm)
      charged vm `shouldReturn` 0
      poolReading session >>= \reading → statusReserved reading `shouldBe` 0

failing ∷ Spec
failing = describe "a pool that is down" $
  it "takes a request back whole when the pool refuses it: no byte, no slot and no hold is left, and the engine failure is not turned into content" $ do
    ExceptionWithContext _ failure ← fatalSession fixedM1Profile (1, 4) (injectedDefect ["f1.bin"] (userError "injected reader defect")) layout $ \session control runtime → do
      broken ← startVm session runtime "broken" OnArrival
      healthy ← startVm session runtime "healthy" OnArrival
      admitDriver session broken "i"
      admitDriver session healthy "j"
      -- A read whose interest was withdrawn raises (injected): its sink is suppressed, so no owner
      -- is told, but the pool latches the defect and refuses everything after it.
      closeGate (ssProbe session) "f1.bin"
      start session broken "i" "a" "f1.bin" Nothing
      awaitStarted (ssProbe session) 1
      command session broken "i" "cancel" "a"
      awaitNote session "cmd cancel a cancelled"
      openGate (ssProbe session) "f1.bin"
      awaitPool session statusFailed
      commandWith session healthy "j" "start" "b" (Just (fetch "f2.bin"))
      -- The handoff of the healthy VM's request failed: it was taken back whole, so nothing of it
      -- is charged and no slot is held.
      -- The owner ends in the host's failure, which supervision raises at its wait.
      ended ← tryWithContext @SomeException (awaitEnd control healthy)
      raised ← case ended of
        Left found → pure found
        Right _ → expectationFailure "the owner should have ended in a failure" >> error "unreachable"
      awaitCharged healthy 0
      awaitPool session (\s → statusReserved s == 0 && statusFailed s)
      awaitVmDiagnostic healthy (\d → rdHeld d == 0)
      rethrowIO raised
    (fromException failure ∷ Maybe PoolRefusal) `shouldSatisfy` isJust

textInfix ∷ Text → Text → Bool
textInfix = Text.isInfixOf

awaitSettled ∷ InstanceTicket → IO ()
awaitSettled ticket = () <$ waitInstance ticket
