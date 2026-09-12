-- | The logging component's examples.
--
-- Every example the logger, its sinks, the record layout, and the logging
-- configuration own sits under the @Logging@ group this module roots, so
-- @--match Logging@ selects the component and nothing else.
module Test.Engine.Logging.Spec (spec) where

import qualified Test.Engine.Logging.Component as Component
import qualified Test.Engine.Logging.Configuration as Configuration
import qualified Test.Engine.Logging.Context as Context
import qualified Test.Engine.Logging.Filtering as Filtering
import qualified Test.Engine.Logging.Layout as Layout
import qualified Test.Engine.Logging.Sink as Sink
import qualified Test.Engine.Logging.Worker as Worker
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Logging" $ do
  Component.spec
  Filtering.spec
  Context.spec
  Layout.spec
  Sink.spec
  Worker.spec
  Configuration.spec
