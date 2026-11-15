module Test.TerrainRuntime.Spec (spec) where

import Test.Hspec (Spec, before_)
import Test.TerrainRuntime.Capabilities (PassSetting)
import qualified Test.TerrainRuntime.Concurrent as Concurrent
import qualified Test.TerrainRuntime.Isolation as Isolation
import qualified Test.TerrainRuntime.Parallel as Parallel
import qualified Test.TerrainRuntime.Pass as Pass

-- | The pure store families first, in parallel ("Test.TerrainRuntime.Parallel" names them and says why); then everything else
-- one example at a time on one capability, each guarded against a parallel example still running; then the concurrent set once
-- more, alone, on the multi-capability pass's count ("Test.TerrainRuntime.Concurrent" names the set and says why). The examples of
-- the pass's own machinery ("Test.TerrainRuntime.Pass") come first among the sequential ones; they read the table, so they
-- cannot be a row of it.
spec ∷ PassSetting → Spec
spec pass = Parallel.spec >> before_ Isolation.sequentialGuard (Pass.spec >> Concurrent.sequentialSpec) >> Concurrent.passSpec pass
