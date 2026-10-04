-- | Entry point for the sprites sample's headless suite.
--
-- The examples live in the modules below; this module declares none of its
-- own. They need no device, display or GLFW session. 'configFailOnEmpty'
-- makes a selection that matches no example a failure rather than a silent
-- pass.
--
-- @tools/vulkan/run.sh test@ is what builds and runs this suite, as part of
-- the validation group @test.vulkan-headless@.
module Main (main) where

import qualified Test.Sample.Sprites.Fixtures as Fixtures
import qualified Test.Sample.Sprites.Oracle as Oracle
import qualified Test.Sample.Sprites.Png as Png
import qualified Test.Sample.Sprites.Record as Record
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, hspecWith)

main ∷ IO ()
main = hspecWith defaultConfig {configFailOnEmpty = True} (Fixtures.spec >> Oracle.spec >> Png.spec >> Record.spec)
