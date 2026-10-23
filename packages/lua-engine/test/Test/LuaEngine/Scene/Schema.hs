{-# LANGUAGE OverloadedStrings #-}

-- | The fixed schema: what a script may hand over and what is refused, whole, with the previous scene
-- and the sink untouched.
--
-- Every example runs Lua in a real instance that owns a real, ready texture, calls @scene.publish@ (the
-- engine's binding over a controlled sink) under @pcall@, and reads what the sink was handed. The
-- metamethod counter is a Lua value the examples' tables write to, so a refusal that touched a
-- metamethod is seen.
module Test.LuaEngine.Scene.Schema (spec) where

import Control.Monad (forM_, unless)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Scene
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (ClearColour))
import Test.Hspec
import Test.LuaEngine.Scene.Support

spec ∷ Spec
spec = describe "the schema" $ do
  accepted
  refused
  metatables
  forged

-- | The scene in a sprite table of the usual shape.
sprite ∷ Text
sprite = "{texture = t, x = 32, y = 32, width = 256, height = 256}"

scene ∷ Text → Text
scene sprites = "{clear = {r = 0, g = 0, b = 0}, sprites = " <> sprites <> "}"

-- | Publish this scene under @pcall@: @ok@ when it was accepted, otherwise the error it raised.
publishing ∷ Text → Text
publishing candidate =
  Text.unlines
    [ "local t = self.ts.a"
    , "local ok, err = pcall(scene.publish, " <> candidate <> ")"
    , "if ok then return 'ok' end"
    , "return 'refused ' .. tostring(err)"
    ]

accepted ∷ Spec
accepted = describe "accepts" $ do
  it "the exact example, as a complete scene of the checked identity and the source dimensions" $
    withReady $ \session vm sink identity → do
      evalOk session vm "i" "k1" (publishing (scene ("{" <> sprite <> "}"))) "ok"
      [prepared] ← published sink
      let content = preparedContent prepared
      sceneClear content `shouldBe` ClearColour 0 0 0 1
      case sceneSprites content of
        [one] → do
          spriteRect one `shouldBe` SceneRect 32 32 256 256
          viewIdentity (useView (spriteTexture one)) `shouldBe` identity
          useView (spriteTexture one) `shouldSatisfy` \(TextureView _ w h) → (w, h) == (8, 4)
        other → expectationFailure ("expected one sprite, found " <> show (length other))

  it "an empty sprite list, as the explicit opaque clear, and the boundary colours, integral floats included" $
    withReady $ \session vm sink _ → do
      evalOk session vm "i" "k1" (publishing "{clear = {r = 255, g = 255.0, b = 0.0}, sprites = {}}") "ok"
      evalOk session vm "i" "k2" (publishing "{clear = {r = 0, g = 0, b = 0}, sprites = {}}") "ok"
      [white, black] ← map (preparedContent) <$> published sink
      sceneClear white `shouldBe` ClearColour 1 1 0 1
      sceneClear black `shouldBe` ClearColour 0 0 0 1
      sceneSprites white `shouldBe` []

  it "the boundary coordinates and extents, fractions and negative or offscreen positions as they are" $
    withReady $ \session vm sink _ → do
      let at x y w h = "{texture = t, x = " <> x <> ", y = " <> y <> ", width = " <> w <> ", height = " <> h <> "}"
      evalOk
        session
        vm
        "i"
        "k1"
        ( publishing . scene $
            "{ "
              <> Text.intercalate
                ", "
                [ at "-1000000" "1000000" "1000000" "1000000"
                , at "1000000.0" "-1000000.0" "0.5" "0.25"
                , at "-0.5" "-300" "1" "1"
                , at "99999" "7.75" "3" "2"
                ]
              <> " }"
        )
        "ok"
      [prepared] ← published sink
      map spriteRect (sceneSprites (preparedContent prepared))
        `shouldBe` [SceneRect (-1000000) 1000000 1000000 1000000, SceneRect 1000000 (-1000000) 0.5 0.25, SceneRect (-0.5) (-300) 1 1, SceneRect 99999 7.75 3 2]

  it "a sprite table or a texture used again, each occurrence a sprite of its own in its place" $
    withReady $ \session vm sink identity → do
      _ ← acquire session vm "i" "b" "b.png"
      evalOk
        session
        vm
        "i"
        "k1"
        ( Text.unlines
            [ "local t = self.ts.a"
            , "local u = self.ts.b"
            , "local s = {texture = t, x = 1, y = 2, width = 3, height = 4}"
            , "local other = {texture = u, x = 5, y = 6, width = 7, height = 8}"
            , "local ok, err = pcall(scene.publish, {clear = {r = 1, g = 2, b = 3}, sprites = {s, other, s, s}})"
            , "return ok and 'ok' or tostring(err)"
            ]
        )
        "ok"
      [prepared] ← published sink
      let sprites = sceneSprites (preparedContent prepared)
      map spriteRect sprites `shouldBe` [SceneRect 1 2 3 4, SceneRect 5 6 7 8, SceneRect 1 2 3 4, SceneRect 1 2 3 4]
      -- Two textures, named once each in order of first use; the first is the acquired one.
      map (viewIdentity . useView) (textureUses prepared) `shouldSatisfy` \found → length found == 2 && take 1 found == [identity]

refused ∷ Spec
refused = describe "refuses, whole" $ do
  it "a candidate that is not the schema, each with the host's reason, and runs no sink and changes no previous scene" $
    withReady $ \session vm sink _ → do
      evalOk session vm "i" "first" (publishing (scene ("{" <> sprite <> "}"))) "ok"
      earlier ← published sink
      forM_ (zip [0 ∷ Int ..] cases) $ \(n, (setup, candidate, expected)) → do
        answer ← eval session vm "i" (Text.pack ("c" <> show n)) (Text.unlines [setup, publishing candidate])
        unless (Text.isPrefixOf "refused scene.publish: " answer && expected `Text.isInfixOf` answer) $
          expectationFailure ("case " <> show n <> " " <> Text.unpack candidate <> " was answered: " <> Text.unpack answer)
      published sink >>= (`shouldBe` map preparedContent earlier) . map preparedContent
      -- The next valid candidate is accepted: nothing is latched.
      evalOk session vm "i" "last" (publishing (scene "{}")) "ok"
      publishedCount sink `shouldReturn` 2
  where
    s = sprite
    withSprite name value = "{texture = t, x = 1, y = 1, width = 1, height = 1, " <> name <> " = " <> value <> "}"
    cases ∷ [(Text, Text, Text)]
    cases =
      [ ("", "{sprites = {}}", "missing field clear")
      , ("", "{clear = {r = 0, g = 0, b = 0}}", "missing field sprites")
      , ("", "{clear = {r = 0, g = 0, b = 0}, sprites = {}, extra = 1}", "unknown field extra")
      , ("", "{clear = {r = 0, g = 0}, sprites = {}}", "missing field b")
      , ("", "{clear = {r = 0, g = 0, b = nil}, sprites = {}}", "missing field b")
      , ("", "{clear = {r = 0, g = 0, b = 0, a = 1}, sprites = {}}", "unknown field a")
      , ("", scene "{{texture = t, x = 1, y = 1, width = 1}}", "missing field height")
      , ("", scene "{{texture = nil, x = 1, y = 1, width = 1, height = 1}}", "missing field texture")
      , ("", scene ("{" <> withSprite "rotation" "0" <> "}"), "unknown field rotation")
      , ("local s = " <> s, scene "{s, nil, s}", "not a sequence")
      , ("local s = " <> s, scene "{s, [3] = s}", "not a sequence")
      , ("local s = " <> s, scene "{s, extra = s}", "not a sequence")
      , ("", scene "{x = 1}", "not a sequence")
      , ("", "{clear = 5, sprites = {}}", "argument 1")
      , ("", "{clear = {r = 0, g = 0, b = 0}, sprites = 5}", "argument 1")
      , ("", scene "{5}", "argument 1")
      , ("", "5", "argument 1")
      , ("", "{clear = {r = '5', g = 0, b = 0}, sprites = {}}", "expected number, found string")
      , ("", "{clear = {r = true, g = 0, b = 0}, sprites = {}}", "expected number, found boolean")
      , ("", scene "{{texture = t, x = '1', y = 1, width = 1, height = 1}}", "expected number, found string")
      , ("", scene "{{texture = t, x = 1, y = 1, width = false, height = 1}}", "expected number, found boolean")
      , ("local c = {r = 0, g = 0, b = 0}; local sc = {clear = c}; sc.sprites = sc", "sc", "contains itself")
      , ("local list = {}; list[1] = list", "{clear = {r = 0, g = 0, b = 0}, sprites = list}", "contains itself")
      ]

metatables ∷ Spec
metatables = describe "a table with a metatable, even an empty or protected one" $
  it "is refused at every level without a metamethod running" $
    withReady $ \session vm sink _ → do
      let setup =
            Text.unlines
              [ "self.hits = 0"
              , "local function hit() self.hits = self.hits + 1 end"
              , "local mt = {__index = hit, __newindex = hit, __len = hit, __pairs = hit, __call = hit, __eq = hit, __tostring = hit, __concat = hit, __lt = hit, __metatable = 'protected'}"
              , "local function with(x, m) return setmetatable(x, m) end"
              , "local function s() return {texture = t, x = 1, y = 1, width = 1, height = 1} end"
              ]
          candidates =
            [ "with({clear = {r = 0, g = 0, b = 0}, sprites = {}}, mt)"
            , "{clear = with({r = 0, g = 0, b = 0}, mt), sprites = {}}"
            , "{clear = {r = 0, g = 0, b = 0}, sprites = with({s()}, mt)}"
            , "{clear = {r = 0, g = 0, b = 0}, sprites = {with(s(), mt)}}"
            , "with({clear = {r = 0, g = 0, b = 0}, sprites = {}}, {})"
            , "{clear = with({r = 0, g = 0, b = 0}, {}), sprites = {}}"
            , "{clear = {r = 0, g = 0, b = 0}, sprites = with({s()}, {})}"
            , "{clear = {r = 0, g = 0, b = 0}, sprites = {with(s(), {})}}"
            , "{clear = {r = 0, g = 0, b = 0}, sprites = {{texture = with({}, mt), x = 1, y = 1, width = 1, height = 1}}}"
            ]
      forM_ (zip [0 ∷ Int ..] candidates) $ \(n, candidate) → do
        answer ← eval session vm "i" (Text.pack ("m" <> show n)) (Text.unlines [setup, "local t = self.ts.a", publishing' candidate])
        unless (Text.isPrefixOf "refused scene.publish: " answer) $
          expectationFailure ("candidate " <> show n <> " was answered: " <> Text.unpack answer)
      evalOk session vm "i" "hits" "return self.hits" "0"
      publishedCount sink `shouldReturn` 0
  where
    publishing' candidate =
      Text.unlines
        [ "local ok, err = pcall(scene.publish, " <> candidate <> ")"
        , "if ok then return 'ok' end"
        , "return 'refused ' .. tostring(err)"
        ]

forged ∷ Spec
forged = describe "a texture that is not an authentic capability of this instance" $
  it "is refused when it is a table shaped like one, a number, a function, a request handle or a pending request" $
    withReady $ \session vm sink _ → do
      acquireRequest session vm "i" "p" "b.png"
      let cases =
            [ "{key = 1, type = 'texture'}"
            , "7"
            , "print"
            , "self.hs.p"
            , "setmetatable({}, {__metatable = false})"
            ]
      forM_ (zip [0 ∷ Int ..] cases) $ \(n, texture) → do
        answer ← eval session vm "i" (Text.pack ("f" <> show n)) (publishing' texture)
        unless (Text.isPrefixOf "refused scene.publish: " answer) $
          expectationFailure ("texture " <> Text.unpack texture <> " was answered: " <> Text.unpack answer)
      publishedCount sink `shouldReturn` 0
      -- Counts nothing against the texture limit: the real one still works.
      evalOk session vm "i" "ok" (publishing (scene ("{" <> sprite <> "}"))) "ok"
  where
    publishing' texture =
      Text.unlines
        [ "local ok, err = pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = {{texture = " <> texture <> ", x = 1, y = 1, width = 1, height = 1}}})"
        , "if ok then return 'ok' end"
        , "return 'refused ' .. tostring(err)"
        ]
