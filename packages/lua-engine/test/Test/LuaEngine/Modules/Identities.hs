{-# LANGUAGE OverloadedStrings #-}

-- | The identity a content key makes for a module, read through the public interface: the root and
-- the path, unambiguous, so the loader's one cache never confuses two modules.
module Test.LuaEngine.Modules.Identities (spec) where

import qualified Data.ByteString as ByteString
import Hetoimasia.Content.Identity (ContentKey, identityLimits, parseReference, rootKey)
import Hetoimasia.LuaEngine.Modules
import Test.Hspec

keyIn ∷ ByteString.ByteString → ByteString.ByteString → ContentKey
keyIn root path =
  either (error . show) id $ do
    bounds ← either (Left . show) Right (identityLimits 200 40 8 100)
    checked ← either (Left . show) Right (rootKey root)
    either (Left . show) Right (parseReference bounds checked path)

spec ∷ Spec
spec = describe "the identity of a module" $ do
  it "is the root and the path, so two roots' same-named files are two identities" $ do
    moduleIdentity (keyIn "game" "a.lua") `shouldNotBe` moduleIdentity (keyIn "other" "a.lua")
    moduleIdentity (keyIn "game" "a.lua") `shouldBe` moduleIdentity (keyIn "game" "a.lua")
    moduleIdentity (keyIn "game" "a.lua") `shouldNotBe` moduleIdentity (keyIn "game" "b.lua")

  it "is unambiguous where one root is a prefix of another" $
    moduleIdentity (keyIn "ga" "me/a.lua") `shouldNotBe` moduleIdentity (keyIn "game" "a.lua")

  it "labels the module by its root and path" $
    moduleLabel (keyIn "game" "lua/util.lua") `shouldBe` "game:lua/util.lua"

  it "names the failure codes a module request carries" $
    moduleCodes `shouldBe` ["not_found", "content_changed", "io_error", "too_large", "module_error", "module_cycle", "module_limit"]
