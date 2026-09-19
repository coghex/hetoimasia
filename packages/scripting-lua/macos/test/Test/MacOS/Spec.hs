-- | LUA-15's proof matrix for macOS, composed.
--
-- The fixture is built once for the whole group: it launches one confined
-- helper, keeps its report, and every example below reads that one run rather
-- than starting its own. The examples that need their own process -- two
-- instances at once, the two limits, the three lifetime endings -- launch it
-- themselves and end it before they return.
module Test.MacOS.Spec (spec) where

import Test.Hspec

import qualified Test.MacOS.Confinement as Confinement
import qualified Test.MacOS.Isolation as Isolation
import qualified Test.MacOS.Lifetime as Lifetime
import qualified Test.MacOS.Limits as Limits
import Test.MacOS.Driver (withFixture)

spec ∷ Spec
spec = describe "MacOS" $ aroundAll withFixture $ do
  Confinement.spec
  Isolation.spec
  Limits.spec
  Lifetime.spec
