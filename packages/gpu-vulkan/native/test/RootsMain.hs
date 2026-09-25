-- | Entry point for the native backend package's headless suite.
--
-- The examples live in the component specs this module composes under one
-- top-level group, @Native roots@; it declares none of its own. They make no
-- native call. 'configFailOnEmpty' makes a selection that matches no example a
-- failure rather than a silent pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.GPU.Vulkan.Native.Generations as Generations
import qualified Test.GPU.Vulkan.Native.Presentation as Presentation
import qualified Test.GPU.Vulkan.Native.Profile as Profile
import qualified Test.GPU.Vulkan.Native.Recording as Recording
import qualified Test.GPU.Vulkan.Native.Roots as Roots
import Test.Hspec (describe)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main =
  hspecWith defaultConfig {configFailOnEmpty = True} $
    describe "Native roots" $ do
      Profile.spec
      Roots.spec
      Presentation.spec
      Generations.spec
      Recording.spec
