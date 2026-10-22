-- | Values the identity examples share: the M1 numbers a consumer would pass,
-- two roots, and small builders for references and observed entries.
--
-- The M1 numbers live here as test inputs only. The package under test holds no
-- such default: every example hands its limits to 'identityLimits' explicitly,
-- as the later assembly will.
module Test.Content.Identity.Support
  ( m1
  , limits
  , rootA
  , rootB
  , utf8
  , bytes
  , accepted
  , refusedReason
  , pathOf
  , keyOf
  , file
  , directory
  , nativeEntry
  , collisionOf
  , exactly
  , scalars
  ) where

import Data.Bifunctor (bimap)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Char (chr)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import Hetoimasia.Content.Identity

-- | The fixed M1 path and entry numbers, passed as plain values.
m1 ∷ IdentityLimits
m1 = limits 1024 255 32 10000

-- | Checked limits for a literal the example knows is valid.
limits ∷ Int → Int → Int → Int → IdentityLimits
limits pathBytes segmentBytes segments entries =
  either (\refusal → error ("invalid fixture limits: " <> show refusal)) id (identityLimits pathBytes segmentBytes segments entries)

rootA ∷ RootKey
rootA = either (\refusal → error (show refusal)) id (rootKey (BC.pack "root-a"))

rootB ∷ RootKey
rootB = either (\refusal → error (show refusal)) id (rootKey (BC.pack "root-b"))

-- | UTF-8 bytes of the characters. Write non-ASCII characters as escapes.
utf8 ∷ String → ByteString
utf8 = TE.encodeUtf8 . T.pack

-- | Exact bytes, for the ill-formed forms no character spells.
bytes ∷ [Word8] → ByteString
bytes = BS.pack

-- | The NFC identity of a reference under the limits, or why it was refused.
accepted ∷ IdentityLimits → ByteString → Either ReferenceReason ByteString
accepted theLimits = bimap refusalReason (logicalPathBytes . contentKeyPath) . parseReference theLimits rootA

-- | Why a reference is refused under the M1 numbers.
refusedReason ∷ ByteString → Either ReferenceReason ByteString
refusedReason = accepted m1

-- | The identity of an accepted reference; fails the example otherwise.
pathOf ∷ ByteString → IO ByteString
pathOf reference = either (\reason → fail ("refused: " <> show reason)) pure (refusedReason reference)

-- | The key of an accepted reference in a root.
keyOf ∷ RootKey → ByteString → ContentKey
keyOf root reference =
  either (\refusal → error ("refused: " <> show refusal)) id (parseReference m1 root reference)

-- | An observed file below the root, its components as characters.
file ∷ [String] → ObservedEntry
file components = ObservedEntry (map utf8 components) ObservedFile

directory ∷ [String] → ObservedEntry
directory components = ObservedEntry (map utf8 components) ObservedDirectory

-- | An observed entry whose components are exact bytes.
nativeEntry ∷ ObservedKind → [ByteString] → ObservedEntry
nativeEntry kind components = ObservedEntry components kind

-- | The collision a refused inventory reports, if it reported one.
collisionOf ∷ Either InventoryRefusal a → Maybe Collision
collisionOf (Left (InventoryRefusal _ (SiblingCollision collision))) = Just collision
collisionOf _ = Nothing

-- | A path of exactly @n@ bytes made of ASCII segments of at most @segment@
-- bytes, separators counted.
exactly ∷ Int → Int → ByteString
exactly segment total = BC.pack (go total)
  where
    go remaining
      | remaining <= segment = replicate remaining 'a'
      | remaining - segment == 1 = replicate (segment - 1) 'a' <> "/" <> go 1
      | otherwise = replicate segment 'a' <> "/" <> go (remaining - segment - 1)

-- | Every Unicode scalar value.
scalars ∷ [Char]
scalars = [chr code | code ← [0 .. 0x10ffff], code < 0xd800 || code > 0xdfff]
