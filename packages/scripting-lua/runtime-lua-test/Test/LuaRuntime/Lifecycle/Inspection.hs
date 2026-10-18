-- | What a script reads of instances: bounded snapshots, coherent for an owner, of covered
-- owners only, and nothing of a Lua table.
module Test.LuaRuntime.Lifecycle.Inspection (spec) where

import Control.Monad (forM, forM_)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lifecycle
import Hetoimasia.Scripting.Lua.Registration (bindingName, namespaceBindings)
import Hetoimasia.Scripting.Lua.Scheduled (ServiceClass (OrdinaryClass))
import Hetoimasia.Scripting.Lua.Value (valueLimits)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Lifecycle.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect)
import Test.LuaRuntime.Support (bounded, withBoundary)

-- | A snapshot as a script renders it.
snapshot ∷ Text → Text → Text → Text → Text
snapshot name label status tid = "{name=" <> name <> ",owner=" <> label <> ",status=" <> status <> ",tid=" <> tid <> "}"

spec ∷ Spec
spec = describe "inspection" $ do
  it "answers one instance's snapshot by its numbers, with its owner's label, its name and its status through its life" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      let seen status = "{ok=true,snapshot=" <> snapshot "a" "target" status (renderTid tid) <> "}"
      ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldBe` seen "active")
      _ ← settleControl targetFx owner "a" InstancePause
      ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldBe` seen "paused")
      _ ← settleControl targetFx owner "a" InstanceStop
      awaitPhase targetFx owner "a" Stopped
      ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldBe` seen "stopped")

  it "reads a one-shot that has run to its end as completed, and finds it no longer there to control" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [oneShot] (testConfig instanceBounds')
      _ ← admitWith targetFx owner "once" (InstanceRequest (moduleNamed "oneshot") RunOnce (Just "once") OrdinaryClass ["tick"])
      awaitEffect (sf targetFx) "run begin 1"
      tid ← tidValue targetFx "once"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      awaitEffect (sf targetFx) "run begin 1"
      -- Running its @run@ hook, which waits for the next tick.
      ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=active")
      grantOne control owner
      awaitPhase targetFx owner "once" Completed
      ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=completed")
      ask callerFx caller "cmdr" "stop" (Just tid) Nothing >>= (`shouldBe` "{accepted=false,refusal=unknown_target}")

  it "lists the instances of one owner in order of identity, in one read, and nothing of an owner it was not granted" $ bounded $ do
    targetFx ← newIFixture
    otherFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      other ← startTarget otherFx runtime "other" [echoer] (testConfig instanceBounds')
      forM_ ["a", "b", "c"] $ \name → admit targetFx owner name (moduleNamed "echoer")
      _ ← admit otherFx other "z" (moduleNamed "echoer")
      forM_ ["a", "b", "c"] $ \name → awaitPhase targetFx owner name Active
      tids ← forM ["a", "b", "c"] (tidValue targetFx)
      firstTid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      admitCommander callerFx caller "cmdr"
      let entries = Text.intercalate "," [Text.pack (show n) <> "=" <> snapshot name "target" "active" (renderTid tid) | (n, name, tid) ← zip3 [1 ∷ Int ..] ["a", "b", "c"] tids]
      ask callerFx caller "cmdr" "inspect_owner" (Just firstTid) Nothing
        >>= (`shouldBe` ("{instances={" <> entries <> "},ok=true,truncated=false}"))
      -- The owner outside the grant is not read, and it is not told apart from none.
      zTid ← tidValue otherFx "z"
      ask callerFx caller "cmdr" "inspect_owner" (Just zTid) Nothing >>= (`shouldBe` "{instances={},ok=false,refusal=unauthorized,truncated=false}")

  it "cuts a list at the snapshot bound its grant names, and says so" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      forM_ ["a", "b", "c"] $ \name → admit targetFx owner name (moduleNamed "echoer")
      forM_ ["a", "b", "c"] $ \name → awaitPhase targetFx owner name Active
      tid ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just ((target owner) {grantSnapshotBound = 2}))
      admitCommander callerFx caller "cmdr"
      listed ← ask callerFx caller "cmdr" "inspect_owner" (Just tid) Nothing
      Text.count "name=" listed `shouldBe` 2
      listed `shouldSatisfy` Text.isSuffixOf ",ok=true,truncated=true}"

  it "cuts a list that would not cross within the owner's value limits, rather than faulting its script" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig (InstanceBounds 16 32 8 8))
      let names = [Text.pack [c] | c ← ['a' .. 'l']]
      forM_ names $ \name → admit targetFx owner name (moduleNamed "echoer")
      forM_ names $ \name → awaitPhase targetFx owner name Active
      tid ← tidValue targetFx "a"
      let tight = either (error . show) id (valueLimits 65536 8 60)
      caller ← startWith callerFx runtime (withLimits tight (lifeSpec callerFx (lifeRegistration callerFx) "caller" [commander] cmdConfig (Just (target owner))))
      admitCommander callerFx caller "cmdr"
      listed ← ask callerFx caller "cmdr" "inspect_owner" (Just tid) Nothing
      Text.count "name=" listed `shouldSatisfy` \n → n > 0 && n < 12
      listed `shouldSatisfy` Text.isSuffixOf ",ok=true,truncated=true}"

  it "lists the owners a grant covers with what each permits, and tells an instance its own identity and a task none" $ bounded $ do
    targetFx ← newIFixture
    otherFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      other ← startTarget otherFx runtime "other" [echoer] (testConfig instanceBounds')
      let grant = lifecycleGrant [grantOver owner bothPermits, grantOver other [PermitInspect], GrantTarget GrantedSelf [PermitInspect] Nothing]
      caller ← startCaller callerFx runtime "caller" (Just grant)
      admitCommander callerFx caller "cmdr"
      listed ← ask callerFx caller "cmdr" "owners" Nothing Nothing
      listed `shouldSatisfy` Text.isInfixOf "control=true,inspect=true,label=target"
      listed `shouldSatisfy` Text.isInfixOf "control=false,inspect=true,label=other"
      listed `shouldSatisfy` Text.isInfixOf "control=false,inspect=true,label=caller"
      Text.count "label=" listed `shouldBe` 3
      mine ← tidValue callerFx "cmdr"
      ask callerFx caller "cmdr" "self" Nothing Nothing >>= (`shouldBe` renderTid mine)
      taskLine callerFx caller "who" [] >>= (`shouldBe` "nil")

  it "gives a script no way to control an owner as a whole, and no way into anything but the namespace the application named" $ do
    map bindingName (namespaceBindings (lifecycleNamespace "anything"))
      `shouldBe` ["pause", "resume", "stop", "result", "forget", "inspect", "inspect_owner", "owners", "self"]
