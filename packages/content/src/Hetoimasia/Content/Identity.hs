-- | The logical identity of content: literal root-relative Unicode paths, one
-- NFC identity with exact case, and the checked mapping from logical names to
-- the exact native components a directory enumeration observed.
--
-- A reference is validated completely from the bytes as supplied, with
-- 'parseReference', before any file system is consulted; it yields a
-- 'ContentKey', the root together with the NFC path, or a 'ReferenceRefusal'
-- that is an argument error. An observed inventory becomes a 'NativeMapping'
-- with 'buildMapping', which refuses a set of entries that cannot be addressed
-- unambiguously; 'lookupPath' then answers, exactly and case-sensitively, which
-- native components to open, or that nothing is there. The three outcomes are
-- distinct: a malformed or over-limit reference, an invalid or colliding
-- inventory, and a well-formed path with no exact match, which is missing
-- content and never a native fallback.
--
-- Everything here is pure. Nothing prints, exits, touches a file or keeps a
-- registry; the caller owns every value it is given. No M1 limits are defined
-- here: the caller passes the numbers it was configured with to
-- 'identityLimits'.
--
-- See @packages/content/README.md@ for the grammar, the pinned Unicode data
-- version, the limits and the refusal classification in full.
module Hetoimasia.Content.Identity
  ( -- * Limits
    IdentityLimits
  , identityLimits
  , limitPathBytes
  , limitSegmentBytes
  , limitSegments
  , limitEntries
  , LimitName (..)
  , LimitsRefusal (..)

    -- * The root value
  , RootKey
  , rootKey
  , rootKeyBytes
  , maxRootKeyBytes
  , RootKeyRefusal (..)

    -- * References
  , parseReference
  , parseReferenceText
  , ContentKey
  , contentKeyRoot
  , contentKeyPath
  , LogicalPath
  , logicalPathBytes
  , logicalPathSegments
  , ReferenceRefusal (..)
  , ReferenceReason (..)
  , SegmentProblem (..)
  , Forbidden (..)

    -- * Observed inventories
  , ObservedKind (..)
  , ObservedEntry (..)
  , NativeMapping
  , buildMapping
  , mappingRoot
  , mappingSize
  , lookupPath
  , mappingEntries
  , MappedEntry
  , mappedPath
  , mappedNative
  , mappedKind
  , mappedSupplied
  , InventoryRefusal (..)
  , InventoryReason (..)
  , EntryProblem (..)
  , Collision (..)
  , CollisionKind (..)
  , CollidingEntry (..)

    -- * Bounded diagnostics
  , Excerpt
  , excerptBytes
  , excerptLength
  , excerptCap
  , renderExcerpt

    -- * Pinned Unicode data
  , unicodeDataVersion
  ) where

import Hetoimasia.Content.Internal.Identity.Mapping
import Hetoimasia.Content.Internal.Identity.Reference (parseReference, parseReferenceText)
import Hetoimasia.Content.Internal.Identity.Types hiding (keyPath, keyRoot, limitEntries, limitPathBytes, limitSegmentBytes, limitSegments)
import qualified Hetoimasia.Content.Internal.Identity.Types as Types
import Hetoimasia.Content.Internal.Identity.Unicode (unicodeDataVersion)

-- | The most UTF-8 bytes a whole relative path may have, separators included.
limitPathBytes ∷ IdentityLimits → Int
limitPathBytes = Types.limitPathBytes

-- | The most UTF-8 bytes one segment may have.
limitSegmentBytes ∷ IdentityLimits → Int
limitSegmentBytes = Types.limitSegmentBytes

-- | The most segments a relative path may have.
limitSegments ∷ IdentityLimits → Int
limitSegments = Types.limitSegments

-- | The most inventory entries a mapping accepts.
limitEntries ∷ IdentityLimits → Int
limitEntries = Types.limitEntries

-- | The root a key belongs to.
contentKeyRoot ∷ ContentKey → RootKey
contentKeyRoot = Types.keyRoot

-- | The checked NFC path within that root.
contentKeyPath ∷ ContentKey → LogicalPath
contentKeyPath = Types.keyPath
