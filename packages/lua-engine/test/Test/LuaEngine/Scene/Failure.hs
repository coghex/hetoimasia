{-# LANGUAGE OverloadedStrings #-}

-- | What a refusal leaves, and what it does not catch: the previous scene and the sink's counter after
-- a caught refusal, the next valid candidate, an uncaught refusal as the script's own error, a copy that
-- no later edit reaches, and a failure of the sink or of the engine that stays fatal.
module Test.LuaEngine.Scene.Failure (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Control.Monad (forM_)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Scene
import Hetoimasia.Render.TwoD.Snapshot (ClearColour (ClearColour))
import Hetoimasia.Scripting.Lua.Instance (InstanceFailure (..))
import Test.Hspec
import Test.LuaEngine.Scene.Support
import Test.LuaEngine.Texture.Contract (small)

spec ∷ Spec
spec = describe "a refusal" $ do
  caught
  uncaught
  copied
  fatal

caught ∷ Spec
caught = describe "caught with pcall" $
  it "leaves the previous scene and the sink's counter, and the next valid candidate is accepted, over many cycles" $
    withReady $ \session vm sink _ → do
      let publish1 = "local ok, err = pcall(scene.publish, {clear = {r = 9, g = 9, b = 9}, sprites = {{texture = self.ts.a, x = 5, y = 6, width = 7, height = 8}}}) return ok and 'ok' or err"
          bad = "local ok, err = pcall(scene.publish, {clear = {r = 9, g = 9, b = 9}, sprites = {{texture = self.ts.a, x = 5, y = 6, width = -7, height = 8}}}) return ok and 'ok' or err"
      evalOk session vm "i" "first" publish1 "ok"
      [previous] ← published sink
      forM_ [1 ∷ Int .. 120] $ \n → do
        eval session vm "i" (Text.pack ("bad" <> show n)) bad >>= (`shouldSatisfy` Text.isPrefixOf "scene.publish: scene.sprites[1].width")
        publishedCount sink `shouldReturn` n
        evalOk session vm "i" (Text.pack ("good" <> show n)) publish1 "ok"
      scenes ← published sink
      length scenes `shouldBe` 121
      -- The scene the first publication prepared is still what it was, and each is a complete copy.
      map preparedContent scenes `shouldSatisfy` all (== preparedContent previous)
      eval session vm "i" "consume" "return scene.consume_last()" >>= (`shouldBe` "fresh")

uncaught ∷ Spec
uncaught = describe "uncaught" $
  it "is the script's own error under the normal classification: the instance fails with the bounded message, and a peer and the owner go on" $
    withReady $ \session vm sink _ → do
      setAutoRetire (ssFake session) True
      admitDriver session vm "j"
      commandWith session vm "i" "eval" "k1" (Just (load "scene.publish({clear = {r = 0, g = 0, b = 0}})"))
      failure ← awaitFailure session "i"
      case failure of
        Just found → show (failureError found) `shouldSatisfy` Text.isInfixOf "scene.publish: argument 1: missing field sprites" . Text.pack
        Nothing → expectationFailure "the instance did not fail"
      publishedCount sink `shouldReturn` 0
      -- The peer is untouched and the owner serves it.
      evalOk session vm "j" "k2" "return 'alive'" "alive"

copied ∷ Spec
copied = describe "a prepared scene" $
  it "is a copy: editing the script's tables afterwards, aliased ones included, changes nothing in it" $
    withReady $ \session vm sink _ → do
      evalOk
        session
        vm
        "i"
        "k1"
        ( Text.unlines
            [ "local t = self.ts.a"
            , "local s = {texture = t, x = 1, y = 2, width = 3, height = 4}"
            , "local clear = {r = 10, g = 20, b = 30}"
            , "local sprites = {s, s, {texture = t, x = 5, y = 6, width = 7, height = 8}}"
            , "local candidate = {clear = clear, sprites = sprites}"
            , "scene.publish(candidate)"
            , "s.x = 99; s.width = 1000; clear.r = 255; sprites[2] = nil; sprites[3].y = -1; sprites[4] = s; candidate.sprites = {}"
            , "return 'edited'"
            ]
        )
        "edited"
      [prepared] ← published sink
      let content = preparedContent prepared
      map spriteRect (sceneSprites content) `shouldBe` [SceneRect 1 2 3 4, SceneRect 1 2 3 4, SceneRect 5 6 7 8]
      sceneClear content `shouldBe` ClearColour (linearOfByte 10) (linearOfByte 20) (linearOfByte 30) 1

fatal ∷ Spec
fatal = describe "a failure that is not a refusal" $
  it "stays fatal: a sink that fails ends the owner with that failure, which a pcall around the call does not hide" $ do
    sink ← newSink
    ExceptionWithContext _ _ ← fatalSession (sceneConfigWith small layout sink (\_ → throwIO (userError "the sink failed"))) $ \session control runtime → do
      setAutoRetire (ssFake session) True
      vm ← startVm session runtime "fatal" OnArrival
      admitDriver session vm "i"
      _ ← acquire session vm "i" "a" "a.png"
      commandWith session vm "i" "eval" "k1" (Just (load "pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = {}}) return 'unreachable'"))
      _ ← awaitEnd control vm
      pure ()
    pure ()
