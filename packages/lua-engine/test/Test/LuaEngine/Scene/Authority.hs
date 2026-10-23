{-# LANGUAGE OverloadedStrings #-}

-- | Whose a texture is, as preparation checks it: the calling instance's authentic, live, ready,
-- unreleased texture, resolved to its complete identity; and what that success is worth later.
--
-- The instances share a VM (so the capability boundary alone cannot tell them apart), the backend is
-- the example's, and a texture is released and an instance ended through the real lease tracking. The
-- stand-in for the publication that follows is @scene.consume_last@, which asks the calling instance's
-- leases for every texture of the last prepared scene.
module Test.LuaEngine.Scene.Authority (spec) where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Scene
import Test.Hspec
import Test.LuaEngine.Scene.Support

spec ∷ Spec
spec = describe "texture authority" $ do
  another
  releasing
  later
  nothing
  elsewhere

-- | Publish a one-sprite scene of this texture expression under @pcall@.
publishing' ∷ Text → Text
publishing' texture =
  Text.unlines
    [ "local ok, err = pcall(scene.publish, {clear = {r = 0, g = 0, b = 0}, sprites = {{texture = " <> texture <> ", x = 1, y = 1, width = 1, height = 1}}})"
    , "if ok then return 'ok' end"
    , "return 'refused ' .. tostring(err)"
    ]

another ∷ Spec
another = describe "another instance's texture, in the same VM" $
  it "is refused as an ordinary error before any sink, leaves the instance that tried running, and leaves its owner its texture" $
    withReady $ \session vm sink identity → do
      admitDriver session vm "j"
      jIdentity ← acquire session vm "j" "b" "b.png"
      jIdentity `shouldNotBe` identity
      -- i passes its handle to j through shared Lua state, as a script can.
      command session vm "i" "share" "a"
      awaitNote session "i share a shared"
      command session vm "j" "adopt" "a"
      awaitNote session "j adopt a adopted"
      answer ← eval session vm "j" "k1" (publishing' "self.ts.a")
      answer `shouldSatisfy` Text.isPrefixOf "refused scene.publish: scene.sprites[1].texture: texture refused: the lease belongs to another instance"
      Text.length answer `shouldSatisfy` (< 256)
      publishedCount sink `shouldReturn` 0
      -- j goes on, and publishes its own; i still has its own.
      evalOk session vm "j" "k2" (publishing' "self.ts.b") "ok"
      evalOk session vm "i" "k3" (publishing' "self.ts.a") "ok"
      scenes ← published sink
      map (map (viewIdentity . useView) . textureUses) scenes `shouldBe` [[jIdentity], [identity]]

releasing ∷ Spec
releasing = describe "a released texture" $ do
  it "is refused while its retirement is pending" $
    withReady $ \session vm sink _ → do
      command session vm "i" "release" "a"
      awaitNote session "i release a retiring"
      eval session vm "i" "k1" (publishing' "self.ts.a") >>= (`shouldSatisfy` Text.isPrefixOf "refused scene.publish: ")
      publishedCount sink `shouldReturn` 0

  it "is refused after the backend proved its retirement" $
    withReady $ \session vm sink _ → do
      setAutoRetire (ssFake session) True
      command session vm "i" "release" "a"
      awaitOwner vm "i" (== OwnerReading 0 0)
      eval session vm "i" "k1" (publishing' "self.ts.a") >>= (`shouldSatisfy` Text.isPrefixOf "refused scene.publish: ")
      publishedCount sink `shouldReturn` 0

later ∷ Spec
later = describe "success is a check of current authority, not a grant" $ do
  it "does not survive the instance releasing the texture: the later check refuses it, and the scene already prepared is unchanged" $
    withReady $ \session vm sink identity → do
      evalOk session vm "i" "k1" (publishing' "self.ts.a") "ok"
      eval session vm "i" "k2" "return scene.consume_last()" >>= (`shouldBe` "fresh")
      command session vm "i" "release" "a"
      awaitNote session "i release a retiring"
      eval session vm "i" "k3" "return scene.consume_last()" >>= (`shouldBe` "refused: the lease has ended")
      [prepared] ← published sink
      map (viewIdentity . useView) (textureUses prepared) `shouldBe` [identity]

  it "does not survive the instance ending, and is not another instance's to use" $
    withReady $ \session vm sink _ → do
      setAutoRetire (ssFake session) True
      admitDriver session vm "j"
      jIdentity ← acquire session vm "j" "b" "b.png"
      evalOk session vm "j" "k1" (publishing' "self.ts.b") "ok"
      -- While j lives, the scene is j's: i's leases refuse it.
      eval session vm "i" "k2" "return scene.consume_last()" >>= (`shouldBe` "refused: the lease belongs to another instance")
      stopInstance session vm "j"
      _ ← awaitFailure session "j"
      awaitReleaseCalls (ssFake session) 1
      releaseCalls (ssFake session) `shouldReturn` [jIdentity]
      eval session vm "i" "k3" "return scene.consume_last()" >>= (`shouldBe` "refused: the lease has ended")
      [prepared] ← published sink
      map (viewIdentity . useView) (textureUses prepared) `shouldBe` [jIdentity]

nothing ∷ Spec
nothing = describe "preparation" $
  it "acquires no hold and starts no native work: no upload, no release, the same live textures and the same charges" $
    withReady $ \session vm sink identity → do
      uploads ← uploadsSeen (ssFake session)
      live ← texturesLive (ssFake session)
      banks ← ownerNow vm "i"
      forM_ [1 ∷ Int .. 5] $ \n → evalOk session vm "i" (Text.pack ("k" <> show n)) (publishing' "self.ts.a") "ok"
      eval session vm "i" "bad" (publishing' "{}") >>= (`shouldSatisfy` Text.isPrefixOf "refused ")
      publishedCount sink `shouldReturn` 5
      uploadsSeen (ssFake session) `shouldReturn` uploads
      texturesLive (ssFake session) `shouldReturn` live
      releaseCalls (ssFake session) `shouldReturn` []
      ownerNow vm "i" >>= (`shouldBe` banks)
      live `shouldBe` [identity]

elsewhere ∷ Spec
elsewhere = describe "a capability that is not this instance's" $
  it "a forged, never-issued or wrong-typed key acquires no authority when the value is prepared from inside a call" $
    withReady $ \session vm sink _ → do
      let probe key kind = eval session vm "i" key ("return scene.probe('" <> kind <> "', " <> key <> ")")
      probe "424242" "texture" >>= (`shouldBe` "scene.sprites[1].texture: texture refused: the lease has ended")
      probe "1" "request" >>= (`shouldBe` "scene.sprites[1].texture: a texture is required")
      probe "0" "texture" >>= (`shouldBe` "scene.sprites[1].texture: texture refused: the lease has ended")
      publishedCount sink `shouldReturn` 0
      -- The capability boundary of the host refuses another VM's handle before any of this runs; the examples
      -- of the host pin that (RuleForeignHandle). Here nothing of a forged key reached a sink.
