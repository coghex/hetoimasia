-- | Validated residency limits. The constructor of 'Limits' is private: the
-- only ways to a value are 'mkLimits' and 'defaultLimits', so a limit that is
-- zero, unrepresentable or inconsistent never reaches the model, and a client
-- cannot rewrite a validated figure with record-update syntax.
--
-- Capacity is guaranteed by configuration, not decided per request. The limits
-- carry the request caps (regions per query and per camera demand, and the cell
-- extent of a region that may ever be loaded), and 'mkLimits' refuses a
-- configuration whose banks cannot hold the worst-case footprint of the largest
-- admissible request of every kind (see 'minimumBytes'). A request within the
-- caps is therefore never invalid for lack of capacity; shortage is only ever
-- busy.
module Hetoimasia.Terrain.Internal.Residency.Limits
  ( Bank (..)
  , Slot (..)
  , allBanks
  , allSlots
  , LimitsSpec (..)
  , LimitField (..)
  , LimitError (..)
  , Limits
  , mkLimits
  , defaultLimits
  , limitCeiling
  , limitBytes
  , limitSlot
  , limitQueryRegions
  , limitExtent
  , limitExplicitStagingBytes
  , limitRegionStoredBytes
  , limitAgingQuanta
  , minimumBytes
  , minimumLoadJobs
  , regionStoredBytes
  ) where

import Data.Word (Word64)
import Hetoimasia.Terrain.Internal.Residency.Coverage
  ( commandRecordBytes
  , interestRecordBytes
  , regionColumnReserveBytes
  , regionMetadataBytes
  , regionSegmentReserveBytes
  , regionSegmentStoredBytes
  , removalResidentGrowthBytes
  , removalRetainedBytes
  , removalStagingBytes
  )

-- | The three service-wide byte banks. Each cost category the model charges
-- belongs to exactly one of them (see "Hetoimasia.Terrain.Residency").
data Bank
  = -- | Region and segment metadata, packed detail payload and sparse indexes.
    ResidentBank
  | -- | Retained session edits.
    EditBank
  | -- | Scratch, request bookkeeping, camera descriptions and temporary duplicates.
    StagingBank
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The three counted slots.
data Slot
  = -- | Internal load jobs.
    LoadJobSlot
  | -- | Accepted, unsettled terrain commands.
    CommandSlot
  | -- | Pinned CPU view revisions, counted per view.
    ViewPinSlot
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allBanks ∷ [Bank]
allBanks = [minBound .. maxBound]

allSlots ∷ [Slot]
allSlots = [minBound .. maxBound]

-- | Unvalidated limits, as a caller states them. Every field is an 'Integer'
-- so that an unrepresentable figure is refused by name instead of wrapping.
data LimitsSpec = LimitsSpec
  { specResidentBytes ∷ !Integer
  , specEditBytes ∷ !Integer
  , specStagingBytes ∷ !Integer
  , specLoadJobs ∷ !Integer
  , specQueuedCommands ∷ !Integer
  , specPinsPerView ∷ !Integer
  , specAgingQuanta ∷ !Integer
  , -- | The most regions an explicit query may name; one internal load job each,
    -- so at most 'specLoadJobs'.
    specQueryRegions ∷ !Integer
  , -- | The cells of a region that may ever be loaded: columns @x < specExtentX@,
    -- rows @y < specExtentY@ and levels @z < specExtentZ@ (at most the region's
    -- 16, 16 and 32). A request naming a cell outside the extent is invalid from
    -- every state. This is the storage format's maximum per-region cost, so a
    -- region's footprint is bounded whatever sequence of requests loads it.
    specExtentX ∷ !Integer
  , specExtentY ∷ !Integer
  , specExtentZ ∷ !Integer
  }
  deriving stock (Eq, Show)

-- | The field a refusal names.
data LimitField
  = FieldResidentBytes
  | FieldEditBytes
  | FieldStagingBytes
  | FieldLoadJobs
  | FieldQueuedCommands
  | FieldPinsPerView
  | FieldAgingQuanta
  | FieldQueryRegions
  | FieldExtentX
  | FieldExtentY
  | FieldExtentZ
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Why a limit was refused. A permanently invalid limit is never clamped.
data LimitError
  = -- | The limit is zero or negative: no request could ever fit it.
    LimitNotPositive !LimitField !Integer
  | -- | The limit exceeds 'limitCeiling' (or, for an extent, the region's size)
    -- and cannot be represented with room for checked arithmetic.
    LimitUnrepresentable !LimitField !Integer
  | -- | A bank is smaller than the worst-case footprint of the largest admissible
    -- request: the bank, the bytes that footprint needs and the bytes configured.
    -- The shortfall is the difference.
    BankBelowMinimum !Bank !Integer !Integer
  | -- | Fewer load-job slots than an admissible query can need at once: the slots
    -- it needs and the slots configured.
    LoadJobsBelowMinimum !Integer !Integer
  deriving stock (Eq, Show)

-- | A validated set of limits.
data Limits = Limits
  { lResident ∷ !Word64
  , lEdit ∷ !Word64
  , lStaging ∷ !Word64
  , lJobs ∷ !Word64
  , lCommands ∷ !Word64
  , lPins ∷ !Word64
  , lAging ∷ !Word64
  , lQuery ∷ !Word64
  , lExtent ∷ !(Int, Int, Int)
  , lExplicitStaging ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | The largest accepted limit, @2^40@. Every sum the model forms is of a few
-- terms bounded by limits and counts, so it stays far below @2^64@ and is
-- additionally computed with checked arithmetic.
limitCeiling ∷ Integer
limitCeiling = 2 ^ (40 ∷ Int)

-- | Validate a specification. The first refused field, in declaration order, is
-- reported, then the first bank below its minimum (resident, edit, staging) and
-- the load jobs. A limit smaller than any single unit charge is refused here
-- (the bank would be below the minimum), never per request, and never clamped.
mkLimits ∷ LimitsSpec → Either LimitError Limits
mkLimits spec = do
  resident ← check FieldResidentBytes limitCeiling (specResidentBytes spec)
  edit ← check FieldEditBytes limitCeiling (specEditBytes spec)
  staging ← check FieldStagingBytes limitCeiling (specStagingBytes spec)
  jobs ← check FieldLoadJobs limitCeiling (specLoadJobs spec)
  commands ← check FieldQueuedCommands limitCeiling (specQueuedCommands spec)
  pins ← check FieldPinsPerView limitCeiling (specPinsPerView spec)
  aging ← check FieldAgingQuanta limitCeiling (specAgingQuanta spec)
  query ← check FieldQueryRegions limitCeiling (specQueryRegions spec)
  ex ← checkInt FieldExtentX 16 (specExtentX spec)
  ey ← checkInt FieldExtentY 16 (specExtentY spec)
  ez ← checkInt FieldExtentZ 32 (specExtentZ spec)
  mapM_ (atLeast spec) allBanks
  if minimumLoadJobs spec > specLoadJobs spec
    then Left (LoadJobsBelowMinimum (minimumLoadJobs spec) (specLoadJobs spec))
    else Right ()
  pure (Limits resident edit staging jobs commands pins aging query (fromInteger ex, fromInteger ey, fromInteger ez) (fromInteger (minimumBytes spec StagingBank)))
  where
    check field top n
      | n <= 0 = Left (LimitNotPositive field n)
      | n > top = Left (LimitUnrepresentable field n)
      | otherwise = Right (fromInteger n)
    checkInt ∷ LimitField → Integer → Integer → Either LimitError Integer
    checkInt field top n
      | n <= 0 = Left (LimitNotPositive field n)
      | n > top = Left (LimitUnrepresentable field n)
      | otherwise = Right n
    atLeast sp bank =
      let needed = minimumBytes sp bank
          have = case bank of
            ResidentBank → specResidentBytes sp
            EditBank → specEditBytes sp
            StagingBank → specStagingBytes sp
       in if needed > have then Left (BankBelowMinimum bank needed have) else Right ()

-- | The most one region can hold, whatever sequence of requests loaded it: its
-- metadata, a column index entry for each of the extent's columns, a segment for
-- each interval (a column of @z@ levels has at most @ceiling (z / 2)@ separate
-- intervals) and two payload bytes per cell. Computed with exact integers.
regionStoredBytes ∷ Integer → Integer → Integer → Integer
regionStoredBytes x y z =
  toInteger regionMetadataBytes
    + toInteger regionColumnReserveBytes * columns
    + toInteger regionSegmentStoredBytes * segments
    + 2 * columns * z
  where
    columns = x * y
    segments = columns * ((z + 1) `div` 2)

-- | The most a job for cells inside the extent can reserve, beyond the region's
-- metadata: every column and every interval, at the model's reservation figures.
regionJobBytes ∷ Integer → Integer → Integer → Integer
regionJobBytes x y z = toInteger regionColumnReserveBytes * columns + toInteger regionSegmentReserveBytes * columns * ((z + 1) `div` 2)
  where
    columns = x * y

-- | The worst-case footprint, in bytes, that the bank must hold for the largest
-- admissible /explicit/ request of every kind (a query, a removal, a handoff's
-- duplicate), computed from the request caps and the region extent with exact
-- arithmetic. Camera demand is best effort and not part of this guarantee. A
-- request of @n@ regions can name regions that already hold everything the extent
-- allows, and then loads the rest, so each region contributes its stored maximum
-- plus the largest job:
--
-- * 'ResidentBank': the most of a query's regions and a removal (one region, one
--   cell, and its resident growth);
-- * 'StagingBank': the most of a query (its command record, an interest and the
--   scratch of a load of the whole extent for each region), a removal (its command
--   and staging) and a handoff's temporary duplicate of a region at its stored
--   maximum. This is also the headroom camera work leaves free (see
--   'limitExplicitStagingBytes');
-- * 'EditBank': one removal's retained growth.
minimumBytes ∷ LimitsSpec → Bank → Integer
minimumBytes spec bank = case bank of
  ResidentBank →
    maximum
      [ queryN * (stored + job)
      , stored + toInteger (regionColumnReserveBytes + regionSegmentReserveBytes) + toInteger removalResidentGrowthBytes
      ]
  EditBank → toInteger removalRetainedBytes
  StagingBank →
    maximum
      [ toInteger (commandRecordBytes 0) + 32 * queryN + interest * queryN + queryN * scratch
      , toInteger (commandRecordBytes 1) + toInteger removalStagingBytes + interest + 256 + 2
      , stored
      ]
  where
    queryN = specQueryRegions spec
    x = specExtentX spec
    y = specExtentY spec
    z = specExtentZ spec
    stored = regionStoredBytes x y z
    job = regionJobBytes x y z
    interest = toInteger interestRecordBytes
    scratch = 256 + 2 * x * y * z

-- | The load-job slots an admissible query can need at once: one per region.
minimumLoadJobs ∷ LimitsSpec → Integer
minimumLoadJobs = specQueryRegions

-- | The approved initial CPU limits (sized for a normal laptop, hundreds of
-- megabytes): 256 MiB resident terrain, 64 MiB retained session edits, 128 MiB CPU
-- render and staging, 128 load jobs, 256 queued commands and two pinned view
-- revisions per view, an aging threshold of 8 service quanta, and the explicit
-- request caps: at most 16 regions in a query and the region's whole 16 x 16 x 32
-- extent. They satisfy 'mkLimits' (the worst-case footprints are recorded in the
-- terrain README and checked by the tests). Camera demand has no cap: it is best
-- effort.
defaultLimits ∷ Limits
defaultLimits =
  Limits
    { lResident = 256 * mib
    , lEdit = 64 * mib
    , lStaging = 128 * mib
    , lJobs = 128
    , lCommands = 256
    , lPins = 2
    , lAging = 8
    , lQuery = 16
    , lExtent = (16, 16, 32)
    , lExplicitStaging = 267904
    }
  where
    mib = 1024 * 1024

limitBytes ∷ Limits → Bank → Word64
limitBytes l ResidentBank = lResident l
limitBytes l EditBank = lEdit l
limitBytes l StagingBank = lStaging l

limitSlot ∷ Limits → Slot → Word64
limitSlot l LoadJobSlot = lJobs l
limitSlot l CommandSlot = lCommands l
limitSlot l ViewPinSlot = lPins l

-- | The most regions one explicit query may name.
limitQueryRegions ∷ Limits → Word64
limitQueryRegions = lQuery

-- | The staging bytes camera work always leaves free, so that an explicit request
-- is never starved of staging by camera interests: the staging minimum for the
-- explicit requests. Camera work likewise leaves 'limitQueryRegions' load-job
-- slots free.
limitExplicitStagingBytes ∷ Limits → Word64
limitExplicitStagingBytes = lExplicitStaging

-- | The columns, rows and levels of a region that may ever be loaded.
limitExtent ∷ Limits → (Int, Int, Int)
limitExtent = lExtent

-- | The most one region can occupy under this extent (a handoff's duplicate of a
-- region can be no larger).
limitRegionStoredBytes ∷ Limits → Word64
limitRegionStoredBytes l = let (x, y, z) = lExtent l in fromInteger (regionStoredBytes (toInteger x) (toInteger y) (toInteger z))

-- | The number of dispatches an eligible job may be passed over before it is
-- served with foreground priority.
limitAgingQuanta ∷ Limits → Word64
limitAgingQuanta = lAging
