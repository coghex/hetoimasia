-- | Validated residency limits. The constructor of 'Limits' is private: the
-- only ways to a value are 'mkLimits' and 'defaultLimits', so a limit that is
-- zero, unrepresentable or inconsistent never reaches the model, and a client
-- cannot rewrite a validated figure with record-update syntax.
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
  , limitDemandRegions
  , limitAgingQuanta
  ) where

import Data.Word (Word64)

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
  , specDemandRegions ∷ !Integer
  , specAgingQuanta ∷ !Integer
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
  | FieldDemandRegions
  | FieldAgingQuanta
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Why a limit was refused. A permanently invalid limit is never clamped.
data LimitError
  = -- | The limit is zero or negative: no request could ever fit it.
    LimitNotPositive !LimitField !Integer
  | -- | The limit exceeds 'limitCeiling' and cannot be represented with room for
    -- checked arithmetic.
    LimitUnrepresentable !LimitField !Integer
  deriving stock (Eq, Show)

-- | A validated set of limits.
data Limits = Limits
  { lResident ∷ !Word64
  , lEdit ∷ !Word64
  , lStaging ∷ !Word64
  , lJobs ∷ !Word64
  , lCommands ∷ !Word64
  , lPins ∷ !Word64
  , lDemand ∷ !Word64
  , lAging ∷ !Word64
  }
  deriving stock (Eq, Show)

-- | The largest accepted limit, @2^40@. Every sum the model forms is of a few
-- terms bounded by limits and counts, so it stays far below @2^64@ and is
-- additionally computed with checked arithmetic.
limitCeiling ∷ Integer
limitCeiling = 2 ^ (40 ∷ Int)

-- | Validate a specification. The first refused field, in declaration order, is
-- reported. A limit smaller than any single unit charge is accepted: it makes
-- every request that needs that unit permanently invalid, which is reported
-- per request, not here.
mkLimits ∷ LimitsSpec → Either LimitError Limits
mkLimits spec = do
  resident ← check FieldResidentBytes (specResidentBytes spec)
  edit ← check FieldEditBytes (specEditBytes spec)
  staging ← check FieldStagingBytes (specStagingBytes spec)
  jobs ← check FieldLoadJobs (specLoadJobs spec)
  commands ← check FieldQueuedCommands (specQueuedCommands spec)
  pins ← check FieldPinsPerView (specPinsPerView spec)
  demand ← check FieldDemandRegions (specDemandRegions spec)
  aging ← check FieldAgingQuanta (specAgingQuanta spec)
  pure (Limits resident edit staging jobs commands pins demand aging)
  where
    check field n
      | n <= 0 = Left (LimitNotPositive field n)
      | n > limitCeiling = Left (LimitUnrepresentable field n)
      | otherwise = Right (fromInteger n)

-- | The approved initial CPU limits: 64 MiB resident terrain, 32 MiB retained
-- session edits, 64 MiB CPU render and staging, 128 load jobs, 256 queued
-- commands and two pinned view revisions per view, with at most 1,024 regions
-- in one demand description and an aging threshold of 8 service quanta.
defaultLimits ∷ Limits
defaultLimits =
  Limits
    { lResident = 64 * mib
    , lEdit = 32 * mib
    , lStaging = 64 * mib
    , lJobs = 128
    , lCommands = 256
    , lPins = 2
    , lDemand = 1024
    , lAging = 8
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

-- | The most regions one demand description may name.
limitDemandRegions ∷ Limits → Word64
limitDemandRegions = lDemand

-- | The number of dispatches an eligible job may be passed over before it is
-- served with foreground priority.
limitAgingQuanta ∷ Limits → Word64
limitAgingQuanta = lAging
