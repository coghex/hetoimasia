-- | Finite submission: the three-way answer, both bounds, observation, and
-- preparation on the producer's side.
module Test.LuaRuntime.Submission (spec) where

import Control.Concurrent (forkIO, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (ErrorCall), evaluate, try)
import Data.IORef (newIORef, readIORef)
import qualified Data.ByteString as ByteString
import GHC.Stats (RTSStats (gc), GCDetails (gcdetails_live_bytes), getRTSStats)
import System.Mem (performMajorGC)
import Control.Monad (forM_, replicateM, replicateM_, void, (>=>))
import Data.Maybe (isJust)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Worker (GroupStatus (statusOutstanding))
import Hetoimasia.Runtime.Supervision (workerGroupStatus)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)
import Test.LuaRuntime.Support

-- | An answer's shape, without its ticket.
shape ∷ Submission → String
shape = \case
  CallAccepted _ → "accepted"
  CallFull → "full"
  CallClosed → "closed"

spec ∷ Spec
spec = describe "submission" $ do
  describe "the queued-call bound" $ do
    it "accepts calls up to the bound, and answers full one past it, without blocking" $ bounded $ do
      fixture ← newFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startOwner runtime (ownerSpec fixture "queue" ["app"] requiredPolicy (bounds 3 100))
        let endpoint = ownerEndpoint owner
        -- One call in flight, so the three that follow wait.
        holder ← submit endpoint "block_call" [VText "hold"] >>= accepted
        awaitEntered fixture "hold"
        queued ← replicateM 3 (submit endpoint "echo" [VInteger 1] >>= accepted)
        -- Nothing blocks: each of these answers at once, and none changes anything.
        answers ← timeout 5000000 (replicateM 5 (shape <$> submit endpoint "echo" [VInteger 1]))
        answers `shouldBe` Just (replicate 5 "full")
        releaseGate fixture "hold"
        _ ← settle holder
        forM_ queued $ \ticket → returnedValues <$> settleOutcome ticket >>= (`shouldBe` Just [VInteger 1])
        -- The refused calls changed nothing: the queue is whole again.
        again ← replicateM 3 (submit endpoint "echo" [VInteger 2] >>= accepted)
        forM_ again settle
        retireOwner owner

  describe "the result bound" $ do
    it "counts every reservation, pending ones included, and recovers capacity on observation" $ bounded $ do
      fixture ← newFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startOwner runtime (ownerSpec fixture "results" ["app"] requiredPolicy (bounds 50 2))
        let endpoint = ownerEndpoint owner
            full ∷ String → IO ()
            full what = submit endpoint "echo" [VInteger 0] >>= \answer → (what, shape answer) `shouldBe` (what, "full")
        -- One in flight and one queued: both reservations are held while pending.
        holder ← submit endpoint "block_call" [VText "hold"] >>= accepted
        awaitEntered fixture "hold"
        waiting ← submit endpoint "echo" [VInteger 1] >>= accepted
        full "while both calls are pending"
        releaseGate fixture "hold"
        -- Calls settle in the order they were accepted, so once the second is
        -- observed the first has settled and nobody has observed it.
        void (settle waiting)
        extra ← submit endpoint "echo" [VInteger 2] >>= accepted
        full "while a settled result is unobserved"
        -- Observing it gives its reservation back, and a place for one more call.
        void (pollCall holder)
        replacement ← submit endpoint "echo" [VInteger 3] >>= accepted
        full "after the place was taken again"
        -- Observing it again, from several threads at once, gives back nothing more.
        done ← newEmptyMVar
        forM_ [1 .. 16 ∷ Int] $ \_ → forkIO (replicateM_ 50 (pollCall holder) >> putMVar done ())
        replicateM_ 16 (takeMVar done)
        full "after repeated and concurrent observation"
        -- Observing the later call proves the earlier one settled, and leaves it
        -- settled and unobserved.
        void (settle replacement)
        -- Abandoning that result gives its reservation back, once however often.
        forgetCall extra
        forgetCall extra
        first ← submit endpoint "echo" [VInteger 4] >>= accepted
        second ← submit endpoint "echo" [VInteger 5] >>= accepted
        full "after the abandoned result's place was taken twice"
        void (settle first)
        void (settle second)
        retireOwner owner

    it "gives a reservation back when an abandoned call settles" $ bounded $ do
      fixture ← newFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startOwner runtime (ownerSpec fixture "forget" ["app"] requiredPolicy (bounds 5 1))
        let endpoint = ownerEndpoint owner
        holder ← submit endpoint "block_call" [VText "hold"] >>= accepted
        awaitEntered fixture "hold"
        forgetCall holder
        submit endpoint "echo" [VInteger 1] >>= (\answer → shape answer `shouldBe` "full")
        releaseGate fixture "hold"
        -- It settled unobserved by anyone who still cared, and freed its place.
        again ← retryAccepted endpoint
        void (settle again)
        pollCall holder >>= (`shouldSatisfy` isJust)
        retireOwner owner

  describe "closed" $ do
    it "answers closed after stop, whatever the bounds, and changes nothing" $ bounded $ do
      fixture ← newFixture
      withBoundary $ \control runtime → do
        owner ← startOwner runtime (ownerSpec fixture "closing" ["app"] requiredPolicy (bounds 1 1))
        let endpoint = ownerEndpoint owner
        retireOwner owner
        _ ← awaitTerminal control owner
        answers ← replicateM 3 (shape <$> submit endpoint "echo" [VInteger 1])
        answers `shouldBe` replicate 3 "closed"

  describe "the bounds" $ do
    it "refuses a bound below one at creation, naming every violation, before any worker or VM exists" $ bounded $ do
      fixture ← newFixture
      withBoundary $ \control runtime → do
        let attempt callBounds =
              try @OwnerBoundsRefused . void $
                startLuaOwner runtime (ownerSpec fixture "refused" ["app"] requiredPolicy callBounds)
        attempt (bounds 0 5) >>= (`shouldBe` Left (OwnerBoundsRefused [QueuedCallsBelowOne 0]))
        attempt (bounds 5 (-1)) >>= (`shouldBe` Left (OwnerBoundsRefused [ResultsBelowOne (-1)]))
        attempt (bounds 0 0) >>= (`shouldBe` Left (OwnerBoundsRefused [QueuedCallsBelowOne 0, ResultsBelowOne 0]))
        -- Nothing started: no worker is registered, and the module and chunk the
        -- configuration would have run never did.
        status ← atomically (workerGroupStatus control)
        statusOutstanding status `shouldBe` []
        noted fixture `shouldReturn` []
        -- A bound of exactly one is allowed.
        owner ← startOwner runtime (ownerSpec fixture "minimal" ["app"] requiredPolicy (bounds 1 1))
        ticket ← submit (ownerEndpoint owner) "echo" [VInteger 1] >>= accepted
        void (settle ticket)
        retireOwner owner

  describe "preparation on the producer's side" $ do
    it "raises a failure nested in a lazy argument on the producer's thread, while the owner is busy, and queues nothing" $ bounded $ do
      fixture ← newFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startOwner runtime (ownerSpec fixture "producer" ["app"] requiredPolicy (bounds 2 10))
        let endpoint = ownerEndpoint owner
        holder ← submit endpoint "block_call" [VText "hold"] >>= accepted
        awaitEntered fixture "hold"
        let poisoned = VList [VInteger 1, error "nested evaluation failure"]
        outcome ← try @ErrorCall (prepareCall endpoint theModule "echo" [poisoned] >>= evaluate)
        outcome `shouldSatisfy` either (\(ErrorCall message) → message == "nested evaluation failure") (const False)
        outcome' ← try @ErrorCall (submitCall endpoint theModule "echo" [poisoned] >>= evaluate)
        outcome' `shouldSatisfy` either (const True) (const False)
        -- The queue holds exactly what it did: two calls fit, the third is full.
        first ← submit endpoint "echo" [VInteger 1] >>= accepted
        second ← submit endpoint "echo" [VInteger 2] >>= accepted
        submit endpoint "echo" [VInteger 3] >>= (\answer → shape answer `shouldBe` "full")
        releaseGate fixture "hold"
        void (settle holder)
        returnedValues <$> settleOutcome first >>= (`shouldBe` Just [VInteger 1])
        returnedValues <$> settleOutcome second >>= (`shouldBe` Just [VInteger 2])
        retireOwner owner

    it "bounds oversized arguments while the owner is occupied, keeps none, and settles them as the value refusal" $ bounded $ do
      fixture ← newFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startOwner runtime (ownerSpec fixture "oversized" ["app"] requiredPolicy (bounds 4 10))
        let endpoint = ownerEndpoint owner
        holder ← submit endpoint "block_call" [VText "hold"] >>= accepted
        awaitEntered fixture "hold"
        -- An endless list is refused at the first limit, so this returns.
        let endless = VList (map VInteger [1 ..])
        prepared ← timeout 10000000 (prepareCall endpoint theModule "echo" [endless])
        prepared `shouldSatisfy` isJust
        oversized ← submit endpoint "echo" [endless] >>= accepted
        after ← submit endpoint "echo" [VInteger 9] >>= accepted
        releaseGate fixture "hold"
        void (settle holder)
        settleOutcome oversized >>= \case
          CallFaulted (BoundaryFailed fault) → do
            boundaryEffect fault `shouldBe` NoEffect
            boundaryModule fault `shouldBe` Just theModule
            boundaryEntry fault `shouldBe` Just "echo"
            boundaryReason fault `shouldSatisfy` \case
              -- An endless list reaches whichever limit comes first.
              ValueRefused (ValueRefusal Arguments 0 [] (RuleBytesLimit _) 0) → True
              ValueRefused (ValueRefusal Arguments 0 [] (RuleElementLimit _) 0) → True
              _ → False
            boundaryOwner fault `shouldBe` "oversized"
          other → failExample ("expected the value refusal, found " <> show other)
        -- The owner went on, in order, and nothing ran for the refused call.
        returnedValues <$> settleOutcome after >>= (`shouldBe` Just [VInteger 9])
        retireOwner owner
    it "bounds a capability's type name, which the value limits do not count, so a huge one is not kept" $ bounded $ do
      fixture ← newFixture
      withBoundaryOpening [openAllGates fixture] $ \_ runtime → do
        owner ← startOwner runtime (ownerSpec fixture "capability" ["app"] requiredPolicy (bounds 4 10))
        let endpoint = ownerEndpoint owner
        holder ← submit endpoint "block_call" [VText "hold"] >>= accepted
        awaitEntered fixture "hold"
        let huge = VCapability (capability (Text.replicate 2000000 "t") 7)
        -- Accepted and queued while the owner is occupied.
        queued ← submit endpoint "redeem" [huge] >>= accepted
        releaseGate fixture "hold"
        void (settle holder)
        settlement ← settle queued
        settledOutcome settlement `shouldSatisfy` \case
          CallFaulted (BoundaryFailed fault) → case boundaryReason fault of
            ValueRefused _ → True
            _ → False
          _ → False
        -- Nothing of the name beyond the longest valid one was kept, so neither
        -- the refusal nor anything else holds two million characters.
        length (show settlement) `shouldSatisfy` (< 4000)
        retireOwner owner
    it "retains only the bytes of a queued string or capability name, not the larger buffer it was cut from" $ bounded $ do
      fixture ← newFixture
      withBoundary $ \_ runtime → do
        owner ← startOwner runtime (ownerSpec fixture "retained" ["app"] requiredPolicy (bounds 4 10))
        let endpoint = ownerEndpoint owner
        size ← newIORef (3000000 ∷ Int) >>= readIORef
        before ← liveBytes
        prepared ← prepareSlices endpoint size
        routed ← prepareRouting endpoint size
        after ← liveBytes
        -- The buffers the slices were cut from are unreachable by now, and the
        -- prepared calls are still held: they keep their own few bytes and nothing
        -- more, in their values and in their routing strings. Slices kept as they
        -- were would hold many megabytes.
        (after - before) `shouldSatisfy` (< 1000000)
        -- Held until here, and then it is a call like any other.
        answer ← submitPrepared prepared
        shape answer `shouldBe` "accepted"
        mapM_ (submitPrepared >=> (\submitted → shape submitted `shouldBe` "accepted")) routed
        retireOwner owner
  where
    liveBytes ∷ IO Int
    liveBytes = do
      performMajorGC
      performMajorGC
      fromIntegral . gcdetails_live_bytes . gc <$> getRTSStats
    -- Slices of large buffers, prepared for a call; the buffers are not kept.
    prepareSlices endpoint size = do
      hugeText ← evaluate (Text.replicate size "t")
      hugeBytes ← evaluate (ByteString.replicate size 7)
      prepareCall
        endpoint
        theModule
        "echo"
        [ VList
            [ VText (Text.take 5 hugeText)
            , VBytes (ByteString.take 5 hugeBytes)
            , VCapability (capability (Text.take 70 hugeText) 1)
            ]
        ]
    -- Calls whose routing strings are slices of large buffers, valid ones and
    -- overlong ones, with no arguments at all.
    prepareRouting endpoint size = do
      hugeText ← evaluate (Text.replicate size "t")
      sequence
        [ prepareCall endpoint (ModuleRef (Text.take 3 hugeText) (Text.take 1 hugeText)) (Text.take 4 hugeText) []
        , prepareCall endpoint (ModuleRef (Text.take size hugeText) (Text.take size hugeText)) (Text.take size hugeText) []
        ]
    retryAccepted endpoint = do
      answer ← submit endpoint "echo" [VInteger 1]
      case answer of
        CallAccepted ticket → pure ticket
        _ → yield >> retryAccepted endpoint
