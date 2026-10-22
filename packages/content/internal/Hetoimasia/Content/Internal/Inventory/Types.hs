-- | The values the whole-folder inventory is made of: the limits a caller
-- narrows it with, the immutable inventory itself, and the structured outcomes
-- of a scan and of a verified read.
--
-- Everything here is plain immutable data owned by whoever holds it. An
-- 'Inventory' is built by one call to the scan and is never mutated; it holds
-- no handle, no pathname to open and no file content, only the checked logical
-- identities, the exact native components that open them, the byte length of
-- each regular file and its SHA-256 digest. The constructors of the checked
-- values are exported by this internal module only; the public
-- "Hetoimasia.Content.Inventory" module exposes them abstractly.
module Hetoimasia.Content.Internal.Inventory.Types
  ( -- * Limits
    InventorySpec (..)
  , InventoryLimits (..)
  , inventoryLimits
  , InventoryLimitName (..)
  , InventoryLimitsRefusal (..)
  , inventoryEntries
  , inventorySegments
  , inventoryPathBytes
  , inventorySegmentBytes
  , inventoryFileBytes
  , inventoryRootBytes
  , inventoryBufferBytes
  , inventoryIdentityLimits

    -- * Digests
  , Sha256 (..)
  , sha256Bytes
  , sha256Hex

    -- * The inventory
  , Inventory (..)
  , FileFact (..)
  , Presence (..)
  , InventoryEntry (..)

    -- * Scan outcomes
  , InventoryFailure (..)
  , InventoryFailureReason (..)
  , InventoryBound (..)
  , Change (..)

    -- * Read outcomes
  , ReadFailure (..)
  , ReadOutcome (..)
  ) where

import Control.Exception (Exception (displayException))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import Data.Word (Word64, Word8)
import Hetoimasia.Content.Internal.Identity.Mapping (InventoryReason, NativeMapping, ObservedKind)
import Hetoimasia.Content.Internal.Identity.Types
  ( ContentKey
  , IdentityLimits
  , LimitsRefusal
  , LogicalPath
  , RootKey
  , identityLimits
  )
import Hetoimasia.Content.Internal.Types
  ( FailureKind
  , NativeName
  , RootAttribution (..)
  , renderBytes
  , renderPath
  )
import Numeric (showHex)

-- | The numbers a caller supplies: nothing here is a default. The M1 assembly
-- passes the approved profile's values; the tests pass smaller ones through the
-- same check.
data InventorySpec = InventorySpec
  { specEntries ∷ !Int
  -- ^ The most entries, the root and every directory and file path included.
  , specSegments ∷ !Int
  -- ^ The most segments a relative path may have; the root is depth zero.
  , specPathBytes ∷ !Int
  -- ^ The most UTF-8 bytes of a relative path, on the native and the NFC form.
  , specSegmentBytes ∷ !Int
  -- ^ The most bytes of one segment, on both forms.
  , specFileBytes ∷ !Int
  -- ^ The most bytes of one regular file.
  , specRootBytes ∷ !Int
  -- ^ The most bytes summed over every regular-file path of a root, a hard-link
  -- alias charged once for each name.
  , specBufferBytes ∷ !Int
  -- ^ The streaming read buffer, the most one read asks for.
  }
  deriving (Eq, Show)

-- | Checked limits.
data InventoryLimits = InventoryLimits
  { limitSpec ∷ !InventorySpec
  , limitIdentity ∷ !IdentityLimits
  }
  deriving (Eq, Show)

-- | The limit a refusal names.
data InventoryLimitName
  = NameEntries
  | NameSegments
  | NamePathBytes
  | NameSegmentBytes
  | NameFileBytes
  | NameRootBytes
  | NameBufferBytes
  deriving (Eq, Show)

-- | Why a specification is not usable.
data InventoryLimitsRefusal
  = -- | A value below one (the entry allowance counts the root, so it is at
    -- least one too).
    SpecNotPositive !InventoryLimitName !Int
  | -- | The path, segment and segment-count limits the identity policy takes
    -- were refused.
    IdentityRefused !LimitsRefusal
  | -- | A single file may not be allowed more bytes than the whole root.
    FileLimitAboveRoot !Int !Int
  deriving (Eq, Show)

-- | Check a specification. Every value is at least one; the identity policy
-- accepts the path, segment and segment-count limits (a segment no larger than
-- the path or than the longest native name); and one file fits its root's
-- budget. The identity policy is given one entry fewer than the allowance,
-- because the root is not an addressable entry.
inventoryLimits ∷ InventorySpec → Either InventoryLimitsRefusal InventoryLimits
inventoryLimits spec
  | specEntries spec < 1 = Left (SpecNotPositive NameEntries (specEntries spec))
  | specSegments spec < 1 = Left (SpecNotPositive NameSegments (specSegments spec))
  | specPathBytes spec < 1 = Left (SpecNotPositive NamePathBytes (specPathBytes spec))
  | specSegmentBytes spec < 1 = Left (SpecNotPositive NameSegmentBytes (specSegmentBytes spec))
  | specFileBytes spec < 1 = Left (SpecNotPositive NameFileBytes (specFileBytes spec))
  | specRootBytes spec < 1 = Left (SpecNotPositive NameRootBytes (specRootBytes spec))
  | specBufferBytes spec < 1 = Left (SpecNotPositive NameBufferBytes (specBufferBytes spec))
  | specFileBytes spec > specRootBytes spec = Left (FileLimitAboveRoot (specFileBytes spec) (specRootBytes spec))
  | otherwise =
      case identityLimits (specPathBytes spec) (specSegmentBytes spec) (specSegments spec) (specEntries spec - 1) of
        Left refusal → Left (IdentityRefused refusal)
        Right identity → Right (InventoryLimits spec identity)

inventoryEntries, inventorySegments, inventoryPathBytes, inventorySegmentBytes, inventoryFileBytes, inventoryRootBytes, inventoryBufferBytes ∷ InventoryLimits → Int
inventoryEntries = specEntries . limitSpec
inventorySegments = specSegments . limitSpec
inventoryPathBytes = specPathBytes . limitSpec
inventorySegmentBytes = specSegmentBytes . limitSpec
inventoryFileBytes = specFileBytes . limitSpec
inventoryRootBytes = specRootBytes . limitSpec
inventoryBufferBytes = specBufferBytes . limitSpec

-- | The identity policy's limits an inventory was scanned under, for parsing a
-- reference against the same bounds.
inventoryIdentityLimits ∷ InventoryLimits → IdentityLimits
inventoryIdentityLimits = limitIdentity

-- | A SHA-256 digest: exactly 32 bytes.
newtype Sha256 = Sha256 ByteString
  deriving (Eq, Ord)

instance Show Sha256 where
  showsPrec _ = showString . sha256Hex

sha256Bytes ∷ Sha256 → ByteString
sha256Bytes (Sha256 bytes) = bytes

-- | Lower-case hexadecimal.
sha256Hex ∷ Sha256 → String
sha256Hex (Sha256 bytes) = concatMap byte (BS.unpack bytes)
  where
    byte ∷ Word8 → String
    byte value = (if value < 16 then "0" else "") <> showHex value ""

-- | What the inventory holds about one regular file.
data FileFact = FileFact
  { factLength ∷ !Word64
  , factDigest ∷ !Sha256
  }
  deriving (Eq, Show)

-- | The immutable result of a successful scan.
--
-- Owner: whoever called the scan, who owns it and its lifetime. Readers: any
-- thread. Writers: none. It is built in one call, from state local to that
-- call, and is never extended, refreshed or merged: a path added to the folder
-- afterwards is not in it, and a changed file is detected when it is read, not
-- by this value. It holds neither a handle nor a copy of any file's bytes.
data Inventory = Inventory
  { invLimits ∷ !InventoryLimits
  , invRootKey ∷ !RootKey
  , invAttribution ∷ !RootAttribution
  -- ^ The launch path and the native identity of the root it was built for.
  , invMapping ∷ !NativeMapping
  , invFiles ∷ !(Map ByteString FileFact)
  -- ^ Regular files by the NFC bytes of their logical path.
  , invEntryCount ∷ !Int
  -- ^ Entries counted, the root included.
  , invByteTotal ∷ !Word64
  -- ^ Regular-file bytes summed over every path, aliases counted per name.
  }

-- | What an inventory says is at a logical key.
data Presence
  = -- | Nothing: a path the scan did not see, or one that differs in case, or a
    -- key of another root.
    Absent
  | -- | An inventoried directory (never a source of bytes).
    PresentDirectory
  | -- | An inventoried regular file, with the byte length the scan counted.
    PresentFile !Word64
  deriving (Eq, Show)

-- | One entry of an inventory, as a diagnostic or a test reads it: no native
-- component, handle or pathname.
data InventoryEntry = InventoryEntry
  { entryLogicalPath ∷ !LogicalPath
  , entryObservedKind ∷ !ObservedKind
  , entryFact ∷ !(Maybe FileFact)
  -- ^ The length and digest of a regular file; nothing for a directory.
  }
  deriving (Eq, Show)

-- | Which numeric bound a scan exceeded. Path, segment and depth bounds are
-- reported by the identity policy as an 'InventoryReason'.
data InventoryBound = BoundEntries | BoundFileBytes | BoundRootBytes
  deriving (Eq, Show)

-- | What changed under a scan or a verified read.
data Change
  = -- | The file is gone.
    Missing
  | -- | The path no longer resolves to a regular file through no-follow opens:
    -- a link, another type, or a directory that is no longer one, as the
    -- content layer classified it.
    Retyped !FailureKind
  | -- | The length the inventory (or the metadata read at open) holds, and the
    -- length now.
    LengthChanged !Word64 !Word64
  | -- | A read ended before the expected length: expected, and bytes seen.
    Truncated !Word64 !Word64
  | -- | A byte followed the expected length.
    Grew !Word64
  | -- | The bytes read are the expected length and are not the inventoried ones.
    DigestMismatch
  deriving (Eq, Show)

-- | Why a scan refused startup. Nothing partial accompanies it.
data InventoryFailureReason
  = -- | The content layer's own refusal: unreadable, a symbolic link, an
    -- unsupported type, a cycle, an unsupported platform, an entry that changed
    -- since it was listed, a directory deeper than the root allows.
    Content !FailureKind
  | -- | The identity policy refused the entries of a directory: an invalid
    -- name, a path over a bound, a sibling collision.
    Identity !InventoryReason
  | -- | A numeric bound: which, the value observed (saturating) and the bound.
    Exceeded !InventoryBound !Word64 !Word64
  | -- | The folder changed while it was being scanned.
    Changed !Change
  deriving (Eq, Show)

-- | A scan's ordinary refusal: the root, the root-relative path it concerns
-- (lossless; at most one component past the depth bound) and why.
data InventoryFailure = InventoryFailure
  { inventoryFailureRoot ∷ !RootAttribution
  , inventoryFailurePath ∷ ![NativeName]
  , inventoryFailureReason ∷ !InventoryFailureReason
  }
  deriving (Eq, Show)

instance Exception InventoryFailure where
  displayException (InventoryFailure attribution path reason) =
    "content inventory of "
      <> renderBytes (attributedSelection attribution)
      <> " at "
      <> renderPath path
      <> ": "
      <> case reason of
        Content kind → show kind
        Identity refusal → show refusal
        Exceeded bound observed limit → show bound <> " exceeded: " <> show observed <> " against " <> show limit
        Changed change → "the folder changed during the scan: " <> show change

-- | A verified read's ordinary outcome other than the bytes.
data ReadOutcome
  = -- | The key is not in the inventory: absent, case-mismatched, a directory
    -- or another root's. Nothing was opened.
    ReadNotFound
  | -- | The inventoried length exceeds the caller's ceiling: the length and the
    -- ceiling. Decided from the inventory, before any open or read.
    ReadTooLarge !Word64 !Int
  | -- | The content no longer is what the scan pinned.
    ReadChanged !Change
  | -- | An expected access or read error, as the content layer classified it.
    ReadIoError !FailureKind
  deriving (Eq, Show)

-- | A verified read's refusal: the key and the outcome. It carries no bytes.
data ReadFailure = ReadFailure
  { readFailureRoot ∷ !RootAttribution
  , readFailureKey ∷ !ContentKey
  , readFailureOutcome ∷ !ReadOutcome
  }
  deriving (Eq, Show)

instance Exception ReadFailure where
  displayException (ReadFailure attribution key outcome) =
    "verified read of " <> show key <> " in " <> renderBytes (attributedSelection attribution) <> ": " <> show outcome
