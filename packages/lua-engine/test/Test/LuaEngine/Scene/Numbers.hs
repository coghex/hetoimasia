{-# LANGUAGE OverloadedStrings #-}

-- | Colours and geometry: what is a number the scene accepts, and what each becomes.
--
-- The colour rule is exercised on the values the preparation reads (so a value no Lua call can build,
-- such as a boolean in a channel, is covered as well), and the geometry through real Lua calls, because
-- a rectangle needs the instance's own texture. Nothing is clamped, rounded, snapped or skipped: each
-- refusal names the field, the sink is not called, and the previous scene stands.
module Test.LuaEngine.Scene.Numbers (spec) where

import Control.Monad (forM_, unless)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (fixedM1Profile)
import Hetoimasia.LuaEngine.Scene
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (ClearColour))
import Hetoimasia.Scripting.Lua.Lease (newLeases)
import Hetoimasia.Scripting.Lua.Lending (newLending)
import Hetoimasia.Scripting.Lua.Value (Value (VBoolean, VFloat, VInteger, VList, VRecord, VText))
import Test.Hspec
import Test.LuaEngine.Scene.Support

spec ∷ Spec
spec = describe "numbers" $ do
  colour
  geometry

-- | A scene with no sprites and this clear, prepared directly.
clearing ∷ Value → Value → Value → IO (Either SceneRefusal PreparedScene)
clearing r g b = do
  lending ← newLending
  leases ← newLeases lending 1
  limits ← either (\refused → fail (show refused)) pure (sceneLimits fixedM1Profile)
  prepareScene limits leases (VRecord [("clear", VRecord [("r", r), ("g", g), ("b", b)]), ("sprites", VList [])])

colour ∷ Spec
colour = describe "the clear colour" $ do
  it "converts each sRGB byte to linear light with an opaque alpha: 0 and 255 exactly, and 128 is not one half" $ do
    linearOfByte 0 `shouldBe` 0
    linearOfByte 255 `shouldBe` 1
    linearOfByte 128 `shouldSatisfy` \found → abs (found - 0.21586) < 1.0e-5
    -- Below the transfer function's knee the curve is linear: byte 10 is 10/255/12.92.
    linearOfByte 10 `shouldSatisfy` \found → abs (found - (10 / 255 / 12.92)) < 1.0e-7
    [linearOfByte byte | byte ← [0 .. 255]] `shouldSatisfy` \found → and (zipWith (<) found (drop 1 found)) && all (\v → v >= 0 && v <= 1) found

  it "takes integers and exactly integral finite floats from 0 to 255, and keeps the channel order and an alpha of one" $ do
    Right prepared ← clearing (VInteger 255) (VFloat 128.0) (VInteger 0)
    sceneClear (preparedContent prepared) `shouldBe` ClearColour 1 (linearOfByte 128) 0 1
    Right edge ← clearing (VFloat 0.0) (VFloat 255.0) (VFloat (-0.0))
    sceneClear (preparedContent edge) `shouldBe` ClearColour 0 1 0 1

  it "refuses a fractional float, a string, a boolean, NaN, the infinities and an out-of-range value, naming the channel, with no coercion or clamping" $ do
    let refusedAt channel value reason = \result → case result of
          Left refusal → refusal `shouldBe` SceneRefusal (AtClearChannel channel) reason
          Right _ → expectationFailure ("accepted " <> show value)
        nan = 0 / 0 ∷ Double
        infinity = 1 / 0 ∷ Double
    clearing (VFloat 127.5) (VInteger 0) (VInteger 0) >>= refusedAt ChannelRed (VFloat 127.5) ChannelNotIntegral
    clearing (VInteger 0) (VFloat 0.0000001) (VInteger 0) >>= refusedAt ChannelGreen (VFloat 0.0000001) ChannelNotIntegral
    clearing (VInteger 0) (VInteger 0) (VFloat 254.99999999999997) >>= refusedAt ChannelBlue (VFloat 254.99999999999997) ChannelNotIntegral
    clearing (VText "5") (VInteger 0) (VInteger 0) >>= refusedAt ChannelRed (VText "5") NumberRequired
    clearing (VInteger 0) (VBoolean True) (VInteger 0) >>= refusedAt ChannelGreen (VBoolean True) NumberRequired
    clearing (VFloat nan) (VInteger 0) (VInteger 0) >>= refusedAt ChannelRed (VFloat nan) NotFinite
    clearing (VInteger 0) (VFloat infinity) (VInteger 0) >>= refusedAt ChannelGreen (VFloat infinity) NotFinite
    clearing (VInteger 0) (VInteger 0) (VFloat (negate infinity)) >>= refusedAt ChannelBlue (VFloat (negate infinity)) NotFinite
    clearing (VInteger 256) (VInteger 0) (VInteger 0) >>= refusedAt ChannelRed (VInteger 256) ChannelOutOfRange
    clearing (VInteger 0) (VInteger (-1)) (VInteger 0) >>= refusedAt ChannelGreen (VInteger (-1)) ChannelOutOfRange
    clearing (VInteger 0) (VInteger 0) (VFloat 256.0) >>= refusedAt ChannelBlue (VFloat 256.0) ChannelOutOfRange
    clearing (VFloat (-1.0)) (VInteger 0) (VInteger 0) >>= refusedAt ChannelRed (VFloat (-1.0)) ChannelOutOfRange
    clearing (VInteger maxBound) (VInteger 0) (VInteger 0) >>= refusedAt ChannelRed (VInteger maxBound) ChannelOutOfRange

  it "refuses with a reason that names the channel in fixed words and no more than 160 bytes" $ do
    Left refusal ← clearing (VInteger 0) (VFloat 1.5) (VInteger 0)
    refusalReasonText refusal `shouldBe` "scene.clear.g: a colour channel is a whole number"
    Text.length (refusalReasonText refusal) `shouldSatisfy` (<= 160)

-- | What a sprite of these four numbers must come to.
data Outcome = Becomes SceneRect | Refused Text

geometry ∷ Spec
geometry = describe "a sprite's rectangle" $ do
  it "keeps fractions, negative and offscreen positions and the smallest rectangles that do not collapse" $
    outcomes
      [ ("0", "0", "1", "1", Becomes (SceneRect 0 0 1 1))
      , ("-0.5", "-300.25", "2.5", "3.75", Becomes (SceneRect (-0.5) (-300.25) 2.5 3.75))
      , ("1000000", "-1000000", "1000000", "1000000", Becomes (SceneRect 1000000 (-1000000) 1000000 1000000))
      , ("1000000", "0", "0.0625", "1", Becomes (SceneRect 1000000 0 0.0625 1))
      , -- Above half a unit in the last place, so the far edge rounds up to the next float and is not the origin.
        ("1000000", "0", "0.0313", "1", Becomes (SceneRect 1000000 0 0.0313 1))
      , ("0", "1000000", "1", "0.0625", Becomes (SceneRect 0 1000000 1 0.0625))
      , -- A subnormal 32-bit extent is still an extent at the origin.
        ("0", "0", "1e-40", "1e-40", Becomes (SceneRect 0 0 1.0e-40 1.0e-40))
      ]

  it "refuses a width or height that is zero, negative, too large, not finite or too small to be anything as a 32-bit float" $
    outcomes
      [ ("1", "1", "0", "1", Refused "scene.sprites[1].width: an extent is greater than zero")
      , ("1", "1", "-3", "1", Refused "scene.sprites[1].width: an extent is greater than zero")
      , ("1", "1", "1", "0", Refused "scene.sprites[1].height: an extent is greater than zero")
      , ("1", "1", "1000001", "1", Refused "scene.sprites[1].width: an extent is at most 1000000")
      , ("1", "1", "1", "1e300", Refused "scene.sprites[1].height: an extent is at most 1000000")
      , ("1", "1", "0/0", "1", Refused "scene.sprites[1].width: not finite")
      , ("1", "1", "1", "math.huge", Refused "scene.sprites[1].height: not finite")
      , ("1", "1", "1e-50", "1", Refused "scene.sprites[1].width: the extent is too small to represent")
      , ("1", "1", "1", "1e-46", Refused "scene.sprites[1].height: the extent is too small to represent")
      ]

  it "refuses a coordinate out of range or not finite, and one that is a string or a boolean" $
    outcomes
      [ ("1000001", "0", "1", "1", Refused "scene.sprites[1].x: a coordinate is from -1000000 to 1000000")
      , ("0", "-1000001", "1", "1", Refused "scene.sprites[1].y: a coordinate is from -1000000 to 1000000")
      , ("1000000.5", "0", "1", "1", Refused "scene.sprites[1].x: a coordinate is from -1000000 to 1000000")
      , ("0/0", "0", "1", "1", Refused "scene.sprites[1].x: not finite")
      , ("0", "math.huge", "1", "1", Refused "scene.sprites[1].y: not finite")
      , ("-math.huge", "0", "1", "1", Refused "scene.sprites[1].x: not finite")
      , ("'1'", "0", "1", "1", Refused "expected number, found string")
      , ("0", "true", "1", "1", Refused "expected number, found boolean")
      ]

  it "refuses a far edge that rounds back onto the origin in either axis, at a large valid origin, and does not make it disappear" $
    outcomes
      [ -- Exactly half a unit in the last place: the tie goes to the even origin.
        ("1000000", "0", "0.03125", "1", Refused "scene.sprites[1]: the far edge is the origin on the x axis")
      , ("1000000", "0", "0.001", "1", Refused "scene.sprites[1]: the far edge is the origin on the x axis")
      , ("-1000000", "0", "0.001", "1", Refused "scene.sprites[1]: the far edge is the origin on the x axis")
      , ("0", "1000000", "1", "0.001", Refused "scene.sprites[1]: the far edge is the origin on the y axis")
      , ("0", "-1000000", "1", "0.001", Refused "scene.sprites[1]: the far edge is the origin on the y axis")
      , ("1000000", "1000000", "1", "0.001", Refused "scene.sprites[1]: the far edge is the origin on the y axis")
      ]

  it "names the sprite by its place in the list" $
    withReady $ \session vm _ _ → do
      let good = "{texture = t, x = 1, y = 1, width = 1, height = 1}"
          bad = "{texture = t, x = 1, y = 1, width = 0, height = 1}"
      answer ← eval session vm "i" "k1" (publishingList (Text.intercalate ", " [good, good, bad]))
      answer `shouldSatisfy` Text.isInfixOf "scene.sprites[3].width: an extent is greater than zero"
  where
    publishingList sprites =
      Text.unlines
        [ "local t = self.ts.a"
        , "local ok, err = pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = {" <> sprites <> "}})"
        , "if ok then return 'ok' end"
        , "return 'refused ' .. tostring(err)"
        ]

-- | Publish a one-sprite scene for each case, expecting the rectangle or the refusal, and the sink to
-- have been handed exactly the accepted ones.
outcomes ∷ [(Text, Text, Text, Text, Outcome)] → Expectation
outcomes cases = withReady $ \session vm sink _ → do
  forM_ (zip [0 ∷ Int ..] cases) $ \(n, (x, y, w, h, expected)) → do
    countBefore ← publishedCount sink
    answer ←
      eval session vm "i" (Text.pack ("g" <> show n)) . Text.unlines $
        [ "local t = self.ts.a"
        , "local ok, err = pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = {{texture = t, x = " <> x <> ", y = " <> y <> ", width = " <> w <> ", height = " <> h <> "}}})"
        , "if ok then return 'ok' end"
        , "return 'refused ' .. tostring(err)"
        ]
    countAfter ← publishedCount sink
    case expected of
      Becomes rect → do
        answer `shouldBe` "ok"
        countAfter `shouldBe` countBefore + 1
        scenes ← published sink
        map spriteRect (sceneSprites (preparedContent (last scenes))) `shouldBe` [rect]
      Refused needle → do
        unless (Text.isPrefixOf "refused scene.publish: " answer && needle `Text.isInfixOf` answer) $
          expectationFailure ("case " <> show n <> " " <> show (x, y, w, h) <> " was answered: " <> Text.unpack answer)
        countAfter `shouldBe` countBefore
