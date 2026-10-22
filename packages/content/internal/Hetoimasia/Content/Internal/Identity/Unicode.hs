-- | The Unicode operations content identity is built from, and nothing else.
--
-- Three operations, each pure and independent of the user's locale, of
-- @GHC.IO.Encoding@ and of the operating system's file system:
--
-- * 'decodeUtf8' accepts exactly the well-formed UTF-8 of RFC 3629 and Unicode
--   Table 3-7, and reports the byte offset of the first ill-formed sequence
--   rather than replacing it.
-- * 'nfc' and 'nfd' are Unicode normalization forms C and D.
-- * 'caselessKey' is the key of Unicode canonical caseless matching (D145):
--   @NFD (toCasefold (NFD x))@ with the default full case folding, the
--   @CaseFolding.txt@ statuses C and F, never the locale-specific T mappings.
--   Two strings match caselessly exactly when their keys are equal.
--
-- Normalization and case folding both take their tables from the
-- @unicode-data@ package, which the package's cabal file pins to one exact
-- version ('unicodeDataVersion' states the Unicode version that version
-- carries), so an ambient system or compiler upgrade cannot change them. The
-- normalizer is @unicode-transforms@, which reads its decompositions, combining
-- classes and Hangul rules from that same package; the case folding is
-- @unicode-data@'s own 'toCaseFoldString'. The suite checks both against the
-- Unicode Consortium's own @NormalizationTest.txt@ and @CaseFolding.txt@ for
-- that version.
module Hetoimasia.Content.Internal.Identity.Unicode
  ( unicodeDataVersion
  , decodeUtf8
  , nfc
  , nfd
  , caseFold
  , caselessKey
  , maxCaselessExpansion
  ) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Char (chr)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Normalize (NormalizationMode (NFC, NFD), normalize)
import Unicode.Char.Case (toCaseFoldString)

-- | The Unicode version of every table this module uses: the version
-- @unicode-data ==0.8.0@ carries. The cabal file holds the package at exactly
-- that version, and the suite fails if the tables stop matching the reference
-- files of this version.
unicodeDataVersion ∷ String
unicodeDataVersion = "17.0.0"

-- | The most code points the caseless key of one code point has, for the pinned
-- data. Every stage of the key (decomposition, folding, decomposition) maps one
-- code point at a time, and reordering never changes a length, so the scratch
-- for a string of @n@ code points is exactly the sum of its code points' keys:
-- at most @n * maxCaselessExpansion@. The suite sweeps every scalar value and
-- requires this figure to be the maximum, so a data change that grows a key
-- fails there before it can exceed the bound a caller sized scratch by.
maxCaselessExpansion ∷ Int
maxCaselessExpansion = 4

-- | Decode well-formed UTF-8, or report the byte offset at which the first
-- ill-formed sequence begins. Overlong forms, encoded surrogates, code points
-- above U+10FFFF, truncated sequences and stray continuation or invalid lead
-- bytes are all ill-formed. Each decoded character comes with its byte offset.
decodeUtf8 ∷ ByteString → Either Int [(Int, Char)]
decodeUtf8 bytes = go 0
  where
    size = BS.length bytes
    at i = fromIntegral (BSU.unsafeIndex bytes i) ∷ Int
    cont i = i < size && at i .&. 0xc0 == 0x80
    inRange i lo hi = i < size && at i >= lo && at i <= hi
    payload i = at i .&. 0x3f
    go i
      | i >= size = Right []
      | b0 < 0x80 = emit i 1 b0
      | b0 >= 0xc2 && b0 <= 0xdf =
          if cont (i + 1)
            then emit i 2 (((b0 .&. 0x1f) `shiftL` 6) .|. payload (i + 1))
            else Left i
      | b0 == 0xe0 = three i (inRange (i + 1) 0xa0 0xbf)
      | b0 >= 0xe1 && b0 <= 0xec = three i (cont (i + 1))
      | b0 == 0xed = three i (inRange (i + 1) 0x80 0x9f)
      | b0 >= 0xee && b0 <= 0xef = three i (cont (i + 1))
      | b0 == 0xf0 = four i (inRange (i + 1) 0x90 0xbf)
      | b0 >= 0xf1 && b0 <= 0xf3 = four i (cont (i + 1))
      | b0 == 0xf4 = four i (inRange (i + 1) 0x80 0x8f)
      | otherwise = Left i
      where
        b0 = at i
    three i secondOk
      | secondOk && cont (i + 2) =
          emit i 3 (((at i .&. 0x0f) `shiftL` 12) .|. (payload (i + 1) `shiftL` 6) .|. payload (i + 2))
      | otherwise = Left i
    four i secondOk
      | secondOk && cont (i + 2) && cont (i + 3) =
          emit
            i
            4
            ( ((at i .&. 0x07) `shiftL` 18)
                .|. (payload (i + 1) `shiftL` 12)
                .|. (payload (i + 2) `shiftL` 6)
                .|. payload (i + 3)
            )
      | otherwise = Left i
    emit i width code = ((i, chr code) :) <$> go (i + width)

-- | Normalization form C.
nfc ∷ Text → Text
nfc = normalize NFC

-- | Normalization form D.
nfd ∷ Text → Text
nfd = normalize NFD

-- | Default full case folding (@CaseFolding.txt@ statuses C and F), character
-- by character. It is not a comparison by itself: use 'caselessKey'.
caseFold ∷ Text → Text
caseFold = T.pack . concatMap toCaseFoldString . T.unpack

-- | The key of canonical caseless matching (Unicode D145).
caselessKey ∷ Text → Text
caselessKey = nfd . caseFold . nfd
