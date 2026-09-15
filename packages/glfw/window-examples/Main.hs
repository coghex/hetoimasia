-- | The window model, window command, window control, window host, and monitor
-- inventory examples, run as an executable so the private window and monitor drivers and
-- command executor they use stay
-- inside this package. Arguments are Hspec's own, so @--match@ selects examples as it does
-- in any suite.
module Main (main) where

import qualified Test.GLFW.Command as Command
import qualified Test.GLFW.Control as Control
import qualified Test.GLFW.Dynamic as Dynamic
import qualified Test.GLFW.Host as Host
import qualified Test.GLFW.Monitor as Monitor
import qualified Test.GLFW.Window as Window
import Test.Hspec (describe, hspec)

main ∷ IO ()
main = hspec (describe "GLFW" (Window.spec >> Command.spec >> Control.spec >> Host.spec >> Dynamic.spec >> Monitor.spec))
