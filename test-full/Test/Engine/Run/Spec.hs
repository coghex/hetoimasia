-- | The @Run@ group of the full-product build: the command's grammar and status as pure functions, its
-- composition over real content in this process, and the built executable and a child of the suite as processes.
-- None acquires a native session; the native launcher is @run-native-tests@'s.
module Test.Engine.Run.Spec (spec) where

import qualified Test.Engine.Run.Abort as Abort
import qualified Test.Engine.Run.Compose as Compose
import qualified Test.Engine.Run.Integrated as Integrated
import qualified Test.Engine.Run.Options as Options
import qualified Test.Engine.Run.Process as Process
import qualified Test.Engine.Run.Serve as Serve
import qualified Test.Engine.Run.Status as Status
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Run" $ do
  Options.spec
  Status.spec
  Abort.spec
  Serve.spec
  Compose.spec
  Integrated.spec
  Process.spec
