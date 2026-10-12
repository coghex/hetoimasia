module Main (main) where

import Test.Hspec (hspec)
import qualified Test.Render.TwoD.Vulkan.Layout as Layout
import qualified Test.Render.TwoD.Vulkan.Recording as Recording

main ∷ IO ()
main = hspec (Layout.spec >> Recording.spec)
