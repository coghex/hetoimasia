{-# LANGUAGE OverloadedStrings #-}

-- | The fixed M1 profile and the validation of injected ones: every fixed value
-- against an independently written expectation in its unit, the derived values,
-- valid smaller profiles, and profiles refused as not positive, above the
-- fixed value, overflowing or inconsistent. Nothing here touches the
-- filesystem or a native service.
module Test.LuaEngine.Profile (spec) where

import Data.Word (Word64)
import Data.List (isInfixOf)
import Hetoimasia.Foundation.Time (Duration, durationNanoseconds, maximumDuration, zeroDuration)
import Hetoimasia.LuaEngine.Profile
import Test.Hspec
import Test.LuaEngine.Support (nanoseconds)

-- | KiB, MiB and GiB, written as powers of two rather than the implementation's
-- own constructors.
kib, mib, gib ∷ Word64
kib = 2 ^ (10 ∷ Int)
mib = 2 ^ (20 ∷ Int)
gib = 2 ^ (30 ∷ Int)

-- | The approved bytes, one entry for each byte limit, written from the issue's
-- table in the table's own units.
expectedBytes ∷ [(ByteLimit, Word64)]
expectedBytes =
  [ (ManifestBytes, 64 * kib)
  , (PathBytes, 1024)
  , (PathSegmentBytes, 255)
  , (HashFileBytes, 64 * mib)
  , (HashRootBytes, 1 * gib)
  , (HashBufferBytes, 64 * kib)
  , (ModuleSourceBytes, 1 * mib)
  , (SourceBankBytes, 16 * mib)
  , (ActiveChainReserveBytes, 1 * mib)
  , (DataBytes, 8 * mib)
  , (RetainedDataBytesPerVm, 64 * mib)
  , (CopiedValueBytes, 16 * mib)
  , (SceneInputBytes, 2 * mib)
  , (MessageBytes, 2 * kib)
  , (TracebackBytes, 8 * kib)
  , (RoleFailureRecordBytes, 16 * kib)
  , (InstanceIdBytes, 128)
  , (EngineReportBytes, 64 * kib)
  , (SecondarySummaryBytes, 2 * kib)
  , (PrintWarnBytes, 4 * kib)
  , (PngEncodedBytes, 32 * mib)
  , (PngInflatedScanlineBytes, 40 * mib)
  , (PngPipelineWorkspaceBytes, 128 * mib)
  , (TextureBytesPerUiInstance, 128 * mib)
  , (TextureBytesPerSession, 256 * mib)
  , (WindowTitleBytes, 512)
  , (NativeAccountedBytes, 2 * gib)
  ]

-- | The approved counts, indices and magnitudes.
expectedCounts ∷ [(CountLimit, Word64)]
expectedCounts =
  [ (ManifestDepth, 8)
  , (InventoryEntries, 10000)
  , (PathSegments, 32)
  , (ModuleIdentitiesPerVm, 256)
  , (ModuleChainDepth, 32)
  , (InstancesPerVm, 2)
  , (LauncherRootsPerRole, 1)
  , (RequestsPerInstance, 16)
  , (RequestsPerVm, 64)
  , (CopiedValueDepth, 8)
  , (CopiedValueElements, 65536)
  , (SceneSprites, 4096)
  , (SceneDepth, 4)
  , (LatestScenesPerWindow, 1)
  , (PublicationDraftsPerWindow, 1)
  , (SecondarySummaries, 16)
  , (PngChunks, 4096)
  , (PngAxisMaximum, 2048)
  , (PngPixels, 4194304)
  , (TextureLeasesPerUiInstance, 16)
  , (WindowSlotsPerUiInstance, 1)
  , (WindowExtentMaximum, 4096)
  , (CoordinateMagnitude, 1000000)
  , (SpriteExtentMaximum, 1000000)
  , (NativeTargetRecords, 2)
  , (FrameSlotsPerWindow, 2)
  , (FrameSlotsAggregate, 4)
  , (FramelessBatches, 4)
  , (GenerationsPerTarget, 2)
  , (TrackedImagesPerGeneration, 16)
  , (NativeObjects, 4096)
  , (ReclaimPassRecords, 64)
  , (ProgressActionsPerTurn, 32)
  , (IoWorkers, 2)
  , (DecodeWorkers, 1)
  , (TexturePipelineLanes, 2)
  , (LuaIntegerMaximum, 2 ^ (63 ∷ Int) - 1)
  ]

-- | The approved durations, in nanoseconds.
expectedDurations ∷ [(DurationLimit, Integer)]
expectedDurations =
  [ (ManifestTickMaximum, 2 ^ (64 ∷ Int) - 1)
  , (MaximumIdleBackoff, 100 * 1000 * 1000)
  ]

rawBytes ∷ Bytes → Word64
rawBytes (Bytes value) = value

rawCount ∷ Count → Word64
rawCount (Count value) = value

nanosecondsOf ∷ Duration → Integer
nanosecondsOf = toInteger . durationNanoseconds

fixedSpec ∷ ProfileSpec
fixedSpec = profileSpec fixedM1Profile

-- | Only whether a candidate is refused, and why. A mismatch then prints a short
-- refusal, never a whole profile.
verdict ∷ ProfileSpec → Either ProfileError ()
verdict = fmap (const ()) . validateProfile

setBytes ∷ ByteLimit → Word64 → ProfileSpec → ProfileSpec
setBytes target value base = base {specBytes = \limit → if limit == target then Bytes value else specBytes base limit}

setCount ∷ CountLimit → Word64 → ProfileSpec → ProfileSpec
setCount target value base = base {specCounts = \limit → if limit == target then Count value else specCounts base limit}

setDuration ∷ DurationLimit → Duration → ProfileSpec → ProfileSpec
setDuration target value base = base {specDurations = \limit → if limit == target then value else specDurations base limit}

-- | Change one limit to a value, whatever its unit.
setLimit ∷ AnyLimit → Word64 → ProfileSpec → ProfileSpec
setLimit limit value = case limit of
  LimitBytes l → setBytes l value
  LimitCount l → setCount l value
  LimitDuration l → setDuration l (nanoseconds (toInteger value))

-- | A limit's fixed value, whatever its unit.
fixedValue ∷ AnyLimit → Word64
fixedValue limit = case limit of
  LimitBytes l → rawBytes (bytesLimit fixedM1Profile l)
  LimitCount l → rawCount (countLimit fixedM1Profile l)
  LimitDuration l → fromInteger (nanosecondsOf (durationLimit fixedM1Profile l))

allLimits ∷ [AnyLimit]
allLimits = map LimitBytes [minBound .. maxBound] <> map LimitCount [minBound .. maxBound] <> map LimitDuration [minBound .. maxBound]

-- | A smaller profile that keeps every relation: a tiny manifest, a tiny scene
-- and tiny images.
smallSpec ∷ ProfileSpec
smallSpec =
  setBytes ManifestBytes 128
    . setCount ManifestDepth 3
    . setCount SceneSprites 2
    . setCount PngPixels 16
    . setCount PngAxisMaximum 4
    . setCount WindowExtentMaximum 64
    . setCount RequestsPerVm 16
    . setCount InstancesPerVm 1
    . setBytes HashFileBytes mib
    . setBytes HashRootBytes (2 * mib)
    . setDuration MaximumIdleBackoff (nanoseconds 1000000)
    $ fixedSpec

-- | A candidate that violates exactly one relation: the limits to shrink.
relationCases ∷ [(Relation, [(AnyLimit, Word64)])]
relationCases =
  [ (ManifestWithinHashFile, [(LimitBytes HashFileBytes, 1)])
  , (ModuleSourceWithinHashFile, [(LimitBytes ManifestBytes, 1), (LimitBytes HashFileBytes, kib)])
  , (HashFileWithinHashRoot, [(LimitBytes HashRootBytes, mib)])
  , (ActiveChainReserveHoldsModuleSource, [(LimitBytes ActiveChainReserveBytes, kib)])
  , (ActiveChainReserveWithinSourceBank, [(LimitBytes SourceBankBytes, mib `div` 2)])
  , (ChainDepthWithinIdentities, [(LimitCount ModuleIdentitiesPerVm, 16)])
  , (RequestsPerInstanceWithinVm, [(LimitCount RequestsPerVm, 8)])
  , (DataWithinRetainedBank, [(LimitBytes RetainedDataBytesPerVm, mib)])
  , (DataWithinCopiedValue, [(LimitBytes CopiedValueBytes, 4 * mib)])
  , (SceneInputWithinCopiedValue, [(LimitBytes DataBytes, mib `div` 2), (LimitBytes CopiedValueBytes, mib)])
  , (SceneDepthWithinCopiedDepth, [(LimitCount CopiedValueDepth, 2)])
  , (SceneElementsWithinCopiedElements, [(LimitCount CopiedValueElements, 1000)])
  , (FailureRecordHoldsMessageAndTraceback, [(LimitBytes RoleFailureRecordBytes, 8 * kib)])
  , (FailureRecordHoldsInstanceId, [(LimitBytes MessageBytes, 1), (LimitBytes TracebackBytes, 1), (LimitBytes RoleFailureRecordBytes, 64)])
  , (SecondarySummariesWithinReport, [(LimitBytes EngineReportBytes, 16 * kib)])
  , (SegmentWithinPath, [(LimitBytes PathBytes, 100)])
  , (PathSegmentsWithinPathBytes, [(LimitBytes PathBytes, 16), (LimitBytes PathSegmentBytes, 8)])
  , (PixelsWithinAxes, [(LimitCount PngAxisMaximum, 1024)])
  , (OutputWithinTextureBytesPerUi, [(LimitBytes TextureBytesPerUiInstance, 8 * mib)])
  , (TextureBytesPerUiWithinSession, [(LimitBytes TextureBytesPerSession, 64 * mib)])
  , (OutputWithinPipelineWorkspace, [(LimitBytes PngPipelineWorkspaceBytes, 8 * mib)])
  , (InflatedScanlinesWithinPipelineWorkspace, [(LimitBytes PngPipelineWorkspaceBytes, 32 * mib)])
  , (FrameSlotsAggregateHoldsWindow, [(LimitCount FrameSlotsAggregate, 1)])
  , (FrameSlotsAggregateWithinTargets, [(LimitCount NativeTargetRecords, 1)])
  ]

spec ∷ Spec
spec = describe "the M1 profile" $ do
  describe "the fixed values" $ do
    it "has an expectation for every limit of every unit, and no other" $ do
      map fst expectedBytes `shouldBe` [minBound .. maxBound]
      map fst expectedCounts `shouldBe` [minBound .. maxBound]
      map fst expectedDurations `shouldBe` [minBound .. maxBound]

    it "holds every byte limit at its approved value" $
      mapM_ (\(limit, value) → (limit, rawBytes (bytesLimit fixedM1Profile limit)) `shouldBe` (limit, value)) expectedBytes

    it "holds every count, index and magnitude at its approved value" $
      mapM_ (\(limit, value) → (limit, rawCount (countLimit fixedM1Profile limit)) `shouldBe` (limit, value)) expectedCounts

    it "holds every duration at its approved value, in nanoseconds" $
      mapM_ (\(limit, value) → (limit, nanosecondsOf (durationLimit fixedM1Profile limit)) `shouldBe` (limit, value)) expectedDurations

    it "has the full positive 64-bit range for the manifest tick" $
      durationLimit fixedM1Profile ManifestTickMaximum `shouldBe` maximumDuration

    it "is the fixed specification, validated like any other" $ do
      fmap (const ()) (validateProfile fixedSpec) `shouldBe` Right ()
      fmap (== fixedM1Profile) (validateProfile fixedSpec) `shouldBe` Right True

    it "derives the RGBA8 output ceiling from the pixel limit instead of storing it" $ do
      pngOutputBytes fixedM1Profile `shouldBe` Bytes (16 * mib)
      rawBytes (pngOutputBytes fixedM1Profile) `shouldBe` 4194304 * 4
      rawCount (countLimit fixedM1Profile PngPixels) `shouldBe` rawCount (countLimit fixedM1Profile PngAxisMaximum) ^ (2 ∷ Int)
      rgba8BytesPerPixel `shouldBe` 4

    it "derives a maximal scene's elements from the sprite limit, within the copied-value ceiling" $ do
      sceneElementBound fixedM1Profile `shouldBe` Count (6 + 6 * 4096)
      sceneElementBound fixedM1Profile `shouldSatisfy` (<= countLimit fixedM1Profile CopiedValueElements)

    it "records the two frame slots per window and does not store the derived six adopted revisions" $ do
      countLimit fixedM1Profile FrameSlotsPerWindow `shouldBe` Count 2
      -- The limit types are the whole vocabulary: nothing is named for adopted revisions.
      map show ([minBound .. maxBound] ∷ [CountLimit]) `shouldSatisfy` all (not . isInfixOf "dopted")

    it "keeps the independently bounded request limits as approved, 64 per VM against 16 per instance" $ do
      countLimit fixedM1Profile RequestsPerVm `shouldBe` Count 64
      countLimit fixedM1Profile RequestsPerInstance `shouldBe` Count 16

  describe "building units" $ do
    it "constructs KiB, MiB and GiB as powers of 1024, checked" $ do
      kibibytes 64 `shouldBe` Just (Bytes 65536)
      mebibytes 64 `shouldBe` Just (Bytes (64 * 1024 * 1024))
      gibibytes 2 `shouldBe` Just (Bytes (2 * 1024 * 1024 * 1024))
      kibibytes 0 `shouldBe` Just (Bytes 0)

    it "refuses a product that does not fit 64 bits" $ do
      kibibytes maxBound `shouldBe` Nothing
      mebibytes maxBound `shouldBe` Nothing
      gibibytes maxBound `shouldBe` Nothing
      gibibytes (2 ^ (34 ∷ Int) - 1) `shouldBe` Just (Bytes (2 ^ (64 ∷ Int) - 2 ^ (30 ∷ Int)))
      gibibytes (2 ^ (34 ∷ Int)) `shouldBe` Nothing
      kibibytes (2 ^ (54 ∷ Int)) `shouldBe` Nothing

  describe "smaller injected profiles" $ do
    it "accepts a smaller profile that keeps every relation, and reads back what was given" $ do
      case validateProfile smallSpec of
        Left refusal → expectationFailure ("a valid smaller profile was refused: " <> show refusal)
        Right profile → do
          bytesLimit profile ManifestBytes `shouldBe` Bytes 128
          countLimit profile ManifestDepth `shouldBe` Count 3
          countLimit profile SceneSprites `shouldBe` Count 2
          durationLimit profile MaximumIdleBackoff `shouldBe` nanoseconds 1000000
          pngOutputBytes profile `shouldBe` Bytes 64
          sceneElementBound profile `shouldBe` Count 18
          -- Limits not changed keep their fixed values.
          bytesLimit profile ModuleSourceBytes `shouldBe` Bytes mib

    it "accepts every limit at its fixed value: the ceiling itself is valid" $
      mapM_ (\limit → (limit, fmap (const ()) (validateProfile (setLimit limit (fixedValue limit) fixedSpec))) `shouldBe` (limit, Right ())) allLimits

    it "refuses every limit one past its fixed value, naming the limit, the value and the ceiling" $
      mapM_
        ( \limit →
            let ceilingValue = fixedValue limit
             in case limit of
                  LimitDuration ManifestTickMaximum → pure () -- the maximum duration has nothing above it
                  _ →
                    (limit, verdict (setLimit limit (ceilingValue + 1) fixedSpec))
                      `shouldBe` (limit, Left (LimitAboveFixed limit (ceilingValue + 1) ceilingValue))
        )
        allLimits

    it "refuses every limit that is zero" $
      mapM_
        (\limit → (limit, verdict (setLimit limit 0 fixedSpec)) `shouldBe` (limit, Left (LimitNotPositive limit)))
        [limit | limit ← allLimits, not (isDuration limit)]

    it "refuses a zero duration" $ do
      validateProfile (setDuration MaximumIdleBackoff (nanoseconds 1) fixedSpec) `shouldSatisfy` either (const False) (const True)
      let zero = zeroDuration
      verdict (setDuration MaximumIdleBackoff zero fixedSpec) `shouldBe` Left (LimitNotPositive (LimitDuration MaximumIdleBackoff))
      verdict (setDuration ManifestTickMaximum zero fixedSpec) `shouldBe` Left (LimitNotPositive (LimitDuration ManifestTickMaximum))

    it "refuses a wider range than the fixed one" $ do
      verdict (setCount CoordinateMagnitude 1000001 fixedSpec) `shouldBe` Left (LimitAboveFixed (LimitCount CoordinateMagnitude) 1000001 1000000)
      verdict (setCount PngAxisMaximum 2049 fixedSpec) `shouldBe` Left (LimitAboveFixed (LimitCount PngAxisMaximum) 2049 2048)
      verdict (setCount WindowExtentMaximum 4097 fixedSpec) `shouldBe` Left (LimitAboveFixed (LimitCount WindowExtentMaximum) 4097 4096)
      verdict (setCount LuaIntegerMaximum (2 ^ (63 ∷ Int)) fixedSpec) `shouldBe` Left (LimitAboveFixed (LimitCount LuaIntegerMaximum) (2 ^ (63 ∷ Int)) (2 ^ (63 ∷ Int) - 1))
      verdict (setCount LuaIntegerMaximum maxBound fixedSpec) `shouldBe` Left (LimitAboveFixed (LimitCount LuaIntegerMaximum) maxBound (2 ^ (63 ∷ Int) - 1))

    it "refuses a derived product that does not fit 64 bits before it reaches any other check" $ do
      verdict (setCount PngPixels (maxBound `div` 2) fixedSpec) `shouldBe` Left (DerivedOverflow PngOutputBytes)
      verdict (setCount PngPixels maxBound fixedSpec) `shouldBe` Left (DerivedOverflow PngOutputBytes)
      verdict (setCount SceneSprites maxBound fixedSpec) `shouldBe` Left (DerivedOverflow SceneElements)
      verdict (setCount SceneSprites (maxBound `div` 6) fixedSpec) `shouldBe` Left (DerivedOverflow SceneElements)
      verdict (setCount PngPixels (2 ^ (62 ∷ Int)) fixedSpec) `shouldBe` Left (DerivedOverflow PngOutputBytes)
      verdict (setCount PngPixels (2 ^ (62 ∷ Int) - 1) fixedSpec) `shouldBe` Left (LimitAboveFixed (LimitCount PngPixels) (2 ^ (62 ∷ Int) - 1) 4194304)

    it "has a case for every relation, and refuses each with the relation's name" $ do
      map fst relationCases `shouldBe` [minBound .. maxBound]
      mapM_
        ( \(relation, shrinks) →
            let candidate = foldr (\(limit, value) → setLimit limit value) fixedSpec shrinks
             in (relation, verdict candidate) `shouldBe` (relation, Left (RelationBroken relation))
        )
        relationCases

    it "does not clamp: a refused profile yields no profile at all" $ do
      validateProfile (setBytes HashFileBytes 1 fixedSpec) `shouldSatisfy` either (const True) (const False)
      validateProfile (setCount PngPixels 0 fixedSpec) `shouldSatisfy` either (const True) (const False)
  where
    isDuration limit = case limit of
      LimitDuration _ → True
      _ → False
