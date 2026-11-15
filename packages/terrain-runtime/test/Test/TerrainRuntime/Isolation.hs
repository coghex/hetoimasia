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
-- THE MULTI-CAPABILITY PASS (#685). The concurrent examples ("Test.TerrainRuntime.Concurrent") run once more, last, after every
-- sequential example, on the pass's capability count. They are still alone: 'passGuard' fails the example if a parallel example
-- is running, and 'assertAlone', the assertion the service and storage examples make, accepts the count of the phase it runs in
-- (one, then the pass's) where 'assertSequential', the assertion of everything that measures the process, accepts one only: a
-- measurement that joined the pass would fail it.
--
-- State: one counter of the running parallel examples, one flag (the phase line printed once) and the capability count the
-- running phase expects, all owned by this module for the life of the process; the counter is written only by 'tracked' and read
-- by the assertions, the expected count is written by 'sequentialGuard' (one) and 'passGuard' (the pass's) and read by
-- 'assertAlone'.
module Test.TerrainRuntime.Isolation
  ( tracked
  , assertSequential
  , assertAlone
  , sequentialGuard
  , passGuard
  , spec
  ) where

import Control.Concurrent (getNumCapabilities, setNumCapabilities)
import Control.Exception (ErrorCall (..), bracket_, throwIO, try)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec
import Test.TerrainRuntime.Capabilities (PassSetting (..), enterPass)
import Test.TerrainRuntime.Output (maxLineChars, printLine)

runningParallel ∷ IORef Int
runningParallel = unsafePerformIO (newIORef 0)
{-# NOINLINE runningParallel #-}

phasePrinted ∷ IORef Bool
phasePrinted = unsafePerformIO (newIORef False)
{-# NOINLINE phasePrinted #-}

-- | The capability count the running phase expects: one, until the multi-capability pass sets its own.
expectedCapabilities ∷ IORef Int
expectedCapabilities = unsafePerformIO (newIORef 1)
{-# NOINLINE expectedCapabilities #-}

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

-- | Fails when a parallel example is running or the capability count is not the running phase's (one in the sequential phase, the
-- pass's count in the multi-capability pass). What a service or storage example asserts: it needs no one-capability measurement,
-- but it must run beside nothing and on the count its phase claims.
assertAlone ∷ String → IO ()
assertAlone what = do
  running ← readIORef runningParallel
  expected ← readIORef expectedCapabilities
  caps ← getNumCapabilities
  if running /= 0
    then expectationFailure (what <> " must run alone but " <> show running <> " parallel examples are running")
    else
      if caps /= expected
        then expectationFailure (what <> " must run on " <> show expected <> " capabilities (its phase) but " <> show caps <> " are active")
        else pure ()

-- | What every sequential example does first: no parallel example is running (nothing of one remains, its cleanup included),
-- the runtime goes back to one capability, and exactly one is active. Prints the phase once.
sequentialGuard ∷ IO ()
sequentialGuard = do
  running ← readIORef runningParallel
  if running /= 0
    then expectationFailure ("a sequential example started while " <> show running <> " parallel examples are running")
    else do
      writeIORef expectedCapabilities 1
      setNumCapabilities 1
      assertSequential "a sequential example"
      first ← atomicModifyIORef' phasePrinted (\p → (True, not p))
      if first then printLine "PHASE sequential: 1 capability, no parallel example running" else pure ()

-- | What every example of the multi-capability pass does first: nothing parallel is running, the phase expects the pass's count,
-- and the runtime is set to it and reports it ("Test.TerrainRuntime.Capabilities").
passGuard ∷ PassSetting → IO ()
passGuard setting = do
  running ← readIORef runningParallel
  if running /= 0
    then expectationFailure ("a multi-capability example started while " <> show running <> " parallel examples are running")
    else do
      writeIORef expectedCapabilities (passRequested setting)
      enterPass setting

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
