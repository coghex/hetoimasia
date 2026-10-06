-- | KTX2 files carrying RGBA8 or BC7 levels, read by a pure function.
--
-- 'decodeKtx2' reads a KTX2 file's bytes, as the caller's stated kind, into
-- an RGBA8 'DecodedImage' or a 'Bc7Image', with the file's own levels in the
-- upload endpoint's layout, level 0 first; or refuses them, naming the asset
-- and the reason. Nothing is generated: the file brings every level.
--
-- A file is accepted only inside this profile (asset design D-9):
--
-- * @vkFormat@ is @R8G8B8A8_SRGB@, @R8G8B8A8_UNORM@, @BC7_SRGB_BLOCK@ or
--   @BC7_UNORM_BLOCK@, with @typeSize@ 1, and the data format descriptor's
--   transfer function is sRGB for the @_SRGB@ formats and linear otherwise;
-- * a colour read takes an @_SRGB@ format and a data read a @_UNORM@ one;
-- * the texture is two-dimensional, with one layer and one face: a positive
--   width and height, depth 0, a layer count of 0 or 1, and one face;
-- * nothing is supercompressed, and between one level and the extent's full
--   chain is stored;
-- * @KTXorientation@ is absent or @rd@, and @KTXswizzle@ absent or @rgba@;
-- * a data file does not carry the premultiplied-alpha flag, and a colour
--   BC7 file without it is opaque in every texel of every level.
--
-- Only those descriptor fields and key/value entries are interpreted; the
-- colour model, the primaries and every other entry are not. The whole file
-- is still checked structurally: every section and level lies inside the
-- file, occupied ranges do not overlap, the descriptor's and the key/value
-- data's framing is consistent, and each level holds exactly its format's
-- bytes at its extent. All offset arithmetic is exact, so a field near its
-- type's maximum is refused, never wrapped.
--
-- Colour RGBA8 without the premultiplied-alpha flag is premultiplied in
-- linear light at load, every level, as a PNG is; with the flag, and for
-- data, texels are returned as stored. BC7 blocks are always returned as
-- stored: BC7 is decoded only to check a straight-alpha colour file's
-- opacity and, through 'bc7Image', to compute level 0's cutout mark.
module Hetoimasia.Asset.Image.Ktx2
  ( Ktx2Image (..)
  , ktx2DecodedImage
  , ktx2Decoder
  , decodeKtx2
  )
where

import Control.DeepSeq (NFData (rnf))
import Control.Monad (forM, forM_, unless, when, zipWithM_)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.List (find, sortOn)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Encoding.Error as Text
import Data.Word (Word32, Word64, Word8)
import Hetoimasia.Asset (Asset, AssetRefusal (..), Decoder (..))
import Hetoimasia.Asset.Image (DecodedImage (..), ImageKind (..), TexelFormat (..))
import Hetoimasia.Asset.Image.Bc7 (Bc7Format (..), Bc7Image, bc7DecodedImage, bc7Image, decodeBc7)
import Hetoimasia.Asset.Image.Internal.Premultiply (premultiplyRgba8)
import Hetoimasia.Asset.Image.Internal.Texels (binaryAlpha)

-- | What a KTX2 file held, in the types the PNG and BC7 decoders return.
data Ktx2Image
  = -- | RGBA8 levels, 'TexelRgba8Srgb' (premultiplied in linear light) or
    -- 'TexelRgba8Linear'.
    Ktx2Rgba8 !DecodedImage
  | -- | BC7 levels exactly as the file stores them. A caller whose device
    -- lacks BC7 passes it to 'Hetoimasia.Asset.Image.Bc7.bc7Fallback'.
    Ktx2Bc7 !Bc7Image
  deriving (Eq, Show)

instance NFData Ktx2Image where
  rnf = \case
    Ktx2Rgba8 image → rnf image
    Ktx2Bc7 image → rnf image

-- | The image as a decoded image the upload endpoint takes, on a device that
-- takes BC7.
ktx2DecodedImage ∷ Ktx2Image → DecodedImage
ktx2DecodedImage = \case
  Ktx2Rgba8 image → image
  Ktx2Bc7 image → bc7DecodedImage image

-- | The KTX2 codec for one kind of image.
ktx2Decoder ∷ ImageKind → Decoder Ktx2Image
ktx2Decoder kind = Decoder (decodeKtx2 kind)

-- | Read a KTX2 file's bytes as the given kind, or refuse them naming the
-- asset. The same bytes and kind always give the same result, and no part of
-- an image accompanies a refusal.
decodeKtx2 ∷ ImageKind → Asset → ByteString → Either AssetRefusal Ktx2Image
decodeKtx2 kind asset bytes = either (Left . AssetRefusal asset) Right $ do
  header ← readHeader bytes
  format ← checkProfile kind header
  let width = pixelWidth header
      height = pixelHeight header
      count = fromIntegral (levelCount header) ∷ Int
  entries ← readLevelIndex bytes count
  index ← readIndex bytes
  sections ← checkSections bytes index
  levels ← forM (zip [0 ..] entries) $ \(level, entry) → checkLevel bytes format width height level entry
  checkOverlaps $
    ("the header and level index", 0, headerBytes + 24 * toInteger count)
      : sections
      <> [("level " <> tshow level, offset, size) | (level, (offset, size)) ← zip [0 ∷ Int ..] (map levelRange entries)]
  (transfer, premultiplied) ← readDescriptor (sectionBytes bytes (dfdOffset index) (dfdLength index))
  checkTransfer format transfer
  readKeyValues (sectionBytes bytes (kvdOffset index) (kvdLength index)) >>= checkKeyValues
  when (kind == DataImage && premultiplied) $
    Left "a data texture must not carry the data format descriptor's premultiplied-alpha flag; this one does"
  case format of
    Rgba8 _ → do
      let stored = map ByteString.copy levels
          returned = if kind == ColourImage && not premultiplied then map premultiplyRgba8 stored else stored
      base ← case returned of
        first : _ → Right first
        [] → Left "the file stores no level"
      Right . Ktx2Rgba8 $
        DecodedImage
          { decodedFormat = if kind == ColourImage then TexelRgba8Srgb else TexelRgba8Linear
          , decodedWidth = width
          , decodedHeight = height
          , decodedLevels = returned
          , decodedBinaryAlpha = binaryAlpha base
          }
    Bc7 _ → do
      image ←
        either (Left . refusalReason) Right $
          bc7Image asset (if kind == ColourImage then Bc7Srgb else Bc7Linear) width height (map ByteString.copy levels)
      when (kind == ColourImage && not premultiplied) $
        zipWithM_ opaqueLevel [0 ∷ Int ..] (zip (levelExtents width height) (decodedLevels (decodeBc7 image)))
      Right (Ktx2Bc7 image)

-- | The four formats the profile accepts, by their colour space.
data Format
  = Rgba8 !Space
  | Bc7 !Space
  deriving (Eq, Show)

data Space = Srgb | Unorm
  deriving (Eq, Show)

formatName ∷ Format → Text
formatName = \case
  Rgba8 Srgb → "R8G8B8A8_SRGB"
  Rgba8 Unorm → "R8G8B8A8_UNORM"
  Bc7 Srgb → "BC7_SRGB_BLOCK"
  Bc7 Unorm → "BC7_UNORM_BLOCK"

formatSpace ∷ Format → Space
formatSpace = \case
  Rgba8 space → space
  Bc7 space → space

-- | The Vulkan format numbers the profile accepts.
vkFormats ∷ [(Word32, Format)]
vkFormats = [(43, Rgba8 Srgb), (37, Rgba8 Unorm), (146, Bc7 Srgb), (145, Bc7 Unorm)]

-- | The header's fields, in file order.
data Header = Header
  { vkFormat ∷ !Word32
  , typeSize ∷ !Word32
  , pixelWidth ∷ !Word32
  , pixelHeight ∷ !Word32
  , pixelDepth ∷ !Word32
  , layerCount ∷ !Word32
  , faceCount ∷ !Word32
  , levelCount ∷ !Word32
  , supercompression ∷ !Word32
  }

-- | The index's section ranges.
data Index = Index
  { dfdOffset ∷ !Word32
  , dfdLength ∷ !Word32
  , kvdOffset ∷ !Word32
  , kvdLength ∷ !Word32
  , sgdOffset ∷ !Word64
  , sgdLength ∷ !Word64
  }

-- | One level index entry: byte offset, byte length, uncompressed length.
data LevelEntry = LevelEntry !Word64 !Word64 !Word64

levelRange ∷ LevelEntry → (Integer, Integer)
levelRange (LevelEntry offset size _) = (toInteger offset, toInteger size)

identifier, ktx1Identifier ∷ ByteString
identifier = ByteString.pack [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]
ktx1Identifier = ByteString.pack [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A]

-- | The identifier, header and index together; the level index follows.
headerBytes ∷ Integer
headerBytes = 80

readHeader ∷ ByteString → Either Text Header
readHeader bytes = do
  unless (identifier `ByteString.isPrefixOf` bytes) $
    Left $
      if ktx1Identifier `ByteString.isPrefixOf` bytes
        then "this is a KTX 1 file; only KTX2 is read"
        else "the bytes do not begin with the KTX2 identifier"
  unless (fileLength bytes >= headerBytes) $
    Left ("the 80-byte header and index lie outside the " <> tshow (fileLength bytes) <> "-byte file")
  let at n = word32 bytes (12 + 4 * n)
  Header <$> at 0 <*> at 1 <*> at 2 <*> at 3 <*> at 4 <*> at 5 <*> at 6 <*> at 7 <*> at 8

-- | Every header condition of the profile; the accepted format.
checkProfile ∷ ImageKind → Header → Either Text Format
checkProfile kind header = do
  format ← case lookup (vkFormat header) vkFormats of
    Just format → Right format
    Nothing →
      Left $
        "vkFormat "
          <> tshow (vkFormat header)
          <> " is not one of R8G8B8A8_SRGB (43), R8G8B8A8_UNORM (37), BC7_SRGB_BLOCK (146) or BC7_UNORM_BLOCK (145)"
  case (kind, formatSpace format) of
    (ColourImage, Unorm) → Left ("a colour read needs an _SRGB format; this file's vkFormat is " <> formatName format)
    (DataImage, Srgb) → Left ("a data read needs a _UNORM format; this file's vkFormat is " <> formatName format)
    _ → Right ()
  unless (typeSize header == 1) $
    Left ("typeSize must be 1 for " <> formatName format <> "; this file's is " <> tshow (typeSize header))
  unless (pixelWidth header > 0) $
    Left "pixelWidth is 0; a texture needs a positive width"
  let dimensionality reason = Left ("the texture is not two-dimensional with one layer and one face: " <> reason)
  when (pixelHeight header == 0) $ dimensionality "pixelHeight is 0, a 1D texture"
  unless (pixelDepth header == 0) $ dimensionality ("pixelDepth is " <> tshow (pixelDepth header) <> ", a 3D texture")
  unless (layerCount header <= 1) $ dimensionality ("layerCount is " <> tshow (layerCount header) <> ", an array texture")
  unless (faceCount header == 1) $
    dimensionality ("faceCount is " <> tshow (faceCount header) <> (if faceCount header == 6 then ", a cube map" else ", not 1"))
  unless (supercompression header == 0) $
    Left ("supercompressionScheme is " <> tshow (supercompression header) <> "; supercompressed files are not read")
  when (levelCount header == 0) $
    Left "levelCount is 0, asking the loader to generate levels; a KTX2 file must store its own"
  let chain = fullChain (pixelWidth header) (pixelHeight header)
  unless (toInteger (levelCount header) <= toInteger chain) $
    Left $
      "levelCount is "
        <> tshow (levelCount header)
        <> ", more than the "
        <> tshow chain
        <> " levels of a full chain at "
        <> extentText (toInteger (pixelWidth header), toInteger (pixelHeight header))
  Right format

readIndex ∷ ByteString → Either Text Index
readIndex bytes =
  Index <$> word32 bytes 48 <*> word32 bytes 52 <*> word32 bytes 56 <*> word32 bytes 60 <*> word64 bytes 64 <*> word64 bytes 72

-- | The level index's entries, level 0 first.
readLevelIndex ∷ ByteString → Int → Either Text [LevelEntry]
readLevelIndex bytes count = do
  let end = headerBytes + 24 * toInteger count
  unless (end <= fileLength bytes) $
    Left ("the level index of " <> tshow count <> " entries ends at byte " <> tshow end <> ", outside the " <> tshow (fileLength bytes) <> "-byte file")
  forM [0 .. count - 1] $ \level → do
    let at = 80 + 24 * level
    LevelEntry <$> word64 bytes at <*> word64 bytes (at + 8) <*> word64 bytes (at + 16)

-- | The occupied regions every section must lie in and not overlap: the
-- header with its level index, and each non-empty section, which must lie
-- inside the file. Ranges are compared as exact integers.
checkSections ∷ ByteString → Index → Either Text [(Text, Integer, Integer)]
checkSections bytes index = do
  let sections =
        [ ("the data format descriptor", toInteger (dfdOffset index), toInteger (dfdLength index))
        , ("the key/value data", toInteger (kvdOffset index), toInteger (kvdLength index))
        , ("the supercompression global data", toInteger (sgdOffset index), toInteger (sgdLength index))
        ]
  when (dfdLength index == 0) $
    Left "the file has no data format descriptor"
  forM_ sections $ \(name, offset, size) →
    unless (size == 0 || offset + size <= fileLength bytes) $
      Left (name <> " (" <> rangeText offset size <> ") lies outside the " <> tshow (fileLength bytes) <> "-byte file")
  Right [(name, offset, size) | (name, offset, size) ← sections, size > 0]

-- | A level's stored bytes, once its range lies inside the file and its
-- length is its format's at its extent.
checkLevel ∷ ByteString → Format → Word32 → Word32 → Int → LevelEntry → Either Text ByteString
checkLevel bytes format width height level (LevelEntry offset size uncompressed) = do
  let name = "level " <> tshow level
      extent = levelExtent width height level
      needed = levelBytes format extent
  unless (size == uncompressed) $
    Left (name <> "'s byteLength " <> tshow size <> " differs from its uncompressedByteLength " <> tshow uncompressed)
  stored ← case slice bytes (toInteger offset) (toInteger size) of
    Just stored → Right stored
    Nothing →
      Left (name <> " (" <> rangeText (toInteger offset) (toInteger size) <> ") lies outside the " <> tshow (fileLength bytes) <> "-byte file")
  unless (toInteger size == needed) $
    Left (name <> " (" <> extentText extent <> ") of " <> formatName format <> " needs " <> tshow needed <> " bytes; the file stores " <> tshow size)
  Right stored

-- | No two occupied regions share a byte. Every region is non-empty.
checkOverlaps ∷ [(Text, Integer, Integer)] → Either Text ()
checkOverlaps regions = zipWithM_ disjoint ordered (drop 1 ordered)
  where
    ordered = sortOn (\(_, offset, _) → offset) regions
    disjoint (first, offset, size) (second, offset', size') =
      unless (offset + size <= offset') $
        Left (first <> " (" <> rangeText offset size <> ") overlaps " <> second <> " (" <> rangeText offset' size' <> ")")

-- | The basic descriptor block's transfer function and whether its
-- premultiplied-alpha flag is set, once the descriptor's framing is
-- consistent: its total size is its section's length, its blocks fill it
-- exactly, and its first block is a whole basic descriptor block.
readDescriptor ∷ ByteString → Either Text (Word8, Bool)
readDescriptor dfd = do
  total ← word32 dfd 0
  unless (toInteger total == fileLength dfd) $
    Left ("the data format descriptor's dfdTotalSize " <> tshow total <> " differs from its dfdByteLength " <> tshow (fileLength dfd))
  blocks ← walk 4
  case blocks of
    (at, header, size) : _
      | header /= 0 → Left "the data format descriptor's first block is not a basic descriptor block"
      | size < 24 →
          Left ("the basic descriptor block is " <> tshow size <> " bytes, too short for its 24 bytes of fields")
      | (size - 24) `mod` 16 /= 0 →
          Left ("the basic descriptor block is " <> tshow size <> " bytes, not 24 bytes and whole 16-byte samples")
      | otherwise → do
          transfer ← byte dfd (at + 10)
          flags ← byte dfd (at + 11)
          Right (transfer, flags .&. 1 /= 0)
    [] → Left "the data format descriptor holds no descriptor block"
  where
    walk at
      | toInteger at == fileLength dfd = Right []
      | toInteger at + 8 > fileLength dfd =
          Left ("a descriptor block's header at descriptor byte " <> tshow at <> " runs past the descriptor's end")
      | otherwise = do
          header ← word32 dfd at
          size ← fromIntegral <$> word16 dfd (at + 6)
          when (size < 8) $
            Left ("a descriptor block at descriptor byte " <> tshow at <> " has descriptorBlockSize " <> tshow size <> ", shorter than its own header")
          when (toInteger at + toInteger size > fileLength dfd) $
            Left ("a descriptor block at descriptor byte " <> tshow at <> " of " <> tshow size <> " bytes runs past the descriptor's end")
          ((at, header, size) :) <$> walk (at + size)

-- | KHR_DF_TRANSFER_LINEAR and KHR_DF_TRANSFER_SRGB.
checkTransfer ∷ Format → Word8 → Either Text ()
checkTransfer format transfer = unless (transfer == expected) $
  Left $
    "the data format descriptor's transfer function "
      <> transferName transfer
      <> " disagrees with "
      <> formatName format
      <> ", which needs "
      <> transferName expected
  where
    expected = case formatSpace format of
      Srgb → 2
      Unorm → 1
    transferName = \case
      1 → "1 (linear)"
      2 → "2 (sRGB)"
      other → tshow other

-- | The key/value entries, once their framing is consistent: each entry's
-- length and padding lie inside the section, the entries fill it exactly,
-- each key is NUL-terminated, and no key appears twice.
readKeyValues ∷ ByteString → Either Text [(ByteString, ByteString)]
readKeyValues kvd = reverse <$> go 0 []
  where
    go at entries
      | toInteger at == fileLength kvd = Right entries
      | toInteger at + 4 > fileLength kvd =
          Left ("a key/value entry's length at key/value byte " <> tshow at <> " runs past the key/value data's end")
      | otherwise = do
          size ← toInteger <$> word32 kvd at
          let padded = size + (negate size `mod` 4)
          unless (toInteger at + 4 + padded <= fileLength kvd) $
            Left ("the key/value entry at key/value byte " <> tshow at <> " of " <> tshow size <> " bytes, with its padding, runs past the key/value data's end")
          entry ← maybe (Left "a key/value entry lies outside its section") Right (slice kvd (toInteger at + 4) size)
          let (key, rest) = ByteString.break (== 0) entry
          when (ByteString.null rest) $
            Left ("the key/value entry at key/value byte " <> tshow at <> " has no NUL-terminated key")
          when (key `elem` map fst entries) $
            Left ("the key " <> keyText key <> " appears more than once")
          go (at + 4 + fromInteger padded) ((key, ByteString.drop 1 rest) : entries)

-- | @KTXorientation@ and @KTXswizzle@, the only entries read. Each value
-- is a string terminated by its entry's one NUL.
checkKeyValues ∷ [(ByteString, ByteString)] → Either Text ()
checkKeyValues entries = do
  check "KTXorientation" "rd"
  check "KTXswizzle" "rgba"
  where
    check key accepted = forM_ (lookup key entries) $ \value → do
      string ← case ByteString.unsnoc value of
        Just (string, 0) | not (ByteString.elem 0 string) → Right string
        _ → Left ("the " <> keyText key <> " value is not a NUL-terminated string")
      unless (string == accepted) $
        Left (keyText key <> " is " <> keyText string <> "; only " <> keyText accepted <> " is accepted")

-- | A level of a straight-alpha colour BC7 file, decoded, is opaque.
opaqueLevel ∷ Int → ((Integer, Integer), ByteString) → Either Text ()
opaqueLevel level ((width, _), texels) =
  forM_ (find (\n → ByteString.index texels (4 * n + 3) /= 255) [0 .. ByteString.length texels `div` 4 - 1]) $ \n →
    Left $
      "a colour BC7 file without the premultiplied-alpha flag must be opaque in every texel of every level; level "
        <> tshow level
        <> "'s texel ("
        <> tshow (toInteger n `mod` width)
        <> ", "
        <> tshow (toInteger n `div` width)
        <> ") has alpha "
        <> tshow (ByteString.index texels (4 * n + 3))

-- | Level @level@'s extent, exactly.
levelExtent ∷ Word32 → Word32 → Int → (Integer, Integer)
levelExtent width height level = (max 1 (toInteger width `shiftR` level), max 1 (toInteger height `shiftR` level))

levelExtents ∷ Word32 → Word32 → [(Integer, Integer)]
levelExtents width height = map (levelExtent width height) [0 ..]

-- | The bytes a level of this extent takes in the format.
levelBytes ∷ Format → (Integer, Integer) → Integer
levelBytes format (w, h) = case format of
  Rgba8 _ → 4 * w * h
  Bc7 _ → 16 * ((w + 3) `div` 4) * ((h + 3) `div` 4)

-- | One more than the base-two logarithm of the larger side, rounded down.
fullChain ∷ Word32 → Word32 → Int
fullChain width height = length (takeWhile (> 0) (iterate (`div` 2) (max width height)))

-- | A section's bytes. Its range was checked against the file; an empty
-- section is empty wherever its offset points.
sectionBytes ∷ ByteString → Word32 → Word32 → ByteString
sectionBytes bytes offset size = maybe ByteString.empty id (slice bytes (toInteger offset) (toInteger size))

-- | The bytes at [offset, offset + size), when that range lies inside the
-- buffer. Narrowed to 'Int' only after the exact comparison.
slice ∷ ByteString → Integer → Integer → Maybe ByteString
slice bytes offset size
  | offset >= 0 && size >= 0 && offset + size <= fileLength bytes =
      Just (ByteString.take (fromInteger size) (ByteString.drop (fromInteger offset) bytes))
  | otherwise = Nothing

fileLength ∷ ByteString → Integer
fileLength = toInteger . ByteString.length

-- | A little-endian field of @size@ bytes at @at@, or a refusal if it runs
-- past the buffer's end.
field ∷ Int → ByteString → Int → Either Text Integer
field size bytes at = case slice bytes (toInteger at) (toInteger size) of
  Just stored → Right (ByteString.foldr' (\b acc → acc `shiftL` 8 .|. toInteger b) 0 stored)
  Nothing → Left ("a " <> tshow size <> "-byte field at byte " <> tshow at <> " runs past the end of its data")

byte ∷ ByteString → Int → Either Text Word8
byte bytes at = fromInteger <$> field 1 bytes at

word16 ∷ ByteString → Int → Either Text Word32
word16 bytes at = fromInteger <$> field 2 bytes at

word32 ∷ ByteString → Int → Either Text Word32
word32 bytes at = fromInteger <$> field 4 bytes at

word64 ∷ ByteString → Int → Either Text Word64
word64 bytes at = fromInteger <$> field 8 bytes at

rangeText ∷ Integer → Integer → Text
rangeText offset size = "bytes " <> tshow offset <> " to " <> tshow (offset + size)

extentText ∷ (Integer, Integer) → Text
extentText (w, h) = tshow w <> " × " <> tshow h

keyText ∷ ByteString → Text
keyText = tshow . Text.decodeUtf8With Text.lenientDecode

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
