{-# LANGUAGE OverloadedStrings #-}

-- | The scene's bounds: 4,096 sprites, a 2 MiB encoded input, nesting of 4 and the element count that
-- follows, applied while the value is read, and told apart from a refusal of the schema.
--
-- Most ceilings of the fixed profile are not reachable by a valid scene before another limit refuses
-- it, so the byte, depth, element and sprite bounds are also exercised under validated, smaller
-- profiles: the accounting is the host's (a table is 5 bytes and its keys and values, a number 9, a
-- string 5 and its length, a capability 21; elements count values and not keys), so a scene of n
-- sprites is exactly @82 + 116 n@ bytes and @6 + 6 n@ elements, and a profile of exactly that size
-- accepts it and one byte or element less refuses it.
module Test.LuaEngine.Scene.Limits (spec) where

import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (ByteLimit (SceneInputBytes), CountLimit (SceneDepth, SceneSprites), fixedM1Profile)
import Hetoimasia.LuaEngine.Scene
import Hetoimasia.Scripting.Lua.Lease (newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VList, VRecord), limitBytes, limitDepth, limitElements)
import Test.Hspec
import Test.LuaEngine.Scene.Support

spec ∷ Spec
spec = describe "limits" $ do
  derived
  sprites
  bytes
  depth
  malformed
  direct

derived ∷ Spec
derived = describe "from the profile" $
  it "are 4,096 sprites, 2 MiB, depth 4 and the elements of a maximal scene, with the coordinate and extent ranges" $ do
    Right limits ← pure (sceneLimits fixedM1Profile)
    sceneSpriteLimit limits `shouldBe` 4096
    limitBytes (sceneValueLimits limits) `shouldBe` 2097152
    limitDepth (sceneValueLimits limits) `shouldBe` 4
    limitElements (sceneValueLimits limits) `shouldBe` 6 + 6 * 4096
    (sceneCoordinateLimit limits, sceneExtentLimit limits) `shouldBe` (1000000, 1000000)

-- | A script that builds this many sprites, each its own table, and publishes them under @pcall@.
publishing ∷ Int → Text
publishing count =
  Text.unlines
    [ "local t = self.ts.a"
    , "local sprites = {}"
    , "for i = 1, " <> Text.pack (show count) <> " do sprites[i] = {texture = t, x = i % 1000, y = 0, width = 1, height = 1} end"
    , "local ok, err = pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = sprites})"
    , "if ok then return 'ok' end"
    , "return 'refused ' .. tostring(err)"
    ]

sprites ∷ Spec
sprites = describe "the sprite count" $ do
  it "accepts 4,096 sprites and refuses 4,097 at the element bound the count gives, as a limit and not as a schema fault" $
    withReady $ \session vm sink _ → do
      evalOk session vm "i" "k4096" (publishing 4096) "ok"
      publishedCount sink `shouldReturn` 1
      [prepared] ← published sink
      length (sceneSprites (preparedContent prepared)) `shouldBe` 4096
      answer ← eval session vm "i" "k4097" (publishing 4097)
      answer `shouldBe` "refused scene.publish: argument 1: more than 24582 values"
      publishedCount sink `shouldReturn` 1

  it "holds a smaller profile to its own sprite count, one past it refused" $
    withReadyUnder (sceneProfile [(SceneSprites, 2)] []) $ \session vm sink _ → do
      evalOk session vm "i" "k2" (publishing 2) "ok"
      eval session vm "i" "k3" (publishing 3) >>= (`shouldBe` "refused scene.publish: argument 1: more than 18 values")
      publishedCount sink `shouldReturn` 1

bytes ∷ Spec
bytes = describe "the encoded bytes" $ do
  it "accepts a scene of exactly the limit and refuses one byte less, by the host's accounting of a scene of n sprites as 82 + 116 n" $ do
    let exact n = 82 + 116 * n
    withReadyUnder (sceneProfile [] [(SceneInputBytes, exact 3)]) $ \session vm sink _ → do
      evalOk session vm "i" "k0" (publishing 0) "ok"
      evalOk session vm "i" "k3" (publishing 3) "ok"
      eval session vm "i" "k4" (publishing 4) >>= (`shouldBe` "refused scene.publish: argument 1: more than 430 bytes")
      publishedCount sink `shouldReturn` 2
    withReadyUnder (sceneProfile [] [(SceneInputBytes, exact 3 - 1)]) $ \session vm sink _ → do
      evalOk session vm "i" "k2" (publishing 2) "ok"
      eval session vm "i" "k3" (publishing 3) >>= (`shouldBe` "refused scene.publish: argument 1: more than 429 bytes")
      publishedCount sink `shouldReturn` 1

depth ∷ Spec
depth = describe "the nesting" $ do
  it "reads a valid scene at depth 3, and refuses a deeper table as a limit where the schema alone would refuse a shallower one" $
    withReady $ \session vm sink _ → do
      let withField field = Text.unlines ["local t = self.ts.a", "local ok, err = pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = {{texture = t, x = " <> field <> ", y = 0, width = 1, height = 1}}})", "if ok then return 'ok' end", "return 'refused ' .. tostring(err)"]
      -- Depth 4 is within the limit, so the schema refuses it; depth 5 is the limit's.
      eval session vm "i" "k4" (withField "{}") >>= (`shouldSatisfy` Text.isInfixOf "expected number, found table")
      eval session vm "i" "k5" (withField "{{}}") >>= (`shouldBe` "refused scene.publish: argument 1: nested deeper than 4")
      publishedCount sink `shouldReturn` 0

  it "holds a smaller profile to its own depth: an empty scene at depth 2 is read and a scene with one sprite at depth 3 is not" $
    withReadyUnder (sceneProfile [(SceneDepth, 2)] []) $ \session vm sink _ → do
      evalOk session vm "i" "k0" (publishing 0) "ok"
      eval session vm "i" "k1" (publishing 1) >>= (`shouldBe` "refused scene.publish: argument 1: nested deeper than 2")
      publishedCount sink `shouldReturn` 1

malformed ∷ Spec
malformed = describe "a malformed large or sparse table" $ do
  it "is refused at a limit, or as not a sequence, and never copied first and checked after" $
    withReady $ \session vm sink _ → do
      let publishingList build =
            Text.unlines
              [ "local sprites = {}"
              , build
              , "local ok, err = pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = sprites})"
              , "if ok then return 'ok' end"
              , "return 'refused ' .. tostring(err)"
              ]
      -- Two hundred thousand empty tables: each is a schema fault, but the reader reaches the element bound first.
      eval session vm "i" "k1" (publishingList "for i = 1, 200000 do sprites[i] = {} end")
        >>= (`shouldBe` "refused scene.publish: argument 1: more than 24582 values")
      eval session vm "i" "k2" (publishingList "for i = 1, 1000000 do sprites[i] = i end")
        >>= (`shouldBe` "refused scene.publish: argument 1: more than 24582 values")
      -- A sparse list is not a sequence, however far its far key is.
      eval session vm "i" "k3" (publishingList "sprites[1] = {}; sprites[1000000] = {}")
        >>= (`shouldSatisfy` Text.isInfixOf "not a sequence")
      eval session vm "i" "k4" (publishingList "sprites[2 ^ 40] = {}")
        >>= (`shouldSatisfy` Text.isInfixOf "not a sequence")
      publishedCount sink `shouldReturn` 0

direct ∷ Spec
direct = describe "preparation itself" $
  it "checks the sprite count before it reads a sprite, walking no more than one past the limit of even an endless list" $ do
    lending ← newLending
    leases ← newLeases lending 1
    Right limits ← pure (sceneLimits (sceneProfile [(SceneSprites, 2)] []))
    let clear = VRecord [("r", VInteger 0), ("g", VInteger 0), ("b", VInteger 0)]
        candidate list = VRecord [("clear", clear), ("sprites", VList list)]
    prepareScene limits leases (candidate (replicate 3 (VRecord []))) >>= \case
      Left refusal → refusal `shouldBe` SceneRefusal AtSprites (TooManySprites 2)
      Right _ → expectationFailure "three sprites were accepted under a limit of two"
    prepareScene limits leases (candidate (repeat (VRecord []))) >>= \case
      Left refusal → refusal `shouldBe` SceneRefusal AtSprites (TooManySprites 2)
      Right _ → expectationFailure "an endless list was accepted"
