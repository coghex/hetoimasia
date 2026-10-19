-- | The two owners' lifetime (requirement 2): created under one supervision boundary, retired in an
-- order in which neither outlives what its bindings borrow, and nothing left live.
module Test.Domains.Lifetime (spec) where

import Control.Concurrent.STM (atomically)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped))
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsGameplay, domainsShared, domainsUi)
  , DomainsConfig (configGameplaySource, configUiSource)
  , OwnerEnd (endExit, endInstance)
  , Retirement (retiredGameplay, retiredUi)
  , Started (startedOwner)
  , retireDomains
  , stepTick
  )
import Hetoimasia.Sample.LuaDomains.Queue (reserved)
import Hetoimasia.Sample.LuaDomains.Scripts (gameplaySource, interfaceSource)
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedQueue))
import Hetoimasia.Scripting.Lua.Instance (InstanceOutcome (InstanceStopped), InstanceSettlement (resultOutcome))
import Hetoimasia.Scripting.Lua.Runtime (ExitKind (ExitStopped), ExitRecord (exitKind, exitNotStarted, exitStarted))
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint, scheduledIdentity, scheduledStatus, ticksOutstanding)
import Test.Domains.Support
import Test.Hspec

-- | The sample's own script with a @shutdown@ hook that records which owner stopped, and why.
recording ∷ Text → ByteString → ByteString
recording owner source =
  source <> luaLines ["", "function shutdown(self, reason) fx.record('" <> owner <> " shutdown ' .. reason) end"]

spec ∷ Spec
spec = describe "the owners' lifetime" $ do
  it "retires the UI owner before the gameplay owner, with clean exit records, and leaves nothing live" $ do
    (domains, ui) ←
      withSample
        (\config → config {configGameplaySource = recording "gameplay" gameplaySource, configUiSource = recording "ui" interfaceSource})
        $ \fx ui domains → do
          _ ← stepTick domains
          _ ← stepTick domains
          retirement ← retireDomains domains
          -- The UI owner's behavior was stopped, with its reason, before gameplay's.
          fxLines fx `shouldReturn` ["ui shutdown stopped", "gameplay shutdown stopped"]
          mapM_ (clean . ($ retirement)) [retiredUi, retiredGameplay]
          pure (domains, ui)
    -- Left the supervision boundary: both owners ended after being asked to, and nothing is armed.
    mapM_
      (\started → atomically (scheduledStatus (startedOwner started)) >>= (`shouldSatisfy` stopped))
      [domainsUi domains, domainsGameplay domains]
    liveCount ui `shouldReturn` 0
    atomically (ticksOutstanding (scheduledEndpoint (startedOwner (domainsGameplay domains)))) `shouldReturn` 0
    atomically (reserved (sharedQueue (domainsShared domains))) `shouldReturn` 0
    -- Two owners of one runtime, each with an identity of its own.
    scheduledIdentity (startedOwner (domainsUi domains)) `shouldNotBe` scheduledIdentity (startedOwner (domainsGameplay domains))
  where
    stopped = \case
      WorkerStopped → True
      _ → False
    clean end = do
      fmap exitKind (endExit end) `shouldBe` Just ExitStopped
      fmap exitNotStarted (endExit end) `shouldBe` Just 0
      fmap exitStarted (endExit end) `shouldBe` Just 0
      fmap (isStopped . resultOutcome) (endInstance end) `shouldBe` Just True
    isStopped = \case
      InstanceStopped → True
      _ → False
