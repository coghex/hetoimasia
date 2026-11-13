-- | The isolation a parallel group needs: nothing that measures the process or depends on scheduling runs beside a parallel
-- example, asserted by the suite and not only arranged by its order.
--
-- THE RULE. An example may run in parallel only if it touches no file, thread, clock, runtime statistic or shared mutable state
-- (a fixture it reads is immutable and built once). Everything else runs sequentially, on exactly one capability, after every
-- parallel example has finished: the measurements of the whole process (a live heap, allocated bytes), every storage and service
-- example, the examples that compile an external client. The parallel modules are named in one place,
-- "Test.TerrainRuntime.Parallel", with the reason each qualifies; a module that measures the process or depends on scheduling
-- never joins them.
--
-- HOW IT IS ENFORCED. The runner starts every parallel item at once and starts a sequential item only after every item before
-- it has reported (hspec-core's job queue), so the parallel group is first in the tree. 'tracked' wraps each parallel example
-- (setup, body and cleanup, on every exit, a failure and a cancellation included) and counts it; 'sequentialGuard' runs before
-- every sequential example and every lazily built measurement ("Test.TerrainRuntime.Store.Depth.lazily"): it fails the example
-- if a parallel one is running, returns the runtime to one capability, and fails it if more than one is active.
--
-- State: one counter of the running parallel examples and one flag (the phase line printed once), both owned by this module for
-- the life of the process; the counter is written only by 'tracked' and read by 'assertSequential'.
module Test.TerrainRuntime.Isolation
  ( tracked
  , assertSequential
  , sequentialGuard
  , spec
  ) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Exception (ErrorCall (..), bracket_, throwIO, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import Test.TerrainRuntime.Output (maxLineChars, printLine)

runningParallel ∷ IORef Int
runningParallel = unsafePerformIO (newIORef 0)
{-# NOINLINE runningParallel #-}

phasePrinted ∷ IORef Bool
phasePrinted = unsafePerformIO (newIORef False)
{-# NOINLINE phasePrinted #-}

-- | Wraps an example that runs in parallel with others: counted from before its setup to after its cleanup, on every exit.
tracked ∷ IO () → IO ()
tracked = bracket_ (bump 1) (bump (-1))
  where
    bump d = atomicModifyIORef' runningParallel (\n → (n + d, ()))

-- | Fails when a parallel example is running or more than one capability is active: a measurement of the whole process, and
-- every example that depends on scheduling, is valid only beside nothing and on one capability.
assertSequential ∷ String → IO ()
assertSequential what = do
  running ← readIORef runningParallel
  caps ← getNumCapabilities
  if running /= 0
    then expectationFailure (what <> " must run alone but " <> show running <> " parallel examples are running")
    else
      if caps /= 1
        then expectationFailure (what <> " must run on one capability but " <> show caps <> " are active")
        else pure ()

-- | What every sequential example does first: no parallel example is running (nothing of one remains, its cleanup included),
-- the runtime goes back to one capability, and exactly one is active. Prints the phase once.
sequentialGuard ∷ IO ()
sequentialGuard = do
  running ← readIORef runningParallel
  if running /= 0
    then expectationFailure ("a sequential example started while " <> show running <> " parallel examples are running")
    else do
      setNumCapabilities 1
      assertSequential "a sequential example"
      first ← atomicModifyIORef' phasePrinted (\p → (True, not p))
      if first then putStrLn "PHASE sequential: 1 capability, no parallel example running" else pure ()

spec ∷ Spec
spec = describe "the isolation of the parallel group" $ do
  it "fails the example that prints a line longer than one write may carry, instead of cutting it" $ do
    printLine (replicate (maxLineChars + 1) 'x') `shouldThrow` anyException
    printLine "PRINT a line within the limit is printed whole"
  it "counts a parallel example until it ends, on every exit, and refuses a sequential one beside it" $ do
    assertSequential "the start of this example"
    seen ← newIORef (0 ∷ Int)
    tracked (readIORef runningParallel >>= \n → atomicModifyIORef' seen (\_ → (n, ())))
    readIORef seen >>= (`shouldBe` 1)
    -- beside a running parallel example the guard fails
    tracked (assertSequential "a probe") `shouldThrow` anyException
    -- and the count returns to zero after a failure and after an exception
    _ ← try (tracked (throwIO (ErrorCall "an example fails"))) ∷ IO (Either ErrorCall ())
    readIORef runningParallel >>= (`shouldBe` 0)
    assertSequential "the end of this example"
  it "refuses a sequential example while more than one capability is active, and the guard restores one" $ do
    setNumCapabilities 2
    assertSequential "a probe" `shouldThrow` anyException
    sequentialGuard
    getNumCapabilities >>= (`shouldBe` 1)
