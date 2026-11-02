-- | The rule for signals during a @lua@ run, as direct examples of the one coordinator SIGINT and
-- SIGTERM share: the first delivery only requests the stop, the second forces exactly once, a later one
-- changes nothing, and overlapping deliveries still request once and force at most once.
--
-- The 32 clients of the overlapping example are owned threads (#600): started together from one gate, and ended and joined
-- with the scope however it ends, including an example that fails before the gate is opened. The last examples judge that,
-- and run the same scenario over an unowned start as the negative control.
module Test.Engine.Console.Lua.Signals (spec) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, readTMVar, putTMVar)
import Control.Exception (finally)
import Control.Monad (forM, void)
import Data.Foldable (for_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import GHC.Conc (BlockReason (BlockedOnSTM))
import Hetoimasia.Console.Lua.Signals (Delivery (..), deliver, newCoordinator, stopRequested)
import Test.Engine.Unowned
  ( Ending
  , Scope
  , blockedFor
  , endings
  , hasEnded
  , newCleanups
  , ownedScope
  , runCleanups
  , runEnding
  , unownedScope
  , withAll
  )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Support.Bounded (bounded)

spec ∷ Spec
spec = describe "the signal coordinator" $ do
  it "requests the stop on the first delivery and never forces on one" $ bounded $ do
    forced ← newIORef (0 ∷ Int)
    coordinator ← newCoordinator (bump forced)
    atomically (stopRequested coordinator) >>= (`shouldBe` False)
    deliver coordinator >>= (`shouldBe` Requested)
    atomically (stopRequested coordinator) >>= (`shouldBe` True)
    readIORef forced >>= (`shouldBe` 0)
  it "forces exactly once on the second delivery" $ bounded $ do
    forced ← newIORef (0 ∷ Int)
    coordinator ← newCoordinator (bump forced)
    _ ← deliver coordinator
    deliver coordinator >>= (`shouldBe` Forcing)
    readIORef forced >>= (`shouldBe` 1)
  it "changes nothing on a later delivery" $ bounded $ do
    forced ← newIORef (0 ∷ Int)
    coordinator ← newCoordinator (bump forced)
    deliveries ← forM [1 .. 6 ∷ Int] (const (deliver coordinator))
    deliveries `shouldBe` [Requested, Forcing] <> replicate 4 Ignored
    readIORef forced >>= (`shouldBe` 1)
    atomically (stopRequested coordinator) >>= (`shouldBe` True)
  it "returns from the first delivery without waiting for anything the stop asks for" $ bounded $ do
    -- Nothing here ever completes a shutdown: the delivery returns at once all the same.
    coordinator ← newCoordinator (pure ())
    deliver coordinator >>= (`shouldBe` Requested)
  it "forces without waiting for cleanup or flushing: the force action is all it runs" $ bounded $ do
    order ← newIORef ([] ∷ [String])
    coordinator ← newCoordinator (atomicModifyIORef' order (\held → ("force" : held, ())))
    _ ← deliver coordinator
    _ ← deliver coordinator
    readIORef order >>= (`shouldBe` ["force"])
  it "requests once and forces at most once when deliveries overlap on many threads" $ bounded $ do
    forced ← newIORef (0 ∷ Int)
    coordinator ← newCoordinator (bump forced)
    start ← newEmptyTMVarIO
    answers ← forM [1 .. 32 ∷ Int] (const newEmptyMVar)
    -- The clients are owned by this example and begin together at the one gate; the example waits for each answer itself.
    withAll ownedScope [atomically (readTMVar start) >> deliver coordinator >>= putMVar answer | answer ← answers] $ \_ → do
      atomically (putTMVar start ())
      results ← mapM takeMVar answers
      length (filter (== Requested) results) `shouldBe` 1
      length (filter (== Forcing) results) `shouldBe` 1
      length (filter (== Ignored) results) `shouldBe` 30
      readIORef forced >>= (`shouldBe` 1)
  describe "the 32 clients of the overlapping example are owned (#600)" $
    for_ endings $ \(label, ending) → do
      it ("have all ended and been joined when the scope returns, none left at the start gate, when " <> label <> " before the gate opens") $
        clientsHeldAtStartGate ending ownedScope >>= (`shouldBe` True)
      it ("negative control: unowned clients are left parked at the start gate when " <> label <> " before the gate opens") $ do
        cleanups ← newCleanups
        -- The judgement is recorded first; only then does anything independent stop and join what the control left.
        (clientsHeldAtStartGate ending (unownedScope cleanups) >>= (`shouldBe` False)) `finally` runCleanups cleanups

-- | Count one more.
bump ∷ IORef Int → IO ()
bump ref = atomicModifyIORef' ref (\count → (count + 1, ()))

-- | The 32 clients of the overlapping example, started in this kind of scope and held at the start gate, which nothing opens:
-- the scope then ends the way the ending says, and the answer is whether every client has ended and been joined when it
-- has.
clientsHeldAtStartGate ∷ Ending → Scope → IO Bool
clientsHeldAtStartGate ending scope = do
  forced ← newIORef (0 ∷ Int)
  coordinator ← newCoordinator (bump forced)
  start ← newEmptyTMVarIO
  started ← newIORef []
  runEnding ending $ \end →
    withAll scope (replicate 32 (atomically (readTMVar start) >> void (deliver coordinator))) $ \clients → do
      writeIORef started clients
      -- Every client is waiting at the gate: the runtime says each one is blocked in the transaction that reads it.
      end (mapM_ (blockedFor BlockedOnSTM) clients)
  readIORef started >>= fmap and . mapM hasEnded
