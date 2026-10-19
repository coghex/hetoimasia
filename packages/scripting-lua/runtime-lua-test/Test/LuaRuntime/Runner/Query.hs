-- | The read-only query of which hooks a module defines, answered by a scheduled owner that loaded it.
module Test.LuaRuntime.Runner.Query (spec) where

import Control.Concurrent.STM (atomically)
import Data.IORef (readIORef)
import Hetoimasia.Scripting.Lua.Instance (ModuleHooks (..), moduleHooks)
import Hetoimasia.Scripting.Lua.Owner (ModuleRef (ModuleRef))
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (Active))
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

spec ∷ Spec
spec = describe "the query of what a module defines" $ do
  it "answers defined, absent and present-but-not-a-function, and nothing for a module the owner did not load" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "query" [echoer, noHooks, initValue, shutdownValue, oneShot] (testConfig instanceBounds') requiredPolicy
      let ask name = atomically (moduleHooks (scheduledEndpoint owner) (ModuleRef name "1"))
      -- echoer: init, update and shutdown, no run.
      ask "echoer" `shouldReturn` Just (ModuleHooks True True True False)
      ask "nohooks" `shouldReturn` Just (ModuleHooks False False False False)
      -- init = 42: present and not a function counts as defined, as the instance's own check counts it.
      ask "initvalue" `shouldReturn` Just (ModuleHooks True False True False)
      ask "shutdownvalue" `shouldReturn` Just (ModuleHooks True False True False)
      ask "never-loaded" `shouldReturn` Nothing
      ask "oneshot" >>= \found → fmap hooksRun found `shouldBe` Just True

  it "runs no code of the module, and does not change for the owner's life" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let counted =
            hooksModule
              "counted"
              [ "inst.next()"
              , "function init(self, api) inst.next() end"
              , "function update(self, dt) inst.next() end"
              , "function run(self, api) inst.next() end"
              , "function shutdown(self, reason) inst.next() end"
              ]
      owner ← startInstances fixture runtime "query" [counted] (testConfig instanceBounds') requiredPolicy
      let ask = atomically (moduleHooks (scheduledEndpoint owner) (ModuleRef "counted" "1"))
      -- The top level ran once, as the module loaded; no hook has run, and asking runs none.
      readIORef (ifCounter fixture) `shouldReturn` 1
      first ← ask
      first `shouldBe` Just (ModuleHooks True True True True)
      _ ← ask
      readIORef (ifCounter fixture) `shouldReturn` 1
      -- An instance of the module runs hooks; the answer is the same afterwards.
      ticket ← admit fixture owner "c" (ModuleRef "counted" "1")
      awaitPhase fixture owner "c" Active
      readIORef (ifCounter fixture) >>= \moved → moved `shouldBe` 2
      ask `shouldReturn` first
      pure (ticket `seq` ())
