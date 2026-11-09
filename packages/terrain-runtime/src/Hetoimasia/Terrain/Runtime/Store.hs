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
--   'Planned' p      -> 'admit' p store, write 'planPages', report each outcome with
--                       'dispatchWrite' and 'completeWrite', then 'publish' (or 'abortTransaction')
--   'NoWork'         -> nothing to append
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
  , windowSize
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
import Hetoimasia.Terrain.Runtime.Store.Internal.Tree (Window, windowBytes, windowInsert, windowPageNumbers, windowSize, windowVersion)

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
        List ps → (ListPage, length ps)
  Right (PageDescription tree level kind n (bodyBytes body))
