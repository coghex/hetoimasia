-- | What stopping the loader leaves behind, and what a late or duplicate source may
-- do: every suspended module closed on the owner with its to-be-closed handlers run,
-- every source interest withdrawn once, every pending identity marked stopped (which is
-- not a failure), nothing resumed or published afterwards, and every failure of the
-- closing kept beside the first.
module Test.Lua.Boundary.Loader.Stop (spec) where

import Control.Monad (forM_)
import Data.IORef (writeIORef)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailures)
import Hetoimasia.Scripting.Lua.Owner
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Loader.Support

-- | A module that notes when its to-be-closed handler runs, then imports what it is given.
closing ∷ Text → Text → [Text]
closing name next =
  [ "local guard <close> = setmetatable({}, { __close = function() trace.mark('closed " <> name <> "') end })"
  , "local dependency = import('" <> next <> "')"
  , "return {}"
  ]

-- | A chain of this many modules, the last waiting for a source that never comes.
suspendedAt ∷ Rig → OwnedVm → Int → IO [Text]
suspendedAt rig owned depth = do
  let names = ["n" <> Text.pack (show i) | i ← [1 .. depth]]
      nexts = drop 1 names <> ["held"]
  forM_ (zip names nexts) $ \(name, next) → supply rig owned name (closing name next)
  _ ← admit owned "n1"
  report ← advance owned
  advanceBlocked report `shouldBe` BlockedSource (ident "held")
  advanceChainDepth report `shouldBe` depth
  pure names

spec ∷ Spec
spec = describe "stopping the loader" $ do
  forM_ [1, 2, 3] $ \depth →
    it ("closes a chain suspended at depth " <> show depth <> ", innermost first, and withdraws every interest") $
      withRig $ \rig owned → do
        names ← suspendedAt rig owned depth
        report ← stopModuleLoader owned
        stopFrames report `shouldBe` depth
        stopWasStopped report `shouldBe` False
        stopWithdrawn report `shouldBe` 1
        Set.fromList (stopIdentities report) `shouldBe` Set.fromList (map ident ("held" : names))
        -- Their closing handlers ran, innermost first, on the owner.
        traced rig >>= (`shouldBe` reverse ["closed " <> name | name ← names])
        forM_ ("held" : names) $ \name → statusOfName owned name >>= (`shouldBe` ModuleStopped)
        found ← ledger owned
        found `shouldSatisfy` balanced
        ledgerTasks found `shouldBe` 0
        let counts = ledgerCounts found
        (countInterestsHeld counts, countSourcesHeld counts, countQueued counts, countChainDepth counts, countEvaluating counts) `shouldBe` (0, 0, 0, 0, 0)
        released rig >>= \freed → (Set.fromList freed, length freed) `shouldBe` (Set.fromList (map ident ("held" : names)), depth + 1)

  describe "an owner that stops allowing evaluation" $ do
    it "does not resume an importer when its dependency finishes after the stop began, leaves it for the stop, and resumes it if allowed again" $
      withRig $ \rig owned → do
        _ ← supply rig owned "a" ["trace.mark('a:start')", "local b = import('b')", "trace.mark('a:got ' .. b.name)", "return {}"]
        _ ← supply rig owned "b" ["trace.mark('b:start')", "trace.deny()", "trace.mark('b:end')", "return { name = 'b' }"]
        _ ← admit owned "a"
        report ← advance owned
        advanceBlocked report `shouldBe` BlockedNotAllowed
        -- The dependency finished (it was running); the importer did not resume.
        traced rig >>= (`shouldBe` ["a:start", "b:start", "b:end"])
        statusOfName owned "b" >>= (`shouldSatisfy` isReadyStatus)
        statusOfName owned "a" >>= (`shouldBe` ModuleEvaluating)
        -- Asking again changes nothing while it is not allowed.
        again ← advance owned
        advanceBlocked again `shouldBe` BlockedNotAllowed
        traced rig >>= (`shouldBe` ["a:start", "b:start", "b:end"])
        writeIORef (rigAllowed rig) True
        resumed ← advance owned
        advanceBlocked resumed `shouldBe` BlockedIdle
        traced rig >>= (`shouldBe` ["a:start", "b:start", "b:end", "a:got b"])
        ledger owned >>= (`shouldSatisfy` balanced)

    it "starts no dependency after the stop began, and the stop finds it pending with its interest withdrawn" $
      withRig $ \rig owned → do
        _ ← supply rig owned "a" ["trace.mark('a:start')", "trace.deny()", "local b = import('b')", "trace.mark('a:got')", "return {}"]
        _ ← supply rig owned "b" ["trace.mark('b:start')", "return {}"]
        _ ← admit owned "a"
        report ← advance owned
        advanceBlocked report `shouldBe` BlockedNotAllowed
        traced rig >>= (`shouldBe` ["a:start"])
        statusOfName owned "b" >>= (`shouldBe` ModulePending)
        stopped ← stopModuleLoader owned
        stopFrames stopped `shouldBe` 1
        traced rig >>= (`shouldBe` ["a:start"])
        statusOfName owned "a" >>= (`shouldBe` ModuleStopped)
        statusOfName owned "b" >>= (`shouldBe` ModuleStopped)
        released rig >>= \freed → Set.fromList freed `shouldBe` Set.fromList [ident "a", ident "b"]
        ledger owned >>= (`shouldSatisfy` balanced)

    it "starts no root after the stop began" $
      withRig $ \rig owned → do
        _ ← supply rig owned "first" ["trace.mark('first:start')", "trace.deny()", "return {}"]
        _ ← supply rig owned "second" ["trace.mark('second:start')", "return {}"]
        _ ← admit owned "first"
        _ ← admit owned "second"
        report ← advance owned
        advanceBlocked report `shouldBe` BlockedNotAllowed
        traced rig >>= (`shouldBe` ["first:start"])
        statusOfName owned "second" >>= (`shouldBe` ModulePending)
        _ ← stopModuleLoader owned
        statusOfName owned "second" >>= (`shouldBe` ModuleStopped)
        traced rig >>= (`shouldBe` ["first:start"])

  it "marks what was only pending as stopped, withdraws its interest and publishes nothing of it" $
    withRig $ \rig owned → do
      _ ← admit owned "waiting"
      report ← stopModuleLoader owned
      stopIdentities report `shouldBe` [ident "waiting"]
      stopFrames report `shouldBe` 0
      released rig >>= (`shouldBe` [ident "waiting"])
      statusOfName owned "waiting" >>= (`shouldBe` ModuleStopped)
      ledger owned >>= (`shouldSatisfy` balanced)

  it "drops a source that arrived and was not used yet, and releases its interest" $
    withRig $ \rig owned → do
      _ ← admit owned "arrived"
      _ ← supply rig owned "arrived" ["trace.mark('never')", "return {}"]
      before ← moduleLoaderCounts owned
      countSourcesHeld before `shouldBe` 1
      _ ← stopModuleLoader owned
      traced rig >>= (`shouldBe` [])
      after ← moduleLoaderCounts owned
      (countSourcesHeld after, countInterestsHeld after) `shouldBe` (0, 0)
      released rig >>= (`shouldBe` [ident "arrived"])

  it "is terminal and idempotent: nothing more is admitted, delivered or run, and a second stop does nothing" $
    withRig $ \rig owned → do
      _ ← suspendedAt rig owned 2
      _ ← stopModuleLoader owned
      second ← stopModuleLoader owned
      second `shouldBe` StopReport [] 0 0 True
      admit owned "late" >>= (`shouldBe` RootClosed)
      deliverSource owned (ident "held") (SourceVerified (lua ["return {}"])) >>= (`shouldBe` SourceAfterStop)
      deliverSource owned (ident "n1") (SourceVerified (lua ["return {}"])) >>= (`shouldBe` SourceAfterStop)
      report ← advance owned
      advanceBlocked report `shouldBe` BlockedStopped
      traced rig >>= (`shouldBe` ["closed n2", "closed n1"])
      statusOfName owned "held" >>= (`shouldBe` ModuleStopped)
      released rig >>= \freed → length freed `shouldBe` 3

  it "keeps what completed: a ready module answers lookups and the hooks' imports after the stop" $
    withRigAt (\config → config {vmModules = [hookDriver]}) $ \rig owned → do
      _ ← supply rig owned "ready" ["return { name = 'ready' }"]
      _ ← supply rig owned "hook" ["return { gameplay = { init = function(self, api) trace.mark(import('ready').name) end } }"]
      _ ← admit owned "ready"
      _ ← admit owned "hook"
      _ ← advance owned
      _ ← stopModuleLoader owned
      statusOfName owned "ready" >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)
      runInit owned "hook"
      traced rig >>= (`shouldBe` ["ready"])

  describe "late and duplicate deliveries" $ do
    it "refuses a second delivery before the advance, one after the module used it, and one nobody asked for" $
      withRig $ \rig owned → do
        _ ← admit owned "a"
        deliverSource owned (ident "a") (SourceVerified (lua ["return {}"])) >>= (`shouldBe` SourceDelivered)
        deliverSource owned (ident "a") (SourceVerified (lua ["error('replaced')"])) >>= (`shouldBe` SourceDuplicate)
        deliverSource owned (ident "a") SourcePending >>= (`shouldBe` SourceNotYet)
        _ ← advance owned
        statusOfName owned "a" >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)
        deliverSource owned (ident "a") (SourceVerified (lua ["error('after')"])) >>= (`shouldBe` SourceDuplicate)
        deliverSource owned (ident "nobody") (SourceVerified (lua ["return {}"])) >>= (`shouldBe` SourceUnwanted)
        statusOfName owned "a" >>= (`shouldSatisfy` \case ModuleReady _ → True; _ → False)
        ledger owned >>= (`shouldSatisfy` balanced)
        acquired rig >>= (`shouldBe` [ident "a"])

    it "does not resume or publish into a stopped loader" $
      withRig $ \rig owned → do
        _ ← suspendedAt rig owned 2
        _ ← stopModuleLoader owned
        before ← traced rig
        deliverSource owned (ident "held") (SourceVerified (lua ["trace.mark('resumed')", "return {}"])) >>= (`shouldBe` SourceAfterStop)
        _ ← advance owned
        traced rig >>= (`shouldBe` before)
        statusOfName owned "held" >>= (`shouldBe` ModuleStopped)

  describe "failures while stopping" $ do
    it "attempts every close and every release, raises the first failure with the others as cleanup evidence, and is stopped regardless" $
      withRig $ \rig owned → do
        let failing name next =
              [ "local guard <close> = setmetatable({}, { __close = function() trace.mark('closing " <> name <> "') error('" <> name <> " failed') end })"
              , "local dependency = import('" <> next <> "')"
              , "return {}"
              ]
        _ ← supply rig owned "outer" (failing "outer" "inner")
        _ ← supply rig owned "inner" (failing "inner" "held")
        _ ← admit owned "outer"
        _ ← advance owned
        writeIORef (rigReleaseFails rig) (Set.fromList (map ident ["held"]))
        stopped ← raised (stopModuleLoader owned)
        case stopped of
          Right _ → fail "the stop reported nothing although closing failed"
          Left failure → do
            -- Both handlers ran although the first failed, and the release failed too.
            traced rig >>= (`shouldBe` ["closing inner", "closing outer"])
            length (cleanupFailures failure) `shouldSatisfy` (>= 2)
            map cleanupFailureLabel (cleanupFailures failure) `shouldSatisfy` elem "lua source release"
        -- Terminal: not retried, and nothing is left held.
        again ← stopModuleLoader owned
        stopWasStopped again `shouldBe` True
        released rig >>= \freed → length freed `shouldBe` 3
        found ← ledger owned
        (ledgerTasks found, balanced found) `shouldBe` (0, True)
        forM_ ["outer", "inner", "held"] $ \name → statusOfName owned name >>= (`shouldBe` ModuleStopped)

-- | Whether a status is a ready module.
isReadyStatus ∷ ModuleStatus → Bool
isReadyStatus = \case
  ModuleReady _ → True
  _ → False
