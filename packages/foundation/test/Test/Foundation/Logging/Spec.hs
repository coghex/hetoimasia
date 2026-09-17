-- | The logging component's examples.
--
-- Every example the logger, its sinks, the record layout, and the logging
-- configuration own sits under the @Logging@ group this module roots, so
-- @--match Logging@ selects the component and nothing else.
module Test.Foundation.Logging.Spec (spec) where

import qualified Test.Foundation.Logging.Component as Component
import qualified Test.Foundation.Logging.Configuration as Configuration
import qualified Test.Foundation.Logging.Context as Context
import qualified Test.Foundation.Logging.Filtering as Filtering
import qualified Test.Foundation.Logging.Layout as Layout
import qualified Test.Foundation.Logging.Sink as Sink
import qualified Test.Foundation.Logging.Worker as Worker
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
