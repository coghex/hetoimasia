-- | The window model and window command examples, run as an executable so the
-- private window drivers and command executor they use stay inside this
-- package. Arguments are Hspec's own, so @--match@ selects examples as it does
-- in any suite.
module Main (main) where

import qualified Test.GLFW.Command as Command
import qualified Test.GLFW.Window as Window
import Test.Hspec (describe, hspec)

main ∷ IO ()
main = hspec (describe "GLFW" (Window.spec >> Command.spec))
