-- | The gameplay workspace's leases on every path an instance can end by (#499 requirement 10): whatever the script
-- does with the handle it was given, and however the instance or the owner ends, the engine releases what was
-- acquired, once; and a release that itself fails is cleanup evidence that ends the owner fatally, never a failure of the
-- session's own.
module Test.Domains.Leases (spec) where

import Control.Concurrent.STM (atomically, modifyTVar', readTVarIO)
import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsShared)
  , DomainsConfig (configExtensions, configGameplaySource, configInput)
  , Evidence (evidenceGameplay, evidenceWorkspaces)
  , Extension (Extension)
  , OwnerEvidence (evidenceEnded)
  , SessionStatus (Failed)
  , Where (InGameplay)
  , cleanupEvidence
  , retireDomains
  , stopSession
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedLeases, sharedWorkspaces))
import Hetoimasia.Sample.LuaDomains.Snapshot (GameSnapshot (snapStatus))
import Hetoimasia.Sample.LuaDomains.Tally (Workspaces (..))
import Hetoimasia.Scripting.Lua.Lease (acquireOwned, leaseHandle)
import Hetoimasia.Scripting.Lua.Registration (Namespace, namespace, stateOperation)
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability), Value)
import Hetoimasia.Foundation.Resource (acquirePart, releaseRank)
import Test.Domains.Support
import Test.Hspec

-- | What the workspaces came to, as the tally counts it: acquired, released, and release failed.
tallyOf ∷ Domains → IO (Int, Int, Int)
tallyOf domains = do
  held ← readTVarIO (sharedWorkspaces (domainsShared domains))
  pure (workspacesAcquired held, workspacesReleased held, workspacesReleaseFailed held)

gameplay ∷ [Text] → DomainsConfig → DomainsConfig
gameplay source config = config {configGameplaySource = luaLines source, configInput = []}

spec ∷ Spec
spec = describe "the gameplay workspace's leases" $ do
  describe "are released once, by the engine, on every path the instance ends by" $ do
    it "on a stop: the handle the init kept is released when the session is stopped" $
      withSample id $ \_ _ domains → do
        _ ← stepCommitted domains
        tallyOf domains `shouldReturn` (1, 0, 0)
        _ ← stopSession domains
        tallyOf domains `shouldReturn` (1, 1, 0)

    it "on an absent shutdown: the instance has no hook to release it, and the engine does" $
      withSample (gameplay ["function init(self, api) self.w = workspace.open() end", "function update(self, dt) staging.finish() end"]) $ \_ _ domains → do
        _ ← stopSession domains
        tallyOf domains `shouldReturn` (1, 1, 0)

    it "on a shutdown that raises: the session fails, and the lease is released all the same" $
      withSample (gameplay ["function init(self, api) self.w = workspace.open() end", "function update(self, dt) staging.finish() end", "function shutdown(self, reason) error('shutdown failed') end"]) $ \_ _ domains → do
        _ ← stepCommitted domains
        _ ← stopSession domains
        tallyOf domains `shouldReturn` (1, 1, 0)
        (latest, _) ← snapshotNow domains
        snapStatus latest `shouldSatisfy` isFailed

    it "on a failed init that had acquired: the initial snapshot says failed, and the lease is released when the instance ends" $
      withSample (gameplay ["function init(self, api) self.w = workspace.open() error('init failed') end", "function update(self, dt) staging.finish() end"]) $ \_ _ domains → do
        (latest, _) ← snapshotNow domains
        snapStatus latest `shouldSatisfy` isFailed
        _ ← stopSession domains
        tallyOf domains `shouldReturn` (1, 1, 0)

    it "when the script overwrites the handle it was given: both leases are the engine's, and both are released" $
      withSample (gameplay ["function init(self, api) self.w = workspace.open() self.w = workspace.open() end", "function update(self, dt) staging.finish() end"]) $ \_ _ domains → do
        _ ← stepCommitted domains
        tallyOf domains `shouldReturn` (2, 0, 0)
        _ ← stopSession domains
        tallyOf domains `shouldReturn` (2, 2, 0)

    it "when the script never stores the handle: the lease is still held until the instance ends, and released then" $
      withSample (gameplay ["function init(self, api) workspace.open() end", "function update(self, dt) staging.finish() end"]) $ \_ _ domains → do
        _ ← stepCommitted domains
        tallyOf domains `shouldReturn` (1, 0, 0)
        _ ← stopSession domains
        tallyOf domains `shouldReturn` (1, 1, 0)

    it "when the owner is retired without a stop: retirement releases it" $
      withSample id $ \_ _ domains → do
        _ ← stepCommitted domains
        void (retireDomains domains)
        tallyOf domains `shouldReturn` (1, 1, 0)

  describe "beyond the capacity" $
    it "is refused by the engine, the refused invocation fails the session, and what was acquired is released" $
      withSample (gameplay ["function init(self, api) self.a = workspace.open() self.b = workspace.open() self.c = workspace.open() end", "function update(self, dt) staging.finish() end"]) $ \_ _ domains → do
        (latest, _) ← snapshotNow domains
        snapStatus latest `shouldSatisfy` isFailed
        _ ← stopSession domains
        (acquired, released, failed) ← tallyOf domains
        (acquired, released, failed) `shouldBe` (2, 2, 0)

  describe "a release that itself fails" $
    it "is cleanup evidence that ends the gameplay owner fatally and terminates its worker, and it is not a recoverable session failure" $ do
      fx ← newFx
      ui ← newFakeUi
      seen ← newIORef Nothing
      let config = (sampleConfig fx ui) {configGameplaySource = luaLines ["function init(self, api) self.w = rig.open() end", "function update(self, dt) staging.finish() end"], configInput = []}
          rigged shared = configExtensions (sampleConfig fx ui) shared <> [Extension (rig shared) InGameplay []]
      outcome ← try @SomeException . withBoundary $ \control →
        withDomains control config {configExtensions = rigged} $ \domains → do
          _ ← stepCommitted domains
          -- The stop may be told of the fatal end first; retirement waits for the worker's raw completion.
          _ ← try @SomeException (stopSession domains)
          _ ← try @SomeException (retireDomains domains)
          evidence ← cleanupEvidence domains
          (latest, _) ← snapshotNow domains
          writeIORef seen (Just (evidenceEnded (evidenceGameplay evidence), evidenceWorkspaces evidence, isFailed (snapStatus latest)))
      -- The release failure is the cleanup evidence that ended the owner: it is the supervised failure that propagates.
      outcome `shouldSatisfy` isLeft
      found ← readIORef seen
      -- The worker ended; the failed release is counted apart from the released; and the session did not fail.
      fmap (\(ended, held, failed) → (ended, (workspacesAcquired held, workspacesReleased held, workspacesReleaseFailed held), failed)) found
        `shouldBe` Just (True, (1, 0, 1), False)
  where
    isFailed = \case
      Failed _ → True
      _ → False
    rig ∷ Shared → Namespace
    rig shared =
      namespace
        "rig"
        [ stateOperation "open" [] [SCapability "workspace"] $ \_ → do
            lease ← acquireOwned (sharedLeases shared) $ \_ →
              acquirePart
                "rigged workspace"
                (releaseRank 0)
                (pure ())
                (\_ → atomically (modifyTVar' (sharedWorkspaces shared) (\held → held {workspacesReleaseFailed = workspacesReleaseFailed held + 1})) >> ioError (userError "the release failed"))
            atomically (modifyTVar' (sharedWorkspaces shared) (\held → held {workspacesAcquired = workspacesAcquired held + 1}))
            pure [leaseHandle "workspace" lease ∷ Value]
        ]
