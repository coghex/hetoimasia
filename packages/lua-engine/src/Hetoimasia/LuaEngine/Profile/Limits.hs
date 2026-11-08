-- | The vocabulary of the fixed M1 profile: units, the closed set of limits
-- each unit names, the specification a profile is built from, and the validated
-- profile.
--
-- __Why enumerations.__ Every limit is one constructor of one of three closed
-- types (bytes, counts, durations), and a specification is a total function
-- from the constructors to values. Completeness is therefore the compiler's:
-- the fixed profile's definition is a @case@ that must name every limit, and
-- validation and tests walk @[minBound ..]@, so a limit added later cannot be
-- left out of a check. The unit a value carries is its type, so a byte limit
-- cannot be read as a count.
--
-- __Ownership.__ A 'Profile' is immutable. It is built only by
-- "Hetoimasia.LuaEngine.Profile.Validate", which is the one place that decides
-- whether a specification is a valid profile, so a 'Profile' in hand is always
-- one that passed. This module holds no policy.
module Hetoimasia.LuaEngine.Profile.Limits
  ( -- * Units
    Bytes (..)
  , Count (..)
  , kibibytes
  , mebibytes
  , gibibytes

    -- * The limits
  , ByteLimit (..)
  , CountLimit (..)
  , DurationLimit (..)
  , AnyLimit (..)

    -- * Specifications and profiles
  , ProfileSpec (..)
  , Profile (..)
  , bytesLimit
  , countLimit
  , durationLimit
  , profileSpec
  , buildProfile

    -- * Derived values
  , rgba8BytesPerPixel
  , pngOutputBytes
  , textureMinimumChargeBytes
  , textureChargeBytes
  , textureReservationBytes
  , textureRoomPerInstance
  , textureRoomPerSession
  , sceneElementBound
  , sceneFixedElements
  , sceneElementsPerSprite
  , sceneCallExtraElements
  , sceneCallExtraBytes
  , sceneCallElementBound
  ) where

import Data.Array (Array, Ix, listArray, (!))
import Data.Word (Word64)
import Hetoimasia.Foundation.Time (Duration)

-- | A number of bytes.
newtype Bytes = Bytes Word64
  deriving (Eq, Ord, Show)

-- | A number of things: entries, requests, workers, sprites.
newtype Count = Count Word64
  deriving (Eq, Ord, Show)

-- | KiB, MiB and GiB are powers of 1024. These construct a byte count from a
-- number of that unit, or nothing when it does not fit 64 bits.
kibibytes, mebibytes, gibibytes ∷ Word64 → Maybe Bytes
kibibytes = scaled 1024
mebibytes = scaled (1024 * 1024)
gibibytes = scaled (1024 * 1024 * 1024)

scaled ∷ Integer → Word64 → Maybe Bytes
scaled unit amount
  | product' <= toInteger (maxBound ∷ Word64) = Just (Bytes (fromInteger product'))
  | otherwise = Nothing
  where
    product' = unit * toInteger amount

-- | The limits measured in bytes.
data ByteLimit
  = ManifestBytes
    -- ^ The manifest file.
  | PathBytes
    -- ^ A content path in UTF-8, on both its supplied/native and NFC forms.
  | PathSegmentBytes
    -- ^ One segment of a content path, on both forms.
  | HashFileBytes
    -- ^ One regular file the startup hashing reads.
  | HashRootBytes
    -- ^ The sum of the file bytes hashed under one root, counted by path.
  | HashBufferBytes
    -- ^ The streaming buffer.
  | ModuleSourceBytes
    -- ^ One module's source.
  | SourceBankBytes
    -- ^ Uncompiled source held by one VM.
  | ActiveChainReserveBytes
    -- ^ The part of the source bank reserved for the active chain's next source.
  | DataBytes
    -- ^ One data file or result.
  | RetainedDataBytesPerVm
    -- ^ Data-provider and result bytes one VM retains.
  | CopiedValueBytes
    -- ^ The encoded bytes of one copied value crossing.
  | SceneInputBytes
    -- ^ The encoded input of one scene.
  | MessageBytes
    -- ^ A failure message.
  | TracebackBytes
    -- ^ A failure traceback.
  | RoleFailureRecordBytes
    -- ^ A complete role-failure record.
  | InstanceIdBytes
    -- ^ An opaque instance identifier, in UTF-8.
  | EngineReportBytes
    -- ^ The engine failure report.
  | SecondarySummaryBytes
    -- ^ One retained secondary cleanup summary.
  | PrintWarnBytes
    -- ^ One @print@ or @warn@ call.
  | PngEncodedBytes
    -- ^ An encoded PNG.
  | PngInflatedScanlineBytes
    -- ^ A PNG's decompressed scanline bytes.
  | PngPipelineWorkspaceBytes
    -- ^ Accounted CPU payload and workspace of one texture pipeline.
  | TextureBytesPerUiInstance
    -- ^ Nominal bytes of the textures one UI instance holds, pending, live and retiring. The /only/ bound on how
    -- much one instance may hold: there is no count of textures (see 'textureMinimumChargeBytes').
  | TextureBytesPerSession
    -- ^ Nominal bytes of the textures the session holds, in the same sense.
  | WindowTitleBytes
    -- ^ A window title, in UTF-8.
  | NativeAccountedBytes
    -- ^ Accounted native GPU bytes.
  deriving (Eq, Ord, Show, Bounded, Enum, Ix)

-- | The limits that are counts, indices or magnitudes.
data CountLimit
  = ManifestDepth
    -- ^ Nested containers, counting the outer object.
  | InventoryEntries
    -- ^ Inventory entries, root and directories included.
  | PathSegments
    -- ^ Segments of a content path.
  | ModuleIdentitiesPerVm
    -- ^ Cache identities of one VM, pending and failed included.
  | ModuleChainDepth
    -- ^ The active import chain, its root included.
  | InstancesPerVm
    -- ^ Assembly instances per VM.
  | LauncherRootsPerRole
    -- ^ Roots the normal launcher creates for each declared role.
  | RequestsPerInstance
    -- ^ Accepted, unretired requests of one instance.
  | RequestsPerVm
    -- ^ Accepted, unretired requests of one VM.
  | CopiedValueDepth
    -- ^ Nesting of a copied value.
  | CopiedValueElements
    -- ^ Elements of a copied value.
  | SceneSprites
    -- ^ Sprites in one scene.
  | SceneDepth
    -- ^ Nesting of a scene's encoded input.
  | LatestScenesPerWindow
    -- ^ Latest scenes kept for a window; there is no publication queue.
  | PublicationDraftsPerWindow
    -- ^ Bounded publication drafts for a window.
  | SecondarySummaries
    -- ^ Secondary cleanup summaries the engine report retains.
  | PngChunks
    -- ^ Chunks of a PNG.
  | PngAxisMaximum
    -- ^ A PNG axis, in texels; the minimum is 1.
  | PngPixels
    -- ^ Pixels of a PNG.
  | WindowSlotsPerUiInstance
    -- ^ Pending, live and retiring windows of one UI instance.
  | WindowExtentMaximum
    -- ^ A requested window width or height; the minimum is 1.
  | CoordinateMagnitude
    -- ^ A sprite's x or y lies in the closed range of minus to plus this.
  | SpriteExtentMaximum
    -- ^ A sprite's width or height lies in zero (exclusive) to this.
  | NativeTargetRecords
    -- ^ Target records of the native budget.
  | FrameSlotsPerWindow
    -- ^ Frame slots of one window.
  | FrameSlotsAggregate
    -- ^ Frame slots across windows.
  | FramelessBatches
    -- ^ Frameless batches.
  | GenerationsPerTarget
    -- ^ Generations of one target.
  | TrackedImagesPerGeneration
    -- ^ Images one generation tracks.
  | NativeObjects
    -- ^ Accounted native objects.
  | ReclaimPassRecords
    -- ^ Records one reclaim pass visits.
  | ProgressActionsPerTurn
    -- ^ Progress actions one owner turn takes.
  | IoWorkers
    -- ^ File-I/O workers of the session.
  | DecodeWorkers
    -- ^ CPU decode workers of the session.
  | TexturePipelineLanes
    -- ^ Texture pipeline lanes spanning read, decode, upload and retirement.
  | LuaIntegerMaximum
    -- ^ The largest logical tick, cadence, offset, wait count or generated
    -- public counter; init tick is 0 and positive counts begin at 1.
  deriving (Eq, Ord, Show, Bounded, Enum, Ix)

-- | The limits that are spans of time.
data DurationLimit
  = ManifestTickMaximum
    -- ^ The largest @tick_seconds@, from 1 ns to this.
  | MaximumIdleBackoff
    -- ^ The longest idle backoff.
  deriving (Eq, Ord, Show, Bounded, Enum, Ix)

-- | Any limit, as a refusal names it.
data AnyLimit
  = LimitBytes !ByteLimit
  | LimitCount !CountLimit
  | LimitDuration !DurationLimit
  deriving (Eq, Show)

-- | A candidate profile: a value for every limit. Only 'validateProfile' in
-- "Hetoimasia.LuaEngine.Profile" turns one into a 'Profile'.
data ProfileSpec = ProfileSpec
  { specBytes ∷ ByteLimit → Bytes
  , specCounts ∷ CountLimit → Count
  , specDurations ∷ DurationLimit → Duration
  }

-- | A validated profile.
data Profile = ProfileData
  { profileByteValues ∷ !(Array ByteLimit Bytes)
  , profileCountValues ∷ !(Array CountLimit Count)
  , profileDurationValues ∷ !(Array DurationLimit Duration)
  }
  deriving (Eq)

instance Show Profile where
  showsPrec precedence profile =
    showParen (precedence > 10) $
      showString "Profile "
        . shows [(limit, bytesLimit profile limit) | limit ← [minBound .. maxBound]]
        . showChar ' '
        . shows [(limit, countLimit profile limit) | limit ← [minBound .. maxBound]]
        . showChar ' '
        . shows [(limit, durationLimit profile limit) | limit ← [minBound .. maxBound]]

-- | The profile's value for a byte limit.
bytesLimit ∷ Profile → ByteLimit → Bytes
bytesLimit profile = (profileByteValues profile !)

-- | The profile's value for a count limit.
countLimit ∷ Profile → CountLimit → Count
countLimit profile = (profileCountValues profile !)

-- | The profile's value for a duration limit.
durationLimit ∷ Profile → DurationLimit → Duration
durationLimit profile = (profileDurationValues profile !)

-- | The profile's values as a specification, for deriving a smaller one.
profileSpec ∷ Profile → ProfileSpec
profileSpec profile = ProfileSpec (bytesLimit profile) (countLimit profile) (durationLimit profile)

-- | Snapshot a specification. Used only by validation, after it has passed.
buildProfile ∷ ProfileSpec → Profile
buildProfile spec =
  ProfileData
    { profileByteValues = table (specBytes spec)
    , profileCountValues = table (specCounts spec)
    , profileDurationValues = table (specDurations spec)
    }
  where
    table ∷ (Bounded a, Enum a, Ix a) ⇒ (a → b) → Array a b
    table value = listArray (minBound, maxBound) (map value [minBound .. maxBound])

-- | A scene's fixed elements under D-66's copied-value counting (a table is one
-- element, a key none): the scene table, the clear table with its three
-- channels, and the sprites table.
sceneFixedElements ∷ Word64
sceneFixedElements = 6

-- | Elements of one sprite: its table, its texture and its x, y, width and
-- height.
sceneElementsPerSprite ∷ Word64
sceneElementsPerSprite = 6

-- | The largest element count of a maximal scene, derived from the sprite
-- limit; validation has shown it fits 64 bits.
sceneElementBound ∷ Profile → Count
sceneElementBound profile =
  Count (sceneFixedElements + sceneElementsPerSprite * sprites)
  where
    Count sprites = countLimit profile SceneSprites

-- | What a scene-publishing call carries beside the scene: the window handle, which the copied-value reader counts
-- with the scene because it keeps one counter for all the arguments of a call. The handle is one element.
sceneCallExtraElements ∷ Word64
sceneCallExtraElements = 1

-- | The bytes the window handle adds to the call's crossing, allowed for generously: far more than its encoding, and
-- far less than any limit it is added to.
sceneCallExtraBytes ∷ Word64
sceneCallExtraBytes = 64

-- | The element count of a maximal publishing call, which is what a profile must let one crossing hold: the scene's
-- ('sceneElementBound') and the window handle's. Validation has shown it fits 64 bits.
sceneCallElementBound ∷ Profile → Count
sceneCallElementBound profile = Count (sceneElementBound' + sceneCallExtraElements)
  where
    Count sceneElementBound' = sceneElementBound profile

-- | Bytes of one RGBA8 pixel.
rgba8BytesPerPixel ∷ Word64
rgba8BytesPerPixel = 4

-- | The RGBA8 output ceiling: four bytes for each of the pixel limit. It is
-- derived, never entered a second time; validation has shown it fits 64 bits.
-- The same value is reserved at admission of a texture.
pngOutputBytes ∷ Profile → Bytes
pngOutputBytes profile = Bytes (rgba8BytesPerPixel * pixels)
  where
    Count pixels = countLimit profile PngPixels

-- | The least a texture is charged, in the instance's byte bank and the session's, from its admission until its
-- proven retirement, however few bytes it decodes to: 4 KiB (4,096 bytes).
--
-- __Owner decision (2026-11-08).__ Texture admission is bounded by memory only: "drop the count, the number is
-- arbitrary in a bindless system, set the limit on memory" (D-1 of the GPU resource services design: every texture is an
-- atlas and a single image is a 1x1 atlas, so a count says nothing about what a texture costs). The byte limits are
-- 'TextureBytesPerUiInstance' (512 MiB) and 'TextureBytesPerSession' (1 GiB), the manager's choice under the owner's
-- delegation of the value: a large zoom-out on a laptop with unified memory needs hundreds of MiB for one instance, and
-- the session total stays within half of the 2 GiB native accounting.
--
-- __Why a minimum charge.__ The least a texture can decode to is one RGBA8 pixel, four bytes. Under bytes alone a
-- gigabyte would then admit 268,435,456 one-pixel textures, far more than any device's descriptor array holds (MoltenVK
-- reports 1,000,000 update-after-bind sampled images), and a full descriptor table could bind before bytes did,
-- leaving accepted work retained with no refusal at all. Charging every texture at least this much makes the byte banks
-- the first bound that answers: a bank of @n@ bytes holds at most @n `div` 4096@ textures, so every structural capacity
-- that holds textures (the native table, the facade's lease scope) is /derived/ from the byte limits and this figure
-- ('textureRoomPerSession', 'textureRoomPerInstance') and can never refuse before the banks do. The figure is an accounting
-- floor chosen by the manager (decision A of issue 672), not a measurement of any device's allocation.
textureMinimumChargeBytes ∷ Word64
textureMinimumChargeBytes = 4096

-- | What a texture of this many decoded bytes is charged: its size, or the minimum charge if that is more.
textureChargeBytes ∷ Word64 → Word64
textureChargeBytes = max textureMinimumChargeBytes

-- | What admission reserves in both byte banks before the decode shrinks it: the largest legal level, or the minimum
-- charge if the profile's level is smaller than that.
textureReservationBytes ∷ Profile → Bytes
textureReservationBytes profile = Bytes (textureChargeBytes out)
  where
    Bytes out = pngOutputBytes profile

-- | The most textures the instance's byte bank can hold at once, given the minimum charge: a consequence of the bank,
-- not a limit beside it. The facade's lease scope is sized from it.
textureRoomPerInstance ∷ Profile → Word64
textureRoomPerInstance profile = bytes `div` textureMinimumChargeBytes
  where
    Bytes bytes = bytesLimit profile TextureBytesPerUiInstance

-- | The most textures the session's byte bank can hold at once, given the minimum charge: a consequence of the bank,
-- not a limit beside it. The native texture table (without its placeholder slot) is sized from it.
textureRoomPerSession ∷ Profile → Word64
textureRoomPerSession profile = bytes `div` textureMinimumChargeBytes
  where
    Bytes bytes = bytesLimit profile TextureBytesPerSession
