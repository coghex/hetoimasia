-- | Examples for component-name validation.
module Test.Foundation.Logging.Component (spec) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (componentText, mkComponent)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Component" $ do
  it "accepts lowercase dotted names" testComponentAccepted
  it "rejects malformed and reserved names" testComponentRejected

testComponentAccepted ∷ IO ()
testComponentAccepted =
  map (fmap componentText . mkComponent) ["gpu.vulkan", "game.world", "lua"]
    `shouldBe` [Right "gpu.vulkan", Right "game.world", Right "lua"]

testComponentRejected ∷ IO ()
testComponentRejected =
  forM_ ["Gpu.Vulkan", "gpu..vulkan", "gpu.", "1gpu", " gpu", "", "all", "none"] $ \name → do
    mkComponent name `shouldSatisfy` isLeft
    -- The rejection is descriptive: it quotes the offending name.
    case mkComponent name of
      Right _ → fail ("accepted " <> show name)
      Left reason → reason `shouldSatisfy` Text.isInfixOf ("\"" <> name <> "\"")
