{-# LANGUAGE OverloadedStrings #-}

-- | Memory is the only bound on the textures a UI instance holds (owner decision 2026-11-08): no count refuses a
-- texture, every texture is charged at least the minimum, and the structural capacities derived from the byte limits
-- (the lease scope's, here) are never what answers first.
--
-- Two examples: an instance holds far more than sixteen textures with no refusal of any kind, and a property over
-- generated validated profiles shows that bytes alone decide every admission through pending, live and retiring
-- holdings, that a refusal names bytes and never a lease capacity, and that the banks come back to zero.
module Test.LuaEngine.Texture.Capacity (spec) where

import Control.Monad (forM_, unless, void)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (..)
  , Bytes (Bytes)
  , CountLimit (..)
  , Profile
  , bytesLimit
  , countLimit
  , Count (Count)
  , textureReservationBytes
  , textureRoomPerInstance
  )
import Hetoimasia.Scripting.Lua.Provider (ProviderDiagnostics (..))
import Test.Hspec
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (loadAs, started)
import Test.LuaEngine.Texture.Png (opaque)
import Test.LuaEngine.Texture.Support
import Test.QuickCheck (Gen, choose, elements, forAll, ioProperty, withNumTests)

spec ∷ Spec
spec = describe "memory is the only bound" $ do
  it "holds more than sixteen textures in one instance, with more than seventeen leases, and refuses nothing on a count: every byte comes back" $
    withSession ((config (profileOf 4096 64 (64 * 4096) (128 * 4096)) pictures) {cfgLeases = 100}) $ \session _ runtime → do
      setAutoRetire (ssFake session) True
      vm ← startVm session runtime "many" OnArrival
      admitDriver session vm "i"
      forM_ [0 .. 39 ∷ Int] $ \n → do
        started session vm "i" (keyOf n) "one.png"
        awaitUploads (ssFake session) (n + 1)
        void (uploadN (ssFake session) n >>= finishUpload (ssFake session))
        command session vm "i" "wait_take" (keyOf n)
        line ← lineStarting session ("i wait_take " <> keyOf n <> " ")
        line `shouldSatisfy` Text.isInfixOf "status=success"
      -- forty live textures, each charged the minimum although it decodes to four bytes
      ownerNow vm "i" >>= (`shouldBe` OwnerReading 40 (40 * 4096))
      sessionNow session `shouldReturn` 40 * 4096
      d ← vmDiagnostics vm
      rdBusy d `shouldBe` 0
      forM_ [0 .. 39 ∷ Int] $ \n → do
        command session vm "i" "release" (keyOf n)
        awaitNote session ("i release " <> keyOf n <> " done")
      awaitOwner vm "i" (== OwnerReading 0 0)
      sessionNow session `shouldReturn` 0

  it "decides every admission on bytes alone, over generated validated profiles: pending, live and retiring holdings, below-minimum textures, limits that are not multiples of the minimum, no refusal that names a lease capacity, no reservation leaked" $
    withNumTests 25 $
      forAll generated $ \shape →
        ioProperty (runShape shape)

-- Generated profiles -----------------------------------------------------------------------------------------------

-- | A validated profile's texture shape: pixel limit, instance bank and session bank.
data Shape = Shape
  { shPixels ∷ !Word64
  , shInstance ∷ !Word64
  , shSession ∷ !Word64
  }
  deriving (Show)

-- | A pixel limit whose reservation is below, at or above the 4 KiB minimum (4, 4,096 and 16,384 bytes of output, and
-- the minimum itself), an instance bank holding one to a few reservations plus a remainder that is not a multiple of
-- anything, and a session bank at least as large.
generated ∷ Gen Shape
generated = do
  pixels ← elements [1, 16, 1024, 2048, 4096]
  let reservation = max 4096 (4 * pixels)
  extra ← choose (0, 5 * reservation + 4095)
  more ← choose (0, 4 * reservation + 4095)
  let bank = reservation + extra
  pure (Shape pixels bank (bank + more))

profileOf ∷ Word64 → Word64 → Word64 → Word64 → Profile
profileOf _ pixels instanceBytes sessionBytes =
  smaller
    [(PngPixels, pixels), (PngAxisMaximum, 64)]
    [ (PngEncodedBytes, 65536)
    , (PngInflatedScanlineBytes, 65536)
    , (PngPipelineWorkspaceBytes, 1048576)
    , (TextureBytesPerUiInstance, instanceBytes)
    , (TextureBytesPerSession, sessionBytes)
    ]

pictures ∷ Layout
pictures = Layout [("one.png", opaque 1 1)]

keyOf ∷ Int → Text
keyOf n = "k" <> Text.pack (show n)

-- The property -------------------------------------------------------------------------------------------------------

-- | What the banks hold, as the model charges it: the first instance, the second instance and the session.
data Used = Used !Word64 !Word64 !Word64
  deriving (Eq, Show)

-- | Run one shape through the real pipeline: two instances start requests until the banks refuse (every one holding its
-- whole reservation), the decodes settle them live at the minimum charge, the room that frees up is filled again, and
-- every texture is released (retiring until the backend proves it) and retired.
runShape ∷ Shape → IO ()
runShape (Shape pixels instanceBytes sessionBytes) = do
  let profile = profileOf 0 pixels instanceBytes sessionBytes
      Bytes reservation = textureReservationBytes profile
      Bytes instanceLimit = bytesLimit profile TextureBytesPerUiInstance
      Bytes sessionLimit = bytesLimit profile TextureBytesPerSession
      Count windowSlots = countLimit profile WindowSlotsPerUiInstance
      -- the facade's derivation: the room the instance's bytes leave, and its window slots
      leaseCapacity = fromIntegral (textureRoomPerInstance profile + windowSlots)
      attempts = 2 * (fromIntegral (sessionLimit `div` 4096) + 2) ∷ Int
  withSession ((config profile pictures) {cfgLeases = leaseCapacity, cfgJobs = 64, cfgPool = (2, 64)}) $ \session _ runtime → do
    vm ← startVm session runtime "property" OnArrival
    mapM_ (admitDriver session vm) ["i", "j"]
    let -- Request one texture for each attempt, alternating between the instances: the model says whether the request fits
        -- both banks; a request that does not is refused on bytes, never on a lease capacity.
        fill ∷ Used → Int → IO (Used, [(Text, Text)], Int)
        fill used0 firstKey = go used0 [] firstKey attempts
          where
            go used accepted key 0 = pure (used, reverse accepted, key)
            go used@(Used usedI usedJ usedS) accepted key left = do
              let name = if even left then "i" else "j"
                  usedHere = if name == "i" then usedI else usedJ
                  fits = reservation <= instanceLimit - usedHere && reservation <= sessionLimit - usedS
              line ← loadAs session vm name (keyOf key) "one.png"
              if fits
                then do
                  line `shouldBe` (name <> " start " <> keyOf key <> " started")
                  let used' = if name == "i" then Used (usedI + reservation) usedJ (usedS + reservation) else Used usedI (usedJ + reservation) (usedS + reservation)
                  go used' ((name, keyOf key) : accepted) (key + 1) (left - 1 ∷ Int)
                else do
                  line `shouldSatisfy` Text.isInfixOf "texture bytes"
                  line `shouldSatisfy` (not . Text.isInfixOf "lease capacity")
                  go used accepted (key + 1) (left - 1)
        -- The banks read what the model says, and hold no more textures than the bytes can.
        check ∷ Used → Int → IO ()
        check (Used usedI usedJ usedS) held = do
          readingI ← ownerNow vm "i"
          readingJ ← ownerNow vm "j"
          ownerNominalHeld readingI `shouldBe` usedI
          ownerNominalHeld readingJ `shouldBe` usedJ
          sessionNow session `shouldReturn` usedS
          ownerTexturesHeld readingI + ownerTexturesHeld readingJ `shouldBe` held
          ownerTexturesHeld readingI `shouldSatisfy` (<= fromIntegral (instanceLimit `div` 4096))
          held `shouldSatisfy` (<= fromIntegral (sessionLimit `div` 4096))
        -- Let the decodes run: every pending request shrinks to the minimum charge and its texture goes live.
        settle ∷ [(Text, Text)] → Int → IO ()
        settle batch already = do
          openGate (ssProbe session) "one.png"
          -- two lanes: a request's upload arrives only once an earlier one has ended, so they are finished one at a time
          forM_ [already .. already + length batch - 1] $ \n → do
            awaitUploads (ssFake session) (n + 1)
            uploadN (ssFake session) n >>= void . finishUpload (ssFake session)
          forM_ batch $ \(name, key) → do
            command session vm name "wait_take" key
            line ← lineStarting session (name <> " wait_take " <> key <> " ")
            line `shouldSatisfy` Text.isInfixOf "status=success"
          closeGate (ssProbe session) "one.png"
        liveUsed ∷ [(Text, Text)] → Used
        liveUsed live = Used (4096 * count "i") (4096 * count "j") (4096 * fromIntegral (length live))
          where
            count who = fromIntegral (length [() | (name, _) ← live, name == who])
    -- every request holds its whole reservation: reads wait at the gate
    closeGate (ssProbe session) "one.png"
    (pendingUsed, first, nextKey) ← fill (Used 0 0 0) 0
    check pendingUsed (length first)
    unless (not (null first)) (expectationFailure "no request fit a validated profile's banks")
    settle first 0
    check (liveUsed first) (length first)
    -- the shrunk charges leave room: fill it again, behind the live textures
    (pendingAgain, second, _) ← fill (liveUsed first) nextKey
    check pendingAgain (length first + length second)
    settle second (length first)
    let everything = first <> second
    check (liveUsed everything) (length everything)
    -- every texture is released: charged while retiring, free once the backend proves its retirement
    forM_ (zip [1 ..] everything) $ \(position, (name, key)) → do
      command session vm name "release" key
      awaitNote session (name <> " release " <> key <> " retiring")
      awaitReleaseCalls (ssFake session) position
      releaseCalls (ssFake session) >>= retireTexture (ssFake session) . last
    awaitOwner vm "i" (== OwnerReading 0 0)
    awaitOwner vm "j" (== OwnerReading 0 0)
    sessionNow session `shouldReturn` 0
