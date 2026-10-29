-- | Turning a candidate profile into a 'Profile': the one validation, shared by
-- the fixed M1 profile and every injected test profile.
--
-- __What validation decides.__ In this order, the first failure wins and names
-- what failed:
--
-- 1. /Representability/: the derived products (the RGBA8 output ceiling, a
--    maximal scene's element count) fit 64 bits, computed with 'Integer' so
--    nothing wraps.
-- 2. /Ceiling/: every limit is positive and no larger than its fixed M1
--    value. An injected profile may only shrink the profile: it cannot widen a
--    ceiling, a range or a count, and no value is clamped into place.
-- 3. /Minimum/: every limit is at least the least that the engine's own schema, format and crossings need of it
--    ("Hetoimasia.LuaEngine.Profile.Minimum").
-- 4. /Relations/: the relationships the profile encodes, listed in
--    'Relation', hold for the values given.
--
-- Independently bounded maxima (for example 16 requests per instance, 2
-- instances and 64 per VM) are each bounded on their own and need not all be
-- attainable at once, so no relation ties them beyond the one that an
-- instance's bound is within its VM's.
--
-- __Ownership.__ Pure; no state.
module Hetoimasia.LuaEngine.Profile.Validate
  ( validateProfile
  , fixedM1Profile
  , ProfileError (..)
  , Relation (..)
  , DerivedValue (..)
  ) where

import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration, durationNanoseconds)
import Hetoimasia.LuaEngine.Profile.Fixed (fixedBytes, fixedCount, fixedDuration, fixedM1Spec)
import Hetoimasia.LuaEngine.Profile.Limits
import Hetoimasia.LuaEngine.Profile.Minimum (minimumBytes, minimumCount, minimumDuration)

-- | A value computed from limits rather than entered.
data DerivedValue
  = PngOutputBytes
    -- ^ The pixel limit times four bytes of RGBA8.
  | SceneElements
    -- ^ A maximal scene's elements: its fixed elements plus the sprite limit
    -- times the elements of a sprite.
  deriving (Eq, Show)

-- | A relationship between limits that a valid profile keeps.
data Relation
  = ManifestWithinHashFile
  | ModuleSourceWithinHashFile
  | HashFileWithinHashRoot
  | ActiveChainReserveHoldsModuleSource
  | ActiveChainReserveWithinSourceBank
  | ChainDepthWithinIdentities
  | RequestsPerInstanceWithinVm
  | DataWithinRetainedBank
  | DataWithinCopiedValue
  | SceneInputWithinCopiedValue
  | SceneDepthWithinCopiedDepth
  | SceneElementsWithinCopiedElements
  | FailureRecordHoldsMessageAndTraceback
  | FailureRecordHoldsInstanceId
  | SecondarySummariesWithinReport
  | SegmentWithinPath
  | PathSegmentsWithinPathBytes
  | PixelsWithinAxes
  | OutputWithinTextureBytesPerUi
  | TextureBytesPerUiWithinSession
  | OutputWithinPipelineWorkspace
  | InflatedScanlinesWithinPipelineWorkspace
  | FrameSlotsAggregateHoldsWindow
  | FrameSlotsAggregateWithinTargets
  deriving (Eq, Show, Bounded, Enum)

-- | Why a candidate is not a profile.
data ProfileError
  = DerivedOverflow !DerivedValue
  | LimitNotPositive !AnyLimit
  | LimitAboveFixed !AnyLimit !Word64 !Word64
    -- ^ The limit, the value given and the fixed ceiling. Durations are in
    -- nanoseconds.
  | LimitBelowMinimum !AnyLimit !Word64 !Word64
    -- ^ The limit, the value given and the least it may be (see "Hetoimasia.LuaEngine.Profile.Minimum").
  | RelationBroken !Relation
  deriving (Eq, Show)

-- | The fixed production profile: the fixed M1 values, through the same
-- validation as any other profile.
fixedM1Profile ∷ Profile
fixedM1Profile = case validateProfile fixedM1Spec of
  Right profile → profile
  -- The profile tests validate the fixed values, so this cannot happen.
  Left refusal → error ("the fixed M1 profile does not validate: " ++ show refusal)

-- | Validate a candidate. See the module header for the order of the checks.
validateProfile ∷ ProfileSpec → Either ProfileError Profile
validateProfile spec = do
  checkDerived spec
  checkCeilings spec
  checkMinimums spec
  checkRelations spec
  Right (buildProfile spec)

-- | The value as bytes, counts and nanoseconds, without a unit.
rawBytes ∷ Bytes → Integer
rawBytes (Bytes value) = toInteger value

rawCount ∷ Count → Integer
rawCount (Count value) = toInteger value

rawDuration ∷ Duration → Integer
rawDuration = toInteger . durationNanoseconds

fits ∷ Integer → Bool
fits value = value >= 0 && value <= toInteger (maxBound ∷ Word64)

checkDerived ∷ ProfileSpec → Either ProfileError ()
checkDerived spec
  | not (fits output) = Left (DerivedOverflow PngOutputBytes)
  | not (fits elements) = Left (DerivedOverflow SceneElements)
  | otherwise = Right ()
  where
    output = toInteger rgba8BytesPerPixel * rawCount (specCounts spec PngPixels)
    elements = toInteger sceneFixedElements + toInteger sceneElementsPerSprite * rawCount (specCounts spec SceneSprites) + toInteger sceneCallExtraElements

checkCeilings ∷ ProfileSpec → Either ProfileError ()
checkCeilings spec = do
  mapM_ (\limit → within (LimitBytes limit) (rawBytes (specBytes spec limit)) (rawBytes (fixedBytes limit))) [minBound .. maxBound]
  mapM_ (\limit → within (LimitCount limit) (rawCount (specCounts spec limit)) (rawCount (fixedCount limit))) [minBound .. maxBound]
  mapM_ (\limit → within (LimitDuration limit) (rawDuration (specDurations spec limit)) (rawDuration (fixedDuration limit))) [minBound .. maxBound]
  where
    within limit given ceiling'
      | given <= 0 = Left (LimitNotPositive limit)
      | given > ceiling' = Left (LimitAboveFixed limit (fromInteger given) (fromInteger ceiling'))
      | otherwise = Right ()

-- | Every limit is at least the least the engine's own schema, format and crossings need of it.
checkMinimums ∷ ProfileSpec → Either ProfileError ()
checkMinimums spec = do
  mapM_ (\limit → atLeast (LimitBytes limit) (rawBytes (specBytes spec limit)) (minimumBytes spec limit)) [minBound .. maxBound]
  mapM_ (\limit → atLeast (LimitCount limit) (rawCount (specCounts spec limit)) (minimumCount spec limit)) [minBound .. maxBound]
  mapM_ (\limit → atLeast (LimitDuration limit) (rawDuration (specDurations spec limit)) (minimumDuration spec limit)) [minBound .. maxBound]
  where
    atLeast limit given least
      | given < toInteger least = Left (LimitBelowMinimum limit (fromInteger given) least)
      | otherwise = Right ()

checkRelations ∷ ProfileSpec → Either ProfileError ()
checkRelations spec = case [relation | (relation, holds) ← relations spec, not holds] of
  [] → Right ()
  relation : _ → Left (RelationBroken relation)

-- | Every relation with whether it holds, in the order they are reported.
relations ∷ ProfileSpec → [(Relation, Bool)]
relations spec =
  [ (ManifestWithinHashFile, bytes ManifestBytes <= bytes HashFileBytes)
  , (ModuleSourceWithinHashFile, bytes ModuleSourceBytes <= bytes HashFileBytes)
  , (HashFileWithinHashRoot, bytes HashFileBytes <= bytes HashRootBytes)
  , (ActiveChainReserveHoldsModuleSource, bytes ModuleSourceBytes <= bytes ActiveChainReserveBytes)
  , (ActiveChainReserveWithinSourceBank, bytes ActiveChainReserveBytes <= bytes SourceBankBytes)
  , (ChainDepthWithinIdentities, count ModuleChainDepth <= count ModuleIdentitiesPerVm)
  , (RequestsPerInstanceWithinVm, count RequestsPerInstance <= count RequestsPerVm)
  , (DataWithinRetainedBank, bytes DataBytes <= bytes RetainedDataBytesPerVm)
  , (DataWithinCopiedValue, bytes DataBytes <= bytes CopiedValueBytes)
  , (SceneInputWithinCopiedValue, bytes SceneInputBytes + toInteger sceneCallExtraBytes <= bytes CopiedValueBytes)
  , (SceneDepthWithinCopiedDepth, count SceneDepth <= count CopiedValueDepth)
  , (SceneElementsWithinCopiedElements, sceneElements <= count CopiedValueElements)
  , (FailureRecordHoldsMessageAndTraceback, bytes MessageBytes + bytes TracebackBytes <= bytes RoleFailureRecordBytes)
  , (FailureRecordHoldsInstanceId, bytes InstanceIdBytes <= bytes RoleFailureRecordBytes)
  , (SecondarySummariesWithinReport, count SecondarySummaries * bytes SecondarySummaryBytes <= bytes EngineReportBytes)
  , (SegmentWithinPath, bytes PathSegmentBytes <= bytes PathBytes)
  , (PathSegmentsWithinPathBytes, count PathSegments <= bytes PathBytes)
  , (PixelsWithinAxes, count PngPixels <= count PngAxisMaximum * count PngAxisMaximum)
  , (OutputWithinTextureBytesPerUi, output <= bytes TextureBytesPerUiInstance)
  , (TextureBytesPerUiWithinSession, bytes TextureBytesPerUiInstance <= bytes TextureBytesPerSession)
  , (OutputWithinPipelineWorkspace, output <= bytes PngPipelineWorkspaceBytes)
  , (InflatedScanlinesWithinPipelineWorkspace, bytes PngInflatedScanlineBytes <= bytes PngPipelineWorkspaceBytes)
  , (FrameSlotsAggregateHoldsWindow, count FrameSlotsPerWindow <= count FrameSlotsAggregate)
  , (FrameSlotsAggregateWithinTargets, count FrameSlotsAggregate <= count NativeTargetRecords * count FrameSlotsPerWindow)
  ]
  where
    bytes = rawBytes . specBytes spec
    count = rawCount . specCounts spec
    output = toInteger rgba8BytesPerPixel * count PngPixels
    sceneElements = toInteger sceneFixedElements + toInteger sceneElementsPerSprite * count SceneSprites + toInteger sceneCallExtraElements
