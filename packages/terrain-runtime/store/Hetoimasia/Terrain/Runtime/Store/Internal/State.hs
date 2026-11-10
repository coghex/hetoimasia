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
  , maxBookkeepingPages
  , bookkeepingSlack
  , maxClaimPages
  , maxWindowPages
  , windowPageBytes
  , maxWindowBytes
  , maxWindowProbes
  , maxRetiredPages
  , worstOwnershipBytes
  , overlayWorstBytes
  , overlayBudgetRecord
  , overlayBudgetBookkeeping
  , txnRamLimit
  , maxReaders
  , readerRecordBytes
  , rootRecordBytes
  , activeRecordBytes
  , looseCap
  , looseSoftCap
  , maxSpillPages
  , maxReclaimPages
  , workOneWindowPages
  , looseGrowthUnit
  , looseGrowthOrdinary
  , workOneProbeBytes
  , removalWindowPages
  , maxRetireInternals

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
  , validateSize

    -- * Roots
  , Roots (..)
  , rootOf
  , rootTrust
  , pinTrust
  , emptyRoots
  , Pins (..)
  ) where

import Data.Word (Word32, Word64)
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

-- | The most bookkeeping pages one candidate plan may take: every page a plan writes counts against the
-- 'maxTxnPages' of a transaction, so the record pages, the list page and the bookkeeping together stay
-- within them (a plan that needs more is the shrinkable 'TxnPagesExceeded'), and the pages it claims stay
-- within 'maxClaimPages'. The bookkeeping a plan needs is not bounded by the reserve alone: every replaced
-- record page is also indexed in the retirement tree, one root-to-leaf path each. The plan counts the pages
-- its bookkeeping edit really needs before it numbers any and, when the reserve is short, takes that many
-- (and 'bookkeepingSlack' more) instead.
maxBookkeepingPages ∷ Int
maxBookkeepingPages = maxTxnPages

-- | The pages taken beyond the count the first attempt needed: the larger supply takes more free
-- extents, which the allocator tree's own edit may need a page or two more for.
bookkeepingSlack ∷ Int
bookkeepingSlack = 8

-- | The most pages one plan takes from the allocator: every page it may write
-- ('maxTxnPages') and the bookkeeping reserve.
maxClaimPages ∷ Int
maxClaimPages = maxTxnPages + bookkeepingReserve

-- | The most validated pages a plan's continuation may hold (a structural bound; the
-- byte bound, 'maxWindowBytes', is the tighter one for dense pages).
maxWindowPages ∷ Int
maxWindowPages = 512

-- | The accounted bytes of one validated page in a window: its 4 KiB buffer and the
-- map entry and headers around it.
windowPageBytes ∷ Int
windowPageBytes = pageSize + 128

-- | The most accounted bytes a plan's window may hold: 1.25 MiB (about 310 pages). The
-- window keeps validated page buffers, not decoded entry lists, so this is the memory
-- it really holds; a plan that needs more is refused with a typed result.
maxWindowBytes ∷ Int
maxWindowBytes = 1310720

-- | The most page probes a plan's window may hold: every page it writes below the used
-- space is probed once ('maxTxnPages'), and a reclamation chunk probes the pages it
-- frees beside the bookkeeping pages it writes.
maxWindowProbes ∷ Int
maxWindowProbes = 512

-- | The most retired pages that may be outstanding when an ordinary plan adds more. Every
-- retired page is indexed in the retirement tree by its number, so a plan can prove in one
-- descent that a page it overwrites is not still owned by an entry; the index is bounded by
-- bounding the backlog (a reader's pin holds it). A plan that would add past it is refused
-- with a typed result until a reader releases and maintenance has reclaimed. Maintenance
-- never adds to it.
maxRetiredPages ∷ Int
maxRetiredPages = 16384

-- | The most accounted bytes of the ownership proof: the probes a window keeps.
worstOwnershipBytes ∷ Int
worstOwnershipBytes = maxWindowProbes * probeBytes

-- | The most accounted bytes of new (overlay) pages the record trees of one plan may
-- hold while it works: the 256 pages it may write at their packed size and a margin.
-- An overlay page is held packed, its entries as one byte string.
overlayBudgetRecord ∷ Int
overlayBudgetRecord = 1100000

-- | The most accounted bytes the new pages a plan keeps can hold at once: its 256
-- written pages at their packed size. The working budgets above are looser bounds on
-- the work in progress; this is what a plan's reservation holds.
overlayWorstBytes ∷ Int
overlayWorstBytes = maxTxnPages * (pagePayloadBytes + 160)

-- | The same for the allocator and retirement trees of one plan.
overlayBudgetBookkeeping ∷ Int
overlayBudgetBookkeeping = 300000

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

-- | The length past which a maintenance transaction hands the excess of the loose list to the allocator
-- tree as free extents. Maintenance returns more pages to the loose list than it takes (every entry it
-- finishes releases its list page, every merge of tree nodes replaces more pages than it writes), so a long
-- drain of small entries would otherwise outgrow 'looseCap'; an ordinary plan takes at least what it adds.
-- The list stays within this and the few pages one transaction adds.
looseSoftCap ∷ Int
looseSoftCap = 512

-- | The most loose pages one maintenance transaction hands to the allocator tree. Each is a free extent of its own
-- (loose pages are not adjacent), so it costs a path of the allocator tree in the transaction's edit, which a window
-- holds at once; and each is a page a plan puts in the allocator's hands, so it gets the same proofs as a page the
-- plan writes ('workOneWindowPages' counts both).
maxSpillPages ∷ Int
maxSpillPages = 8

-- | The most pages one reclamation transaction frees.
maxReclaimPages ∷ Int
maxReclaimPages = 64

-- | The most a maintenance transaction of ONE page adds to the loose list, net of the pages it takes from it, once the
-- list is at or below 'looseSoftCap' (above it the transaction is a spill that only inserts into the allocator tree
-- and strictly lowers the list). Replaced bookkeeping pages return to the list and the pages written are taken from
-- it, so the list grows only by the pages a deletion merges away or a root it collapses, and by the list page of the
-- entry it finishes: a deletion in a tree of @h@ levels merges at most one node on each level above the leaf and
-- collapses the root once, so at most @h@ pages. The unit of one unindexes one page (@hr@), removes or updates its
-- entry (@hr@), frees the entry's list page (1) and edits the allocator tree: it coalesces the one page it frees with
-- its neighbours (two deletions and an insertion, at most @2 * hf@) and, when the loose list cannot supply it,
-- consumes the lowest extents, whose deletions empty at most 3 leaves (at most 72 pages of extents of one page, 56 to
-- a leaf) and merge one node on each level above (@hf@).
looseGrowthUnit ∷ Int → Int → Int
looseGrowthUnit hr hf = 2 * hr + 1 + 2 * hf + 3 + hf

-- | The most an ORDINARY plan (a standalone removal included) adds to the loose list net of what it takes: none while
-- the list holds at least the pages the plan claims, because the bookkeeping edit of an ordinary plan has no
-- deletion (it indexes the pages it replaces and consumes no extent when the loose list supplies it), so it replaces
-- no more pages than it writes; below that the plan consumes at most 'maxClaimPages' pages of extents, whose
-- deletions empty at most @maxClaimPages / 56 + 1@ leaves and merge one node on each level above, @hf@. The list
-- then holds the unused part of the supply and what it replaced, at most 'maxClaimPages' plus this.
looseGrowthOrdinary ∷ Int → Int
looseGrowthOrdinary hf = maxClaimPages `div` 56 + 1 + hf

-- | The pages a maintenance transaction of ONE page holds in its window AT ONCE, from the heights of the
-- retirement tree (@hr@), the allocator tree (@hf@) and the record trees (@hrec@) and the readers pinned at
-- distinct versions (@pins@). It rests on 'maxLevel' (every height is at most @maxLevel + 1@) and
-- 'maxReaders' alone: a tree the load path accepts need not be at minimum fill. The window holds what the
-- transaction edits and ONE proof; every proof beyond it is a fact the plan carries through a checkpoint, so no
-- proof is ever held with another:
--
-- * the oldest entry and its list: @hr + 1@;
-- * the unindexing of the page and the update or removal of the entry: @2 * hr@;
-- * the allocator tree's own edit: @3 * hf@, and the free extents of the loose pages it spills ('maxSpillPages'), one
--   path each: @maxSpillPages * hf@;
-- * the largest proof: that the page is unreachable, a path in the committed tree and in each pinned one,
--   @(1 + pins) * hrec@; that the retired-page index does not own it or has dropped it, @hr@; that the free
--   extents do not contain it, @hf@.
--
-- The probes it holds are at most @3 * hr + 3 * hf + 2 + maxSpillPages@ ('workOneProbeBytes').
workOneWindowPages ∷ Int → Int → Int → Int → Int
workOneWindowPages hr hf hrec pins =
  (hr + 1) + 2 * hr + 3 * hf + maxSpillPages * hf + max ((1 + pins) * hrec) (max hr hf)

-- | The most internal pages a retirement tree can have: at most @2 * maxRetiredPages@ records (an index record for
-- each retired page and an entry for each list), at least 46 to a leaf and 47 to an internal page.
maxRetireInternals ∷ Int
maxRetireInternals = 17

-- | The accounted bytes of the probes of a transaction of one page.
workOneProbeBytes ∷ Int → Int → Int
workOneProbeBytes hr hf = (3 * hr + 3 * hf + 2 + maxSpillPages) * probeBytes

-- | The pages a standalone explicit removal holds at once. It cannot shrink (it is atomic): its edit is held
-- whole. At most 'worstEditWrites' writes (7) each read a path of @hrec@ pages and replace at most as many;
-- each replaced page is indexed in the retirement tree, which reads one leaf for each (at most 7 * hrec + 1) and
-- the internal pages above them, at most @retireInternals@, which is 'maxRetireInternals': the store refuses a
-- non-root page below a quarter of a payload when it descends to it ('UnderFull') and a root set that retires more
-- than 'maxRetiredPages' pages, so a retirement tree holds at most twice that many records (an index record for
-- each retired page and an entry for each list) at least 46 to a leaf and 47 children to an internal page, that is
-- 712 leaves, 16 internal pages and a root; the allocator tree's edit, @3 * hf@; and ONE proof as above.
removalWindowPages ∷ Int → Int → Int → Int → Int
removalWindowPages retireInternals hf hrec pins =
  7 * hrec + (7 * hrec + 1) + retireInternals + 3 * hf + max ((1 + pins) * hrec) hf

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

-- | Whether a size is a legal allowance on its own: at least the minimum, a multiple
-- of the unit and inside the native offset limit. The overhead and the reserve room
-- are properties of a whole configuration, not of a size.
validateSize ∷ StoreConfig → Integer → Either ConfigError ()
validateSize c bytes = do
  let limit = toInteger (cfgLimit c)
  if bytes < toInteger minAllowanceBytes then Left (AllowanceBelowMinimum bytes) else Right ()
  if bytes `mod` toInteger allowanceUnitBytes /= 0 then Left (AllowanceNotAligned bytes) else Right ()
  if bytes > limit then Left (AllowanceBeyondOffsetLimit bytes limit) else Right ()

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
  , rRootCrcs ∷ [(TreeId, Word32)]
  -- ^ The checksum each tree's root page must carry, as published with the root: the anchor of the
  -- checksum chain (an internal entry records its child's, the root record records the roots'). A tree
  -- with no entry here is read unchecked (a root set made by hand).
  }
  deriving stock (Eq, Show)

-- | The root page of a tree.
rootOf ∷ Roots → TreeId → Maybe PageNo
rootOf r TreeRuns = rRuns r
rootOf r TreeLinks = rLinks r
rootOf r TreeTodo = rTodo r
rootOf r TreeFree = rFree r
rootOf r TreeRetire = rRetire r

-- | What a window must hold for a root set: the checksum each root page carries, by page number.
rootTrust ∷ Roots → [(PageNo, Word32)]
rootTrust r = [(p, c) | (t, c) ← rRootCrcs r, Just p ← [rootOf r t]]

-- | The same for the record roots a reader pins.
pinTrust ∷ Pins → [(PageNo, Word32)]
pinTrust p = [(pg, c) | (t, c) ← pinCrcs p, Just pg ← [case t of TreeRuns → pinRuns p; TreeLinks → pinLinks p; TreeTodo → pinTodo p; _ → Nothing]]

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
    , rRootCrcs = []
    }

-- | The record trees' roots a reader pins, with the version they belong to.
data Pins = Pins
  { pinVersion ∷ !Word64
  , pinRuns ∷ !(Maybe PageNo)
  , pinLinks ∷ !(Maybe PageNo)
  , pinTodo ∷ !(Maybe PageNo)
  , pinCrcs ∷ [(TreeId, Word32)]
  , pinHw ∷ !Word64
  -- ^ The used page space of the pinned version: no pinned tree reaches a page at or past it.
  }
  deriving stock (Eq, Show)
