-- | The fixed limits of the terrain views of one graphics session (TRA-9, D-6), and the CPU allowance they reserve.
--
-- = Counts, not bytes
--
-- Every limit is a count, enforced at admission; nothing is charged per object. The CPU the views can hold is
-- bounded by those counts, and 'reservation' turns them into the one allowance the session takes from the shared
-- render/staging account at construction, with checked arithmetic ('Integer', refused before anything is made
-- when it does not fit). The figures it multiplies are declared costs, engineering estimates kept with the code,
-- whose measured peak is recorded as evidence.
--
-- Terrain vertex data, live and retiring, is bounded by @targets × slots × chunk bytes@: a chunk never holds more
-- than 'profileChunkBytes' of encoded instances and occupies one of its target's 'profileSlots' from its build to
-- its physical disposal, whether it is a candidate, drawn, retiring or failed, across a view's close and reopen.
module Hetoimasia.LuaEngine.Graphics.TerrainView.Profile
  ( ViewProfile (..)
  , defaultViewProfile
  , ProfileRefusal (..)
  , checkProfile
  , chunkInstances
  , Reservation (..)
  , reservation
  , gpuVertexBound
  , gpuVertexCeiling
  , declaredQuadBytes
  , declaredPendingBytes
  , declaredRegionBytes
  , declaredRunBytes
  , declaredSlotBytes
  , declaredControlBytes
  ) where

import Data.Word (Word64)

-- | The views' limits.
data ViewProfile = ViewProfile
  { profileTargets ∷ !Int
    -- ^ Views (one per target incarnation) open at once: @W@.
  , profileSlots ∷ !Int
    -- ^ Chunk slots of each target: @K@.
  , profileChunkBytes ∷ !Word64
    -- ^ The most encoded instance bytes one chunk holds: @C@, a whole number of 64-byte instances.
  , profileRegions ∷ !Int
    -- ^ Terrain regions one plan is copied from.
  , profileRequestRegions ∷ !Int
    -- ^ Regions one regional snapshot request asks for (at most the terrain service's hold bound).
  , profileQuads ∷ !Int
    -- ^ Quads one plan holds (the planner's instance bound).
  , profilePending ∷ !Int
    -- ^ Pending spans one plan holds.
  , profileRuns ∷ !Int
    -- ^ Input runs and intervals one plan reads: every removed interval of every copied region, a region split
    -- into several copies counted each time, and every knowledge run of a region that is not one class.
  , profileColumns ∷ !Int
    -- ^ Candidate columns one plan examines: the planner's work bound, beside its levels.
  , profileLevels ∷ !Int
    -- ^ Cell levels one plan evaluates.
  , profileStepWork ∷ !Int
    -- ^ What one planning step may examine (the planner's meter): the owner's planning quantum.
  , profileBuilds ∷ !Int
    -- ^ Chunks one owner step builds.
  }
  deriving (Eq, Show)

-- | The profile of a session with two windows: 2 targets, 128 slots of 32 KiB (512 instances) each, plans of at
-- most 16,384 quads and 8,192 pending spans copied from at most 512 regions.
defaultViewProfile ∷ ViewProfile
defaultViewProfile =
  ViewProfile
    { profileTargets = 2
    , profileSlots = 128
    , profileChunkBytes = 32 * 1024
    , profileRegions = 512
    , profileRequestRegions = 64
    , profileQuads = 16384
    , profilePending = 8192
    , profileRuns = 131072
    , profileColumns = 65536
    , profileLevels = 1048576
    , profileStepWork = 1048576
    , profileBuilds = 16
    }

-- | Why a profile cannot be used.
data ProfileRefusal
  = -- | A count is below its least usable value: the field and the value.
    ProfileTooSmall !String !Integer
  | -- | The chunk bytes are not a whole, positive number of instances.
    ProfileChunkBytes !Word64
  | -- | @targets × slots × chunk bytes@ exceeds the terrain vertex ceiling: the product and the ceiling.
    ProfileVertexBound !Integer !Integer
  | -- | One plan's quads cannot fit the target's slots: the quads and what the slots hold.
    ProfileQuadsBeyondSlots !Integer !Integer
  deriving (Eq, Show)

-- | The ceiling of terrain vertex data, live and retiring: 128 MiB.
gpuVertexCeiling ∷ Integer
gpuVertexCeiling = 128 * 1024 * 1024

-- | @targets × slots × chunk bytes@.
gpuVertexBound ∷ ViewProfile → Integer
gpuVertexBound profile = toInteger (profileTargets profile) * toInteger (profileSlots profile) * toInteger (profileChunkBytes profile)

-- | Instances one chunk holds.
chunkInstances ∷ ViewProfile → Int
chunkInstances profile = fromIntegral (profileChunkBytes profile `div` 64)

-- | Check a profile; every refusal is a configuration that can never work.
checkProfile ∷ ViewProfile → Either ProfileRefusal ViewProfile
checkProfile profile
  | Just (field, value) ← tooSmall = Left (ProfileTooSmall field value)
  | profileChunkBytes profile == 0 || profileChunkBytes profile `mod` 64 /= 0 = Left (ProfileChunkBytes (profileChunkBytes profile))
  | gpuVertexBound profile > gpuVertexCeiling = Left (ProfileVertexBound (gpuVertexBound profile) gpuVertexCeiling)
  | toInteger (profileQuads profile) > slotsHold = Left (ProfileQuadsBeyondSlots (toInteger (profileQuads profile)) slotsHold)
  | otherwise = Right profile
  where
    slotsHold = toInteger (profileSlots profile) * toInteger (chunkInstances profile)
    tooSmall = case [(name, toInteger value) | (name, value, least) ← counts, value < least] of
      found : _ → Just found
      [] → Nothing
    counts =
      [ ("targets", profileTargets profile, 1)
      , ("slots", profileSlots profile, 1)
      , ("regions", profileRegions profile, 1)
      , ("request regions", profileRequestRegions profile, 1)
      , ("quads", profileQuads profile, 1)
      , ("pending", profilePending profile, 1)
      , ("runs", profileRuns profile, 1)
      , ("columns", profileColumns profile, 1)
      , ("levels", profileLevels profile, 1)
      , ("step work", profileStepWork profile, 8192)
      , ("builds", profileBuilds profile, 1)
      ]

-- Declared costs: what each counted thing may hold on the CPU, in bytes.

-- | One planned quad, with its adaptation and its instance while the candidate is made.
declaredQuadBytes ∷ Integer
declaredQuadBytes = 512

-- | One pending span.
declaredPendingBytes ∷ Integer
declaredPendingBytes = 128

-- | One copied region's record and planner entry, beside its runs.
declaredRegionBytes ∷ Integer
declaredRegionBytes = 2048

-- | One input run or interval, as copied and as the planner's index holds it.
declaredRunBytes ∷ Integer
declaredRunBytes = 64

-- | One chunk slot's description in the registry: a full chunk's instances (192 bytes each) and its records.
declaredSlotBytes ∷ ViewProfile → Integer
declaredSlotBytes profile = toInteger (chunkInstances profile) * 192 + 4096

-- | One view's controls: its camera, intent, settlements and bookkeeping.
declaredControlBytes ∷ Integer
declaredControlBytes = 16384

-- | The allowance the views reserve once, and its parts for one target.
data Reservation = Reservation
  { reserveControls ∷ !Integer
  , reserveScratch ∷ !Integer
    -- ^ One candidate's copies, inputs and plan while it is prepared.
  , reservePins ∷ !Integer
    -- ^ The two plans a target pins: the drawn revision's and one successor's.
  , reserveSlots ∷ !Integer
    -- ^ The chunk descriptions of the target's slots.
  , reserveTotal ∷ !Integer
    -- ^ The whole allowance: every target's parts.
  }
  deriving (Eq, Show)

-- | The allowance of a profile, over 'Integer', so nothing wraps before it is compared with the account.
reservation ∷ ViewProfile → Reservation
reservation profile =
  Reservation
    { reserveControls = controls
    , reserveScratch = scratch
    , reservePins = pins
    , reserveSlots = slots
    , reserveTotal = toInteger (profileTargets profile) * (controls + scratch + pins + slots)
    }
  where
    plan = toInteger (profileQuads profile) * declaredQuadBytes + toInteger (profilePending profile) * declaredPendingBytes
    controls = declaredControlBytes
    scratch = plan + toInteger (profileRegions profile) * declaredRegionBytes + toInteger (profileRuns profile) * declaredRunBytes
    pins = 2 * plan
    slots = toInteger (profileSlots profile) * declaredSlotBytes profile
