-- | Expected pixels of a validated 2D snapshot, computed without a GPU.
--
-- 'newOracle' takes an 'OracleInput': a validated snapshot, the cutout marks it
-- is planned with, each target's 'TargetSpec' (metrics, colour format, pixel
-- extent), and a lookup from complete texture handle to 'DecodedImage'. 'expect'
-- then answers, for a 'Probe' naming a pass and a pixel of that pass's target,
-- what the target holds once that pass has run:
--
-- * 'Expected': an 8-bit RGBA value and a per-channel tolerance;
-- * 'Indeterminate': the oracle will not guess, and says why;
-- * 'Unevaluable': an input is defective, and the oracle says which.
--
-- 'judge' and 'judgeReadback' compare an expectation with a pixel or a
-- readback; only 'Passed' passes. The full contract is in the package README:
-- the quad, the equations, the exactness rule and every indeterminate case.
--
-- __The quad.__ An instance's transform places the unit square [0, 1]² in its
-- layer's space. Local (0, 0) is the instance's origin, which pixel snap
-- rounds, and texture coordinates interpolate affinely from @(u0, v0)@ at
-- local (0, 0) to @(u1, v1)@ at local (1, 1).
--
-- __Exactness.__ Placement, coverage and texel addressing are computed in
-- 'Rational's from the snapshot's 32-bit coefficients. Colour is computed in
-- double precision with every store rounded to 8 bits.
--
-- __Retained chunks__ (R2D-10). A layer that lists chunks is evaluated as the
-- plan orders it ("Hetoimasia.Render.TwoD.DrawPlan"): the chunks' cutout
-- instances first, each listing as a run in the order listed, with the path the
-- chunk was built with, then the layer's dynamic cutouts, then the ordered
-- instances of the chunks and of the layer merged by ascending depth key and then
-- source order (a chunk listing before the dynamic instances, in listing order
-- and build order). The chunks are those the snapshot was validated against,
-- which the valid snapshot carries, so the oracle looks nothing up. A chunk
-- that a view culls ("Hetoimasia.Render.TwoD.Culling", with the view's mapping
-- and the target's extent) contributes nothing to that view; bounds that
-- enclose the chunk's geometry make that no change to any pixel, and the
-- oracle is built so that a chunk whose bounds do not is not possible. A
-- fragment of a chunk's instance is named by its 'AtChunkInstance' location.
--
-- __Purity.__ Every function is pure and total over a validated snapshot and
-- the lookup it is given; the same inputs always give the same expectations.
--
-- __Dependencies.__ @base@, @array@, @containers@, and this repository's
-- render-2d, render-api, math, asset and asset-image packages.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle
  ( -- * Inputs
    OracleInput (..)
  , TargetSpec (..)

    -- * The oracle
  , Oracle
  , newOracle
  , probeTarget

    -- * Probes and expectations
  , Probe (..)
  , Expectation (..)
  , Indeterminate (..)
  , Failure (..)
  , ImageFault (..)
  , expect

    -- * Verdicts
  , Verdict (..)
  , ChannelDifference (..)
  , ReadbackFault (..)
  , readProbe
  , judge
  , judgeReadback
  , passes
  ) where

import Control.Monad (unless)
import Data.Array (listArray, (!))
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (mapMaybe)
import Data.Word (Word32, Word8)
import Hetoimasia.Render.TwoD.Chunk (Chunk, ChunkRef, chunkCutoutPositions, chunkInstanceAt)
import Hetoimasia.Render.TwoD.Culling (chunkCulled)
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Math.Affine2 (columns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.DrawPlan
  ( CutoutMarks
  , DrawPath (..)
  , LayerSpace (..)
  , DrawPlan (..)
  , PlannedLayer
  , PlannedPass (..)
  , PlannedView (..)
  , RunSource (..)
  , drawingSources
  , planSnapshotCulled
  , plannedClearsDepth
  , plannedRuns
  , plannedSpace
  , runCount
  , runPath
  , runSource
  , runStart
  , InstanceSource (..)
  )
import Hetoimasia.Render.TwoD.Mapping
  ( ViewMapping
  , mappingPixelSnap
  , snapPoint
  , uiToTarget
  , uiTransform
  , viewMapping
  , viewportContains
  , viewportIsEmpty
  , worldToTarget
  , worldTransform
  )
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..), validMetrics)
import Hetoimasia.Render.TwoD.Oracle.Colour
  ( Channel (..)
  , ColourFormat
  , Rgba8 (..)
  , Tolerance (..)
  , formatIsSrgb
  , withinTolerance
  )
import Hetoimasia.Render.TwoD.Oracle.Internal.Geometry
  ( Coverage (..)
  , Placement
  , coverage
  , instanceIsSingular
  , inverseLinear
  , isDegenerate
  , nearBoundary
  , place
  , representable
  )
import Hetoimasia.Render.TwoD.Oracle.Internal.Image (Image (..), ImageFault (..), Level (..), checkImage)
import Hetoimasia.Render.TwoD.Oracle.Internal.Pipeline
  ( Cut (..)
  , Source
  , blend
  , clearPixel
  , cutout
  , pixelOutcome
  , shade
  )
import Hetoimasia.Render.TwoD.Oracle.Internal.Sample
  ( LevelRefusal (..)
  , SampleRefusal (..)
  , chooseLevel
  , derivatives
  , placeholder
  , sampleLevel
  )
import Hetoimasia.Render.TwoD.Oracle.Readback (ReadbackFault (..), readPixel)
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..), ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot
  ( ClearColour
  , Instance (..)
  , Layer
  , Pass (..)
  , Sampler (..)
  , Snapshot (..)
  , Target (..)
  , UvRect (..)
  , View (..)
  , Viewport (..)
  , layerInstances
  )
import Hetoimasia.Render.TwoD.Target (TargetRef)
import Hetoimasia.Render.TwoD.Validation (Location (..), ValidSnapshot, validLayerChunks, validLayerLocation, validLayers, validSnapshot)

-- | What the oracle needs to know about one target.
data TargetSpec = TargetSpec
  { specMetrics ∷ !TargetMetrics
  -- ^ The metrics the view mappings are built from.
  , specFormat ∷ !ColourFormat
  -- ^ The target's colour format.
  , specExtent ∷ !PixelExtent
  -- ^ The target's extent in pixels, which must equal the metrics'
  -- framebuffer extent.
  }
  deriving stock (Eq, Show)

-- | Everything the oracle evaluates.
data OracleInput = OracleInput
  { inputSnapshot ∷ !ValidSnapshot
  , inputCutoutMarks ∷ !CutoutMarks
  -- ^ The marks the snapshot is planned with.
  , inputWindow ∷ !(Maybe TargetSpec)
  -- ^ The window target, if any pass draws to it.
  , inputOffscreen ∷ !(Map TargetRef TargetSpec)
  -- ^ Each offscreen target a pass draws to.
  , inputTextures ∷ TextureHandle → Maybe DecodedImage
  -- ^ The image behind a complete handle, generation included. A handle the
  -- lookup does not know samples the placeholder, transparent black.
  }

-- | A pass by index and a pixel within that pass's target.
data Probe = Probe
  { probePass ∷ !Int
  , probeX ∷ !Int
  , probeY ∷ !Int
  }
  deriving stock (Eq, Ord, Show)

-- | What a probe is expected to read.
data Expectation
  = -- | This value, each channel within its tolerance.
    Expected !Rgba8 !Tolerance
  | -- | The oracle declines to give a value.
    Indeterminate !Indeterminate
  | -- | An input defect stops the oracle from answering.
    Unevaluable !Failure
  deriving stock (Eq, Show)

-- | Why a probe is indeterminate. Each names where: the view, or the instance
-- by pass, view, layer and submission index.
data Indeterminate
  = -- | The probe's centre is within 1/16 pixel of an edge of a view's viewport
    -- that is not on a whole pixel.
    NearViewportEdge !Location
  | -- | The probe's centre is within 1/16 pixel of an edge of an instance's quad.
    NearQuadEdge !Location
  | -- | A cutout-path instance's sample has an alpha, before brightness, within
    -- 2/255 of ½, the cutout variant's threshold (design D-26).
    NearCutoutThreshold !Location
  | -- | A minified probe whose derivatives are sheared or rotated by other than
    -- a quarter turn, on a texture with more than one level.
    MinifiedNotAxisAligned !Location
  | -- | A minified, axis-aligned probe whose level of detail is between two
    -- levels.
    MinifiedFractionalLevel !Location
  | -- | A nearest-filtered coordinate within 1/16 texel of an interior boundary
    -- between texels that differ.
    NearTexelBoundary !Location
  | -- | A channel whose stored byte cannot be bounded to within one step: the
    -- stores' rounding, where a value is a tie or within a 1024th of a byte of
    -- one, leaves more than three bytes it could hold after the last draw.
    RoundingNotBounded !Channel
  deriving stock (Eq, Show)

-- | Why the oracle cannot answer.
data Failure
  = -- | The probe's pass index is not a pass of the snapshot.
    PassOutOfRange !Int
  | -- | The probe's pixel is outside its pass's target: column, then row.
    PixelOutsideTarget !Int !Int
  | -- | No 'TargetSpec' was supplied for the pass's target.
    MissingTarget !Target
  | -- | The target's metrics are invalid: a negative extent, or a content scale
    -- that is not finite and positive.
    InvalidMetrics !Target
  | -- | The target's pixel extent is not its metrics' framebuffer extent.
    ExtentDisagrees !Target
  | -- | An extent beyond 2²³ pixels, where a pixel centre is not exactly a
    -- 'Float'.
    TargetTooLarge !Target
  | -- | A view's mapping cannot be represented as finite 'Float's, though an
    -- instance in it needs one.
    MappingNotRepresentable !Location
  | -- | A non-singular instance whose placed corners, or whose snapped origin,
    -- cannot be represented as finite 'Float's.
    PlacementNotRepresentable !Location
  | -- | A texture the lookup returned, which is not a well-formed image.
    MalformedImage !Location !TextureHandle !ImageFault
  deriving stock (Eq, Show)

-- | A snapshot prepared for probing. Building it checks nothing eagerly: every
-- defect is reported by the probes it affects.
data Oracle = Oracle
  { oraclePasses ∷ [OraclePass]
  , oracleTextures ∷ TextureHandle → Maybe DecodedImage
  }

data OraclePass = OraclePass
  { opTarget ∷ Either Failure TargetSpec
  , opClear ∷ !ClearColour
  , opViews ∷ [OracleView]
  }

data OracleView = OracleView
  { ovLocation ∷ !Location
  , ovViewport ∷ !Viewport
  , ovSettings ∷ !ViewSettings
  , ovMapping ∷ Maybe ViewMapping
  , ovLayers ∷ [OracleLayer]
  }

data OracleLayer = OracleLayer
  { olSpace ∷ !LayerSpace
  , olDepth ∷ !Bool
    -- ^ Whether the layer is a depth-enabled world layer: it clears depth within
    -- its view's viewport before its runs.
  , olInstances ∷ [Drawn]
  }

-- | An instance in its layer's drawing order: where it is, the instance and the
-- path the plan gave it.
data Drawn = Drawn !Location !Instance !DrawPath

-- | Prepare a snapshot for probing.
newOracle ∷ OracleInput → Oracle
newOracle input =
  Oracle
    { oraclePasses =
        [ buildPass input chunksOf passIndex pass planned
        | (passIndex, pass, planned) ← zip3 [0 ..] (snapshotPasses snapshot) (planPasses plan)
        ]
    , oracleTextures = inputTextures input
    }
  where
    snapshot = validSnapshot (inputSnapshot input)
    plan = planSnapshotCulled culler (inputCutoutMarks input) (inputSnapshot input)
    chunksOf = Map.fromList [((pass, view, layer), validLayerChunks held) | held ← validLayers (inputSnapshot input), AtLayer pass view layer ← [validLayerLocation held]]
    -- A view skips the chunks it culls; one whose target or mapping the oracle
    -- cannot resolve skips none, and is reported by the probes it affects.
    culler passIndex viewIndex kind bounds =
      case Map.lookup (passIndex, viewIndex) cullable of
        Just (mapping, extent, viewport) → chunkCulled mapping extent viewport kind bounds
        Nothing → False
    cullable =
      Map.fromList
        [ ((passIndex, viewIndex), (mapping, (fromIntegral width, fromIntegral height), viewViewport view))
        | (passIndex, pass) ← zip [0 ..] (snapshotPasses snapshot)
        , Right spec ← [resolveTarget input (passTarget pass)]
        , let PixelExtent width height = specExtent spec
        , (viewIndex, view) ← zip [0 ..] (passViews pass)
        , Just mapping ← [viewMapping (specMetrics spec) view]
        ]

type ChunksOf = Map (Int, Int, Int) [(ChunkRef, Chunk)]

buildPass ∷ OracleInput → ChunksOf → Int → Pass → PlannedPass → OraclePass
buildPass input chunksOf passIndex pass planned =
  OraclePass
    { opTarget = resolved
    , opClear = passClear pass
    , opViews =
        [ buildView chunksOf passIndex viewIndex resolved view plannedView
        | (viewIndex, view, plannedView) ← zip3 [0 ..] (passViews pass) (plannedViews planned)
        ]
    }
  where
    resolved = resolveTarget input (passTarget pass)

buildView ∷ ChunksOf → Int → Int → Either Failure TargetSpec → View → PlannedView → OracleView
buildView chunksOf passIndex viewIndex resolved view planned =
  OracleView
    { ovLocation = AtView passIndex viewIndex
    , ovViewport = viewViewport view
    , ovSettings = viewSettings view
    , ovMapping = either (const Nothing) (\spec → viewMapping (specMetrics spec) view) resolved
    , ovLayers =
        [ buildLayer passIndex viewIndex layerIndex layer (Map.findWithDefault [] (passIndex, viewIndex, layerIndex) chunksOf) plannedLayer
        | (layerIndex, layer, plannedLayer) ← zip3 [0 ..] (viewLayers view) (plannedLayers planned)
        ]
    }

-- | A layer's instances in the order the plan draws them: each run in turn, a
-- chunk's cutout run read from the chunk and a ring run from the layer's ring
-- entries, which are its dynamic instances and the chunks' ordered ones.
buildLayer ∷ Int → Int → Int → Layer → [(ChunkRef, Chunk)] → PlannedLayer → OracleLayer
buildLayer passIndex viewIndex layerIndex layer chunks planned =
  OracleLayer
    { olSpace = plannedSpace planned
    , olDepth = plannedClearsDepth planned
    , olInstances = concatMap drawRun (plannedRuns planned)
    }
  where
    list = layerInstances layer
    dynamic = listArray (0, length list - 1) list
    ring = drawingSources planned
    drawRun run = case runSource run of
      RingRun → [drawn source (runPath run) | source ← take (runCount run) (drop (runStart run) ring)]
      ChunkRun position →
        [ drawn (ChunkInstance position index) (runPath run)
        | index ← take (runCount run) (drop (runStart run) (maybe [] (chunkCutoutPositions . snd) (nth position chunks)))
        ]
    drawn source path = case source of
      DynamicInstance index → Drawn (AtInstance passIndex viewIndex layerIndex index) (dynamic ! index) path
      ChunkInstance position index → case nth position chunks >>= \(_, held) → chunkInstanceAt held index of
        Just candidate → Drawn (AtChunkInstance passIndex viewIndex layerIndex position index) candidate path
        Nothing → error "the plan names a chunk instance the layer's chunks do not hold"
    nth position items = case drop position items of
      item : _ → Just item
      [] → Nothing

-- | The checked spec of a pass's target.
resolveTarget ∷ OracleInput → Target → Either Failure TargetSpec
resolveTarget input target = do
  spec ← maybe (Left (MissingTarget target)) Right $ case target of
    WindowTarget → inputWindow input
    OffscreenTarget reference → Map.lookup reference (inputOffscreen input)
  unless (validMetrics (specMetrics spec)) (Left (InvalidMetrics target))
  unless (specExtent spec == metricsFramebuffer (specMetrics spec)) (Left (ExtentDisagrees target))
  let PixelExtent width height = specExtent spec
  unless (width <= 8388608 && height <= 8388608) (Left (TargetTooLarge target))
  Right spec

-- | The target spec a probe reads, or why there is none.
probeTarget ∷ Oracle → Probe → Either Failure TargetSpec
probeTarget oracle (Probe passIndex x y) = do
  pass ← passAt oracle passIndex
  spec ← opTarget pass
  let PixelExtent width height = specExtent spec
  unless (x >= 0 && y >= 0 && x < width && y < height) (Left (PixelOutsideTarget x y))
  Right spec

passAt ∷ Oracle → Int → Either Failure OraclePass
passAt oracle passIndex
  | passIndex < 0 = Left (PassOutOfRange passIndex)
  | otherwise = case drop passIndex (oraclePasses oracle) of
      pass : _ → Right pass
      [] → Left (PassOutOfRange passIndex)

-- | What one fragment of the pixel's evaluation came to.
data Fragment
  = Draws !Source
  | -- | A cutout fragment the variant discards: it draws nothing and writes no
    -- depth.
    Discards
  | Unsure !Indeterminate
  | Bad !Failure

-- | What a probe is expected to read.
expect ∷ Oracle → Probe → Expectation
expect oracle probe@(Probe passIndex x y) =
  case probeTarget oracle probe >>= \spec → fmap ((,) spec) (passAt oracle passIndex) of
    Left failure → Unevaluable failure
    Right (spec, pass) → combine spec pass (concatMap (viewFragments oracle spec x y) (opViews pass))

-- | Refusals first, then indeterminacies, then the blend in drawing order.
combine ∷ TargetSpec → OraclePass → [Fragment] → Expectation
combine spec pass fragments =
  case ([failure | Bad failure ← fragments], [why | Unsure why ← fragments]) of
    (failure : _, _) → Unevaluable failure
    ([], why : _) → Indeterminate why
    ([], []) →
      let format = specFormat spec
          final = foldl' (\pixel source → blend format source pixel) (clearPixel format (opClear pass)) [source | Draws source ← fragments]
       in case pixelOutcome final of
            Left channel → Indeterminate (RoundingNotBounded channel)
            Right (value, tolerance) → Expected value tolerance

viewFragments ∷ Oracle → TargetSpec → Int → Int → OracleView → [Fragment]
viewFragments oracle spec x y view
  | viewportIsEmpty viewport = []
  | near = Unsure (NearViewportEdge (ovLocation view)) : body
  | contains = body
  | otherwise = []
  where
    viewport = ovViewport view
    centreX = fromIntegral x + 0.5 ∷ Float
    centreY = fromIntegral y + 0.5 ∷ Float
    contains = viewportContains viewport (V2 centreX centreY)
    near = nearBoundary (1 / 16) (viewportEdges viewport) (toRational centreX, toRational centreY)
    body = case ovMapping view of
      -- A mapping is needed by an instance that has area: a singular quad is
      -- known to cover nothing from its own transform.
      Nothing → [Bad (MappingNotRepresentable (ovLocation view)) | any needsMapping (concatMap olInstances (ovLayers view))]
      Just mapping →
        concatMap (layerFragments oracle spec x y view mapping) (ovLayers view)

-- | A layer's fragments at a pixel in the layer's drawing order. A layer
-- without depth draws every covering instance. A depth-enabled layer first
-- clears depth to 1.0 within its viewport (the pixel is within it, or this is
-- not asked), then runs its cutouts, which are tested less-or-equal and written,
-- and its ordered instances, which are tested and not written; the plan's
-- order puts every cutout first.
layerFragments ∷ Oracle → TargetSpec → Int → Int → OracleView → ViewMapping → OracleLayer → [Fragment]
layerFragments oracle spec x y view mapping layer
  | olDepth layer =
      depthTested
        [ (path, nearness (instanceDepthKey instanceValue), fragment)
        | drawn@(Drawn _ instanceValue path) ← olInstances layer
        , Just fragment ← [instanceFragment oracle spec x y view mapping (olSpace layer) drawn]
        ]
  | otherwise = mapMaybe (instanceFragment oracle spec x y view mapping (olSpace layer)) (olInstances layer)

-- | A depth key's depth, @(2²⁴ − 1 − k) / 2²⁴@ (design D-23): exact in a 32-bit
-- float, and a larger key is nearer.
nearness ∷ Word32 → Rational
nearness key = (16777215 - toRational key) / 16777216

-- | The fragments of a depth-enabled layer that pass its depth test, from the
-- 1.0 its clear leaves: each is compared less-or-equal against the depth held,
-- and a cutout fragment that passes writes its own. A discarded fragment writes
-- nothing, and one that is indeterminate or refused is kept for its reason.
depthTested ∷ [(DrawPath, Rational, Fragment)] → [Fragment]
depthTested = go 1
  where
    go _ [] = []
    go held ((path, depth, fragment) : rest) = case fragment of
      Draws _
        | depth <= held → fragment : go (if path == Cutout then depth else held) rest
        | otherwise → go held rest
      Discards → go held rest
      _ → fragment : go held rest

-- | Whether an instance has area, so that drawing it needs the view's mapping.
needsMapping ∷ Drawn → Bool
needsMapping (Drawn _ instanceValue _) = not (instanceIsSingular (instanceTransform instanceValue))

-- | A viewport's four edges, exactly.
viewportEdges ∷ Viewport → [((Rational, Rational), (Rational, Rational))]
viewportEdges (Viewport (V2 ox oy) (V2 width height)) =
  [(topLeft, topRight), (topRight, bottomRight), (bottomRight, bottomLeft), (bottomLeft, topLeft)]
  where
    left = toRational ox
    top = toRational oy
    right = left + toRational width
    bottom = top + toRational height
    topLeft = (left, top)
    topRight = (right, top)
    bottomRight = (right, bottom)
    bottomLeft = (left, bottom)

instanceFragment ∷ Oracle → TargetSpec → Int → Int → OracleView → ViewMapping → LayerSpace → Drawn → Maybe Fragment
instanceFragment oracle spec x y view mapping space (Drawn location instanceValue path)
  | instanceIsSingular transform = Nothing
  | otherwise = case placement of
      Nothing → Just (Bad (PlacementNotRepresentable location))
      Just placed
        | isDegenerate placed || not (representable placed) → Just (Bad (PlacementNotRepresentable location))
        | otherwise → case coverage placed centre of
            Outside → Nothing
            NearEdge → Just (Unsure (NearQuadEdge location))
            Inside local
              | onCutoutPath → Just (cutoutSampled oracle spec view instanceValue location placed local)
              | otherwise → Just (sampled oracle spec view instanceValue location placed local)
  where
    transform = instanceTransform instanceValue
    onCutoutPath = path == Cutout
    centre = (fromIntegral x + 1 / 2, fromIntegral y + 1 / 2)
    (V2 _ _, V2 _ _, V2 originX originY) = columns transform
    layerTransform = case space of
      WorldSpace _ → worldTransform mapping
      UiSpace → uiTransform mapping
    toTarget = case space of
      WorldSpace _ → worldToTarget mapping
      UiSpace → uiToTarget mapping
    placement
      | mappingPixelSnap mapping = do
          mapped ← toTarget (V2 originX originY)
          let V2 snappedX snappedY = snapPoint mapped
          Just (place layerTransform transform (Just (snappedX, snappedY)))
      | otherwise = Just (place layerTransform transform Nothing)

-- | The fragment an ordered-path instance draws at a pixel its quad covers, at
-- local coordinates @(lx, ly)@.
sampled ∷ Oracle → TargetSpec → OracleView → Instance → Location → Placement → (Rational, Rational) → Fragment
sampled oracle spec view instanceValue location placed local =
  either id (Draws . lit) (texelAt oracle spec view instanceValue location placed local)
  where
    lit = shade (instanceTint instanceValue) (settingBrightness (ovSettings view)) (instanceAdditive instanceValue)

-- | The fragment a cutout-path instance gives at such a pixel: the cutout
-- variant's rule (design D-26) on the sample.
cutoutSampled ∷ Oracle → TargetSpec → OracleView → Instance → Location → Placement → (Rational, Rational) → Fragment
cutoutSampled oracle spec view instanceValue location placed local =
  case texelAt oracle spec view instanceValue location placed local of
    Left fragment → fragment
    Right texel → case cutout (instanceTint instanceValue) (settingBrightness (ovSettings view)) texel of
      Discarded → Discards
      Survives source → Draws source
      AtThreshold → Unsure (NearCutoutThreshold location)

-- | The texel an instance samples at local coordinates @(lx, ly)@, or the
-- fragment that says why there is none.
texelAt ∷ Oracle → TargetSpec → OracleView → Instance → Location → Placement → (Rational, Rational) → Either Fragment Source
texelAt oracle spec view instanceValue location placed (lx, ly) =
  case oracleTextures oracle handle of
    Nothing → Right placeholder
    Just decoded → case checkImage decoded of
      Left fault → Left (Bad (MalformedImage location handle fault))
      Right image → case imageLevels image of
        [] → Left (Bad (MalformedImage location handle (LevelCountInvalid 0)))
        Level width0 height0 _ : _ →
          let slopes = derivatives (inverseLinear placed) (r u0, r v0, r u1, r v1) (width0, height0)
           in case chooseLevel (length (imageLevels image)) slopes of
                Left NotAxisAligned → Left (Unsure (MinifiedNotAxisAligned location))
                Left FractionalLevel → Left (Unsure (MinifiedFractionalLevel location))
                Right level → case sampleLevel (formatIsSrgb (specFormat spec)) filtering image level (u, v) of
                  Left AtTexelBoundary → Left (Unsure (NearTexelBoundary location))
                  Right source → Right source
  where
    handle = instanceTexture instanceValue
    UvRect u0 v0 u1 v1 = instanceUv instanceValue
    r = toRational
    u = r u0 + (r u1 - r u0) * lx
    v = r v0 + (r v1 - r v0) * ly
    settings = ovSettings view
    filtering = case instanceSampler instanceValue of
      SamplerDefault → settingFilter settings
      SamplerNearest → FilterNearest
      SamplerLinear → FilterLinear

-- | How a probe's verdict reads against the pixel that was observed.
data Verdict
  = -- | Every channel is within its tolerance.
    Passed
  | -- | These channels are not.
    OutOfTolerance [ChannelDifference]
  | -- | The probe is indeterminate, which is never a pass.
    ProbeIndeterminate !Indeterminate
  | -- | The probe cannot be evaluated, which is never a pass.
    ProbeUnevaluable !Failure
  | -- | The readback has no pixel there.
    ReadbackFaulty !ReadbackFault
  deriving stock (Eq, Show)

-- | A channel outside its tolerance.
data ChannelDifference = ChannelDifference
  { differenceChannel ∷ !Channel
  , differenceExpected ∷ !Word8
  , differenceActual ∷ !Word8
  , differenceTolerance ∷ !Word8
  }
  deriving stock (Eq, Show)

-- | Whether a verdict is a pass: only 'Passed' is.
passes ∷ Verdict → Bool
passes Passed = True
passes _ = False

-- | An expectation against an observed pixel in RGBA order.
judge ∷ Expectation → Rgba8 → Verdict
judge (Indeterminate why) _ = ProbeIndeterminate why
judge (Unevaluable failure) _ = ProbeUnevaluable failure
judge (Expected expected@(Rgba8 er eg eb ea) tolerance@(Tolerance tr tg tb ta)) actual@(Rgba8 ar ag ab aa)
  | withinTolerance tolerance expected actual = Passed
  | otherwise =
      OutOfTolerance
        [ ChannelDifference channel e a t
        | (channel, e, a, t) ← [(Red, er, ar, tr), (Green, eg, ag, tg), (Blue, eb, ab, tb), (Alpha, ea, aa, ta)]
        , abs (fromIntegral e - fromIntegral a ∷ Int) > fromIntegral t
        ]

-- | The pixel a probe names in a tightly packed readback of a target of this
-- format and extent, in RGBA order: 'readPixel' at the probe's column and row.
readProbe ∷ ColourFormat → PixelExtent → ByteString → Probe → Either ReadbackFault Rgba8
readProbe format extent bytes (Probe _ x y) = readPixel format extent bytes x y

-- | A probe judged against a tightly packed readback of its target, which must
-- be in the target's format and extent.
judgeReadback ∷ Oracle → Probe → ByteString → Verdict
judgeReadback oracle probe bytes =
  case probeTarget oracle probe of
    Left failure → ProbeUnevaluable failure
    Right spec →
      case readPixel (specFormat spec) (specExtent spec) bytes (probeX probe) (probeY probe) of
        Left fault → ReadbackFaulty fault
        Right pixel → judge (expect oracle probe) pixel
