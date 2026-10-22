-- | The runtime adapter's examples. Every execution and lifecycle example
-- acquires real VMs under a real supervision boundary; the structural checks
-- need no VM.
module Test.LuaRuntime.Spec (spec) where

import qualified Test.LuaRuntime.Accounting.Spec
import qualified Test.LuaRuntime.Callbacks
import qualified Test.LuaRuntime.Dependencies
import qualified Test.LuaRuntime.Expected
import qualified Test.LuaRuntime.Gates
import qualified Test.LuaRuntime.HostFailures
import qualified Test.LuaRuntime.Identity
import qualified Test.LuaRuntime.Independence
import qualified Test.LuaRuntime.Instance.Spec
import qualified Test.LuaRuntime.Lifecycle.Spec
import qualified Test.LuaRuntime.Loading
import qualified Test.LuaRuntime.Readiness
import qualified Test.LuaRuntime.Recoverable
import qualified Test.LuaRuntime.Request.Spec
import qualified Test.LuaRuntime.Runner.Spec
import qualified Test.LuaRuntime.Retention.Spec
import qualified Test.LuaRuntime.Subscription.Spec
import qualified Test.LuaRuntime.Scheduled.Spec
import qualified Test.LuaRuntime.Scheduler.Spec
import qualified Test.LuaRuntime.Settlement
import qualified Test.LuaRuntime.Stop
import qualified Test.LuaRuntime.Submission
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "the Lua runtime adapter" $ do
  Test.LuaRuntime.Dependencies.spec
  Test.LuaRuntime.Readiness.spec
  Test.LuaRuntime.Identity.spec
  Test.LuaRuntime.Submission.spec
  Test.LuaRuntime.Settlement.spec
  Test.LuaRuntime.HostFailures.spec
  Test.LuaRuntime.Stop.spec
  Test.LuaRuntime.Gates.spec
  Test.LuaRuntime.Expected.spec
  Test.LuaRuntime.Independence.spec
  Test.LuaRuntime.Callbacks.spec
  Test.LuaRuntime.Recoverable.spec
  Test.LuaRuntime.Scheduler.Spec.spec
  Test.LuaRuntime.Scheduled.Spec.spec
  Test.LuaRuntime.Accounting.Spec.spec
  Test.LuaRuntime.Instance.Spec.spec
  Test.LuaRuntime.Lifecycle.Spec.spec
  Test.LuaRuntime.Loading.spec
  Test.LuaRuntime.Request.Spec.spec
  Test.LuaRuntime.Retention.Spec.spec
  Test.LuaRuntime.Subscription.Spec.spec
  Test.LuaRuntime.Runner.Spec.spec
