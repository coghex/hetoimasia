-- | The constants, identities and failures of the temporary store's private page
-- format. Nothing here performs an effect.
--
-- The format is an internal session format: it is not a game-save schema, is not
-- written by @Show@ or read by @Read@, and is never read by another run. The page
-- layout is documented with the codec ("Hetoimasia.Terrain.Runtime.Store.Internal.Page").
--
-- State, ownership and lifetime: none. Plain immutable values.
module Hetoimasia.Terrain.Runtime.Store.Internal.Format
  ( -- * Sizes
    pageSize
  , pageSizeW
  , pageHeaderBytes
  , pageChecksumOffset
  , pagePayloadBytes
  , formatVersion
  , maxKeyBytes
  , maxValueBytes
  , maxEntryBytes
  , maxLevel
  , maxListPages
  , maxTxnPages
  , maxTxnBytes
  , minNodeBytes
  , probeBytes

    -- * Identities
  , PageNo (..)
  , TreeId (..)
  , allTrees
  , recordTrees
  , bookkeepingTrees
  , treeCode
  , treeFromCode
  , StoreIdentity (..)

    -- * Failures
  , PageError (..)
  ) where

import Data.Word (Word16, Word32, Word64, Word8)
import Hetoimasia.Terrain.Residency (ArenaId)

-- | Every page is exactly this many bytes (4 KiB), immutable once written.
pageSize ∷ Int
pageSize = 4096

-- | 'pageSize' as a 'Word64' for page-number arithmetic.
pageSizeW ∷ Word64
pageSizeW = 4096

-- | The fixed header before a page's payload.
pageHeaderBytes ∷ Int
pageHeaderBytes = 40

-- | Where the four-byte CRC32C sits: it covers every byte before it.
pageChecksumOffset ∷ Int
pageChecksumOffset = pageSize - 4

-- | The bytes a page's payload may use.
pagePayloadBytes ∷ Int
pagePayloadBytes = pageChecksumOffset - pageHeaderBytes

-- | The only format version this implementation reads or writes.
formatVersion ∷ Word16
formatVersion = 1

-- | The longest encoded key a page holds. The longest real key is 52 bytes (a
-- source component node); the bound leaves room and is checked on decode.
maxKeyBytes ∷ Int
maxKeyBytes = 64

-- | The longest encoded value a page holds (the longest real value is 53 bytes).
maxValueBytes ∷ Int
maxValueBytes = 64

-- | The most bytes one leaf entry takes: a one-byte key length, a one-byte value
-- length, the key and the value. An internal entry is smaller (a key and an
-- eight-byte page number).
maxEntryBytes ∷ Int
maxEntryBytes = 2 + maxKeyBytes + maxValueBytes

-- | The highest level of a tree: levels are @0@ (leaf) to @maxLevel@, so a tree is
-- at most 8 pages deep. A page that claims more is refused, which is what stops a
-- malformed or cyclic structure from looping, and a plan that would need a taller
-- tree is refused with a typed result and never truncated.
--
-- A legitimate tree needs more than 8 levels only when it holds more than about
-- 6.7e7 records: every non-root node holds at least a quarter of a payload
-- ('minNodeBytes'), so a leaf holds at least 7 entries and an internal node at
-- least 13 children, and a root with two children at level 7 over 13-way nodes
-- has at least 2 * 13^6 leaves of 7 entries. That is more than 9.6e6 leaf pages,
-- 36 GiB of leaves alone, so the default 1 GiB allowance and every allowance below
-- 36 GiB can never reach the bound; a larger one meets the typed refusal.
maxLevel ∷ Int
maxLevel = 7

-- | The accounted bytes of one page probe a window keeps: its map entry, tag, level and
-- the key it keeps, copied out of the page buffer (at most 'maxKeyBytes').
probeBytes ∷ Int
probeBytes = 256 + maxKeyBytes

-- | The most page numbers one retirement list page holds.
maxListPages ∷ Int
maxListPages = (pagePayloadBytes - 8) `div` 8

-- | The most new encoded pages one transaction writes, metadata included: 1 MiB.
maxTxnPages ∷ Int
maxTxnPages = 256

-- | The most new encoded bytes one transaction writes.
maxTxnBytes ∷ Int
maxTxnBytes = maxTxnPages * pageSize

-- | The occupancy below which a node is rebalanced after a deletion: a quarter of
-- the payload.
minNodeBytes ∷ Int
minNodeBytes = pagePayloadBytes `div` 4

-- | A page number: the page's index in the store's page space, not a byte offset.
newtype PageNo = PageNo Word64
  deriving stock (Eq, Ord, Show)

-- | The five indexes. The first three hold #661's logical record categories; the
-- last two are the allocator and the retirement work.
data TreeId
  = -- | Removed intervals: @KeyRun column lo → RecRun hi@.
    TreeRuns
  | -- | Component, union and knowledge records: @KeyLink node@.
    TreeLinks
  | -- | Pending discovery obligations: @KeyTodo sequence@.
    TreeTodo
  | -- | Free extents of pages: start page → length.
    TreeFree
  | -- | Retirement work: the version that replaced the pages → the list of them.
    TreeRetire
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allTrees ∷ [TreeId]
allTrees = [minBound .. maxBound]

-- | The trees a reader may traverse.
recordTrees ∷ [TreeId]
recordTrees = [TreeRuns, TreeLinks, TreeTodo]

-- | The owner-private allocator and retirement trees.
bookkeepingTrees ∷ [TreeId]
bookkeepingTrees = [TreeFree, TreeRetire]

-- | The tree's byte in a page header.
treeCode ∷ TreeId → Word8
treeCode = fromIntegral . fromEnum

treeFromCode ∷ Word8 → Maybe TreeId
treeFromCode c
  | fromIntegral c <= fromEnum (maxBound ∷ TreeId) = Just (toEnum (fromIntegral c))
  | otherwise = Nothing

-- | What a decoded page must be bound to: the arena incarnation and the source
-- identity the owner supplied. A page of another arena or source is refused even
-- when its checksum is valid.
data StoreIdentity = StoreIdentity
  { siArena ∷ !ArenaId
  , siSource ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | Why a page or a record could not be used. Every one is an explicit integrity
-- or format result: none reads as absent history, empty terrain or pristine
-- source.
data PageError
  = ShortPage !Int
  | OversizedPage !Int
  | BadMagic
  | UnsupportedVersion !Word16
  | UnsupportedKind !Word8
  | UnsupportedTree !Word8
  | BadChecksum !Word32 !Word32
  | WrongArena
  | WrongSource
  | WrongPageNumber !PageNo !PageNo
  | NonZeroReserved
  | BadLevel !Int
  | BadCount !Int
  | BadLength !Int
  | BadUsedBytes !Int
  | NonZeroPadding
  | KeyLength !Int
  | ValueLength !Int
  | KeyOrder
  | MalformedKey
  | MalformedValue
  | BadReference !PageNo
  | Overflow
  | KindMismatch
  | -- | A child page's checksum is not the one its parent records for it: the checksum the
    -- parent expects, the one the page carries.
    ChildChecksum !Word32 !Word32
  | -- | A root page was asked for with no checksum recorded for it by the root record (or the pin) the
    -- window was built from: a root is never read unchecked, except through the test-only
    -- 'Hetoimasia.Terrain.Runtime.Store.Internal.Tree.windowUnchecked'.
    RootChecksumMissing
  | EntryTooLarge !Int
  deriving stock (Eq, Show)
