-- | Progress while gameplay is held (requirement 10; D-44), deterministic: a test-only binding holds
-- a gameplay segment inside a running segment while the UI owner completes a fixed number of updates,
-- each one made due by hand and awaited by its own completion signal; the snapshot still shows the
-- last completed tick throughout, and the tick commits once gameplay is released.
module Test.Domains.Barrier (spec) where

import qualified Data.Text as Text
import Hetoimasia.Sample.LuaDomains
  ( DomainsConfig (configGameplaySource)
  , GameSnapshot (snapTick)
  , stepTick
  )
import Test.Domains.Support
import Test.Hspec

updatesWhileHeld ∷ Int
updatesWhileHeld = 5

spec ∷ Spec
spec = describe "progress while gameplay is held" $
  it "lets the UI complete a fixed number of updates while gameplay is inside a segment, then commits the tick" $
    withSample (\config → config {configGameplaySource = luaLines (map Text.pack ["function update(self, dt) fx.hold('gameplay') staging.finish() end"])}) $
      \fx ui domains → withReleased fx ["gameplay"] $ do
        collect ← spawn (stepTick domains)
        awaitEntered fx "gameplay"
        mapM_
          ( \done → do
              tickUi domains ui
              awaitUpdates domains done
              -- Each update completed with gameplay still held, and nothing was published.
              (snapshot, revision) ← snapshotNow domains
              (snapTick snapshot, revision) `shouldBe` (0, 0)
          )
          [1 .. updatesWhileHeld]
        updatesNow domains `shouldReturn` updatesWhileHeld
        releaseGate fx "gameplay"
        committed ← collect
        snapTick committed `shouldBe` 1
        (snapshot, revision) ← snapshotNow domains
        (snapTick snapshot, revision) `shouldBe` (1, 1)
