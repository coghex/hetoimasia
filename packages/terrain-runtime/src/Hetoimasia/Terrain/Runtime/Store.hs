-- | The temporary store's pure model (TRA-20): the private page format, the
-- copy-on-write indexes over it, staged transaction planning, readers, reclamation
-- and the allowance, all as values and typed results.
--
-- Nothing here opens a file, starts a thread, reads a clock or runs STM. A later
-- backend (TRA-21) performs the page I/O this module describes, and the terrain
-- owner (TRA-22) holds the one current 'Store', supplies outcomes and decides
-- publication; the design contract and the field-level format are in the package
-- README and in the private modules this interface hides.
--
-- == Using it
--
-- @
-- plan <- 'planRemoval' env store window tile        -- or 'planDiscovery', 'planMaintenance'
-- case plan of
--   'Pending' page   -> fetch the page, 'addPage' it to the window, plan again
--   'PendingProbes' pages -> fetch each page, 'addProbe' it to the window (it may not be a page
--                       at all), plan again: the plan must first prove no owner claims it
--   'Checkpoint' facts -> the window filled while the plan was proving that the pages it will
--                       overwrite are owned by nobody but the allocator: build a fresh window of the
--                       same version with 'windowCheckpoint' facts (it keeps what was proven and the
--                       work limit, and drops the pages and probes) and plan again. A consumer MUST
--                       handle it; the 'Facts' are opaque and only the planner makes them
--   'Planned' p      -> 'admit' p store, write 'planPages', report each outcome with
--                       'dispatchWrite' and 'completeWrite', then 'publish' (or 'abortTransaction')
--   'NoWork'         -> nothing to append
--   'Refused' ('Capacity' ('WindowExceeded' _ | 'WindowBytesExceeded' _ | 'ProbesExceeded' _))
--                    -> the window outgrew its bounds while the plan read more than one unit of work
--                       (the pages one maintenance transaction frees, the writes of one batch) needs:
--                       build a fresh window for the same version, 'reduceWork' it from the old one
--                       (the work halves, to one page or one write at the least) and plan again; a
--                       unit of one needs a bounded window, so the retry ends with the work done
--   'Refused' why    -> 'classifyPlan' (in "Hetoimasia.Terrain.Runtime.Store.Admission")
-- @
--
-- A 'Window' is the continuation of one plan or one read and belongs to one version;
-- a plan or read through a window of another version is refused.
module Hetoimasia.Terrain.Runtime.Store
  ( -- * Format
    pageSize
  , maxTxnPages
  , maxTxnBytes
  , maxLevel
  , maxKeyBytes
  , maxValueBytes
  , PageNo (..)
  , TreeId (..)
  , StoreIdentity (..)
  , PageError (..)
  , crc32c
  , PageKind (..)
  , PageDescription (..)
  , describePage

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
  , defaultAllowanceBytes
  , minAllowanceBytes
  , allowanceUnitBytes
  , protectedReserveBytes
  , reservePages
  , defaultOffsetLimit
  , OffsetError (..)
  , pageFileOffset
  , rangeFileEnd
  , maxWindowPages
  , maxWindowBytes
  , txnRamLimit
  , maxReaders
  , bookkeepingReserve
  , maxClaimPages
  , maxReclaimPages

    -- * Windows
  , Window
  , storeWindow
  , addPage
  , addProbe
  , windowSize
  , limitWork
  , reduceWork
  , windowWork
  , Facts
  , windowCheckpoint
  , windowBytes
  , windowVersion
  , windowPageNumbers

    -- * The store
  , Store
  , newStore
  , storeConfig
  , storeIdentity
  , storeVersion
  , storeHeader
  , storeRoots
  , committedRoot
  , oldestPin
  , Roots
  , rootsVersion
  , rootsHighWater
  , rootsFreePages
  , rootsLivePages
  , rootsRetiredPages
  , rootsLoosePages
  , Usage (..)
  , usage
  , controlBytes

    -- * Planning
  , Plan
  , planPages
  , planEffects
  , planMeasure
  , planClass
  , planKind
  , planIdentity
  , planNextVersion
  , PlanIdentity (..)
  , TxClass (..)
  , PlanKind (..)
  , Effects (..)
  , RamCharge (..)
  , ramTotal
  , Measure (..)
  , Planned (..)
  , PlanRefusal (..)
  , StaleWhy (..)
  , InvalidWhy (..)
  , CapacityWhy (..)
  , IntegrityWhy (..)
  , planEdit
  , planRemoval
  , planDiscovery
  , planMaintenance
  , WindowRefusal (..)
  , providerAt
  , missingAt
  , freePool
  , availablePages

    -- * The transaction
  , TxnId
  , txnSerial
  , AdmitRefusal (..)
  , admit
  , EventResult (..)
  , WriteOutcome (..)
  , dispatchWrite
  , completeWrite
  , requestCancel
  , Eligibility (..)
  , eligibility
  , Published (..)
  , PublishRefusal (..)
  , publish
  , AbortRefusal (..)
  , abortTransaction
  , activePages
  , ActiveView (..)
  , activeView

    -- * Conditions
  , Condition (..)
  , conditions
  , pauseFor
  , clearCondition

    -- * Readers
  , ReaderToken
  , ReaderRefusal (..)
  , StaleReader (..)
  , acquireReader
  , releaseReader
  , readerVersion
  , readerWindow
  , RangeStart (..)
  , ReadOutcome (..)
  , maxRangeRecords
  , readerLookup
  , readerFloorRun
  , readerRange
  , PinRefusal (..)
  , readerProviderFor
  , readerMissing

    -- * Growth
  , GrowthProposal
  , growthFrom
  , growthTo
  , GrowthDecision (..)
  , GrowthRefusal (..)
  , proposeGrowth
  , beginGrowth
  , growthReserved
  , commitGrowth
  , growthFailed
  , growthReleased
  , growthReleaseFailed
  , GrowthView (..)
  , growthView

    -- * Feasibility
  , Counterexample (..)
  , minimumRemovalFeasible
  , minimumRemovalPages
  , minimumRemovalRam
  ) where

import Data.ByteString (ByteString)
import Data.Word (Word64)
import Hetoimasia.Terrain.Runtime.Store.Internal.Crc32c (crc32c)
import Hetoimasia.Terrain.Runtime.Store.Internal.Format
import Hetoimasia.Terrain.Runtime.Store.Internal.Model
import Hetoimasia.Terrain.Runtime.Store.Internal.Page (Body (..), Page (..), bodyBytes, decodePage)
import Hetoimasia.Terrain.Runtime.Store.Internal.Plan
import Hetoimasia.Terrain.Runtime.Store.Internal.State
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Facts, Window, limitWork, reduceWork, windowBytes, windowInsert, windowPageNumbers, windowProbe, windowCheckpoint, windowSize, windowVersion, windowWork)

-- The accessors below are functions, never record fields, so a client cannot rewrite
-- a plan, a growth proposal or a root set with record-update syntax.

-- | The encoded pages a plan writes, in the order the transaction's outcomes expect.
planPages ∷ Plan → [(PageNo, ByteString)]
planPages = plPages

planEffects ∷ Plan → Effects
planEffects = plEffects

planMeasure ∷ Plan → Measure
planMeasure = plMeasure

planClass ∷ Plan → TxClass
planClass = plClass

planKind ∷ Plan → PlanKind
planKind = plKind

planIdentity ∷ Plan → PlanIdentity
planIdentity = plIdentity

-- | The version the store has once the plan is published.
planNextVersion ∷ Plan → Word64
planNextVersion = rVersion . plNext

rootsVersion, rootsHighWater, rootsFreePages, rootsLivePages, rootsRetiredPages ∷ Roots → Word64
rootsVersion = rVersion
rootsHighWater = rHw
rootsFreePages = rFreePages
rootsLivePages = rLivePages
rootsRetiredPages = rRetiredPages

rootsLoosePages ∷ Roots → [PageNo]
rootsLoosePages = rLoose

-- | The base of a growth proposal and the allowance it proposes, in bytes.
growthFrom, growthTo ∷ GrowthProposal → Word64
growthFrom = gpFrom
growthTo = gpTo

-- | Add a page read from the store to a window. The page is decoded and fully
-- validated against the window's store (arena and source) and page space first; one that fails is
-- refused and the window is unchanged.
addPage ∷ StoreConfig → PageNo → ByteString → Window → Either PageError Window
addPage cfg = windowInsert (cfgTotalPages cfg)

-- | Add what a page is, read for a 'PendingProbe': the plan is about to overwrite or free
-- it and only needs to know whether a committed or pinned tree can reach it. A buffer that
-- is not a valid page of this store at that number is recorded as nothing, never refused,
-- and only its classification is kept, never the 4 KiB.
addProbe ∷ StoreConfig → PageNo → ByteString → Window → Window
addProbe cfg = windowProbe (cfgTotalPages cfg)

-- | The kind of a page.
data PageKind = LeafPage | InternalPage | ListPage
  deriving stock (Eq, Show)

-- | What a validated page holds.
data PageDescription = PageDescription
  { pdTree ∷ !TreeId
  , pdLevel ∷ !Int
  , pdKind ∷ !PageKind
  , pdEntries ∷ !Int
  , pdPayloadBytes ∷ !Int
  }
  deriving stock (Eq, Show)

-- | Decode and validate a page, and describe it. A page that fails any check is
-- refused with the reason and describes nothing.
describePage ∷ StoreConfig → StoreIdentity → PageNo → ByteString → Either PageError PageDescription
describePage cfg ident no bytes = do
  Page tree level _ body ← decodePage ident (cfgTotalPages cfg) no bytes
  let (kind, n) = case body of
        Leaf es → (LeafPage, length es)
        Inner es → (InternalPage, length es)
        List _ ps → (ListPage, length ps)
  Right (PageDescription tree level kind n (bodyBytes body))
