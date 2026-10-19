-- | Progress while gameplay is CPU-bound, with no hook (requirement 11; D-44, P-6).
--
-- A pure-Lua finite computation with no binding call and no yield inside its loop runs as gameplay's
-- update while the UI owner runs on the real clock and timer at a short interval. The check is an
-- /ordering/: the UI's count of completed updates, taken when the computation starts and again when
-- it ends, differs by at least a fixed number. Updates before the computation or after it cannot
-- satisfy it, and the instrumentation (@fx.mark@) is outside the loop.
--
-- The workload is sized by the example, by measuring how fast this machine runs the loop, so that
-- it lasts at least ten times as long as the UI needs to make the required updates. The only waits
-- are deadlock guards. The runtime options in force are printed with the check: the executable and
-- this suite are both built @-threaded -with-rtsopts=-N2@.
module Test.Domains.Progress (spec) where

import Control.Concurrent (getNumCapabilities, rtsSupportsBoundThreads)
import Control.Monad (replicateM)
import qualified Data.ByteString
import qualified Data.Text as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumProcessors)
import Hetoimasia.Foundation.Time (durationNanoseconds)
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configGameplaySource, configUiInterval)
  , defaultConfig
  , stepTick
  )
import Hetoimasia.Scripting.Lua.Owner (Library (LibraryBase), chunkName, evalOwned, vmConfig, withVmOwner)
import Test.Domains.Support
import Test.Hspec

-- | The updates the UI must complete while the computation runs.
requiredUpdates ∷ Int
requiredUpdates = 5

-- | How many times longer than the UI needs the computation is sized to last.
margin ∷ Double
margin = 10

-- | How long the computation is sized to last, in seconds: the margin, and then some.
targetSeconds ∷ Double
targetSeconds = 0.25

-- | How many iterations of the loop this machine runs in a second, the best of three runs of a
-- short one.
iterationsPerSecond ∷ IO Double
iterationsPerSecond = do
  rates ← replicateM 3 $
    withVmOwner (vmConfig [LibraryBase]) $ \vm → do
      started ← getMonotonicTimeNSec
      evalOwned vm (chunkName "calibration") (loop calibrationIterations)
      finished ← getMonotonicTimeNSec
      pure (fromIntegral calibrationIterations / (fromIntegral (finished - started) / 1.0e9))
  pure (maximum rates)
  where
    calibrationIterations = 2000000 ∷ Word64

loop ∷ Word64 → Data.ByteString.ByteString
loop count = luaLines [Text.pack ("local x = 0 for i = 1, " <> show count <> " do x = x + i % 7 end")]

spec ∷ Spec
spec = describe "progress while gameplay is CPU-bound" $
  it "lets the UI complete updates between the start of gameplay's computation and its end, with no hook" $ do
    capabilities ← getNumCapabilities
    processors ← getNumProcessors
    putStrLn ("RTS options in force: threaded=" <> show rtsSupportsBoundThreads <> ", capabilities=" <> show capabilities <> ", processors=" <> show processors <> " (-threaded -with-rtsopts=-N2)")
    rtsSupportsBoundThreads `shouldBe` True
    capabilities `shouldSatisfy` (>= 2)
    rate ← iterationsPerSecond
    let iterations = max 1000000 (min 4000000000 (ceiling (rate * targetSeconds))) ∷ Word64
        intervalSeconds = fromIntegral (durationNanoseconds (configUiInterval defaultConfig)) / 1.0e9 ∷ Double
        sized = fromIntegral iterations / rate
    putStrLn ("workload: " <> show iterations <> " iterations, sized for " <> show sized <> " s; the UI interval is " <> show intervalSeconds <> " s, so it needs " <> show (fromIntegral requiredUpdates * intervalSeconds) <> " s")
    -- The sizing carries the margin: the computation lasts at least ten times what the required
    -- updates take.
    sized `shouldSatisfy` (>= margin * fromIntegral requiredUpdates * intervalSeconds)
    withRealSample
      ( \config →
          config
            { configGameplaySource =
                luaLines
                  [ "function update(self, dt)"
                  , "  fx.mark('begin')"
                  , "  local x = 0"
                  , "  for i = 1, " <> Text.pack (show iterations) <> " do x = x + i % 7 end"
                  , "  fx.mark('end')"
                  , "  staging.finish()"
                  , "end"
                  ]
            }
      )
      $ \fx domains → do
        _ ← generous (stepTick domains)
        marks ← fxMarks fx
        case marks of
          [("begin", begun), ("end", ended)] → do
            putStrLn ("UI updates completed while gameplay computed: " <> show (ended - begun))
            (ended - begun) `shouldSatisfy` (>= requiredUpdates)
          other → expectationFailure ("unexpected marks: " <> show other)
