-- | Who does what: sources arrive from a thread that is not the VM's owner and are
-- delivered by the owner; every operation on the loader is refused to any other thread
-- with nothing changed; the owner goes on with its other work while a chain waits; an
-- independent VM does not wait for it; and a seam asked to enter the VM it was called
-- from is refused, not left waiting.
module Test.Lua.Boundary.Loader.Threads (spec) where

import Control.Exception (fromException)
import Data.IORef (readIORef)
import Hetoimasia.Scripting.Lua.Owner
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Loader.Support

spec ∷ Spec
spec = describe "the loader's threads" $ do
  it "resumes a suspended importer only when the owner delivers what another thread found, and refuses every other thread" $
    withRig $ \rig owned → do
      _ ← admit owned "a"
      _ ← supply rig owned "a" ["trace.mark('a:start')", "local b = import('b')", "trace.mark('a:got ' .. b.name)", "return {}"]
      held ← advance owned
      advanceBlocked held `shouldBe` BlockedSource (ident "b")
      -- The provider's thread finds the source and tells the owner; it cannot touch the
      -- loader itself.
      (refused, answer) ← inThread $ do
        delivered ← raised (deliverSource owned (ident "b") (SourceVerified (lua ["return { name = 'b' }"])))
        advanced ← raised (advanceLoader owned)
        admitted ← raised (admitRoot owned (RootRequest (ident "x") "game:x"))
        stopped ← raised (stopModuleLoader owned)
        counted ← raised (moduleLoaderCounts owned)
        looked ← raised (lookupModule owned (ident "b"))
        pure ([isNotOwned delivered, isNotOwned advanced, isNotOwned admitted, isNotOwned stopped, isNotOwned counted, isNotOwned looked], SourceVerified (lua ["return { name = 'b' }"]))
      refused `shouldBe` replicate 6 True
      -- Nothing changed: the importer is still suspended, and nothing of b exists.
      traced rig >>= (`shouldBe` ["a:start"])
      statusOfName owned "b" >>= (`shouldBe` ModulePending)
      deliverSource owned (ident "b") answer >>= (`shouldBe` SourceDelivered)
      traced rig >>= (`shouldBe` ["a:start"])
      _ ← advance owned
      traced rig >>= (`shouldBe` ["a:start", "a:got b"])
      ledger owned >>= (`shouldSatisfy` balanced)

  it "lets the owner run other Lua and stop while a chain waits for a source" $
    withRigAt (\config → config {vmModules = [hookDriver]}) $ \rig owned → do
      _ ← supply rig owned "ready" ["return { name = 'ready' }"]
      _ ← supply rig owned "hook" ["return { gameplay = { init = function(self, api) trace.mark('hook ran ' .. import('ready').name) end } }"]
      _ ← admit owned "ready"
      _ ← admit owned "hook"
      _ ← advance owned
      _ ← admit owned "waits"
      _ ← supply rig owned "waits" ["local never = import('never')", "return {}"]
      held ← advance owned
      advanceBlocked held `shouldBe` BlockedSource (ident "never")
      advanceChainDepth held `shouldBe` 1
      -- Hooks run while the chain is unfinished.
      runInit owned "hook"
      traced rig >>= (`shouldBe` ["hook ran ready"])
      ledger owned >>= \found → ledgerTasks found `shouldBe` 1
      -- And the owner can stop it: its coroutine is closed and nothing is left held.
      report ← stopModuleLoader owned
      (stopFrames report, stopWasStopped report) `shouldBe` (1, False)
      ledger owned >>= \found → (ledgerTasks found, balanced found) `shouldBe` (0, True)

  it "does not make an independent VM wait for another's held source" $
    withRig $ \rig owned → do
      _ ← admit owned "held"
      _ ← supply rig owned "held" ["local x = import('never')", "return {}"]
      blocked ← advance owned
      advanceBlocked blocked `shouldBe` BlockedSource (ident "never")
      (status, marks) ← inThread . withRig $ \rig' owned' → do
        _ ← supply rig' owned' "free" ["trace.mark('free')", "return {}"]
        _ ← admit owned' "free"
        _ ← advance owned'
        (,) <$> statusOfName owned' "free" <*> traced rig'
      status `shouldSatisfy` \case ModuleReady _ → True; _ → False
      marks `shouldBe` ["free"]
      -- This one is still waiting where it was.
      statusOfName owned "held" >>= (`shouldBe` ModuleEvaluating)

  it "refuses a seam's attempt to run Lua on the VM it was called from, as a re-entry, and goes on" $
    withRig $ \rig owned → do
      pointRigAt rig owned
      _ ← admit owned "a"
      _ ← supply rig owned "a" ["local b = import('b')", "local c = pcall(import, '../no')", "return {}"]
      _ ← supply rig owned "b" ["return {}"]
      _ ← advance owned
      attempts ← readIORef (rigReentered rig)
      -- The acquires ran on the owner's thread and inside a callback, the resolver inside
      -- a callback; each was refused as a re-entry, and none waited.
      attempts `shouldSatisfy` (not . null)
      attempts `shouldSatisfy` all (`elem` ["acquire:reentered", "resolve:reentered"])
      attempts `shouldSatisfy` elem "resolve:reentered"
      attempts `shouldSatisfy` elem "acquire:reentered"
      statusOfName owned "a" >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)
  where
    isNotOwned outcome = case outcome of
      Left failure → maybe False (\(VmNotOwned _) → True) (fromException failure)
      Right _ → False
