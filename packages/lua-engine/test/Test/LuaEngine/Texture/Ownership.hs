{-# LANGUAGE OverloadedStrings #-}

-- | Whose a texture is, and how it ends: every request has its own read, decode, upload and
-- texture even for one path; an instance cannot use or release another's; an explicit release revokes
-- new use at once, asks the backend once and never waits; and the charges stay until the backend
-- proves the texture retired, however long that takes and whether or not Lua kept its handle.
module Test.LuaEngine.Texture.Ownership (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext))
import Control.Monad (forM_)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Word (Word64)
import qualified Data.Text as Text
import Test.Hspec
import Test.LuaEngine.Texture.Contract (layout, small, started)
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "ownership" $ do
  independence
  releasing
  sharedHandles

-- | Load, finish the upload and take the success under this key.
acquire ∷ Session → Vm → Text → Text → Text → IO Word64
acquire session vm name key path = do
  -- Snapshot before the request starts: its upload can arrive before the script's acknowledgement does.
  count ← uploadsSeen (ssFake session)
  started session vm name key path
  awaitUploads (ssFake session) (count + 1)
  identity ← uploadN (ssFake session) count >>= finishUpload (ssFake session)
  command session vm name "wait_take" key
  line ← lineStarting session (name <> " wait_take " <> key <> " ")
  line `shouldSatisfy` Text.isInfixOf "status=success"
  pure identity


independence ∷ Spec
independence = describe "independent loads" $ do
  it "gives two requests for one path in one instance their own reads, uploads and textures, and keeps the other alive when one is released" $
    withSession (config small layout) $ \session _ runtime → do
      setAutoRetire (ssFake session) True
      vm ← startVm session runtime "same" OnArrival
      admitDriver session vm "i"
      first ← acquire session vm "i" "k0" "a.png"
      second ← acquire session vm "i" "k1" "a.png"
      first `shouldNotBe` second
      startedPaths (ssProbe session) >>= (`shouldBe` ["a.png", "a.png"])
      uploadsSeen (ssFake session) `shouldReturn` 2
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 2 256)
      command session vm "i" "release" "k0"
      awaitNote session "i release k0 done"
      command session vm "i" "use" "k1"
      awaitNote session ("i use k1 " <> showT second)
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)

  it "gives two instances loading one path their own work and textures, and ending one leaves the other usable" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "peers" OnArrival
      mapM_ (admitDriver session vm) ["i", "j"]
      first ← acquire session vm "i" "k0" "a.png"
      second ← acquire session vm "j" "k0" "a.png"
      first `shouldNotBe` second
      uploadsSeen (ssFake session) `shouldReturn` 2
      stopInstance session vm "i"
      awaitReleaseCalls (ssFake session) 1
      releaseCalls (ssFake session) `shouldReturn` [first]
      command session vm "j" "use" "k0"
      awaitNote session ("j use k0 " <> showT second)
      ownerNow vm "j" >>= (`shouldBe` OwnerReading 1 128)
  where
    showT = Text.pack . show

releasing ∷ Spec
releasing = describe "an explicit release" $ do
  it "answers done for a texture nothing holds, refuses further use at once, and answers already_released after: the backend released it once and the charges are back" $
    withSession (config small layout) $ \session _ runtime → do
      setAutoRetire (ssFake session) True
      vm ← startVm session runtime "plain" OnArrival
      admitDriver session vm "i"
      identity ← acquire session vm "i" "k0" "a.png"
      command session vm "i" "release" "k0"
      awaitNote session "i release k0 done"
      awaitOwner vm "i" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0
      command session vm "i" "puse" "k0"
      line ← lineStarting session "i puse k0 "
      line `shouldSatisfy` Text.isPrefixOf "i puse k0 error "
      command session vm "i" "release" "k0"
      awaitNote session "i release k0 already_released"
      releaseCalls (ssFake session) `shouldReturn` [identity]

  it "answers retiring while a scene still holds the texture, for the first and every repeated release, keeps the slot and the bytes charged, and never asks the backend twice" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "held" OnArrival
      admitDriver session vm "i"
      identity ← acquire session vm "i" "k0" "a.png"
      -- One texture serves any number of sprites until it is released.
      command session vm "i" "use" "k0"
      awaitNote session ("i use k0 " <> showT identity)
      command session vm "i" "use" "k0"
      command session vm "i" "release" "k0"
      awaitNote session "i release k0 retiring"
      -- New use is refused at once; the held scene is the backend's to keep alive.
      command session vm "i" "puse" "k0"
      line ← lineStarting session "i puse k0 "
      line `shouldSatisfy` Text.isPrefixOf "i puse k0 error "
      command session vm "i" "prelease" "k0"
      awaitNote session "i prelease k0 retiring"
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      sessionNow session `shouldReturn` 128
      releaseCalls (ssFake session) `shouldReturn` [identity]
      retireTexture (ssFake session) identity
      awaitOwner vm "i" (== OwnerReading 0 0)
      command session vm "i" "prelease" "k0"
      awaitNote session "i prelease k0 already_released"
      releaseCalls (ssFake session) `shouldReturn` [identity]

  it "is a cleanup failure when the backend's release raises: fatal to the owner, never retried, and the texture is never reported reclaimed" $ do
    ExceptionWithContext _ _ ← fatalSession (config small layout) $ \session control runtime → do
      vm ← startVm session runtime "cleanup" OnArrival
      admitDriver session vm "i"
      identity ← acquire session vm "i" "k0" "a.png"
      setRaiseOnRelease (ssFake session) True
      -- Called under pcall, as the host's own examples call a release that fails.
      command session vm "i" "prelease" "k0"
      _ ← lineStarting session "i prelease k0 "
      -- The backend was asked once, and nothing was returned: the texture is not reclaimed.
      releaseCalls (ssFake session) `shouldReturn` [identity]
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      sessionNow session `shouldReturn` 128
      _ ← awaitEnd control vm
      pure ()
    pure ()
  where
    showT = Text.pack . show

sharedHandles ∷ Spec
sharedHandles = describe "a handle passed through shared Lua state" $
  it "cannot be used or released by another instance: the boundary refuses it before any backend action and faults the instance that tried, and its owner keeps it" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "foreign" OnArrival
      mapM_ (admitDriver session vm) ["i", "j", "k"]
      identity ← acquire session vm "i" "k0" "a.png"
      command session vm "i" "share" "k0"
      awaitNote session "i share k0 shared"
      forM_ ["j", "k"] $ \name → do
        command session vm name "adopt" "k0"
        awaitNote session (name <> " adopt k0 adopted")
      -- Using it, and releasing it, are each refused for the instance that does not own it.
      command session vm "j" "use" "k0"
      awaitFailure session "j" >>= (`shouldSatisfy` isJust)
      command session vm "k" "release" "k0"
      awaitFailure session "k" >>= (`shouldSatisfy` isJust)
      releaseCalls (ssFake session) `shouldReturn` []
      -- The owner still has it, and it is still charged to the owner.
      command session vm "i" "use" "k0"
      awaitNote session ("i use k0 " <> Text.pack (show identity))
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      releaseCalls (ssFake session) `shouldReturn` []
