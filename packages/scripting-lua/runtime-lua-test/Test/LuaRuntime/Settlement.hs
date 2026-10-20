-- | Dispatch and settlement: calls run one at a time, in admission order, and
-- every accepted call settles exactly once, a fault of the call as data.
module Test.LuaRuntime.Settlement (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Support

spec ∷ Spec
spec = describe "dispatch and settlement" $ do
  it "runs accepted calls in admission order, one at a time" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "ordered" ["app"])
      tickets ← forM [0 .. 11 ∷ Int] $ \n →
        submit (ownerEndpoint owner) "note" [VText (Text.pack (show n))] >>= accepted
      forM_ tickets settle
      noted fixture >>= (`shouldBe` map (Text.pack . show) [0 .. 11 ∷ Int])
      retireOwner owner

  it "answers what an entry point returned, and answers an absent optional entry point as absent" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "answers" ["app"])
      let endpoint = ownerEndpoint owner
      sum' ← submit endpoint "add" [VInteger 2, VInteger 3] >>= accepted
      returnedValues <$> settleOutcome sum' >>= (`shouldBe` Just [VInteger 5])
      absent ← submit endpoint "absent" [] >>= accepted
      settleOutcome absent >>= \case
        CallReturned EntryAbsent → pure ()
        other → failExample ("expected an absent entry point, found " <> show other)
      retireOwner owner

  it "returns a script error, a value refusal, a not-yet-supported binding and an unknown module to the caller as data, and serves the next call" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (quickSpec fixture "faults" ["app"])
      let endpoint = ownerEndpoint owner
      scriptError ← submit endpoint "boom" [] >>= accepted
      valueRefusal ← submit endpoint "echo" [VText "not an integer"] >>= accepted
      lifecycle ← submit endpoint "lifecycle" [] >>= accepted
      ghost ← submitCall endpoint (ModuleRef "ghost" "9") "echo" [VInteger 1] >>= accepted
      next ← submit endpoint "echo" [VInteger 7] >>= accepted
      settleOutcome scriptError >>= \case
        CallFaulted (BoundaryFailed fault) → do
          boundaryReason fault `shouldSatisfy` \case ScriptFailed CallFailed _ → True; _ → False
          boundaryEffect fault `shouldBe` LuaRan
        other → failExample ("expected a script fault, found " <> show other)
      settleOutcome valueRefusal >>= \case
        CallFaulted fault@(BoundaryFailed inner) → do
          boundaryReason inner `shouldSatisfy` \case ValueRefused _ → True; _ → False
          callFaultEffect fault `shouldBe` NoEffect
        other → failExample ("expected a value refusal, found " <> show other)
      settleOutcome lifecycle >>= \case
        CallFaulted (BoundaryFailed fault) → boundaryReason fault `shouldSatisfy` \case NotYetSupported _ → True; _ → False
        other → failExample ("expected a not-yet-supported fault, found " <> show other)
      settleOutcome ghost >>= \case
        CallFaulted fault@(ModuleNotLoaded ref) → do
          ref `shouldBe` ModuleRef "ghost" "9"
          callFaultEffect fault `shouldBe` NoEffect
        other → failExample ("expected the unknown module, found " <> show other)
      returnedValues <$> settleOutcome next >>= (`shouldBe` Just [VInteger 7])
      -- Nothing ended the owner, and nothing of the faults reached supervision.
      noted fixture >>= (`shouldBe` [])
      retireOwner owner

  it "settles every call exactly once across a thousand submissions interleaved with a stop" $ bounded $ do
    fixture ← newFixture
    withBoundaryOpening [openAllGates fixture] $ \control runtime → do
      owner ← startOwner runtime (ownerSpec fixture "thousand" ["app"] requiredPolicy (bounds 1000 1000))
      let endpoint = ownerEndpoint owner
      -- One call is held in flight, so what follows queues behind it.
      holder ← submit endpoint "block_call" [VText "hold"] >>= accepted
      awaitEntered fixture "hold"
      halfway ← newEmptyMVar
      finished ← newEmptyMVar
      _ ← forkIO $ do
        answers ← forM [1 .. 999 ∷ Int] $ \n → do
          when' (n == 300) (putMVar halfway ())
          submit endpoint "echo" [VInteger (fromIntegral n)]
        putMVar finished answers
      takeMVar halfway
      -- The stop races the submissions that remain.
      retireOwner owner
      answers ← takeMVar finished
      let tickets = [ticket | CallAccepted ticket ← answers]
          closed = length [() | CallClosed ← answers]
          full = length [() | CallFull ← answers]
      full `shouldBe` 0
      length tickets + closed `shouldBe` 999
      -- Admission is closed from the request: nothing is accepted late.
      length tickets `shouldSatisfy` (>= 299)
      releaseGate fixture "hold"
      held ← settle holder
      settledOutcome held `shouldSatisfy` \case CallReturned (Returned [VInteger 1]) → True; _ → False
      outcomes ← forM tickets $ \ticket → do
        first ← settle ticket
        -- Read again: the same settlement, nothing overwritten.
        second ← settle ticket
        show (settledOutcome first) `shouldBe` show (settledOutcome second)
        pure (settledOutcome first)
      let discarded = length (filter (isDiscard ExitStopped NotStarted) outcomes)
          returned = length (catMaybes (map returnedValues outcomes))
      -- Every accepted call settled as one thing, and none was lost.
      discarded + returned `shouldBe` length tickets
      _ ← awaitTerminal control owner
      Just record ← atomically (ownerExitRecord owner)
      exitNotStarted record `shouldBe` discarded
      exitStarted record `shouldBe` 0
  where
    when' condition action = if condition then action else pure ()
