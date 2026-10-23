{-# LANGUAGE OverloadedStrings #-}

-- | The charges as each stage moves them: the lane's workspace from before the read until the backend
-- retires the level, the nominal bytes reserved at 16 MiB-equivalent and shrunk only once the
-- dimensions are validated, the per-instance and the session accounts together, and a live texture
-- that outlasts the request, the result and the pipeline's own buffers.
module Test.LuaEngine.Texture.Stages (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..))
import Test.Hspec
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (layout, loadAs, small, started)
import Test.LuaEngine.Texture.Png (opaque)
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "the charges, stage by stage" $ do
  it "charges the lane the encoded input before the read, the level while the backend holds it and nothing once it retires, and shrinks the nominal charge only after the decode validated the dimensions" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "trace" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "a.png"
      started session vm "i" "k0" "a.png"
      awaitStarted (ssProbe session) 1
      -- Before the read: the input's length is charged to the lane and the reservation is the maximum.
      lanesCharged session `shouldReturn` [fromIntegral (BS.length (opaque 8 4)), 0]
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 4096)
      openGate (ssProbe session) "a.png"
      awaitUploads (ssFake session) 1
      -- At the handoff: the input is released and dropped, the level is charged, the nominal bytes are
      -- the validated width times height times four.
      lanesCharged session `shouldReturn` [128, 0]
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      held ← uploadN (ssFake session) 0
      -- The backend lets go of the level: the lane's workspace is free, but the lane is not, until the
      -- backend says the upload ended too.
      _ ← retireBuffers (ssFake session) held
      lanesCharged session `shouldReturn` [0, 0]
      pipelineNow session >>= \reading → map laneReadingJob (readingLanes reading) `shouldBe` [Just 0, Nothing]
      identity ← fst <$> registerTexture (ssFake session) held
      awaitPipeline session (all ((== Nothing) . laneReadingJob) . readingLanes)
      -- The texture is live and still charged to its instance and the session.
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 1 128)
      sessionNow session `shouldReturn` 128
      command session vm "i" "wait_take" "k0"
      _ ← lineStarting session "i wait_take k0 "
      command session vm "i" "use" "k0"
      awaitNote session ("i use k0 " <> Text.pack (show identity))

  it "keeps each instance's account and the session's together: a smaller image shrinks only its own share" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "accounts" OnArrival
      mapM_ (admitDriver session vm) ["i", "j"]
      started session vm "i" "k0" "a.png"
      started session vm "i" "k1" "c.png"
      started session vm "j" "k0" "b.png"
      awaitUploads (ssFake session) 2
      -- Two lanes: the third waits, holding its whole reservation.
      awaitPipeline session ((== 1) . readingPending)
      sessionNow session `shouldReturn` 128 + 1024 + 4096
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 2 (128 + 1024))
      ownerNow vm "j" >>= (`shouldBe` OwnerReading 1 4096)
      first ← uploadN (ssFake session) 0
      _ ← finishUpload (ssFake session) first
      awaitUploads (ssFake session) 3
      awaitOwner vm "j" (== OwnerReading 1 128)
      sessionNow session `shouldReturn` 128 + 1024 + 128

  it "lets a live texture outlast the request, the result and the pipeline's buffers: the request place is reusable while the slot and the nominal bytes stay charged" $
    withSession (config (smaller [(RequestsPerInstance, 1), (PngPixels, 1024), (PngAxisMaximum, 32)] bytes) layout) $ \session _ runtime → do
      vm ← startVm session runtime "outlast" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      loadAs session vm "i" "z" "b.png" >>= (`shouldSatisfy` Text.isInfixOf "the instance holds all 1 of its request places")
      awaitUploads (ssFake session) 1
      _ ← uploadN (ssFake session) 0 >>= finishUpload (ssFake session)
      command session vm "i" "wait_take" "k0"
      _ ← lineStarting session "i wait_take k0 "
      lanesCharged session `shouldReturn` [0, 0]
      -- The request is taken and its work retired: a new request is accepted at once, and the first
      -- texture still holds its slot and its bytes.
      started session vm "i" "k1" "b.png"
      ownerNow vm "i" >>= \reading → ownerSlotsHeld reading `shouldBe` 2
      awaitUploads (ssFake session) 2
      command session vm "i" "use" "k0"
      awaitNote session "i use k0 100"
  where
    bytes =
      [ (PngEncodedBytes, 65536)
      , (PngInflatedScanlineBytes, 65536)
      , (PngPipelineWorkspaceBytes, 1048576)
      , (TextureBytesPerUiInstance, 16384)
      , (TextureBytesPerSession, 32768)
      ]
