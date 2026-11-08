{-# LANGUAGE OverloadedStrings #-}

-- | What one texture request is: a verified read, a bounded decode, an upload and a registration,
-- and a usable owned texture only when the backend says the upload is complete and the registration
-- usable, with the stages' charges shown as they move.
module Test.LuaEngine.Texture.Contract (spec, small, wide, wideLayout, layout, loadAs, started) where

import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..), Profile)
import Test.Hspec
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Png
import Test.LuaEngine.Texture.Support

-- | 32 by 32 texels at most (so a texture reserves 4,096 nominal bytes), four of them for an
-- instance and eight for the session.
small ∷ Profile
small =
  smaller
    [(PngPixels, 1024), (PngAxisMaximum, 32)]
    [ (PngEncodedBytes, 65536)
    , (PngInflatedScanlineBytes, 65536)
    , (PngPipelineWorkspaceBytes, 1048576)
    , (TextureBytesPerUiInstance, 16384)
    , (TextureBytesPerSession, 32768)
    ]

-- | 64 by 64 texels at most (so a texture reserves 16,384 nominal bytes), four of them for an instance and eight for the
-- session: a reservation well above the 4,096-byte minimum charge, so that a decode which shrinks it is visible.
wide ∷ Profile
wide =
  smaller
    [(PngPixels, 4096), (PngAxisMaximum, 64)]
    [ (PngEncodedBytes, 65536)
    , (PngInflatedScanlineBytes, 65536)
    , (PngPipelineWorkspaceBytes, 1048576)
    , (TextureBytesPerUiInstance, 65536)
    , (TextureBytesPerSession, 131072)
    ]

-- | The examples' images, and one of 40 by 40 texels: 6,400 bytes decoded, above the minimum charge.
wideLayout ∷ Layout
wideLayout = case layout of
  Layout images → Layout (images <> [("big.png", opaque 40 40)])

-- | The images the examples load.
layout ∷ Layout
layout =
  Layout
    [ ("a.png", opaque 8 4)
    , ("b.png", opaque 8 4)
    , ("c.png", opaque 16 16)
    , ("d.png", opaque 8 4)
    ]

-- | Start a required load of this path under this key, and wait for the answer line.
loadAs ∷ Session → Vm → Text → Text → Text → IO Text
loadAs session vm name key path = do
  commandWith session vm name "start" key (Just (load path))
  lineStarting session (name <> " start " <> key <> " ")

-- | Start a load that must be accepted.
started ∷ Session → Vm → Text → Text → Text → IO ()
started session vm name key path = loadAs session vm name key path >>= (`shouldBe` (name <> " start " <> key <> " started"))

spec ∷ Spec
spec = describe "a request" $ do
  it "succeeds only when the backend reports the upload complete and the registration usable, with the instance's lease and the source dimensions" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "contract" OnArrival
      admitDriver session vm "i"
      started session vm "i" "a" "a.png"
      awaitUploads (ssFake session) 1
      held ← uploadN (ssFake session) 0
      let upload = heldUpload held
      (uploadWidth upload, uploadHeight upload) `shouldBe` (8, 4)
      BS.length (uploadTexels upload) `shouldBe` 8 * 4 * 4
      BS.unpack (BS.take 4 (uploadTexels upload)) `shouldBe` expectedOpaque 8 4 0 0
      BS.unpack (BS.take 4 (BS.drop (4 * (3 * 8 + 5)) (uploadTexels upload))) `shouldBe` expectedOpaque 8 4 5 3
      -- A decoded image and an acknowledged submission are not a texture: the request is pending, the
      -- instance owns no texture, and the level is charged to the lane that holds it, not yet retired.
      command session vm "i" "ready" "a"
      awaitNote session "i ready a false"
      lanesCharged session `shouldReturn` [128, 0]
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 4096)
      sessionNow session `shouldReturn` 4096
      identity ← finishUpload (ssFake session) held
      command session vm "i" "wait_take" "a"
      line ← lineStarting session "i wait_take a "
      line `shouldBe` "i wait_take a {status=success,value={height=4,texture=<userdata>,width=8}}"
      command session vm "i" "use" "a"
      awaitNote session ("i use a " <> showT identity)
      -- The CPU buffers retired; the texture is live and still charges its slot and nominal bytes.
      lanesCharged session `shouldReturn` [0, 0]
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 4096)
      awaitLeaseSummary session vm "i" (const True)
  where
    showT = Text.pack . show
