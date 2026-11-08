{-# LANGUAGE OverloadedStrings #-}

-- | The `validated data texture pixels (TRA-15)` subgroup: what a texture requested with a declared image kind and
-- policy looks like on a real device, and that an input its policy refuses never becomes a texture a draw could sample.
--
-- = What runs for real, and what is substituted
--
-- The same machine as the controlled "texture backend on a real device, with no window" examples: a content root, the
-- verified read, the bounded decoder under the request's policy, the pipeline's lanes, banks and shared CPU account, the
-- production texture adapter on the session's one graphics owner (allocation, upload, registration through the one table),
-- and the renderer's public path recording one frame-less offscreen batch into a surface-free colour target
-- (@R8G8B8A8_SRGB@, 32 × 16), read back only after that batch's own ticket completed. The window-free session opens no
-- window, and each example says so. Only the Lua scaffolding that asks for the texture is the example's own: the request goes
-- through the real texture service and pipeline, not the facade's bindings, which the device-free suites already cover.
--
-- = What is judged, and by whom
--
-- Every readback is judged three ways, none of them the code under test. The render-2d oracle expects every pixel the scene
-- determines from the image the texture decoded to. The expected bytes of the ramp's texels are also stated here by hand,
-- worked out in comments from the IEC 61966-2-1 transfer function. And the facts of the coverage and the checked profile are
-- reached only through the public retention boundary ('retainTexture'), never through an accessor into the pipeline or the
-- adapter.
--
-- = Target encoding
--
-- The target is sRGB. A /colour/ texture is an sRGB image: sampling decodes it to linear light and the store encodes it
-- again, so an opaque texel reads back as itself. A /data/ texture is a linear UNORM image: the sampled number @v ÷ 255@ is
-- taken as linear light and the store encodes it, so the same file's texel reads back as @255 × encode (v ÷ 255)@, which is
-- 188 for 128, not 128. The two routes agreeing would mean the data route was reinterpreted as colour. The refusal examples
-- show that an image its policy refuses leaves no registration, no live texture and no charge behind.
--
-- = Evidence
--
-- Each image is retained when @HETOIMASIA_VALIDATION_EVIDENCE@ names a directory: the lossless PNG of the readback and a
-- machine-readable JSON record with the SHA-256 of every input file, the request, the target, the build identity the runner
-- recorded, the window count (0), every hand comparison and the oracle's counts. The input files are explicitly labelled
-- technical fixtures: tiny images built byte by byte by "Test.LuaEngine.Graphics.Png", not production artwork.
module Test.LuaEngine.Graphics.Native.DataTextures (spec) where

import Control.Concurrent.STM (atomically, retry)
import Control.Monad (forM, forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Word (Word64, Word8)
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Asset.Image.DataMap (coverageBits)
import Hetoimasia.LuaEngine.Graphics.Texture
import Hetoimasia.LuaEngine.Texture
  ( NormalEncoding (..)
  , OwnerReading (..)
  , TextureKind (..)
  , accountCharged
  , ownerReading
  , retainedCoverage
  , retainedKind
  , retainedNormal
  , retainedVersion
  , releaseRetained
  )
import Hetoimasia.Render.TwoD.Oracle.Colour (ColourFormat (..), Rgba8 (..))
import Hetoimasia.Render.TwoD.Oracle.Readback (readPixel)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures (retainedEntries)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Composition
import Test.LuaEngine.Graphics.Native.Frame (Shot (..), shootRaw, sideHeight, sideWidth)
import Test.LuaEngine.Graphics.Native.Scenes (evidence)
import Test.LuaEngine.Graphics.Native.Session (Env (..))
import Test.LuaEngine.Graphics.Native.Spec (noWindows, within)
import Test.LuaEngine.Graphics.Pixels (sha256Text)
import qualified Test.LuaEngine.Graphics.Png as Png

-- The technical fixtures ---------------------------------------------------------------------------------------------

-- | TRA-15 technical test asset (not production art): 4 × 2, opaque, with intermediate numeric channels.
--
-- >        col 0           col 1            col 2            col 3
-- > row 0  32,64,96        128,128,128      160,192,224      16,48,240
-- > row 1  64,128,192      200,100,50       1,2,3            250,251,252
rampTexels ∷ [[(Word8, Word8, Word8)]]
rampTexels =
  [ [(32, 64, 96), (128, 128, 128), (160, 192, 224), (16, 48, 240)]
  , [(64, 128, 192), (200, 100, 50), (1, 2, 3), (250, 251, 252)]
  ]

rampPng ∷ ByteString
rampPng = Png.rgba8 4 2 (\x y → let (r, g, b) = rampTexels !! y !! x in (r, g, b, 255))

-- | What the ramp reads back as through the data route into the sRGB target: @round (255 × encode (v ÷ 255))@ per channel,
-- with encode the sRGB transfer function (linear below 0.0031308 at 12.92, else 1.055 v^(1/2.4) − 0.055). Worked by hand:
--
-- >   v:  1   2   3   16  32  48  50   64   96   100  128  160  192  200  224  240  250  251  252
-- >   → 13  22  28  71  99  120 122  137  165  168  188  208  225  229  241  248  253  253  254
dataReadback ∷ [[(Word8, Word8, Word8)]]
dataReadback =
  [ [(99, 137, 165), (188, 188, 188), (208, 225, 241), (71, 120, 248)]
  , [(137, 188, 225), (229, 168, 122), (13, 22, 28), (253, 253, 254)]
  ]

-- | 4 × 2 normals with binary alpha (technical asset): flat-up, the W ramp, a transparent texel whose RGB is not a normal, a
-- mirrored ramp, two tilts and two legal extremes. Texel (2, 0) is transparent, so its coverage bit is clear.
normalTexels ∷ [[(Word8, Word8, Word8, Word8)]]
normalTexels =
  [ [(128, 128, 255, 255), (38, 128, 218, 255), (0, 0, 0, 0), (218, 128, 38, 255)]
  , [(128, 38, 218, 255), (128, 218, 38, 255), (1, 255, 128, 255), (255, 1, 128, 255)]
  ]

normalsPng ∷ ByteString
normalsPng = Png.rgba8 4 2 (\x y → normalTexels !! y !! x)

-- | Technical asset: a normal map with the zero vector (128,128,128) in a nontransparent texel.
zeroVectorPng ∷ ByteString
zeroVectorPng = Png.rgba8 2 1 (\x _ → [(128, 128, 255, 255), (128, 128, 128, 255)] !! x)

-- | Technical asset: alpha 254 in one texel, so it has no binary coverage.
nonBinaryPng ∷ ByteString
nonBinaryPng = Png.rgba8 2 1 (\x _ → [(10, 20, 30, 255), (10, 20, 30, 254)] !! x)

files ∷ Files
files =
  [ ("ramp.png", rampPng)
  , ("normals.png", normalsPng)
  , ("zerovector.png", zeroVectorPng)
  , ("nonbinary.png", nonBinaryPng)
  ]

-- The subgroup -----------------------------------------------------------------------------------------------------------

spec ∷ Env → Spec
spec env = describe "validated data texture pixels (TRA-15)" $ do
  it "reads the same file's intermediate channels back as themselves through the colour route and as sRGB-encoded numbers through the data route, in a window-free session" $
    within 120 . withLoaded' $ \comp vm → do
      noWindows env
      admit comp vm "a"
      colourIdentity ← loadOn comp vm "a" "c" "ramp.png" []
      dataIdentity ← loadOn comp vm "a" "d" "ramp.png" ["data"]
      colourIdentity `shouldNotBe` dataIdentity
      -- Opaque, so the colour route's premultiplication changes nothing: the decoded image the oracle reads is the file's.
      colour ← shoot' colourIdentity (decodedAs TexelRgba8Srgb)
      dataRoute ← shoot' dataIdentity (decodedAs TexelRgba8Linear)
      shotFailed colour `shouldBe` []
      shotFailed dataRoute `shouldBe` []
      shotDeterminate colour `shouldSatisfy` (>= 8)
      shotDeterminate dataRoute `shouldSatisfy` (>= 8)
      colourComparisons ← compareRamp colour [[t | t <- row] | row <- rampTexels]
      dataComparisons ← compareRamp dataRoute dataReadback
      forM_ (colourComparisons <> dataComparisons) $ \(_, _, expected, read', _) → read' `shouldSatisfy` (\got → got `within1` expected)
      -- The two routes do not agree on a mid-grey: 128 is 128 as colour and 188 as numeric data.
      pixelAt colour 1 0 `shouldSatisfy` (`within1` (128, 128, 128))
      pixelAt dataRoute 1 0 `shouldSatisfy` (`within1` (188, 188, 188))
      retainShot env "ramp-colour-route" "ramp.png" rampPng "colour" colour colourComparisons
      retainShot env "ramp-data-route" "ramp.png" rampPng "data" dataRoute dataComparisons
      evidence env "ramp: the same file read back as colour (128 → 128) and as data (128 → 188) through the production adapter into an sRGB target; windows 0"
      releaseAll comp vm "a" ["c", "d"]

  it "reaches the coverage and the checked profile of the texture it just drew only through the public retention boundary, with the plane's bits stated by hand" $
    within 120 . withLoaded' $ \comp vm → do
      noWindows env
      admit comp vm "a"
      identity ← loadOn comp vm "a" "n" "normals.png" ["data", "coverage", "normal"]
      commandRetain comp vm "a" "n" "facts" ["data", "coverage", "normal"]
      _ ← awaitNoteContaining comp "a retain n retained"
      held ← heldRetained vm "facts" >>= maybe (expectationFailure "nothing was retained" >> fail "none") pure
      retainedKind held `shouldBe` DataKind
      retainedNormal held `shouldBe` Just UnitNormalRgbV1
      -- Texels row by row: 1 1 0 1 / 1 1 1 1. Bit k is texel k, least significant first: 0b11111011 = 0xFB.
      fmap coverageBits (retainedCoverage held) `shouldBe` Just (ByteString.pack [0xFB])
      -- The very texture a draw resolves is the retained version's: the identity is the device registration's.
      shot ← shoot' identity (normalsDecoded)
      shotFailed shot `shouldBe` []
      retainShotFacts env "normals-facts" "normals.png" normalsPng shot (retainedVersion held)
      -- A request for the same file as plain data has neither fact, and the boundary says so.
      plain ← loadOn comp vm "a" "p" "normals.png" ["data"]
      plain `shouldNotBe` identity
      commandRetain comp vm "a" "p" "plain" ["coverage"]
      refusal ← awaitNoteContaining comp "a retain p refused"
      refusal `shouldSatisfy` Text.isInfixOf "no binary coverage"
      commandRetain comp vm "a" "p" "plain" ["normal"]
      refusedProfile ← awaitNoteContaining comp "a retain p refused: the texture's texels were not validated"
      refusedProfile `shouldSatisfy` Text.isInfixOf "normal_encoding=unit-normal-rgb-v1"
      releaseRetained held
      releaseAll comp vm "a" ["n", "p"]
      evidence env "normals: coverage plane 0xFB and the unit-normal-rgb-v1 fact reached through retainTexture only; a plain data request has neither"

  it "makes no texture of an image its policy refuses: a zero vector with a declared normal profile and a nonbinary alpha with binary coverage leave no registration, no live texture and no charge" $
    within 120 . withLoaded' $ \comp vm → do
      noWindows env
      admit comp vm "a"
      marksBefore ← retainedEntries (graphicsTextures (envGraphics env))
      liveBefore ← atomically (graphicsReading (envGraphics env))
      forM_
        [ ("z", "zerovector.png", ["data", "normal"], "normal_encoding=unit-normal-rgb-v1")
        , ("b", "nonbinary.png", ["coverage"], "coverage=binary")
        ] $ \(key, path, wordsGiven, policy) → do
          commandLoadPolicy comp vm "a" key path True wordsGiven
          command comp vm "a" "wait_take" key
          line ← awaitNoteContaining comp ("a wait_take " <> key)
          line `shouldSatisfy` Text.isInfixOf "status=failure"
          line `shouldSatisfy` Text.isInfixOf "code=invalid_image"
          line `shouldSatisfy` Text.isInfixOf policy
      owner ← ownerOf vm "a"
      atomically (ownerReading owner >>= \reading → unless (ownerSlotsHeld reading == 0 && ownerNominalHeld reading == 0) retry)
      -- Nothing was uploaded or registered, so nothing a draw could sample exists: the table's marks and the live count are
      -- what they were, and the shared CPU account holds nothing.
      retainedEntries (graphicsTextures (envGraphics env)) `shouldReturn` marksBefore
      liveAfter ← atomically (graphicsReading (envGraphics env))
      readingLiveTextures liveAfter `shouldBe` readingLiveTextures liveBefore
      atomically (accountCharged (cpAccount comp)) `shouldReturn` 0
      evidence env "refused: a zero-vector normal map and a nonbinary alpha under coverage=binary failed as invalid_image and registered nothing"
  where
    withLoaded' body = withComposition' env body

    shoot' identity decoded =
      shootRaw (envHost env) (graphicsRenderer (envGraphics env)) (textureHandleOf (fromIntegral identity)) decoded >>= \case
        Left failure → expectationFailure ("the frame failed: " <> Text.unpack failure) >> fail "frame"
        Right shot → pure shot

    compareRamp shot expected =
      forM [(x, y) | y ← [0, 1], x ← [0 .. 3]] $ \(x, y) →
        pure (x, y, expected !! y !! x, pixelAt shot x y, rampTexels !! y !! x)

-- | Release every texture the instance holds, then wait for its slots to come back on the table's own evidence.
releaseAll ∷ Composition → Vm → Text → [Text] → IO ()
releaseAll comp vm who keys = do
  forM_ keys $ \key → do
    command comp vm who "release" key
    awaitNoteContaining comp (who <> " release " <> key) >>= \_ → pure ()
  owner ← ownerOf vm who
  atomically (ownerReading owner >>= \reading → unless (ownerSlotsHeld reading == 0) retry)

-- | A composition over the session's production backend with these files.
withComposition' ∷ Env → (Composition → Vm → IO a) → IO a
withComposition' env body = withComposition compositionProfile files (graphicsBackend (envGraphics env)) $ \comp _ runtime → do
  vm ← startVm comp runtime "native-data-vm"
  -- A bound of its own, well inside the example's, so that a request that never settles reports what the scripts recorded.
  timeout 80000000 (body comp vm) >>= \case
    Just value → pure value
    Nothing → do
      seen ← notes comp
      assertFailure ("the example did not finish; the scripts recorded " <> show seen)

-- | Load this path with these policy words on an admitted instance and answer the texture's identity once the request
-- reported success.
loadOn ∷ Composition → Vm → Text → Text → Text → [Text] → IO Integer
loadOn comp vm who key path wordsGiven = do
  commandLoadPolicy comp vm who key path False wordsGiven
  command comp vm who "wait_take" key
  line ← awaitNoteContaining comp (who <> " wait_take " <> key)
  line `shouldSatisfy` Text.isInfixOf "status=success"
  command comp vm who "use" key
  used ← awaitNoteContaining comp (who <> " use " <> key)
  case reads (Text.unpack (last (Text.words used))) of
    [(identity, "")] → pure identity
    _ → expectationFailure ("the identity was not a number: " <> Text.unpack used) >> fail "identity"

-- | The ramp as the oracle reads it: one level of straight texels (opaque, so premultiplied is the same), in this format.
decodedAs ∷ TexelFormat → DecodedImage
decodedAs format =
  DecodedImage
    { decodedFormat = format
    , decodedWidth = 4
    , decodedHeight = 2
    , decodedLevels = [ByteString.pack (concat [[r, g, b, 255] | row ← rampTexels, (r, g, b) ← row])]
    , decodedBinaryAlpha = True
    }

normalsDecoded ∷ DecodedImage
normalsDecoded =
  DecodedImage
    { decodedFormat = TexelRgba8Linear
    , decodedWidth = 4
    , decodedHeight = 2
    , decodedLevels = [ByteString.pack (concat [[r, g, b, a] | row ← normalTexels, (r, g, b, a) ← row])]
    , decodedBinaryAlpha = True
    }

-- Reading a shot ---------------------------------------------------------------------------------------------------------

-- | The texture is drawn one texel to a pixel, centred in the target: its top-left texel is at this pixel.
originOf ∷ (Int, Int)
originOf = ((sideWidth - 4) `div` 2, (sideHeight - 2) `div` 2)

-- | The target pixel of texel (x, y), RGB.
pixelAt ∷ Shot → Int → Int → (Word8, Word8, Word8)
pixelAt shot x y =
  case readPixel R8G8B8A8Srgb (PixelExtent (fromIntegral sideWidth) (fromIntegral sideHeight)) (shotBytes shot) (fst originOf + x) (snd originOf + y) of
    Right (Rgba8 r g b _) → (r, g, b)
    Left _ → (0, 0, 0)

within1 ∷ (Word8, Word8, Word8) → (Word8, Word8, Word8) → Bool
within1 (a, b, c) (d, e, f) = and [abs (fromIntegral p - fromIntegral q ∷ Int) <= 1 | (p, q) ← [(a, d), (b, e), (c, f)]]

-- Evidence -------------------------------------------------------------------------------------------------------------

type Comparison = (Int, Int, (Word8, Word8, Word8), (Word8, Word8, Word8), (Word8, Word8, Word8))

-- | Retain one image: the lossless PNG of the readback and a machine-readable record.
retainShot ∷ Env → Text → Text → ByteString → Text → Shot → [Comparison] → IO ()
retainShot env stem file input route shot comparisons = do
  identity ← buildIdentity
  let readbackPng = readbackImage shot
      record =
        Text.unlines
          [ "{"
          , "  \"group\": \"validated data texture pixels (TRA-15)\","
          , "  \"image\": " <> quoted stem <> ","
          , "  \"route\": " <> quoted route <> ","
          , "  \"technicalFixture\": \"TRA-15 technical test asset built byte by byte by the suite; not production art\","
          , "  \"input\": {\"file\": " <> quoted file <> ", \"bytes\": " <> tshow (ByteString.length input) <> ", \"sha256\": " <> quoted (sha256Text input) <> "},"
          , "  \"request\": " <> (if route == "data" then "{\"kind\": \"data\"}" else "{\"kind\": \"colour\"}") <> ","
          , "  \"target\": {\"format\": \"R8G8B8A8_SRGB\", \"width\": " <> tshow sideWidth <> ", \"height\": " <> tshow sideHeight <> ", \"surfaceFree\": true},"
          , "  \"windows\": 0,"
          , "  \"completion\": \"read after the batch's own ticket completed\","
          , "  \"build\": " <> identity <> ","
          , "  \"oracle\": {\"determinatePixels\": " <> tshow (shotDeterminate shot) <> ", \"failures\": " <> tshow (length (shotFailed shot)) <> "},"
          , "  \"handTolerance\": 1,"
          , "  \"comparisons\": [" <> Text.intercalate ", " (map comparison comparisons) <> "],"
          , "  \"readbackSha256\": " <> quoted (sha256Text (shotBytes shot)) <> ","
          , "  \"pngSha256\": " <> quoted (sha256Text readbackPng)
          , "}"
          ]
  write env stem readbackPng record

-- | The facts record of the texture whose coverage and profile were reached through the retention boundary.
retainShotFacts ∷ Env → Text → Text → ByteString → Shot → Word64 → IO ()
retainShotFacts env stem file input shot versionId = do
  identity ← buildIdentity
  let readbackPng = readbackImage shot
      record =
        Text.unlines
          [ "{"
          , "  \"group\": \"validated data texture pixels (TRA-15)\","
          , "  \"image\": " <> quoted stem <> ","
          , "  \"technicalFixture\": \"TRA-15 technical test asset built byte by byte by the suite; not production art\","
          , "  \"input\": {\"file\": " <> quoted file <> ", \"bytes\": " <> tshow (ByteString.length input) <> ", \"sha256\": " <> quoted (sha256Text input) <> "},"
          , "  \"request\": {\"kind\": \"data\", \"coverage\": \"binary\", \"normal_encoding\": \"unit-normal-rgb-v1\"},"
          , "  \"versionId\": " <> tshow versionId <> ","
          , "  \"coverageBitsHex\": \"fb\","
          , "  \"factsReachedThrough\": \"retainTexture (the public retention boundary)\","
          , "  \"windows\": 0,"
          , "  \"build\": " <> identity <> ","
          , "  \"oracle\": {\"determinatePixels\": " <> tshow (shotDeterminate shot) <> ", \"failures\": " <> tshow (length (shotFailed shot)) <> "},"
          , "  \"readbackSha256\": " <> quoted (sha256Text (shotBytes shot)) <> ","
          , "  \"pngSha256\": " <> quoted (sha256Text readbackPng)
          , "}"
          ]
  write env stem readbackPng record

comparison ∷ Comparison → Text
comparison (x, y, expected, got, input) =
  "{\"texel\": [" <> tshow x <> ", " <> tshow y <> "], \"input\": " <> triple input <> ", \"expected\": " <> triple expected <> ", \"read\": " <> triple got <> "}"
  where
    triple (r, g, b) = "[" <> tshow r <> ", " <> tshow g <> ", " <> tshow b <> "]"

-- | The readback as a lossless PNG.
readbackImage ∷ Shot → ByteString
readbackImage shot =
  Png.rgba8 sideWidth sideHeight $ \x y →
    case readPixel R8G8B8A8Srgb (PixelExtent (fromIntegral sideWidth) (fromIntegral sideHeight)) (shotBytes shot) x y of
      Right (Rgba8 r g b a) → (r, g, b, a)
      Left _ → (0, 0, 0, 0)

-- | The build identity the runner recorded for this executable, as JSON.
buildIdentity ∷ IO Text
buildIdentity = do
  revision ← lookupEnv "HETOIMASIA_VULKAN_REVISION"
  digest ← lookupEnv "HETOIMASIA_VULKAN_SOURCE_DIGEST"
  pure ("{\"revision\": " <> quoted (maybe "unknown" Text.pack revision) <> ", \"sourceDigest\": " <> quoted (maybe "unknown" Text.pack digest) <> "}")

write ∷ Env → Text → ByteString → Text → IO ()
write env stem png record = do
  evidence env ("validated data texture pixels (TRA-15) / " <> stem <> ": png sha256 " <> sha256Text png)
  directory ← lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE"
  forM_ directory $ \place → do
    let folder = place </> "validated-data-texture-pixels"
    createDirectoryIfMissing True folder
    ByteString.writeFile (folder </> Text.unpack stem <> ".png") png
    Text.writeFile (folder </> Text.unpack stem <> ".json") record

quoted ∷ Text → Text
quoted text = "\"" <> Text.concatMap escape text <> "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape c = Text.singleton c

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
