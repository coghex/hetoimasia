-- | The rule for signals during a @lua@ run, as direct examples of the one coordinator SIGINT and
-- SIGTERM share: the first delivery only requests the stop, the second forces exactly once, a later one
-- changes nothing, and overlapping deliveries still request once and force at most once.
module Test.Engine.Console.Lua.Signals (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newEmptyTMVarIO, readTMVar, putTMVar)
import Control.Monad (forM, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Hetoimasia.Console.Lua.Signals (Delivery (..), deliver, newCoordinator, stopRequested)
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
    answers ← forM [1 .. 32 ∷ Int] $ \_ → do
      answer ← newEmptyMVar
      void (forkIO (atomically (readTMVar start) >> deliver coordinator >>= putMVar answer))
      pure answer
    atomically (putTMVar start ())
    results ← mapM takeMVar answers
    length (filter (== Requested) results) `shouldBe` 1
    length (filter (== Forcing) results) `shouldBe` 1
    length (filter (== Ignored) results) `shouldBe` 30
    readIORef forced >>= (`shouldBe` 1)
  where
    bump ref = atomicModifyIORef' ref (\count → (count + 1, ()))
