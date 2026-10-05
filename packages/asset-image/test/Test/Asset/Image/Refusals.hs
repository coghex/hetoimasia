-- | Bytes the PNG decoder refuses, each naming the asset.
--
-- Every result is evaluated completely ('decodeFully') before it is
-- inspected, so a failure deferred inside a successful-looking result would
-- surface here as an escaped exception and fail the example.
--
-- Where a refusal depends on what is wrong with a fixture, the fixture's
-- defect is established independently first — with JuicyPixels' own chunk
-- reader and zlib — so a refusal for some other reason cannot pass for it.
module Test.Asset.Image.Refusals (spec) where

import Codec.Compression.Zlib (decompress)
import Codec.Compression.Zlib.Internal (DecompressError (DataFormatError))
import Codec.Picture.Png (decodePng)
import Codec.Picture.Png.Internal.Type (PngRawChunk (..), PngRawImage (..), iDATSignature)
import Control.Exception (evaluate, try)
import Data.Binary (decodeOrFail)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Either (isLeft)
import qualified Data.Text as Text
import Hetoimasia.Asset (Asset (..), AssetId (..), AssetRefusal (..), Provenance (..))
import Hetoimasia.Asset.Image (ImageKind (..))
import Test.Asset.Image.Support (decodeFully, fixtureAsset, fixtureBytes)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Refusals" $ do
  it "refuses empty bytes" $
    refuses (memory "empty") ByteString.empty

  it "refuses bytes that are not a PNG" $ do
    refuses (memory "text") "this is not a PNG image at all"
    refuses (memory "GIF") "GIF89a\1\0\1\0\0\0\0;"
    refuses (memory "one byte") "\137"

  it "refuses every truncation of a PNG, from inside its signature to inside IEND's CRC" $ do
    -- interlaced-rgba8.png spreads its compressed data over three IDAT
    -- chunks, so some cuts fall between complete chunks mid-stream.
    whole ← fixtureBytes "interlaced-rgba8.png"
    mapM_
      (\n → refuses (memory ("interlaced-rgba8.png cut to " <> Text.pack (show n) <> " bytes")) (ByteString.take n whole))
      [1 .. ByteString.length whole - 1]

  it "refuses a PNG whose compressed stream is corrupt, in decompression" $ do
    bytes ← fixtureBytes "corrupt-stream.png"
    stream ← intactFraming bytes
    inflated ← try (evaluate (Lazy.length (decompress stream)))
    case inflated of
      Left (DataFormatError _) → pure ()
      other → expectationFailure ("the fixture's stream should fail to inflate with a format error, and gave " <> show other)
    refusesFixture "corrupt-stream.png"

  it "refuses a PNG whose stream inflates to fewer bytes than its header needs" $ do
    bytes ← fixtureBytes "short-stream.png"
    stream ← intactFraming bytes
    -- Two rows of a 2-pixel RGB image need 2 × (1 + 6) bytes.
    Lazy.length (decompress stream) `shouldSatisfy` (< 14)
    refusesFixture "short-stream.png"

  it "refuses a PNG that fails a chunk CRC" $ do
    bytes ← fixtureBytes "rgb8.png"
    -- Byte 41 lies inside the IDAT chunk's data.
    refuses (memory "rgb8.png with a flipped IDAT byte") (flipByte 41 bytes)
    -- Byte 30 lies inside the IHDR chunk's CRC, which JuicyPixels does not check.
    refuses (memory "rgb8.png with a flipped IHDR CRC byte") (flipByte 30 bytes)

  describe "PNGs that cannot be decoded" $ do
    it "refuses an indexed PNG without a palette, as JuicyPixels does" $ do
      bytes ← fixtureBytes "no-palette.png"
      _ ← intactFraming bytes
      isLeft (decodePng bytes) `shouldBe` True
      refusesFixture "no-palette.png"
    it "refuses a palette index outside the palette" $ do
      _ ← fixtureBytes "palette-index-out-of-range.png" >>= intactFraming
      refusesFixture "palette-index-out-of-range.png"
    it "refuses a bit depth its colour type does not allow" $
      refusesFixture "rgb-depth4.png"
    it "refuses a zero width" $
      refusesFixture "zero-width.png"
  where
    memory name = Asset (AssetId name) (FromMemory "Test.Asset.Image.Refusals")
    refusesFixture name = fixtureBytes name >>= refuses (fixtureAsset name)

-- | Both kinds refuse the bytes, naming the asset and giving a reason, and
-- return nothing else.
refuses ∷ Asset → ByteString → Expectation
refuses asset bytes =
  mapM_
    ( \kind →
        decodeFully kind asset bytes >>= \case
          Left refusal → do
            refusedAsset refusal `shouldBe` asset
            refusalReason refusal `shouldSatisfy` (not . Text.null)
          Right image → expectationFailure (show kind <> " decoded " <> show (Text.unpack (case assetId asset of AssetId name → name)) <> " to " <> show image)
    )
    [ColourImage, DataImage]

-- | The fixture's chunk framing is sound — signature, lengths, every chunk's
-- CRC, and IEND — as JuicyPixels' own chunk reader judges it; its
-- concatenated IDAT data.
intactFraming ∷ ByteString → IO Lazy.ByteString
intactFraming bytes = case decodeOrFail (Lazy.fromStrict bytes) of
  Left (_, _, message) → do
    expectationFailure ("the fixture's framing is not intact: " <> message)
    pure Lazy.empty
  Right (_, _, raw) → pure (Lazy.concat [chunkData c | c ← chunks raw, chunkType c == iDATSignature])

flipByte ∷ Int → ByteString → ByteString
flipByte at bytes = ByteString.take at bytes <> ByteString.singleton (ByteString.index bytes at + 1) <> ByteString.drop (at + 1) bytes
