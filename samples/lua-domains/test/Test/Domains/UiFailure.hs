-- | A failure of the UI owner's behavior (#499 requirement 11): it is isolated. It is recorded once and bounded, the
-- UI instance ends and is not restarted, and nothing else changes: gameplay is not told and keeps ticking, intentions
-- already accepted are still applied, the UI offers nothing more, and the report says the UI failed.
module Test.Domains.UiFailure (spec) where

import Control.Concurrent.STM (readTVar, readTVarIO, retry)
import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.List (isInfixOf)
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsShared)
  , DomainsConfig (configInput, configUiSource)
  , Evidence (evidenceUi)
  , GameSnapshot (snapStatus, snapWorld)
  , InstanceEvidence (evidenceInstance, evidenceOutcome)
  , OwnerEvidence (evidenceInstances)
  , SessionStatus (Running)
  , cleanupEvidence
  , retireDomains
  )
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedCounts, sharedUiFailure))
import Hetoimasia.Sample.LuaDomains.Snapshot (SessionFailure (failMessage, failStage))
import Hetoimasia.Sample.LuaDomains.Tally (Counts (..))
import Test.Domains.Support
import Test.Hspec

-- | A UI behavior that offers one intention in each update and fails in the update of this number.
uiFailingAt ∷ Int → Text → [Text]
uiFailingAt number initBody =
  [ "local updates = 0"
  , "function init(self, api) " <> initBody <> " end"
  , "function update(self, dt)"
  , "  updates = updates + 1"
  , "  if updates == " <> Text.pack (show number) <> " then error('ui failed') end"
  , "  local _, _, _, version = view.entity(0)"
  , "  intent.submit(view.session(), view.tick(), 0, version, 1, 0)"
  , "  ui.updated()"
  , "end"
  ]

-- | Block until the UI's failure has been recorded, and answer it.
awaitUiFailure ∷ Domains → IO SessionFailure
awaitUiFailure domains = waitFor (readTVar (sharedUiFailure (domainsShared domains)) >>= maybe retry pure)

spec ∷ Spec
spec = describe "a failure of the UI owner's behavior" $ do
  it "is recorded once and bounded, ends the UI instance as failed, and leaves gameplay ticking with the session running" $
    withSample (\config → config {configInput = [], configUiSource = luaLines (uiFailingAt 2 "")}) $ \_ ui domains → do
      tickUi domains ui
      awaitUpdates domains 1
      tickUi domains ui
      failure ← awaitUiFailure domains
      (failStage failure, Text.unpack (failMessage failure)) `shouldSatisfy` \(stage, message) → stage == "update" && "ui failed" `isInfixOf` message
      forM_ [1 .. 4 ∷ Int] $ \_ → stepCommitted domains
      (snapshot, _) ← snapshotNow domains
      snapStatus snapshot `shouldBe` Running
      _ ← retireDomains domains
      evidence ← cleanupEvidence domains
      map (\found → (evidenceInstance found, evidenceOutcome found)) (evidenceInstances (evidenceUi evidence)) `shouldBe` [("interface", "failed")]

  it "is the failure of an init as well: recorded at the start, and gameplay is unaffected" $
    withSample (\config → config {configInput = [], configUiSource = luaLines (uiFailingAt 99 "error('ui init failed')")}) $ \_ _ domains → do
      failure ← awaitUiFailure domains
      failStage failure `shouldBe` "init"
      forM_ [1 .. 3 ∷ Int] $ \_ → stepCommitted domains
      (snapshot, _) ← snapshotNow domains
      snapStatus snapshot `shouldBe` Running

  it "leaves gameplay's world what it is without the failure: five ticks give the same world with a UI that fails as with one that offers nothing" $ do
    failed ← worldAfter (uiFailingAt 1 "")
    quiet ← worldAfter ["function update(self, dt) ui.updated() end"]
    failed `shouldBe` quiet

  it "still applies what had been accepted before the UI failed, and the UI offers nothing more" $
    withSample (\config → config {configInput = [], configUiSource = luaLines (uiFailingAt 2 "")}) $ \_ ui domains → do
      -- The first update's offer is accepted; the second update fails before it can offer.
      tickUi domains ui
      awaitUpdates domains 1
      tickUi domains ui
      _ ← awaitUiFailure domains
      accepted ← countAccepted <$> readTVarIO (sharedCounts (domainsShared domains))
      accepted `shouldBe` 1
      forM_ [1 .. 3 ∷ Int] $ \_ → stepCommitted domains
      counts ← readTVarIO (sharedCounts (domainsShared domains))
      (countAccepted counts, countApplied counts + countStale counts) `shouldBe` (1, 1)
      balanced domains
  where
    worldAfter ui =
      withSample (\config → config {configInput = [], configUiSource = luaLines ui}) $ \_ fake domains → do
        tickUi domains fake
        forM_ [1 .. 5 ∷ Int] $ \_ → stepCommitted domains
        (snapshot, _) ← snapshotNow domains
        pure (snapWorld snapshot)
