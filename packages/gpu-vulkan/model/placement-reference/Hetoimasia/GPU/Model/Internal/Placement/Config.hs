-- | The validated configuration a placement allocator grows its blocks under.
--
-- It follows the admission budgets' rule (D-11): the application states plain
-- 'Integer's, and they are validated once, before an allocator exists. Zero,
-- negative, non-power-of-two and unrepresentable values are rejected and never
-- clamped, and neither is an initial block size above the maximum. A validated
-- 'PlacementConfig' is closed to clients the same way 'Budgets' is: its
-- constructor and field labels stay in this hidden module, so the sizes an
-- allocator grows by can only be ones 'validatePlacementConfig' accepted.
module Hetoimasia.GPU.Model.Internal.Placement.Config
  ( -- * Requesting a configuration
    PlacementConfigRequest (..)
  , defaultPlacementConfigRequest

    -- * The validated configuration
  , PlacementConfig
  , ConfigField (..)
  , PlacementConfigRejected (..)
  , validatePlacementConfig
  , initialBlockBytes
  , maximumBlockBytes
  , bufferImageGranularity
  , dedicatedThreshold

    -- * Inside the package
  , configInitialBlock
  , configMaximumBlock
  , configGranularity
  , configDedicatedThreshold
  , validateCapacity
  , validateGranularity
  ) where

import Data.Word (Word64)
import Hetoimasia.GPU.Model.Internal.Placement.Types (isPowerOfTwo, placementCeiling)

-- ---------------------------------------------------------------------------
-- Requesting a configuration

-- | A configuration as the application and the device state it, before
-- validation.
data PlacementConfigRequest = PlacementConfigRequest
  { requestedInitialBlockBytes ∷ !Integer
    -- ^ The size of each memory type's first block.
  , requestedMaximumBlockBytes ∷ !Integer
    -- ^ The size growth doubles up to. It also sets the dedicated threshold:
    -- half of it.
  , requestedBufferImageGranularity ∷ !Integer
    -- ^ The device's @bufferImageGranularity@: the page size linear and
    -- optimally tiled placements never share. One when the device imposes none.
  }
  deriving (Eq, Show)

-- | D-13's defaults — blocks grow from 8 MiB, doubling to 64 MiB — for a device
-- reporting the given @bufferImageGranularity@. The granularity is a property of
-- the device rather than a policy, so it has no default of its own.
defaultPlacementConfigRequest ∷ Integer → PlacementConfigRequest
defaultPlacementConfigRequest granularity =
  PlacementConfigRequest
    { requestedInitialBlockBytes = 8 * 1024 * 1024
    , requestedMaximumBlockBytes = 64 * 1024 * 1024
    , requestedBufferImageGranularity = granularity
    }

-- ---------------------------------------------------------------------------
-- The validated configuration

-- | Block sizes and a granularity every one of which is a positive power of two
-- no larger than 'placementCeiling', with the initial size no larger than the
-- maximum. Only 'validatePlacementConfig' builds one.
data PlacementConfig = PlacementConfig
  { configInitialBlock ∷ {-# UNPACK #-} !Int
  , configMaximumBlock ∷ {-# UNPACK #-} !Int
  , configGranularity ∷ {-# UNPACK #-} !Int
  }
  deriving (Eq, Show)

-- | Which field of a request a rejection is about.
data ConfigField
  = InitialBlockField
  | MaximumBlockField
  | GranularityField
  | BlockCapacityField
    -- ^ The capacity of a fixed block, which is validated by the same rules
    -- except that it need not be a power of two.
  deriving (Eq, Ord, Show)

-- | Why a requested configuration is not a configuration.
data PlacementConfigRejected
  = ConfigNotPositive !ConfigField !Integer
    -- ^ Zero or negative. Neither is clamped.
  | ConfigNotPowerOfTwo !ConfigField !Integer
    -- ^ Positive but not a power of two. It is not rounded.
  | ConfigAboveCeiling !ConfigField !Integer
    -- ^ Above 'placementCeiling', so not representable in placement arithmetic.
  | InitialAboveMaximum !Integer !Integer
    -- ^ An initial block size, then the maximum it exceeds.
  deriving (Eq, Show)

-- | Validate a requested configuration, or say which field is wrong. Fields are
-- checked in a fixed order — initial, maximum, granularity, then their
-- relation — so a request with several faults reports the same one every time.
validatePlacementConfig ∷ PlacementConfigRequest → Either PlacementConfigRejected PlacementConfig
validatePlacementConfig request = do
  initial ← powerOfTwo InitialBlockField (requestedInitialBlockBytes request)
  maximumBlock ← powerOfTwo MaximumBlockField (requestedMaximumBlockBytes request)
  granularity ← validateGranularity (requestedBufferImageGranularity request)
  if initial > maximumBlock
    then Left (InitialAboveMaximum (requestedInitialBlockBytes request) (requestedMaximumBlockBytes request))
    else Right (PlacementConfig initial maximumBlock granularity)

-- | A granularity: a positive power of two no larger than 'placementCeiling'.
validateGranularity ∷ Integer → Either PlacementConfigRejected Int
validateGranularity = powerOfTwo GranularityField

-- | A fixed block's capacity: positive and no larger than 'placementCeiling',
-- but any size, as a virtual block's may be.
validateCapacity ∷ Integer → Either PlacementConfigRejected Int
validateCapacity = representable BlockCapacityField

powerOfTwo ∷ ConfigField → Integer → Either PlacementConfigRejected Int
powerOfTwo field value = do
  checked ← representable field value
  if isPowerOfTwo value then Right checked else Left (ConfigNotPowerOfTwo field value)

representable ∷ ConfigField → Integer → Either PlacementConfigRejected Int
representable field value
  | value <= 0 = Left (ConfigNotPositive field value)
  | value > toInteger placementCeiling = Left (ConfigAboveCeiling field value)
  | otherwise = Right (fromInteger value)

-- | The size of each memory type's first block.
initialBlockBytes ∷ PlacementConfig → Word64
initialBlockBytes = fromIntegral . configInitialBlock

-- | The size growth doubles up to.
maximumBlockBytes ∷ PlacementConfig → Word64
maximumBlockBytes = fromIntegral . configMaximumBlock

-- | The device's @bufferImageGranularity@ this configuration was validated with.
bufferImageGranularity ∷ PlacementConfig → Word64
bufferImageGranularity = fromIntegral . configGranularity

-- | The smallest request that is placed as a dedicated allocation whatever the
-- driver said: half of the configured maximum block size, rounded up, so a
-- one-byte maximum dedicates every request rather than none. It is read against
-- the configured maximum, never the size of the latest block opened.
dedicatedThreshold ∷ PlacementConfig → Word64
dedicatedThreshold = fromIntegral . configDedicatedThreshold

-- | 'dedicatedThreshold' in the arithmetic a strategy computes in.
configDedicatedThreshold ∷ PlacementConfig → Int
configDedicatedThreshold config = (configMaximumBlock config + 1) `div` 2
