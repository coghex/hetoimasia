-- | Entry point for the native backend package's headless suite.
--
-- The examples live in the component specs this module composes under one
-- top-level group, @Native roots@; it declares none of its own. They make no
-- native call. 'configFailOnEmpty' makes a selection that matches no example a
-- failure rather than a silent pass.
--
-- @tools/vulkan-proof/run-proof.sh --headless@ is what builds and runs this
-- suite, and it hands every suite it runs its own @--headless@ mode flag, which
-- means nothing more here than it already is: this suite is headless whatever
-- it is given. It is dropped before Hspec reads the arguments.
module Main (main) where

import System.Environment (getArgs, withArgs)
import qualified Test.GPU.Vulkan.Native.Profile as Profile
import qualified Test.GPU.Vulkan.Native.Roots as Roots
import Test.Hspec (describe)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = do
  arguments ← filter (/= "--headless") <$> getArgs
  withArgs arguments $
    hspecWith defaultConfig {configFailOnEmpty = True} $
      describe "Native roots" $ do
        Profile.spec
        Roots.spec
