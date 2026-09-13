-- | The runtime component's examples.
--
-- Application composition, the console executable's startup, the logging
-- lifetime, the recovery and terminal-failure reporting adapter, and worker
-- supervision sit under
-- the @Runtime@ group this module roots, so @--match Runtime@ selects the
-- component and nothing else.
module Test.Engine.Runtime.Spec (spec) where

import qualified Test.Engine.Runtime.Application as Application
import qualified Test.Engine.Runtime.Console as Console
import qualified Test.Engine.Runtime.Lifetime as Lifetime
import qualified Test.Engine.Runtime.Reporting as Reporting
import qualified Test.Engine.Runtime.Supervision as Supervision
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Runtime" $ do
  Application.spec
  Console.spec
  Lifetime.spec
  Reporting.spec
  Supervision.spec
