-- | BC7 images: their shape checks, the software decoder, the cutout mark and
-- the fallback for devices without BC7.
--
-- Expected texels come from @test/fixtures/bc7-reference.txt@, which
-- @make_bc7_fixtures.py@ writes with an independent reference decoder,
-- Pillow 12.2.0's BCn decoder; the file's header names it. None comes from
-- the decoder under test. Two expectations are stated here instead: the
-- sprites sample's mode-6 block and its oracle, restated from
-- @samples/sprites@, and a block with no valid mode, whose texels the BC7
-- format defines as all channels zero.
module Test.Asset.Image.Bc7 (spec) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Bits (countTrailingZeros, shiftR, (.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.Char (digitToInt, intToDigit, isHexDigit)
import Data.List (isPrefixOf, nub)
import qualified Data.Text as Text
import Data.Word (Word32, Word8)
import Hetoimasia.Asset (Asset (..), AssetId (..), AssetRefusal (..), Provenance (..))
import Hetoimasia.Asset.Image (DecodedImage (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Bc7
import Test.Asset.Image.Support (fixtureBytes)
import Test.Hspec (Expectation, Spec, describe, expectationFailure, it, runIO, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "Bc7" $ do
  reference ← runIO (fixtureBytes "bc7-reference.txt" >>= either fail pure . parseReference)

  describe "the reference fixture" $ do
    it "names its reference decoder and version" $
      referenceDecoder reference `shouldBe` "Pillow 12.2.0 (PIL BCn decoder, src/libImaging/BcnDecode.c)"
    it "covers every mode, every partition, every rotation and both index selections" $ do
      let headers = map (blockHeader . fst . snd) (referenceBlocks reference)
      [m | m ← [0 .. 7], any ((== m) . headerMode) headers] `shouldBe` [0 .. 7]
      forM_ [(0, 16), (1, 64), (2, 64), (3, 64), (7, 64)] $ \(m, count) →
        [p | p ← [0 .. count - 1], any (\h → headerMode h == m && headerPartition h == p) headers] `shouldBe` [0 .. count - 1]
      forM_ [4, 5] $ \m →
        [r | r ← [0 .. 3], any (\h → headerMode h == m && headerRotation h == r) headers] `shouldBe` [0 .. 3]
      [s | s ← [0, 1], any (\h → headerMode h == 4 && headerSelection h == s) headers] `shouldBe` [0, 1]

  describe "every reference block decodes exactly to the reference's texels" $
    forM_ (referenceBlocks reference) $ \(name, (block, expected)) →
      it name $ forM_ [minBound .. maxBound] $ \format → do
        image ← construct (memory name) format 4 4 [block]
        hex (level0 (decodeBc7 image)) `shouldBe` hex expected

  it "decodes the sprites sample's mode-6 block to its oracle" $ do
    image ← construct (memory "sprites bc7Block") Bc7Linear 4 4 [spritesBlock]
    texels (level0 (decodeBc7 image)) `shouldBe` concat spritesDecoded

  it "decodes a block with no valid mode to four zero channels in every texel" $
    forM_ [ByteString.replicate 16 0, ByteString.pack (0 : [0x11, 0x22 .. 0xff])] $ \block → do
      ByteString.length block `shouldBe` 16
      image ← construct (memory "no valid mode") Bc7Srgb 4 4 [block]
      level0 (decodeBc7 image) `shouldBe` ByteString.replicate 64 0
      bc7BinaryAlpha image `shouldBe` True

  describe "extents" $ do
    let chain = map (named (referenceLevels reference)) ["chain9x6-level0", "chain9x6-level1", "chain9x6-level2", "chain9x6-level3"]
    it "decodes a 9 × 6 image's full chain, each level cropped and placed as the reference places it" $ do
      map (\(w, h, _, _) → (w, h)) chain `shouldBe` [(9, 6), (4, 3), (2, 1), (1, 1)]
      image ← construct (memory "chain9x6") Bc7Linear 9 6 [blocks | (_, _, blocks, _) ← chain]
      let decoded = decodeBc7 image
      (decodedWidth decoded, decodedHeight decoded) `shouldBe` (9, 6)
      map hex (decodedLevels decoded) `shouldBe` [hex expected | (_, _, _, expected) ← chain]
    it "places distinguishable blocks across block rows and columns" $ do
      -- The reference's 9 × 6 level is its six blocks' 4 × 4 texels, cropped
      -- to columns 0–8 and rows 0–5. Each texel of the decoded level must be
      -- the texel its block gives when decoded alone.
      let (_, _, blocks, expected) = named (referenceLevels reference) "chain9x6-level0"
          block n = ByteString.take 16 (ByteString.drop (16 * n) blocks)
      alone ← mapM (\n → level0 . decodeBc7 <$> construct (memory "one block") Bc7Linear 4 4 [block n]) [0 .. 5]
      length (nub alone) `shouldBe` 6
      image ← construct (memory "chain9x6 level 0") Bc7Linear 9 6 [blocks]
      let decoded = level0 (decodeBc7 image)
      forM_ [(x, y) | y ← [0 .. 5], x ← [0 .. 8]] $ \(x, y) → do
        let n = (y `div` 4) * 3 + x `div` 4
        texelAt 9 x y decoded `shouldBe` texelAt 4 (x `mod` 4) (y `mod` 4) (alone !! n)
        texelAt 9 x y expected `shouldBe` texelAt 4 (x `mod` 4) (y `mod` 4) (alone !! n)

  it "maps each colour space to its RGBA8 format, with texels unchanged" $ do
    let (block, expected) = named (referenceBlocks reference) "mode5-rotation2"
    srgb ← construct (memory "srgb") Bc7Srgb 4 4 [block]
    linear ← construct (memory "linear") Bc7Linear 4 4 [block]
    decodedFormat (decodeBc7 srgb) `shouldBe` TexelRgba8Srgb
    decodedFormat (decodeBc7 linear) `shouldBe` TexelRgba8Linear
    decodedFormat (bc7DecodedImage srgb) `shouldBe` TexelBc7Srgb
    decodedFormat (bc7DecodedImage linear) `shouldBe` TexelBc7Linear
    level0 (decodeBc7 srgb) `shouldBe` expected
    level0 (decodeBc7 linear) `shouldBe` expected

  describe "the cutout mark" $ do
    let block name = fst (named (referenceBlocks reference) name)
        alphas name = alphaChannel (snd (named (referenceBlocks reference) name))
        marked name format w h levels expected = do
          image ← construct (memory name) format w h levels
          bc7BinaryAlpha image `shouldBe` expected
          decodedBinaryAlpha (bc7DecodedImage image) `shouldBe` expected
          decodedBinaryAlpha (decodeBc7 image) `shouldBe` expected
          forM_ [minBound .. maxBound] $ \support →
            decodedBinaryAlpha (fallbackImage (bc7Fallback support image)) `shouldBe` expected
    it "is true for binary alpha" $ do
      alphas "alpha-binary" `shouldSatisfy` all binary
      marked "alpha-binary" Bc7Srgb 4 4 [block "alpha-binary"] True
    it "is false for a block holding an intermediate alpha" $ do
      alphas "alpha-intermediate" `shouldSatisfy` (not . all binary)
      marked "alpha-intermediate" Bc7Linear 4 4 [block "alpha-intermediate"] False
    it "ignores intermediate alpha in texels the extent discards" $ do
      let edgeAlphas = alphas "alpha-intermediate-edges"
      [edgeAlphas !! (4 * y + x) | y ← [0 .. 2], x ← [0 .. 2]] `shouldSatisfy` all binary
      edgeAlphas `shouldSatisfy` (not . all binary)
      marked "alpha-intermediate-edges" Bc7Srgb 3 3 [block "alpha-intermediate-edges"] True
      marked "alpha-intermediate-edges" Bc7Srgb 4 4 [block "alpha-intermediate-edges"] False
    it "ignores intermediate alpha in a level other than level 0" $ do
      [alphas "alpha-intermediate" !! (4 * y + x) | y ← [0, 1], x ← [0, 1]] `shouldSatisfy` (not . all binary)
      marked "mip" Bc7Linear 4 4 [block "alpha-binary", block "alpha-intermediate", block "alpha-intermediate"] True

  describe "refusals, each naming the asset" $ do
    let block = ByteString.replicate 16 0x40
    it "refuses a zero width or height" $ do
      refuses 0 4 [block]
      refuses 4 0 [block]
      refuses 0 0 []
    it "refuses an empty chain" $
      refuses 4 4 []
    it "refuses more levels than the extent's full chain" $ do
      refuses 1 1 [block, block]
      refuses 9 6 (replicate 5 (ByteString.replicate 96 0x40))
    it "refuses a wrong byte count at any level" $ do
      refuses 4 4 [ByteString.take 15 block]
      refuses 4 4 [block <> block]
      refuses 9 6 [ByteString.replicate 96 0x40, ByteString.take 15 block]
      refuses 9 6 [ByteString.replicate 95 0x40]
    it "computes byte counts without wraparound" $ do
      -- ceil (w / 4) × ceil (h / 4) × 16 is 2⁶⁴ here, zero in 64-bit
      -- arithmetic.
      refuses maxBound maxBound [ByteString.empty]
      refuses 0x40000000 0x40000000 [ByteString.empty]
    it "accepts a valid partial chain" $ do
      image ← construct (memory "partial") Bc7Srgb 9 6 [ByteString.replicate 96 0x40, block]
      (bc7Width image, bc7Height image, length (bc7Levels image)) `shouldBe` (9, 6, 2)
      map ByteString.length (decodedLevels (decodeBc7 image)) `shouldBe` [4 * 9 * 6, 4 * 4 * 3]

  describe "the fallback step" $ do
    let (block, expected) = named (referenceBlocks reference) "mode7-partition17"
    it "returns the BC7 image unchanged, with no software decode, when the device takes BC7" $
      forM_ [minBound .. maxBound] $ \format → do
        image ← construct (memory "kept") format 4 4 [block]
        let result = bc7Fallback DeviceTakesBc7 image
        result `shouldBe` KeptBc7 image
        fallbackSoftwareDecode result `shouldBe` Nothing
        fallbackImage result `shouldBe` bc7DecodedImage image
        decodedLevels (fallbackImage result) `shouldBe` [block]
    it "returns the decoded RGBA8 image, stating the software decode with the asset and the BC7 format, when it does not" $
      forM_ [(Bc7Srgb, TexelRgba8Srgb), (Bc7Linear, TexelRgba8Linear)] $ \(format, rgba8) → do
        let asset = memory "decoded"
        image ← construct asset format 4 4 [block]
        let result = bc7Fallback DeviceLacksBc7 image
        fallbackSoftwareDecode result `shouldBe` Just (SoftwareDecode asset format)
        case result of
          DecodedInSoftware decode decoded → do
            decode `shouldBe` SoftwareDecode asset format
            decoded `shouldBe` decodeBc7 image
          KeptBc7 _ → expectationFailure "the device lacks BC7, and the image was kept"
        decodedFormat (fallbackImage result) `shouldBe` rgba8
        decodedLevels (fallbackImage result) `shouldBe` [expected]
  where
    memory name = Asset (AssetId (Text.pack name)) (FromMemory "Test.Asset.Image.Bc7")

-- | Construct a BC7 image the example expects to be valid, fully evaluated.
construct ∷ Asset → Bc7Format → Word32 → Word32 → [ByteString] → IO Bc7Image
construct asset format width height levels =
  evaluate (force (bc7Image asset format width height levels)) >>= \case
    Right image → pure image
    Left refusal → do
      expectationFailure ("refused: " <> Text.unpack (refusalReason refusal))
      fail "unreachable"

-- | Both formats refuse the shape, naming the asset and giving a reason.
refuses ∷ Word32 → Word32 → [ByteString] → Expectation
refuses width height levels =
  forM_ [minBound .. maxBound] $ \format →
    evaluate (force (bc7Image asset format width height levels)) >>= \case
      Left refusal → do
        refusedAsset refusal `shouldBe` asset
        refusalReason refusal `shouldSatisfy` (not . Text.null)
      Right image → expectationFailure ("accepted " <> show (bc7Width image, bc7Height image, map ByteString.length (bc7Levels image)))
  where
    asset = Asset (AssetId "refused") (FromMemory "Test.Asset.Image.Bc7")

-- | The sprites sample's committed block (@bc7Block@ in
-- @samples/sprites/renderer/src/Hetoimasia/Sample/Sprites/Fixtures.hs@).
spritesBlock ∷ ByteString
spritesBlock = ByteString.pack [0xc0, 0x3f, 0x00, 0x00, 0x00, 0xfc, 0xff, 0xff, 0x01, 0xff, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff]

-- | Its oracle, @bc7Decoded@: the first endpoint in the left two columns, the
-- second in the right two, in every row.
spritesDecoded ∷ [[(Word8, Word8, Word8, Word8)]]
spritesDecoded = replicate 4 [left, left, right, right]
  where
    left = (255, 1, 1, 255)
    right = (1, 1, 255, 255)

-- ---------------------------------------------------------------------------
-- The reference fixture

data Reference = Reference
  { referenceDecoder ∷ String
  , referenceBlocks ∷ [(String, (ByteString, ByteString))]
  , referenceLevels ∷ [(String, (Int, Int, ByteString, ByteString))]
  }

-- | The named entry; the suite's own names are always present.
named ∷ [(String, a)] → String → a
named entries name = maybe (error ("the reference has no " <> name)) id (lookup name entries)

parseReference ∷ ByteString → Either String Reference
parseReference = fmap reverseEntries . foldl step (Right (Reference "" [] [])) . lines . Char8.unpack
  where
    step acc line = acc >>= \r → case words line of
      _ | Just decoder ← stripPrefix "# reference decoder: " line → Right r {referenceDecoder = decoder}
      ("#" : _) → Right r
      ["block", name, block, texels'] → do
        b ← unhex 16 block
        t ← unhex 64 texels'
        Right r {referenceBlocks = (name, (b, t)) : referenceBlocks r}
      ["level", name, w, h, blocks, texels'] → do
        let (width, height) = (read w, read h)
        b ← unhex (16 * ((width + 3) `div` 4) * ((height + 3) `div` 4)) blocks
        t ← unhex (4 * width * height) texels'
        Right r {referenceLevels = (name, (width, height, b, t)) : referenceLevels r}
      [] → Right r
      _ → Left ("an unreadable reference line: " <> line)
    stripPrefix prefix line = if prefix `isPrefixOf` line then Just (drop (length prefix) line) else Nothing
    reverseEntries r = r {referenceBlocks = reverse (referenceBlocks r), referenceLevels = reverse (referenceLevels r)}
    unhex size text
      | length text == 2 * size && all isHexDigit text = Right (ByteString.pack (pairs text))
      | otherwise = Left ("a reference field is not " <> show size <> " bytes of hex: " <> text)
    pairs (a : b : rest) = fromIntegral (16 * digitToInt a + digitToInt b) : pairs rest
    pairs _ = []

data Header = Header {headerMode, headerPartition, headerRotation, headerSelection ∷ Int}

-- | A block's mode and the header fields after it, read independently of
-- the decoder: partition bits per mode 0–7 are 4, 6, 6, 6, 0, 0, 0, 6; modes
-- 4 and 5 have two rotation bits, and mode 4 one index-selection bit.
blockHeader ∷ ByteString → Header
blockHeader block = Header mode (field (mode + 1) partitionBits) (field (mode + 1) rotationBits) (field (mode + 3) selectionBits)
  where
    low = foldr (\b acc → acc * 256 + fromIntegral b) 0 (ByteString.unpack (ByteString.take 2 block)) ∷ Int
    mode = countTrailingZeros (fromIntegral (ByteString.head block) ∷ Word8)
    partitionBits = [4, 6, 6, 6, 0, 0, 0, 6, 0] !! mode
    rotationBits = if mode == 4 || mode == 5 then 2 else 0
    selectionBits = if mode == 4 then 1 else 0
    field ∷ Int → Int → Int
    field at width = (low `shiftR` at) .&. (2 ^ width - 1)

-- ---------------------------------------------------------------------------
-- Texels

level0 ∷ DecodedImage → ByteString
level0 image = case decodedLevels image of
  level : _ → level
  [] → ByteString.empty

hex ∷ ByteString → String
hex = concatMap (\b → [intToDigit (fromIntegral (b `div` 16)), intToDigit (fromIntegral (b `mod` 16))]) . ByteString.unpack

texels ∷ ByteString → [(Word8, Word8, Word8, Word8)]
texels bytes = case ByteString.unpack bytes of
  r : g : b : a : _ → (r, g, b, a) : texels (ByteString.drop 4 bytes)
  _ → []

texelAt ∷ Int → Int → Int → ByteString → (Word8, Word8, Word8, Word8)
texelAt width x y bytes = let at = 4 * (y * width + x) in (ByteString.index bytes at, ByteString.index bytes (at + 1), ByteString.index bytes (at + 2), ByteString.index bytes (at + 3))

alphaChannel ∷ ByteString → [Word8]
alphaChannel = map (\(_, _, _, a) → a) . texels

binary ∷ Word8 → Bool
binary a = a == 0 || a == 255
