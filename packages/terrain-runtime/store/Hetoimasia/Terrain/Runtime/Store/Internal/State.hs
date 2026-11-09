-- | The store's configuration, its limits and the committed root set.
--
-- = Page states
--
-- Every page below the high-water mark @hw@ is in exactly one state, and the
-- counters of 'Roots' say how many pages are in each:
--
-- * __live__: reachable from the committed roots (a record, allocator or
--   retirement tree page, or a retirement list page);
-- * __retired__: replaced by a commit and listed in a retirement entry, kept until
--   every reader that could still read it has released;
-- * __free__: a free extent of the allocator tree, ready to be taken;
-- * __loose__: an owner-private bookkeeping page (an allocator or retirement page
--   a commit replaced, or a page a plan reserved and did not use) kept in the root
--   set for the next plan to take first.
--
-- Pages at or above @hw@ and below the usable page count are the untouched tail:
-- free, and taken by raising @hw@, which needs no allocator record. A page is in
-- the committed root's state only after its transaction published; pages a pending
-- transaction has claimed are /staged/ and counted separately.
--
-- Used pages are @hw - free@ plus the staged claim; free capacity is the rest of
-- the usable pages. Free reserved extents are never used bytes, retired pages are a
-- subset of the used pages (pending reclaim is not extra free capacity), and a page
-- reached by several roots is one page.
--
-- = Why loose pages are safe to reuse
--
-- A reader pins the record trees only; the allocator and retirement trees are the
-- owner's, read only while planning against the committed roots. A bookkeeping page
-- a commit replaced is unreachable from the new committed roots and from every
-- reader, and the single mutating transaction that could still hold it has just
-- published, so the next plan may take it at once. Record-tree pages a commit
-- replaced are never loose: they go to a retirement entry and wait for the readers.
--
-- State, ownership and lifetime: values. The terrain owner holds the one current
-- 'Roots' and replaces it only when a published plan says so.
module Hetoimasia.Terrain.Runtime.Store.Internal.State
  ( -- * Limits
    mib
  , gib
  , defaultAllowanceBytes
  , minAllowanceBytes
  , allowanceUnitBytes
  , protectedReserveBytes
  , reservePages
  , defaultOffsetLimit
  , bookkeepingReserve
  , maxClaimPages
  , maxWindowPages
  , windowPageBytes
  , txnRamLimit
  , maxReaders
  , readerRecordBytes
  , rootRecordBytes
  , activeRecordBytes
  , looseCap
  , maxReclaimPages

    -- * Configuration
  , StoreSpec (..)
  , StoreConfig
  , ConfigError (..)
  , mkStoreConfig
  , defaultStoreSpec
  , cfgAllowanceBytes
  , cfgOverheadBytes
  , cfgOffsetLimit
  , cfgUsablePages
  , cfgTotalPages
  , OffsetError (..)
  , pageFileOffset
  , rangeFileEnd
  , growConfig

    -- * Roots
  , Roots (..)
  , rootOf
  , emptyRoots
  , Pins (..)
  ) where

import Data.Word (Word64)
import Hetoimasia.Terrain.Discovery (Authority (..), Header (..))
import Hetoimasia.Terrain.Residency (ArenaId, Revision (..))
import Hetoimasia.Terrain.Runtime.Store.Internal.Format

mib ∷ Word64
mib = 1024 * 1024

gib ∷ Word64
gib = 1024 * mib

-- | The default per-arena storage allowance: 1 GiB.
defaultAllowanceBytes ∷ Word64
defaultAllowanceBytes = gib

-- | The smallest allowance: 64 MiB.
minAllowanceBytes ∷ Word64
minAllowanceBytes = 64 * mib

-- | An allowance is a whole number of these: 1 MiB.
allowanceUnitBytes ∷ Word64
allowanceUnitBytes = mib

-- | The bytes of the allowance protected for allocator and reclamation progress:
-- 8 MiB. Ordinary new history cannot spend them.
protectedReserveBytes ∷ Word64
protectedReserveBytes = 8 * mib

reservePages ∷ Word64
reservePages = protectedReserveBytes `div` pageSizeW

-- | The largest signed 64-bit file offset: the default native limit.
defaultOffsetLimit ∷ Word64
defaultOffsetLimit = 2 ^ (63 ∷ Int) - 1

-- | The pages a plan reserves for its allocator and retirement trees: four updates
-- at the worst cost of one, @2 * (maxLevel + 1) + 1@. Pages it does not use become
-- loose.
bookkeepingReserve ∷ Int
bookkeepingReserve = 4 * (2 * (maxLevel + 1) + 1)

-- | The most pages one plan takes from the allocator: every page it may write
-- ('maxTxnPages') and the bookkeeping reserve.
maxClaimPages ∷ Int
maxClaimPages = maxTxnPages + bookkeepingReserve

-- | The most decoded pages a plan's continuation may hold.
maxWindowPages ∷ Int
maxWindowPages = 512

-- | The accounted bytes of one decoded page in a window: the decoded copy and its
-- container overhead.
windowPageBytes ∷ Int
windowPageBytes = pageSize + 256

-- | The RAM one transaction may reserve: 4 MiB.
txnRamLimit ∷ Int
txnRamLimit = 4 * 1024 * 1024

-- | The readers one store may have pinned at once.
maxReaders ∷ Int
maxReaders = 16

-- | The accounted bytes of one reader pin record.
readerRecordBytes ∷ Int
readerRecordBytes = 256

-- | The accounted bytes of the committed root record.
rootRecordBytes ∷ Int
rootRecordBytes = 512

-- | The accounted bytes of the active transaction's control record.
activeRecordBytes ∷ Int
activeRecordBytes = 512

-- | The most loose pages the root set holds: a plan reserves at most
-- 'maxClaimPages' and a commit replaces at most as many bookkeeping pages.
looseCap ∷ Int
looseCap = 1024

-- | The most pages one reclamation transaction frees.
maxReclaimPages ∷ Int
maxReclaimPages = 64

-- ---------------------------------------------------------------------------
-- Configuration

-- | An unvalidated configuration, every figure an 'Integer' so that an
-- unrepresentable one is refused by name and never wrapped.
data StoreSpec = StoreSpec
  { specAllowanceBytes ∷ !Integer
  -- ^ The per-arena allowance in bytes.
  , specOverheadBytes ∷ !(Maybe Integer)
  -- ^ Conservative format and reservation overhead inside the allowance. A later
  -- backend supplies its own figure; 'Nothing' takes the default: 1/256 of the
  -- allowance, at least 1 MiB, rounded up to a page.
  , specOffsetLimit ∷ !Integer
  -- ^ The largest file offset the platform's signed offset type holds.
  }
  deriving stock (Eq, Show)

-- | A specification with the default allowance and the signed 64-bit offset limit.
defaultStoreSpec ∷ StoreSpec
defaultStoreSpec = StoreSpec (toInteger defaultAllowanceBytes) Nothing (toInteger defaultOffsetLimit)

-- | A validated configuration. The constructor is private.
data StoreConfig = StoreConfig
  { cfgAllowance ∷ !Word64
  , cfgOverhead ∷ !Word64
  , cfgLimit ∷ !Word64
  }
  deriving stock (Eq, Show)

cfgAllowanceBytes ∷ StoreConfig → Word64
cfgAllowanceBytes = cfgAllowance

cfgOverheadBytes ∷ StoreConfig → Word64
cfgOverheadBytes = cfgOverhead

cfgOffsetLimit ∷ StoreConfig → Word64
cfgOffsetLimit = cfgLimit

-- | The pages the allowance holds beyond its overhead: the page space the store
-- numbers.
cfgUsablePages ∷ StoreConfig → Word64
cfgUsablePages c = (cfgAllowance c - cfgOverhead c) `div` pageSizeW

-- | The bound of every page reference: the usable pages.
cfgTotalPages ∷ StoreConfig → Word64
cfgTotalPages = cfgUsablePages

-- | Why a configuration was refused. A bad configuration is never a capacity
-- outcome of an operation.
data ConfigError
  = AllowanceBelowMinimum !Integer
  | AllowanceNotAligned !Integer
  | AllowanceBeyondOffsetLimit !Integer !Integer
  | OffsetLimitInvalid !Integer
  | OverheadInvalid !Integer
  | -- | The allowance minus its overhead leaves too little for the protected
    -- reserve and one transaction.
    NoRoomForReserve !Integer !Integer
  deriving stock (Eq, Show)

-- | Validate a specification. The allowance is at least 64 MiB, a multiple of
-- 1 MiB and within the offset limit; the overhead is non-negative and leaves room
-- for the protected reserve and a maximal transaction, so that a configuration that
-- is accepted can always make the supported minimum edit.
mkStoreConfig ∷ StoreSpec → Either ConfigError StoreConfig
mkStoreConfig spec = do
  let bytes = specAllowanceBytes spec
      limit = specOffsetLimit spec
  if limit < 1 || limit > toInteger defaultOffsetLimit then Left (OffsetLimitInvalid limit) else Right ()
  if bytes < toInteger minAllowanceBytes then Left (AllowanceBelowMinimum bytes) else Right ()
  if bytes `mod` toInteger allowanceUnitBytes /= 0 then Left (AllowanceNotAligned bytes) else Right ()
  if bytes > limit then Left (AllowanceBeyondOffsetLimit bytes limit) else Right ()
  let overhead = maybe (defaultOverhead bytes) id (specOverheadBytes spec)
  if overhead < 0 || overhead >= bytes then Left (OverheadInvalid overhead) else Right ()
  let usable = (bytes - overhead) `div` toInteger pageSizeW
      need = toInteger reservePages + toInteger maxClaimPages + 1
  if usable < need then Left (NoRoomForReserve usable need) else Right ()
  Right (StoreConfig (fromInteger bytes) (fromInteger overhead) (fromInteger limit))

defaultOverhead ∷ Integer → Integer
defaultOverhead bytes = ((max (toInteger mib) (bytes `div` 256) + 4095) `div` 4096) * 4096

-- | Why a page or range could not be placed in the file.
data OffsetError
  = PageBeyondAllowance !PageNo
  | OffsetOverflow
  deriving stock (Eq, Show)

-- | The file offset of a page, checked: the page lies inside the usable pages and
-- its end is inside the allowance and the native offset limit, with no wrapping.
pageFileOffset ∷ StoreConfig → PageNo → Either OffsetError Word64
pageFileOffset c p@(PageNo n)
  | n >= cfgUsablePages c = Left (PageBeyondAllowance p)
  | otherwise = do
      let off = toInteger n * toInteger pageSizeW
          end = off + toInteger pageSizeW
      if end > toInteger (cfgAllowance c) || end > toInteger (cfgLimit c) then Left OffsetOverflow else Right (fromInteger off)

-- | The end offset of a byte range starting at a page, checked against the page
-- space, the allowance and the offset limit: @offset + length@ never wraps.
rangeFileEnd ∷ StoreConfig → PageNo → Word64 → Either OffsetError Word64
rangeFileEnd c p len = do
  off ← pageFileOffset c p
  let end = toInteger off + toInteger len
      pageSpace = toInteger (cfgUsablePages c) * toInteger pageSizeW
  if end > pageSpace || end > toInteger (cfgAllowance c) || end > toInteger (cfgLimit c) then Left OffsetOverflow else Right (fromInteger end)

-- | The configuration with a larger allowance, the overhead unchanged, validated
-- as a new configuration would be.
growConfig ∷ StoreConfig → Integer → Either ConfigError StoreConfig
growConfig c bytes = mkStoreConfig (StoreSpec bytes (Just (toInteger (cfgOverhead c))) (toInteger (cfgLimit c)))

-- ---------------------------------------------------------------------------
-- Roots

-- | The committed immutable root set: one version of every tree, the discovery
-- control header and the page counters. A plan is made against exactly one 'Roots'
-- and publishes the next; nothing here changes in place.
data Roots = Roots
  { rVersion ∷ !Word64
  , rRuns ∷ !(Maybe PageNo)
  , rLinks ∷ !(Maybe PageNo)
  , rTodo ∷ !(Maybe PageNo)
  , rFree ∷ !(Maybe PageNo)
  , rRetire ∷ !(Maybe PageNo)
  , rHeader ∷ !Header
  , rHw ∷ !Word64
  , rFreePages ∷ !Word64
  , rLivePages ∷ !Word64
  , rRetiredPages ∷ !Word64
  , rLoose ∷ [PageNo]
  }
  deriving stock (Eq, Show)

-- | The root page of a tree.
rootOf ∷ Roots → TreeId → Maybe PageNo
rootOf r TreeRuns = rRuns r
rootOf r TreeLinks = rLinks r
rootOf r TreeTodo = rTodo r
rootOf r TreeFree = rFree r
rootOf r TreeRetire = rRetire r

-- | The roots of a fresh arena incarnation: no page, no record, revisions zero.
emptyRoots ∷ ArenaId → Roots
emptyRoots arena =
  Roots
    { rVersion = 0
    , rRuns = Nothing
    , rLinks = Nothing
    , rTodo = Nothing
    , rFree = Nothing
    , rRetire = Nothing
    , rHeader = Header (Authority arena (Revision 0) (Revision 0) (Revision 0)) 0 0 0
    , rHw = 0
    , rFreePages = 0
    , rLivePages = 0
    , rRetiredPages = 0
    , rLoose = []
    }

-- | The record trees' roots a reader pins, with the version they belong to.
data Pins = Pins
  { pinVersion ∷ !Word64
  , pinRuns ∷ !(Maybe PageNo)
  , pinLinks ∷ !(Maybe PageNo)
  , pinTodo ∷ !(Maybe PageNo)
  }
  deriving stock (Eq, Show)
