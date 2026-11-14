{-# LANGUAGE OverloadedStrings #-}

-- | TRA-17 requirement 6, through the real texture pipeline (#672): a terrain's two atlas parents, a 288 x 64
-- colour atlas and a 768 x 384 normal atlas, are charged to the UI instance's byte bank at their DECODED size,
-- once each however many regions and quads will read them; a second pending reservation that the bank cannot
-- hold is refused on bytes with nothing partial charged; and releasing the original lease while the upload or a
-- batch still holds the texture leaves the bytes charged (retiring) until the backend's own proof of
-- retirement, when the bank returns to zero. The terrain adapter allocates no texture: it holds handles to what
-- this pipeline admitted, so this is the contract its parents live under.
module Test.LuaEngine.Texture.TerrainParents (spec) where

import Control.Monad (forM_, void)
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (..)
  , Bytes (Bytes)
  , CountLimit (..)
  , Profile
  , bytesLimit
  , textureReservationBytes
  )
import Test.Hspec
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (loadAs)
import Test.LuaEngine.Texture.Png (rgba8)
import Test.LuaEngine.Texture.Support
import qualified Data.Text as Text
import Data.ByteString (ByteString)

spec ∷ Spec
spec = describe "a terrain's two atlas parents through the texture pipeline" $ do
  it "charges each parent once at its decoded size, refuses a second pending reservation on bytes with nothing partial charged, and frees both only at the backend's proof of retirement" $
    withSession ((config terrainProfile atlases) {cfgLeases = 8, cfgJobs = 8, cfgPool = (2, 8)}) $ \session _ runtime → do
      vm ← startVm session runtime "terrain" OnArrival
      admitDriver session vm "i"
      let Bytes reservation = textureReservationBytes terrainProfile
          Bytes instanceLimit = bytesLimit terrainProfile TextureBytesPerUiInstance
      closeGate (ssProbe session) "colour.png"
      closeGate (ssProbe session) "normal.png"
      -- Both parents are requested; each holds its whole reservation while its read waits at the gate.
      loadAs session vm "i" "colour" "colour.png" >>= (`shouldBe` "i start colour started")
      loadAs session vm "i" "normal" "normal.png" >>= (`shouldBe` "i start normal started")
      ownerNow vm "i" >>= (\reading → ownerNominalHeld reading `shouldBe` 2 * reservation)
      -- A third reservation does not fit beside them: refused on BYTES, and nothing is charged for the refusal.
      (2 * reservation + reservation > instanceLimit) `shouldBe` True
      line ← loadAs session vm "i" "extra" "normal.png"
      line `shouldSatisfy` Text.isInfixOf "texture bytes"
      ownerNow vm "i" >>= (\reading → ownerNominalHeld reading `shouldBe` 2 * reservation)
      sessionNow session `shouldReturn` 2 * reservation
      -- The decodes settle: each charge shrinks to its decoded size (288 x 64 x 4 and 768 x 384 x 4 bytes), once per
      -- physical parent however many regions and quads will read it.
      openGate (ssProbe session) "colour.png"
      openGate (ssProbe session) "normal.png"
      settle session vm "colour.png" "colour"
      settle session vm "normal.png" "normal"
      ownerNow vm "i" >>= (\reading → (ownerTexturesHeld reading, ownerNominalHeld reading) `shouldBe` (2, colourBytes + normalBytes))
      sessionNow session `shouldReturn` colourBytes + normalBytes
      -- The original leases are released while the backend still holds the textures: the bytes stay charged
      -- (retiring), never freed by the release request alone.
      forM_ (zip [1 ..] ["colour", "normal"]) $ \(position, key) → do
        command session vm "i" "release" key
        awaitNote session ("i release " <> key <> " retiring")
        awaitReleaseCalls (ssFake session) position
      ownerNow vm "i" >>= (\reading → ownerNominalHeld reading `shouldBe` colourBytes + normalBytes)
      sessionNow session `shouldReturn` colourBytes + normalBytes
      -- The backend proves each retirement: the bank returns to zero.
      calls ← releaseCalls (ssFake session)
      forM_ calls (retireTexture (ssFake session))
      awaitOwner vm "i" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0

  it "rolls a partial acquisition back: a required second parent refused on bytes leaves the first parent's reservation to be released, the bank returns to the prior terrain's charges, and the prior parents stay live" $
    withSession ((config terrainProfile atlases) {cfgLeases = 8, cfgJobs = 8, cfgPool = (2, 8)}) $ \session _ runtime → do
      vm ← startVm session runtime "terrain" OnArrival
      admitDriver session vm "i"
      -- A prior terrain's two parents are live (decoded size each).
      loadAs session vm "i" "priorColour" "colour.png" >>= (`shouldBe` "i start priorColour started")
      loadAs session vm "i" "priorNormal" "normal.png" >>= (`shouldBe` "i start priorNormal started")
      settle session vm "colour.png" "priorColour"
      settle session vm "normal.png" "priorNormal"
      ownerNow vm "i" >>= (\reading → (ownerTexturesHeld reading, ownerNominalHeld reading) `shouldBe` (2, colourBytes + normalBytes))
      -- A new terrain: its colour parent's reservation fits beside the prior pair and is held while its read waits.
      closeGate (ssProbe session) "colour.png"
      loadAs session vm "i" "newColour" "colour.png" >>= (`shouldBe` "i start newColour started")
      let Bytes reservation = textureReservationBytes terrainProfile
      ownerNow vm "i" >>= (\reading → ownerNominalHeld reading `shouldBe` colourBytes + normalBytes + reservation)
      -- Its REQUIRED normal parent does not fit: refused on bytes, nothing charged for the refusal.
      refused ← loadAs session vm "i" "newNormal" "normal.png"
      refused `shouldSatisfy` Text.isInfixOf "texture bytes"
      ownerNow vm "i" >>= (\reading → ownerNominalHeld reading `shouldBe` colourBytes + normalBytes + reservation)
      -- The acquisition fails as a whole: the caller rolls the colour parent's pending request back (cancelled). The bank returns to exactly the prior
      -- terrain's charges, and its two parents are live and unchanged.
      command session vm "i" "cancel" "newColour"
      awaitNote session "i cancel newColour cancelled"
      command session vm "i" "take" "newColour"
      awaitNote session "i take newColour {status=cancelled}"
      openGate (ssProbe session) "colour.png"
      awaitOwner vm "i" (\reading → (ownerTexturesHeld reading, ownerNominalHeld reading) == (2, colourBytes + normalBytes))
      sessionNow session `shouldReturn` colourBytes + normalBytes
      -- The prior parents release and retire as before: the bank returns to zero only at the backend's proofs.
      forM_ (zip [1 ..] ["priorColour", "priorNormal"]) $ \(position, key) → do
        command session vm "i" "release" key
        awaitNote session ("i release " <> key <> " retiring")
        awaitReleaseCalls (ssFake session) position
      ownerNow vm "i" >>= (\reading → ownerNominalHeld reading `shouldBe` colourBytes + normalBytes)
      calls ← releaseCalls (ssFake session)
      forM_ calls (retireTexture (ssFake session))
      awaitOwner vm "i" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0
  where
    colourBytes, normalBytes ∷ Word64
    colourBytes = 288 * 64 * 4
    normalBytes = 768 * 384 * 4
    -- Let this file's decode finish, then its upload, and take the texture. The two parents' reads run on
    -- two readers at once, so their uploads arrive in the order the workers finish: the upload is found by
    -- its file, never by its arrival index.
    settle session vm path key = do
      void (uploadFor (ssFake session) path >>= finishUpload (ssFake session))
      command session vm "i" "wait_take" key
      taken ← lineStarting session ("i wait_take " <> key <> " ")
      taken `shouldSatisfy` Text.isInfixOf "status=success"

-- | A flat-colour image compresses to almost nothing, so the PNG fits the encoded-byte limit at atlas size.
flat ∷ Int → Int → ByteString
flat width height = rgba8 width height (\_ _ → (40, 30, 20, 255))



atlases ∷ Layout
atlases = Layout [("colour.png", flat 288 64), ("normal.png", flat 768 384)]

-- | A profile whose pixel and axis limits admit the 768 x 384 atlas and whose instance bank (2,300,000 bytes) holds the two decoded
-- parents (1,253,376 bytes) and one pending reservation beside a live parent, but not two pending reservations
-- (2 x 1,179,648 = 2,359,296).
terrainProfile ∷ Profile
terrainProfile =
  smaller
    [(PngPixels, 294912), (PngAxisMaximum, 768)]
    [ (PngEncodedBytes, 1048576)
    , (PngInflatedScanlineBytes, 2097152)
    , (PngPipelineWorkspaceBytes, 8388608)
    , (TextureBytesPerUiInstance, 2500000)
    , (TextureBytesPerSession, 5000000)
    ]
