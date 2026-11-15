-- | The control of the multi-capability pass (#685): the one example that shows what the pass can see and one capability cannot.
-- It is run by hand, from its own selection, and by no routine group: @terrain-runtime-tests --capability-control@ (see
-- "Main"), at @+RTS -N2@ and @-N4@ where it passes and at @-N1@ where it fails by its own bound.
--
-- THE REGION. Two owned threads, pinned to capabilities 0 and 1 ('forkOn' takes the number modulo the capability count, so at
-- @-N1@ both are on capability 0), must each be inside the region at the same instant as the other /on a different capability/:
-- each enters (publishes the capability it runs on), reads the other's entry until it sees one from another capability, says so,
-- and leaves only once the other has said so too. A rendezvous of MVars or STM alone would not tell the runs apart: on one
-- capability the scheduler preempts a spinning thread, the peer runs, and both are "inside" at once without ever executing
-- together. Here a peer on the same capability does not count, so on one capability no entry ever satisfies the wait.
--
-- THE BOUND. Each wait is a count of reads, never a clock and never a sleep: when it is exhausted the thread returns a refusal
-- naming what it never saw, and ends; both owned threads therefore end, and are joined, on the failing path too.
module Test.TerrainRuntime.CapabilityControl (spec) where

import Control.Concurrent (ThreadId, getNumCapabilities, myThreadId, threadCapability)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Data.IORef (IORef, atomicWriteIORef, newIORef, readIORef)
import Test.Hspec
import Test.Support.Owned (withOwnedThreadOn)

-- | Reads of the peer's entry a thread makes before it gives up: far beyond any start latency on a machine that can run two
-- threads at once, and a bounded time (seconds) where it cannot.
bound ∷ Int
bound = 300000000

data Seat = Seat
  { seatInside ∷ IORef (Maybe Int)
  , seatSaw ∷ IORef Bool
  }

newSeat ∷ IO Seat
newSeat = Seat <$> newIORef Nothing <*> newIORef False

-- | Spin until the condition holds or the bound is spent; the reads allocate nothing the scheduler need wait for, but the thread
-- is preemptible (a count of reads is the bound, so a preempted thread loses none of it).
spinUntil ∷ IO Bool → IO Bool
spinUntil ok = go bound
  where
    go 0 = pure False
    go n = do
      r ← ok
      if r then pure True else go (n - 1)

-- | One thread's visit: enter, see the other inside on another capability, say so, and leave once the other has said so too.
visit ∷ Seat → Seat → IO (Either String Int)
visit mine theirs = do
  tid ← myThreadId
  (cap, _) ← threadCapability tid
  atomicWriteIORef (seatInside mine) (Just cap)
  saw ← spinUntil (maybe False (/= cap) <$> readIORef (seatInside theirs))
  if not saw
    then pure (Left ("the peer was never inside the region on another capability than " <> show cap <> " (the rendezvous bound is spent)"))
    else do
      atomicWriteIORef (seatSaw mine) True
      said ← spinUntil (readIORef (seatSaw theirs))
      atomicWriteIORef (seatInside mine) Nothing
      pure (if said then Right cap else Left "the peer never confirmed that it saw this thread inside (the rendezvous bound is spent)")

-- | Run one visit on an owned thread pinned to a capability; the result is read after the thread is joined.
onCapability ∷ Int → Seat → Seat → MVar (Either String Int) → (ThreadId → IO () → IO a) → IO a
onCapability cap mine theirs out = withOwnedThreadOn cap (visit mine theirs >>= putMVar out)

spec ∷ Spec
spec = describe "The multi-capability control" $
  it "has two owned threads inside a region at the same instant on different capabilities" $ do
    caps ← getNumCapabilities
    putStrLn ("CONTROL capabilities=" <> show caps)
    a ← newSeat
    b ← newSeat
    outA ← newEmptyMVar
    outB ← newEmptyMVar
    (ra, rb) ← onCapability 0 a b outA $ \_ waitA → onCapability 1 b a outB $ \_ waitB → do
      waitA
      waitB
      (,) <$> takeMVar outA <*> takeMVar outB
    case (ra, rb) of
      (Right x, Right y) | x /= y → putStrLn ("CONTROL rendezvous completed on capabilities " <> show (x, y))
      (Right x, Right y) → expectationFailure ("both threads ran on capability " <> show x <> " and " <> show y)
      _ → expectationFailure ("the rendezvous failed by its own bound: " <> show [e | Left e ← [ra, rb]])
