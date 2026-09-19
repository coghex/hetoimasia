-- | The fixture report for this group: how many interpreters it acquired.
--
-- Every VM this suite constructs goes through 'acquireVm', so the counter is
-- the suite's whole construction record. 'Test.Lua.Protocol.Spec' captures it
-- before the group's first example, and this example — the group's last —
-- reports the difference. Under @--match Protocol@ nothing else runs and the
-- difference is the absolute count; in a full run it is the count this group
-- alone is responsible for. Either way the answer has to be zero.
--
-- The difference is the group's own only because Hspec runs a tree in the
-- order it was written; a run that shuffles examples across groups would
-- interleave another group's acquisitions into this window, and the report
-- would be about the run rather than about this group.
--
-- Zero acquisitions says these examples did not need an interpreter. Whether
-- the model /could/ reach one is a question about its dependency closure, and
-- "Test.Lua.Protocol.Boundary" answers that separately.
module Test.Lua.Protocol.Fixture (spec, baseline) where

import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.IO.Unsafe (unsafePerformIO)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Support (interpreterAcquisitions)

-- | What the counter read when this group started.
baselineRef ∷ IORef Int
baselineRef = unsafePerformIO (newIORef 0)
{-# NOINLINE baselineRef #-}

-- | Record the acquisition count as the group begins.
baseline ∷ IO ()
baseline = interpreterAcquisitions >>= writeIORef baselineRef

spec ∷ Spec
spec = describe "fixture" $
  it "reports zero interpreter acquisitions for the Protocol examples" $ do
    started ← readIORef baselineRef
    finished ← interpreterAcquisitions
    (finished - started) `shouldBe` 0
