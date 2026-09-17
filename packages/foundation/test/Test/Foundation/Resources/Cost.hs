-- | Cost examples for the cleanup-evidence inspection of
-- 'Hetoimasia.Foundation.Resource'.
--
-- Inspection runs while a program is already recovering from a failure, so
-- what it costs is part of the contract rather than an implementation detail.
-- The examples below fix the shape that offers inspection exponentially many
-- routes to the same evidence — nested scopes whose releases each run the next
-- scope, so every enclosing release carries the evidence retained below it —
-- and hold both public entry points to a fixed allocation budget at two
-- depths. Two depths are what distinguish a changed growth rate from a
-- constant factor: a traversal that re-expands every route fails the shallower
-- budget by an order of magnitude and the deeper one by six more.
--
-- The budgets are generous next to what a bounded traversal actually
-- allocates. They are ceilings on the growth rate, not measurements of the
-- current implementation, so an ordinary change to how evidence is gathered
-- does not have to move them. Allocation is used rather than elapsed time
-- because it is stable across machines and load.
module Test.Foundation.Resources.Cost (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AllocationLimitExceeded
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , evaluate
  , fromException
  , throwIO
  , try
  , tryWithContext
  )
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Conc (disableAllocationLimit, enableAllocationLimit, setAllocationCounter)
import GHC.Stats (RTSStats (allocated_bytes), getRTSStats, getRTSStatsEnabled)
import Hetoimasia.Foundation.Resource
  ( CleanupFailure
  , cleanupFailureLabel
  , cleanupFailures
  , cleanupFailuresInContext
  , withResourceLabelled
  )
import System.Mem (performGC)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe)

spec ∷ Spec
spec = describe "Resource evidence inspection cost" $ do
  describe "at twenty nested releases" $ do
    it "bounds what cleanupFailures allocates"
      (inspectFromException shallowDepth shallowBudget)
    it "bounds what cleanupFailuresInContext allocates"
      (inspectFromContext shallowDepth shallowBudget)

  describe "at forty nested releases" $ do
    it "bounds what cleanupFailures allocates"
      (inspectFromException deepDepth deepBudget)
    it "bounds what cleanupFailuresInContext allocates"
      (inspectFromContext deepDepth deepBudget)

-- Budgets ---------------------------------------------------------------------

-- | The depth the original measurement used, and a deeper one. The second
-- depth is what makes the example a statement about growth: doubling it may
-- cost a small multiple, never a multiple per level.
shallowDepth, deepDepth ∷ Int
shallowDepth = 20
deepDepth = 40

-- | Fixed allocation ceilings for the two depths, in bytes.
shallowBudget, deepBudget ∷ Word64
shallowBudget = 128 * mebibyte
deepBudget = 512 * mebibyte

mebibyte ∷ Word64
mebibyte = 1024 * 1024

-- | The allocation one measured inspection may spend before it is abandoned.
--
-- This bound is a reporting device, not the assertion: it is high enough that
-- a route-per-expansion traversal's twenty-deep cost is still measured and
-- reported exactly, and low enough that the same traversal's forty-deep cost
-- fails here in seconds rather than running for hours.
measurementBound ∷ Word64
measurementBound = 8192 * mebibyte

-- Examples --------------------------------------------------------------------

inspectFromException ∷ Int → Word64 → Expectation
inspectFromException depth budget = do
  requireStatistics
  -- The fixture is built before the interval opens, so what is measured is the
  -- inspection alone.
  propagated ← expectFailure (nestedReleases depth)
  measured ← measureAllocation (evaluate (length (cleanupFailures propagated)))
  reportWithin depth budget measured
  -- The result is asserted outside the interval, on a traversal that is not
  -- the sample.
  labelsOf (cleanupFailures propagated) `shouldBe` expectedLabels depth

inspectFromContext ∷ Int → Word64 → Expectation
inspectFromContext depth budget = do
  requireStatistics
  caught ← tryWithContext (nestedReleases depth)
  case caught of
    Right () → expectationFailure "expected the nested releases to fail"
    Left (ExceptionWithContext context (_ ∷ SomeException)) → do
      measured ← measureAllocation (evaluate (length (cleanupFailuresInContext context)))
      reportWithin depth budget measured
      labelsOf (cleanupFailuresInContext context) `shouldBe` expectedLabels depth

-- | Fail unless the measured inspection finished within @budget@, naming what
-- it actually cost either way.
reportWithin ∷ Int → Word64 → Measured Int → Expectation
reportWithin depth budget measured = case measured of
  Abandoned →
    expectationFailure $
      "inspecting "
        <> show depth
        <> " nested releases allocated more than "
        <> mebibytes measurementBound
        <> " and was abandoned; the budget is "
        <> mebibytes budget
  Completed allocated found → do
    -- Every distinct failure is still reported, whatever the cost was.
    found `shouldBe` depth
    if allocated <= budget
      then pure ()
      else
        expectationFailure $
          "inspecting "
            <> show depth
            <> " nested releases allocated "
            <> show allocated
            <> " bytes, above the "
            <> mebibytes budget
            <> " budget"

-- Fixture ---------------------------------------------------------------------

-- | @depth@ nested scopes whose releases each run the next scope, with the
-- innermost release throwing.
--
-- Each enclosing release therefore fails while carrying the evidence the scope
-- below it retained, so the same subgraph is reachable through every prefix of
-- the nesting.
nestedReleases ∷ Int → IO ()
nestedReleases depth =
  withResourceLabelled (labelAt depth) (pure ()) release (\_ → pure ())
  where
    release _
      | depth <= 1 = throwIO (userError "innermost release failed")
      | otherwise = nestedReleases (depth - 1)

labelAt ∷ Int → Text
labelAt depth = "release " <> Text.pack (show depth)

-- | The innermost release is attempted first, so observation order counts up
-- from the innermost label.
expectedLabels ∷ Int → [Text]
expectedLabels depth = map labelAt [1 .. depth]

labelsOf ∷ [CleanupFailure] → [Text]
labelsOf = map cleanupFailureLabel

expectFailure ∷ IO a → IO SomeException
expectFailure action = do
  outcome ← try action
  case outcome of
    Left exception → pure exception
    Right _ → fail "expected the nested releases to fail, but they returned"

-- Measurement ------------------------------------------------------------------

-- | What one measured inspection cost, or that it overran 'measurementBound'.
data Measured a = Completed !Word64 a | Abandoned

-- | Run @action@ under an allocation limit and report what the program
-- allocated while it ran.
--
-- @allocated_bytes@ advances at garbage collections, so the interval is
-- bracketed by 'performGC' rather than read directly around the action. The
-- action runs on a thread of its own because the allocation limit that bounds
-- an overrunning traversal is delivered asynchronously to whichever thread
-- spends it, and that must not be the example's own.
measureAllocation ∷ IO a → IO (Measured a)
measureAllocation action = do
  done ← newEmptyMVar
  performGC
  before ← allocatedBytes
  _ ← forkIO $ do
    outcome ← try @SomeException $ do
      setAllocationCounter (fromIntegral measurementBound)
      enableAllocationLimit
      result ← action
      disableAllocationLimit
      pure result
    disableAllocationLimit
    putMVar done outcome
  outcome ← takeMVar done
  performGC
  after ← allocatedBytes
  case outcome of
    Right result → pure (Completed (after - before) result)
    Left exception
      | Just (_ ∷ AllocationLimitExceeded) ← fromException exception → pure Abandoned
      | otherwise → throwIO exception

allocatedBytes ∷ IO Word64
allocatedBytes = allocated_bytes <$> getRTSStats

-- | Refuse to report a budget as met when the runtime is not collecting the
-- statistics the measurement reads.
requireStatistics ∷ Expectation
requireStatistics = do
  enabled ← getRTSStatsEnabled
  if enabled
    then pure ()
    else
      expectationFailure
        "RTS statistics are unavailable; this suite must run with -T, which \
        \hetoimasia.cabal supplies through -with-rtsopts"

mebibytes ∷ Word64 → String
mebibytes bytes = show (bytes `div` mebibyte) <> " MiB"
