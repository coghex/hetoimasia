-- | The KTX2 reader over committed fixtures.
--
-- @make_ktx2_fixtures.py@ assembles every fixture byte by byte, using only
-- Python's standard library; @ktx2-fixtures.txt@ records each one's producer
-- and version. The expected levels are restated here: RGBA8 texels by value,
-- with the premultiplied ones computed by IEC 61966-2-1 in double precision
-- and rounded to nearest (every one lies more than 0.01 of a code value from
-- a rounding boundary), and BC7 levels as the mode-6 blocks the script
-- builds, whose alpha follows from their constant endpoints. Nothing expected
-- comes from the reader under test.
module Test.Asset.Image.Ktx2 (spec) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Char (digitToInt)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word8)
import Hetoimasia.Asset (AssetRefusal (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Bc7 (Bc7Format (..), bc7Asset, bc7BinaryAlpha, bc7Format, bc7Height, bc7Levels, bc7Width)
import Hetoimasia.Asset.Image.Ktx2 (Ktx2Image (..), decodeKtx2, ktx2DecodedImage)
import Test.Asset.Image.Support (Texel, fixtureAsset, fixtureBytes)
import Test.Hspec (Spec, describe, expectationFailure, it, runIO, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Ktx2" $ do
  manifest ← runIO (parseManifest <$> fixtureBytes "ktx2-fixtures.txt")

  describe "the fixtures" $ do
    it "records every fixture's producer and version beside it" $
      forM_ fixtureNames $ \name → lookup name manifest `shouldBe` Just "make_ktx2_fixtures.py 1"
    it "has an example for every fixture it records" $
      sort (map fst manifest) `shouldBe` sort fixtureNames

  describe "RGBA8" $ forM_ rgba8Cases $ \(Rgba8Case name kind format (w, h) levels binary) →
    it (name <> " reads as " <> show kind <> " to its expected levels") $
      readFixture kind name >>= \case
        Ktx2Rgba8 image → do
          decodedFormat image `shouldBe` format
          (decodedWidth image, decodedHeight image) `shouldBe` (w, h)
          decodedLevels image `shouldBe` map packTexels levels
          decodedBinaryAlpha image `shouldBe` binary
        other → expectationFailure ("not an RGBA8 image: " <> show other)

  describe "BC7" $ forM_ bc7Cases $ \(Bc7Case name kind format (w, h) levels binary) →
    it (name <> " reads as " <> show kind <> " to its stored blocks and mark") $
      readFixture kind name >>= \case
        Ktx2Bc7 image → do
          bc7Asset image `shouldBe` fixtureAsset name
          bc7Format image `shouldBe` format
          (bc7Width image, bc7Height image) `shouldBe` (w, h)
          bc7Levels image `shouldBe` map (ByteString.concat . map hexBytes) levels
          bc7BinaryAlpha image `shouldBe` binary
          let decoded = ktx2DecodedImage (Ktx2Bc7 image)
          decodedFormat decoded `shouldBe` (if format == Bc7Srgb then TexelBc7Srgb else TexelBc7Linear)
          decodedLevels decoded `shouldBe` bc7Levels image
        other → expectationFailure ("not a BC7 image: " <> show other)

  describe "refusals name the asset and the reason" $
    forM_ refusals $ \(name, kind, fragments) →
      it (name <> " as " <> show kind) $ do
        bytes ← fixtureBytes name
        result ← evaluate (force (decodeKtx2 kind (fixtureAsset name) bytes))
        case result of
          Left refusal → do
            refusedAsset refusal `shouldBe` fixtureAsset name
            forM_ fragments $ \fragment → refusalReason refusal `shouldSatisfy` Text.isInfixOf fragment
          Right image → expectationFailure ("read: " <> show image)

  it "gives the same result for the same bytes and kind" $
    forM_ ([(name, kind) | Rgba8Case name kind _ _ _ _ ← rgba8Cases] <> [(name, kind) | Bc7Case name kind _ _ _ _ ← bc7Cases]) $ \(name, kind) → do
      bytes ← fixtureBytes name
      first ← evaluate (force (decodeKtx2 kind (fixtureAsset name) bytes))
      second ← evaluate (force (decodeKtx2 kind (fixtureAsset name) (ByteString.copy bytes)))
      first `shouldBe` second

-- | A fixture expected to read as RGBA8: its kind, format, extent, every
-- level's texels, and its mark.
data Rgba8Case = Rgba8Case String ImageKind TexelFormat (Word32, Word32) [[Texel]] Bool

-- | A fixture expected to read as BC7: every level's blocks in hex.
data Bc7Case = Bc7Case String ImageKind Bc7Format (Word32, Word32) [[String]] Bool

-- | The straight texels the single-level files hold, and those texels
-- premultiplied in linear light.
single, singlePremultiplied ∷ [Texel]
single = [(255, 0, 0, 255), (0, 255, 0, 128), (0, 0, 255, 0), (200, 100, 50, 64)]
singlePremultiplied = [(255, 0, 0, 255), (0, 188, 0, 128), (0, 0, 0, 0), (106, 50, 22, 64)]

-- | The 4 × 2 files' full chain, straight and premultiplied.
multi, multiPremultiplied ∷ [[Texel]]
multi =
  [ [(255, 255, 255, 255), (128, 64, 32, 200), (10, 20, 30, 40), (0, 0, 0, 0), (255, 128, 0, 1), (90, 180, 250, 254), (17, 34, 51, 128), (240, 240, 240, 255)]
  , [(100, 150, 200, 100), (50, 60, 70, 255)]
  , [(33, 66, 99, 33)]
  ]
multiPremultiplied =
  [ [(255, 255, 255, 255), (114, 56, 28, 200), (2, 4, 7, 40), (0, 0, 0, 0), (13, 3, 0, 1), (90, 180, 250, 254), (9, 22, 35, 128), (240, 240, 240, 255)]
  , [(63, 97, 131, 100), (50, 60, 70, 255)]
  , [(6, 20, 34, 33)]
  ]

-- | Level @level@ of the partial-chain file, at its extent.
partial ∷ Word8 → Word8 → Word8 → [Texel]
partial level w h = [(x * 30 + level, y * 60 + level, 100, 255 - x - y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]

rgba8Cases ∷ [Rgba8Case]
rgba8Cases =
  [ -- Straight-alpha colour is premultiplied at load, every level.
    Rgba8Case "rgba8-srgb.ktx2" ColourImage TexelRgba8Srgb (2, 2) [singlePremultiplied] False
  , Rgba8Case "rgba8-srgb-mips.ktx2" ColourImage TexelRgba8Srgb (4, 2) multiPremultiplied False
  , -- With the flag, colour texels are returned as stored.
    Rgba8Case "rgba8-srgb-premultiplied.ktx2" ColourImage TexelRgba8Srgb (2, 2) [singlePremultiplied] False
  , Rgba8Case "rgba8-srgb-premultiplied-mips.ktx2" ColourImage TexelRgba8Srgb (4, 2) multiPremultiplied False
  , -- Data is returned unchanged.
    Rgba8Case "rgba8-linear.ktx2" DataImage TexelRgba8Linear (2, 2) [single] False
  , Rgba8Case "rgba8-linear-mips.ktx2" DataImage TexelRgba8Linear (4, 2) multi False
  , -- Two of a full chain of four.
    Rgba8Case "rgba8-linear-partial.ktx2" DataImage TexelRgba8Linear (8, 4) [partial 0 8 4, partial 1 4 2] False
  , Rgba8Case "rgba8-linear-layer-one.ktx2" DataImage TexelRgba8Linear (2, 2) [single] False
  , Rgba8Case "rgba8-linear-no-metadata.ktx2" DataImage TexelRgba8Linear (2, 2) [single] False
  , Rgba8Case "rgba8-linear-explicit-metadata.ktx2" DataImage TexelRgba8Linear (2, 2) [single] False
  , -- An unspecified colour model and primaries, a second, vendor-specific
    -- descriptor block, and unknown keys, one with a binary value.
    Rgba8Case "rgba8-linear-ignored.ktx2" DataImage TexelRgba8Linear (2, 2) [single] False
  ]

-- Blocks, named by what every texel decodes to. Each holds constant
-- endpoints, so its alpha follows from its indices alone.
holes15, holes15b, holes3, holes1 ∷ String
holes15 = "40324006c800fe80f000f00000000000" -- alpha 0 at texels 1 and 5, 255 elsewhere
holes15b = "40324006c800fe8000000000000000f0" -- alpha 0 at texel 15
holes3 = "40324006c800fe8000f0000000000000" -- alpha 0 at texel 3
holes1 = "40324006c800fe80f000000000000000" -- alpha 0 at texel 1

opaqueA, opaqueB, opaqueC, opaqueD, opaqueE ∷ String
opaqueA = "c04241a1783cfeff0100000000000000" -- alpha 255 everywhere
opaqueB = "400a2593f178feff0100000000000000"
opaqueC = "400020101008feff0100000000000000"
opaqueD = "c0c180402814feff0100000000000000"
opaqueE = "4083e1704020feff0100000000000000"

translucentA, translucentB, translucentC, translucentD ∷ String
translucentA = "c0d108856ab580400000000000000000" -- alpha 128 everywhere
translucentB = "4099ec76e3f180400000000000000000"
translucentC = "c0404020180c80400000000000000000"
translucentD = "408562b1603080400000000000000000"

-- | Alpha 255 inside the named corner of the block, and 188 outside it.
cropped43, cropped13, cropped21, cropped11 ∷ String
cropped43 = "c03f10080200fec00000000000008888" -- 4 × 3
cropped13 = "c03f10080200fec08088808880888888" -- 1 × 3
cropped21 = "c03f10080200fec00088888888888888" -- 2 × 1
cropped11 = "c03f10080200fec08088888888888888" -- 1 × 1

bc7Cases ∷ [Bc7Case]
bc7Cases =
  [ -- Level 0's alpha is 0 and 255 only.
    Bc7Case "bc7-srgb-premultiplied.ktx2" ColourImage Bc7Srgb (8, 8) [[holes15, opaqueA, holes15b, opaqueB], [translucentA], [holes3], [opaqueC]] True
  , -- Level 0's alpha is 128: not binary.
    Bc7Case "bc7-srgb-premultiplied-translucent.ktx2" ColourImage Bc7Srgb (4, 4) [[translucentB]] False
  , -- Data is never checked for opacity; level 0's alpha is 128 and 255.
    Bc7Case "bc7-linear.ktx2" DataImage Bc7Linear (8, 4) [[translucentC, opaqueD], [opaqueE], [holes1], [translucentD]] False
  , -- Without the flag, but opaque in every texel inside every level's
    -- extent. The edge blocks' texels outside it have alpha 188, which
    -- neither refuses the file nor clears its mark.
    Bc7Case "bc7-srgb-straight-opaque.ktx2" ColourImage Bc7Srgb (5, 3) [[cropped43, cropped13], [cropped21], [cropped11]] True
  ]

refusals ∷ [(String, ImageKind, [Text])]
refusals =
  [ -- Requirement 2: the profile.
    ("refuse-format.ktx2", DataImage, ["vkFormat 44 is not one of R8G8B8A8_SRGB (43), R8G8B8A8_UNORM (37), BC7_SRGB_BLOCK (146) or BC7_UNORM_BLOCK (145)"])
  , ("refuse-transfer-srgb.ktx2", ColourImage, ["transfer function 1 (linear) disagrees with R8G8B8A8_SRGB, which needs 2 (sRGB)"])
  , ("refuse-transfer-unorm.ktx2", DataImage, ["transfer function 2 (sRGB) disagrees with BC7_UNORM_BLOCK, which needs 1 (linear)"])
  , ("refuse-1d.ktx2", ColourImage, ["not two-dimensional with one layer and one face: pixelHeight is 0, a 1D texture"])
  , ("refuse-3d.ktx2", ColourImage, ["not two-dimensional with one layer and one face: pixelDepth is 2, a 3D texture"])
  , ("refuse-array.ktx2", ColourImage, ["not two-dimensional with one layer and one face: layerCount is 2, an array texture"])
  , ("refuse-cube.ktx2", ColourImage, ["not two-dimensional with one layer and one face: faceCount is 6, a cube map"])
  , ("refuse-supercompressed.ktx2", ColourImage, ["supercompressionScheme is 2; supercompressed files are not read"])
  , ("refuse-level-count-zero.ktx2", ColourImage, ["levelCount is 0, asking the loader to generate levels"])
  , ("refuse-orientation.ktx2", ColourImage, ["\"KTXorientation\" is \"ru\"; only \"rd\" is accepted"])
  , ("refuse-swizzle.ktx2", ColourImage, ["\"KTXswizzle\" is \"bgra\"; only \"rgba\" is accepted"])
  , ( "bc7-srgb-straight-translucent.ktx2"
    , ColourImage
    , ["a colour BC7 file without the premultiplied-alpha flag must be opaque in every texel of every level; level 0's texel (0, 0) has alpha 128"]
    )
  , -- Level 0 is opaque; level 2's texel (1, 1) is not.
    ("bc7-srgb-straight-deep-translucent.ktx2", ColourImage, ["must be opaque in every texel of every level; level 2's texel (1, 1) has alpha 0"])
  , ("refuse-data-premultiplied.ktx2", DataImage, ["a data texture must not carry the data format descriptor's premultiplied-alpha flag"])
  , -- Requirement 3: the kind and the format agree.
    ("rgba8-linear.ktx2", ColourImage, ["a colour read needs an _SRGB format; this file's vkFormat is R8G8B8A8_UNORM"])
  , ("bc7-linear.ktx2", ColourImage, ["a colour read needs an _SRGB format; this file's vkFormat is BC7_UNORM_BLOCK"])
  , ("rgba8-srgb.ktx2", DataImage, ["a data read needs a _UNORM format; this file's vkFormat is R8G8B8A8_SRGB"])
  , ("bc7-srgb-premultiplied.ktx2", DataImage, ["a data read needs a _UNORM format; this file's vkFormat is BC7_SRGB_BLOCK"])
  , -- Requirement 4: structure.
    ("refuse-not-ktx2.ktx2", ColourImage, ["the bytes do not begin with the KTX2 identifier"])
  , ("refuse-ktx1.ktx2", ColourImage, ["this is a KTX 1 file; only KTX2 is read"])
  , ("refuse-truncated-header.ktx2", ColourImage, ["the 80-byte header and index lie outside the 60-byte file"])
  , ("refuse-level-index-outside.ktx2", ColourImage, ["the level index of 3 entries ends at byte 152, outside the 120-byte file"])
  , ("refuse-dfd-outside.ktx2", ColourImage, ["the data format descriptor (bytes 252 to 344) lies outside the 252-byte file"])
  , ("refuse-kvd-outside.ktx2", ColourImage, ["the key/value data (bytes 196 to 448) lies outside the 252-byte file"])
  , ("refuse-level-outside.ktx2", ColourImage, ["level 0 (bytes 252 to 268) lies outside the 252-byte file"])
  , ("refuse-level-length.ktx2", ColourImage, ["level 0 (2 × 2) of R8G8B8A8_SRGB needs 16 bytes; the file stores 12"])
  , ("refuse-level-count-chain.ktx2", ColourImage, ["levelCount is 3, more than the 2 levels of a full chain at 2 × 2"])
  , -- The review's additions.
    ("refuse-zero-width.ktx2", ColourImage, ["pixelWidth is 0; a texture needs a positive width"])
  , ("refuse-type-size.ktx2", ColourImage, ["typeSize must be 1 for R8G8B8A8_SRGB; this file's is 4"])
  , ("refuse-uncompressed-length.ktx2", ColourImage, ["level 0's byteLength 16 differs from its uncompressedByteLength 32"])
  , ("refuse-dfd-total.ktx2", ColourImage, ["the data format descriptor's dfdTotalSize 96 differs from its dfdByteLength 92"])
  , ("refuse-dfd-block-size.ktx2", ColourImage, ["a descriptor block at descriptor byte 4 of 92 bytes runs past the descriptor's end"])
  , ("refuse-dfd-not-basic.ktx2", ColourImage, ["the data format descriptor's first block is not a basic descriptor block"])
  , ("refuse-dfd-short-basic.ktx2", ColourImage, ["the basic descriptor block is 16 bytes, too short for its 24 bytes of fields"])
  , ("refuse-dfd-samples.ktx2", ColourImage, ["the basic descriptor block is 32 bytes, not 24 bytes and whole 16-byte samples"])
  , ("refuse-dfd-empty.ktx2", ColourImage, ["the file has no data format descriptor"])
  , ("refuse-kv-length.ktx2", ColourImage, ["the key/value entry at key/value byte 0 of 42 bytes, with its padding, runs past the key/value data's end"])
  , ("refuse-kv-no-nul.ktx2", ColourImage, ["the key/value entry at key/value byte 0 has no NUL-terminated key"])
  , ("refuse-kv-short.ktx2", ColourImage, ["the key/value entry at key/value byte 0 is 1 bytes, shorter than a one-byte key and its NUL"])
  , ("refuse-kv-empty-key.ktx2", ColourImage, ["the key/value entry at key/value byte 0 has an empty key"])
  , ("refuse-kv-padding.ktx2", ColourImage, ["the key/value entry at key/value byte 0 has nonzero padding"])
  , ("refuse-kv-duplicate.ktx2", ColourImage, ["the key \"KTXwriter\" appears more than once"])
  , ("refuse-kv-unterminated.ktx2", ColourImage, ["the \"KTXorientation\" value is not a NUL-terminated string"])
  , ("refuse-overlap-levels.ktx2", ColourImage, ["level 0 (bytes ", " overlaps level 1 (bytes "])
  , ("refuse-overlap-header.ktx2", ColourImage, ["the header and level index (bytes 0 to 104) overlaps the data format descriptor (bytes 96 to 188)"])
  , -- Fields near their type's maximum are compared exactly, never wrapped.
    ("refuse-overflow-level-offset.ktx2", ColourImage, ["level 0 (bytes 18446744073709551608 to 18446744073709551624) lies outside the 252-byte file"])
  , ("refuse-overflow-level-length.ktx2", ColourImage, ["level 0 (bytes 236 to 18446744073709551851) lies outside the 252-byte file"])
  , ("refuse-overflow-extent.ktx2", ColourImage, ["level 0 (4294967295 × 4294967295) of R8G8B8A8_SRGB needs 73786976260478468100 bytes; the file stores 16"])
  , ("refuse-overflow-dfd.ktx2", ColourImage, ["the data format descriptor (bytes 4294967280 to 8589934560) lies outside the 252-byte file"])
  , ( "refuse-overflow-kv-entry.ktx2"
    , ColourImage
    , ["the key/value entry at key/value byte 0 of 4294967295 bytes, with its padding, runs past the key/value data's end"]
    )
  ]

fixtureNames ∷ [String]
fixtureNames =
  uniq ([name | Rgba8Case name _ _ _ _ _ ← rgba8Cases] <> [name | Bc7Case name _ _ _ _ _ ← bc7Cases] <> [name | (name, _, _) ← refusals])
  where
    uniq = foldr (\name rest → if name `elem` rest then rest else name : rest) []

-- | Read a fixture, failing the example on a refusal. The result is
-- evaluated completely, so nothing deferred inside it can fail later.
readFixture ∷ ImageKind → FilePath → IO Ktx2Image
readFixture kind name = do
  bytes ← fixtureBytes name
  evaluate (force (decodeKtx2 kind (fixtureAsset name) bytes)) >>= \case
    Right image → pure image
    Left refusal → failWith ("refused: " <> show refusal)
  where
    failWith message = expectationFailure message >> fail message

packTexels ∷ [Texel] → ByteString
packTexels = ByteString.pack . concatMap (\(r, g, b, a) → [r, g, b, a])

hexBytes ∷ String → ByteString
hexBytes = ByteString.pack . pairs
  where
    pairs (high : low : rest) = fromIntegral (16 * digitToInt high + digitToInt low) : pairs rest
    pairs _ = []

-- | The manifest's (fixture, producer) pairs.
parseManifest ∷ ByteString → [(String, String)]
parseManifest bytes =
  [ (Char8.unpack name, Char8.unpack producer)
  | line ← Char8.lines bytes
  , not (Char8.isPrefixOf "#" line)
  , name : producer : _ ← [Char8.split '\t' line]
  ]
