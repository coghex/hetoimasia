-- | The value boundary's contracts, composed: registration, bounded values,
-- bindings, modules, handles, discipline and the faults they report.
module Test.Lua.Boundary.Spec (spec) where

import Test.Hspec (Spec, describe)
import qualified Test.Lua.Boundary.ArgumentChecks
import qualified Test.Lua.Boundary.Bindings
import qualified Test.Lua.Boundary.Dependencies
import qualified Test.Lua.Boundary.Discipline
import qualified Test.Lua.Boundary.ExportTable
import qualified Test.Lua.Boundary.Exports
import qualified Test.Lua.Boundary.Finalizers
import qualified Test.Lua.Boundary.Independence
import qualified Test.Lua.Boundary.Installation
import qualified Test.Lua.Boundary.Lifecycle
import qualified Test.Lua.Boundary.Loader
import qualified Test.Lua.Boundary.Loader.Failures
import qualified Test.Lua.Boundary.Loader.Limits
import qualified Test.Lua.Boundary.Loader.Placed
import qualified Test.Lua.Boundary.Loader.Stop
import qualified Test.Lua.Boundary.Loader.Threads
import qualified Test.Lua.Boundary.Modules
import qualified Test.Lua.Boundary.Recoverable
import qualified Test.Lua.Boundary.Registration
import qualified Test.Lua.Boundary.Release
import qualified Test.Lua.Boundary.Requests
import qualified Test.Lua.Boundary.Tasks
import qualified Test.Lua.Boundary.Values

spec ∷ Spec
spec = describe "the value boundary" $ do
  Test.Lua.Boundary.Bindings.spec
  Test.Lua.Boundary.Recoverable.spec
  Test.Lua.Boundary.ArgumentChecks.spec
  Test.Lua.Boundary.Registration.spec
  Test.Lua.Boundary.Release.spec
  Test.Lua.Boundary.Values.spec
  Test.Lua.Boundary.Modules.spec
  Test.Lua.Boundary.Exports.spec
  Test.Lua.Boundary.ExportTable.spec
  Test.Lua.Boundary.Loader.spec
  Test.Lua.Boundary.Loader.Failures.spec
  Test.Lua.Boundary.Loader.Limits.spec
  Test.Lua.Boundary.Loader.Placed.spec
  Test.Lua.Boundary.Loader.Stop.spec
  Test.Lua.Boundary.Loader.Threads.spec
  Test.Lua.Boundary.Tasks.spec
  Test.Lua.Boundary.Discipline.spec
  Test.Lua.Boundary.Finalizers.spec
  Test.Lua.Boundary.Independence.spec
  Test.Lua.Boundary.Installation.spec
  Test.Lua.Boundary.Lifecycle.spec
  Test.Lua.Boundary.Requests.spec
  Test.Lua.Boundary.Dependencies.spec
