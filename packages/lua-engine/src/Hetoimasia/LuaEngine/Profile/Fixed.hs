-- | The fixed M1 production values, defined once.
--
-- These are engineering limits fixed by the M1 assembly (P-74, accepted by
-- D-77 and D-74), never read from Lua, the manifest, the environment or the
-- command line. They are configuration values, not proof of live accounting,
-- codec allocation safety, GPU availability or a total Lua or process memory
-- cap: the later slices that own admission and retirement enforce them.
--
-- Each function is total over its limit type, so adding a limit without giving
-- its value here is a compile error. A value that is derived from others (the
-- RGBA8 output ceiling, the six adopted revisions per target) is not here: see
-- "Hetoimasia.LuaEngine.Profile.Limits".
module Hetoimasia.LuaEngine.Profile.Fixed
  ( fixedM1Spec
  , fixedBytes
  , fixedCount
  , fixedDuration
  ) where

import Data.Word (Word64)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (RequirePositive)
  , durationFromNanoseconds
  , maximumDuration
  )
import Hetoimasia.LuaEngine.Profile.Limits

-- | The fixed M1 values.
fixedM1Spec ∷ ProfileSpec
fixedM1Spec = ProfileSpec fixedBytes fixedCount fixedDuration

-- | A number of KiB, MiB or GiB. The arguments below are small literals; the
-- checked constructors in "Hetoimasia.LuaEngine.Profile.Limits" guard values
-- that come from a caller.
kib, mib, gib ∷ Word64 → Bytes
kib amount = Bytes (amount * 1024)
mib amount = Bytes (amount * 1024 * 1024)
gib amount = Bytes (amount * 1024 * 1024 * 1024)

-- | The fixed byte limits.
fixedBytes ∷ ByteLimit → Bytes
fixedBytes limit = case limit of
  ManifestBytes → kib 64
  PathBytes → Bytes 1024
  PathSegmentBytes → Bytes 255
  HashFileBytes → mib 64
  HashRootBytes → gib 1
  HashBufferBytes → kib 64
  ModuleSourceBytes → mib 1
  SourceBankBytes → mib 16
  ActiveChainReserveBytes → mib 1
  DataBytes → mib 8
  RetainedDataBytesPerVm → mib 64
  CopiedValueBytes → mib 16
  SceneInputBytes → mib 2
  MessageBytes → kib 2
  TracebackBytes → kib 8
  RoleFailureRecordBytes → kib 16
  InstanceIdBytes → Bytes 128
  EngineReportBytes → kib 64
  SecondarySummaryBytes → kib 2
  PrintWarnBytes → kib 4
  PngEncodedBytes → mib 32
  PngInflatedScanlineBytes → mib 40
  PngPipelineWorkspaceBytes → mib 128
  TextureBytesPerUiInstance → mib 128
  TextureBytesPerSession → mib 256
  WindowTitleBytes → Bytes 512
  NativeAccountedBytes → gib 2

-- | The fixed count limits.
fixedCount ∷ CountLimit → Count
fixedCount limit = Count $ case limit of
  ManifestDepth → 8
  InventoryEntries → 10000
  PathSegments → 32
  ModuleIdentitiesPerVm → 256
  ModuleChainDepth → 32
  InstancesPerVm → 2
  LauncherRootsPerRole → 1
  RequestsPerInstance → 16
  RequestsPerVm → 64
  CopiedValueDepth → 8
  CopiedValueElements → 65536
  SceneSprites → 4096
  SceneDepth → 4
  LatestScenesPerWindow → 1
  PublicationDraftsPerWindow → 1
  SecondarySummaries → 16
  PngChunks → 4096
  PngAxisMaximum → 2048
  PngPixels → 4194304
  TextureLeasesPerUiInstance → 16
  WindowSlotsPerUiInstance → 1
  WindowExtentMaximum → 4096
  CoordinateMagnitude → 1000000
  SpriteExtentMaximum → 1000000
  NativeTargetRecords → 2
  FrameSlotsPerWindow → 2
  FrameSlotsAggregate → 4
  FramelessBatches → 4
  GenerationsPerTarget → 2
  TrackedImagesPerGeneration → 16
  NativeObjects → 4096
  ReclaimPassRecords → 64
  ProgressActionsPerTurn → 32
  IoWorkers → 2
  DecodeWorkers → 1
  TexturePipelineLanes → 2
  LuaIntegerMaximum → 9223372036854775807

-- | The fixed duration limits: the manifest tick through the full positive
-- Word64 nanosecond range, and a 100 ms idle backoff.
fixedDuration ∷ DurationLimit → Duration
fixedDuration limit = case limit of
  ManifestTickMaximum → maximumDuration
  MaximumIdleBackoff → case durationFromNanoseconds RequirePositive 100000000 of
    Right duration → duration
    -- 100 ms is a positive literal far below the maximum, so this cannot
    -- happen; the profile tests read the value back.
    Left rejected → error ("the fixed idle backoff is not a duration: " ++ show rejected)
