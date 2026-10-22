-- | The literal root-relative path grammar and the NFC identity it produces.
--
-- A reference is validated completely, from the bytes as supplied, before any
-- file system is consulted and before any request is admitted. The same segment
-- check ('checkSegment') validates the components of an observed native
-- inventory entry, so an authored reference and an observed name meet one
-- policy.
module Hetoimasia.Content.Internal.Identity.Reference
  ( parseReference
  , parseReferenceText
  , checkSegment
  , CheckedSegment (..)
  , sumCapped
  ) where

import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Word (Word8)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Hetoimasia.Content.Internal.Identity.Types
import Hetoimasia.Content.Internal.Identity.Unicode (caselessKey, decodeUtf8, nfc)

-- | One segment that passed the grammar: its NFC bytes, which are its identity,
-- and its canonical caseless key, computed only if a collision check asks for
-- it. The key is for rejecting ambiguity and is never a lookup identity.
data CheckedSegment = CheckedSegment
  { checkedNfc ∷ !ByteString
  , checkedCaseless ∷ ByteString
  }

-- | Check a reference and name its NFC identity within the root.
--
-- The checks run in this order, and the first failure is the refusal: empty;
-- the whole reference's bytes against the path limit; the segment count against
-- the segment limit (counted from the separators, before anything is split);
-- leading, trailing and repeated slashes; then each segment in turn (its bytes
-- against the segment limit, @.@ and @..@, well-formed UTF-8, forbidden
-- characters, its NFC form against the segment limit and against the grammar
-- again); and last the NFC path against the path limit. Raw bounds are
-- therefore checked before any normalization, and normalization's shrinkage
-- never excuses an over-limit original.
parseReference ∷ IdentityLimits → RootKey → ByteString → Either ReferenceRefusal ContentKey
parseReference limits root reference = either refuse Right (check limits reference)
  where
    refuse reason = Left (ReferenceRefusal root (excerpt reference) reason)
    check = \l r → ContentKey root <$> checkReference l r

-- | 'parseReference' for a reference held as text: its UTF-8 encoding is the
-- reference, so the bounds count encoded bytes, never characters.
parseReferenceText ∷ IdentityLimits → RootKey → Text → Either ReferenceRefusal ContentKey
parseReferenceText limits root = parseReference limits root . TE.encodeUtf8

checkReference ∷ IdentityLimits → ByteString → Either ReferenceReason LogicalPath
checkReference limits reference
  | BS.null reference = Left EmptyReference
  | BS.length reference > limitPathBytes limits = Left (ReferenceTooLong (BS.length reference) (limitPathBytes limits))
  | segmentCount > limitSegments limits = Left (TooManySegments segmentCount (limitSegments limits))
  | BS.head reference == slash = Left LeadingSlash
  | BS.last reference == slash = Left TrailingSlash
  | otherwise = do
      let raw = BS.split slash reference
      case firstEmpty raw of
        Just index → Left (RepeatedSlash index)
        Nothing → pure ()
      checked ← traverse (uncurry segment) (zip [0 ..] raw)
      let identity = BS.intercalate "/" (map checkedNfc checked)
      if BS.length identity > limitPathBytes limits
        then Left (NormalizedTooLong (BS.length identity) (limitPathBytes limits))
        else case map checkedNfc checked of
          (first : rest) → Right (LogicalPath identity (first :| rest))
          [] → Left EmptyReference
  where
    segmentCount = BS.count slash reference + 1
    firstEmpty segments = lookup True (zip (map BS.null segments) [0 ..])
    segment index bytes = either (Left . BadSegment index) Right (checkSegment limits bytes)

slash ∷ Word8
slash = 0x2f

-- | Check one segment: raw bound, structure, well-formed UTF-8, forbidden
-- characters, then its NFC identity against the segment limit and the grammar.
checkSegment ∷ IdentityLimits → ByteString → Either SegmentProblem CheckedSegment
checkSegment limits bytes
  | BS.null bytes = Left SegmentEmpty
  | BS.length bytes > limitSegmentBytes limits = Left (SegmentTooLong (BS.length bytes) (limitSegmentBytes limits))
  | Just offset ← BS.elemIndex slash bytes = Left (SegmentSeparator offset)
  | bytes == "." = Left SegmentDot
  | bytes == ".." = Left SegmentDotDot
  | otherwise = do
      decoded ← either (Left . SegmentMalformedUtf8) Right (decodeUtf8 bytes)
      case [(forbidden, offset, fromEnum c) | (offset, c) ← decoded, Just forbidden ← [classify c]] of
        ((forbidden, offset, code) : _) → Left (SegmentForbidden forbidden offset code)
        [] → pure ()
      let normalizedText = nfc (T.pack (map snd decoded))
          normalized = TE.encodeUtf8 normalizedText
      if BS.length normalized > limitSegmentBytes limits
        then Left (SegmentNormalizedTooLong (BS.length normalized) (limitSegmentBytes limits))
        else do
          normalizedGrammar normalized
          pure (CheckedSegment normalized (TE.encodeUtf8 (caselessKey normalizedText)))

-- | The grammar again, on the NFC form that will be returned as the identity.
normalizedGrammar ∷ ByteString → Either SegmentProblem ()
normalizedGrammar normalized
  | BS.null normalized = Left (SegmentNormalizedGrammar 0)
  | normalized == "." = Left (SegmentNormalizedGrammar 0x2e)
  | normalized == ".." = Left (SegmentNormalizedGrammar 0x2e)
  | BS.elem slash normalized = Left (SegmentNormalizedGrammar 0x2f)
  | otherwise = case decodeUtf8 normalized of
      Left _ → Left (SegmentNormalizedGrammar 0xfffd)
      Right decoded → case [fromEnum c | (_, c) ← decoded, Just _ ← [classify c]] of
        (code : _) → Left (SegmentNormalizedGrammar code)
        [] → Right ()

-- | The characters the grammar forbids inside a segment.
classify ∷ Char → Maybe Forbidden
classify c
  | c == '\\' = Just Backslash
  | c == ':' = Just Colon
  | code == 0 = Just Nul
  | code <= 0x1f || (code >= 0x7f && code <= 0x9f) = Just Control
  | otherwise = Nothing
  where
    code = fromEnum c

-- | A sum that stops growing past a cap, so a long list is never summed in
-- full, and that saturates at 'maxBound' instead of wrapping.
sumCapped ∷ Int → [Int] → Int
sumCapped cap = go 0
  where
    go acc [] = acc
    go acc (x : xs)
      | acc > cap = acc
      | otherwise = go (addSaturating acc x) xs
