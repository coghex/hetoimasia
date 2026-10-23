-- | Native pressure is bounded progress of work already accepted, not a failure and not a busy answer:
-- a full staging buffer or upload queue, a full action lane, a full release lane, no free table slot and no
-- room for another image. Each retains the job (and so its reservations) until the owner's own progress
-- changes, with bounded records, no re-read, no restart and no thread beyond the pump.
module Test.LuaEngine.Graphics.Pressure (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Monad (forM, forM_)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture.Backend (BackendReading (..))
import Hetoimasia.LuaEngine.Texture.Backend (BackendTexture (..), RetirementState (..))
import Test.Hspec
import Test.LuaEngine.Graphics.Fake
import Test.LuaEngine.Graphics.Rig

spec ∷ Spec
spec = describe "pressure retains accepted work" $ do
  it "waits for staging, then proceeds, when the first upload leaves it" $
    withRig defaultFakeConfig {fcStagingBytes = 20} $ \rig → do
      hold (rigFake rig) HoldUploadFinish
      first ← newProbe
      second ← newProbe
      _ ← submit rig first 2 2 255
      awaitEvent (rigFake rig) "upload started"
      _ ← submit rig second 2 2 255
      awaitEventCount (rigFake rig) "admission pressure" 1
      terminals second `shouldReturn` []
      reading ← readingNow rig
      readingJobs reading `shouldBe` 2
      release (rigFake rig) HoldUploadFinish
      awaitTerminal first >>= (`shouldSatisfy` isReady)
      awaitTerminal second >>= (`shouldSatisfy` isReady)
      seen ← events (rigFake rig)
      length (filter (Text.isPrefixOf "allocated") seen) `shouldBe` 2

  it "does not lose a relief that lands between the attempt and the reading of its answer" $
    withRig defaultFakeConfig $ \rig → do
      inject (rigFake rig) (PressureAllocate 1)
      hold (rigFake rig) HoldOutcome
      probe ← newProbe
      _ ← submit rig probe 2 2 255
      awaitEventCount (rigFake rig) "allocation pressure" 1
      -- The owner has answered pressure and the backend has not read the answer; the pressure is relieved now.
      progress (rigFake rig)
      release (rigFake rig) HoldOutcome
      awaitTerminal probe >>= (`shouldSatisfy` isReady)

  it "waits while the action lane is full and takes the lane as it drains" $
    withRig defaultFakeConfig {fcActCapacity = 1} $ \rig → do
      hold (rigFake rig) HoldOwner
      probes ← forM [1 .. 3 ∷ Int] $ \_ → newProbe
      forM_ probes $ \probe → submit rig probe 2 2 255
      awaitFake (rigFake rig) ((== 1) . readingActsQueued)
      forM_ probes $ \probe → terminals probe `shouldReturn` []
      release (rigFake rig) HoldOwner
      forM_ probes $ \probe → awaitTerminal probe >>= (`shouldSatisfy` isReady)

  it "waits for a table slot until a released texture's slot is reclaimed" $
    withRig defaultFakeConfig {fcSlots = 1} $ \rig → do
      first ← newProbe
      _ ← submit rig first 2 2 255
      _ ← awaitTerminal first
      texture ← delivered first
      second ← newProbe
      hold (rigFake rig) HoldReclaim
      setVersionHolders (rigFake rig) 1
      _ ← submit rig second 2 2 255
      awaitEvent (rigFake rig) "upload completed 1"
      terminals second `shouldReturn` []
      reading ← textureRelease texture
      awaitEvent (rigFake rig) "released"
      atomically (reading >>= \case ProviderPending → pure (); _ → retry)
      -- The slot is still held by a batch's version: the second job keeps waiting.
      terminals second `shouldReturn` []
      setVersionHolders (rigFake rig) 0
      release (rigFake rig) HoldReclaim
      awaitTerminal second >>= (`shouldSatisfy` isReady)

  it "waits for room for another image until one is gone" $
    withRig defaultFakeConfig {fcImages = 1, fcInitialHolds = [HoldBind]} $ \rig → do
      first ← newProbe
      second ← newProbe
      _ ← submit rig first 2 2 255
      awaitPhase rig "uploaded"
      _ ← submit rig second 2 2 255
      awaitEventCount (rigFake rig) "allocation pressure" 1
      terminals second `shouldReturn` []
      release (rigFake rig) HoldBind
      awaitTerminal first >>= (`shouldSatisfy` isReady)
      texture ← delivered first
      reading ← textureRelease texture
      atomically (reading >>= \case ProviderComplete → pure (); _ → retry)
      awaitTerminal second >>= (`shouldSatisfy` isReady)

  it "waits while the release lane is full, and releases both when it drains" $
    withRig defaultFakeConfig {fcReleaseCapacity = 1} $ \rig → do
      first ← newProbe
      second ← newProbe
      _ ← submit rig first 2 2 255
      _ ← submit rig second 2 2 255
      _ ← awaitTerminal first
      _ ← awaitTerminal second
      one ← delivered first
      two ← delivered second
      holdBarrier (rigFake rig)
      readingOne ← textureRelease one
      readingTwo ← textureRelease two
      awaitFake (rigFake rig) ((== 1) . readingReleasesQueued)
      -- Both are revoked at once; only one has a place in the lane.
      awaitFake (rigFake rig) (\r → length (readingMarkedNow r) == 2)
      atomically (readingTwo >>= \case ProviderPending → pure (); _ → retry)
      release (rigFake rig) HoldAdoption
      atomically (readingOne >>= \case ProviderComplete → pure (); _ → retry)
      atomically (readingTwo >>= \case ProviderComplete → pure (); _ → retry)
  where
    isReady = \case SeReady _ → True; _ → False
