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
-- __Clips__ (design D-11, R2D-12). An instance whose clip index selects an
-- entry of its view's clip table, resolved as 'resolveClips' resolves it, draws
-- only where the fragment's pixel centre, carried back to the layer's space by
-- the exact inverse of the transform the layer draws with, lies in the
-- half-open resolved rectangle; a centre outside it receives nothing from that
-- instance, colour or depth. The layer's transform is the view's own, with its
-- snapped translation, and no sprite's origin snap is undone or applied to the
-- clip. A centre within 1/16 pixel, measured in target pixels against the
-- clip's boundary after transformation, of an instance that could draw there is
-- 'NearClipEdge'. Clip index 0 means none.
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
-- __Application materials__ (R2D-11). An instance names its material by a
-- reference. The default material's model is built in: its output is the
-- texel itself. Any other material needs a 'MaterialModel'
-- ("Hetoimasia.Render.TwoD.Oracle.Material") given to 'newOracleWith' under its
-- reference, a pure function of the inputs the material receives — the
-- instance's texel, texture coordinates and parameter word, its record, the
-- view's push block for the material, and the sampling of any further texture
-- through the same lookup and generation check. A fragment of an instance
-- whose material has no model is 'Unevaluable' ('MissingMaterialModel'), never
-- drawn as the default. The oracle applies the same wrapping to the model's
-- colour that it applies to the default texel: the tint, the brightness and the
-- additive flag, or the cutout variant's discard. The record is the view's for a
-- dynamic instance and the chunk's own for a chunk's instance.
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
  , newOracleWith
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
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Map.Strict (Map)
import Data.Maybe (mapMaybe)
import Data.Word (Word32, Word8)
import Hetoimasia.Render.TwoD.Chunk (Chunk, ChunkRef, chunkCutoutPositions, chunkInstanceAt, chunkRecords)
import Hetoimasia.Render.TwoD.Material (MaterialData (..), MaterialRecord (..), MaterialRef, defaultMaterial)
import Hetoimasia.Render.TwoD.Culling (chunkCulled)
import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Math.Affine2 (columns, identity)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Clip (ResolvedClip (..), clipEntryOfIndex, clipIsEmpty)
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
import Hetoimasia.Render.TwoD.Oracle.Material
  ( Colour (..)
  , MaterialInput (..)
  , MaterialModel (..)
  , ModelFault (..)
  )
import Hetoimasia.Render.TwoD.Oracle.Internal.Geometry
  ( ClipStanding (..)
  , Coverage (..)
  , Placement
  , clipStanding
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
  ( Chan (..)
  , Cut (..)
  , Quad (..)
  , Source
  , blend
  , clearPixel
  , cutout
  , pinChan
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
  | -- | A model sampled a texture of more than one level at coordinates other
    -- than the fragment's own without saying how fast they change.
    UnrelatedSecondaryCoordinates !Location
  | -- | The probe's centre is within 1/16 pixel of the boundary of the clip
    -- rectangle of an instance that could draw there.
    NearClipEdge !Location
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
  | -- | An instance of an application material for which no model was given:
    -- the instance, and the material.
    MissingMaterialModel !Location !MaterialRef
  | -- | An instance whose material's model returned a colour with a component
    -- that is NaN or infinite.
    ModelOutputNotFinite !Location
  deriving stock (Eq, Show)

-- | A snapshot prepared for probing. Building it checks nothing eagerly: every
-- defect is reported by the probes it affects.
data Oracle = Oracle
  { oraclePasses ∷ [OraclePass]
  , oracleTextures ∷ TextureHandle → Maybe DecodedImage
  , oracleModels ∷ Map MaterialRef MaterialModel
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
  , ovClips ∷ [ResolvedClip]
  -- ^ The view's clip table, resolved: entry @k − 1@ is what clip index @k@ selects.
  , ovLayers ∷ [OracleLayer]
  }

data OracleLayer = OracleLayer
  { olSpace ∷ !LayerSpace
  , olDepth ∷ !Bool
    -- ^ Whether the layer is a depth-enabled world layer: it clears depth within
    -- its view's viewport before its runs.
  , olInstances ∷ [Drawn]
  }

-- | What an instance's material is given beyond the instance: the record its
-- parameter word indexes, from its view or its chunk, and the view's push block.
data ModelData = ModelData
  { modelRecord ∷ !MaterialRecord
  , modelPush ∷ !ByteString
  }

-- | An instance in its layer's drawing order: where it is, the instance, the
-- path the plan gave it and what its material is given.
data Drawn = Drawn !Location !Instance !DrawPath !ModelData

-- | Prepare a snapshot for probing, with no application material's model: an
-- instance of one is unevaluable.
newOracle ∷ OracleInput → Oracle
newOracle = newOracleWith Map.empty

-- | Prepare a snapshot for probing, with a model for each application material
-- it uses ("Hetoimasia.Render.TwoD.Oracle.Material"). The default material's is
-- built in and need not be given, and one that is given for it is ignored.
newOracleWith ∷ Map MaterialRef MaterialModel → OracleInput → Oracle
newOracleWith models input =
  Oracle
    { oraclePasses =
        [ buildPass input chunksOf passIndex pass planned
        | (passIndex, pass, planned) ← zip3 [0 ..] (snapshotPasses snapshot) (planPasses plan)
        ]
    , oracleTextures = inputTextures input
    , oracleModels = models
    }
  where
    snapshot = validSnapshot (inputSnapshot input)
    plan = planSnapshotCulled culler (inputCutoutMarks input) (inputSnapshot input)
    chunksOf = Map.fromList [((pass, view, layer), validLayerChunks held) | held ← validLayers (inputSnapshot input), AtLayer pass view layer ← [validLayerLocation held]]
    -- A view skips the chunks it culls; one whose target or mapping the oracle
    -- cannot resolve skips none, and is reported by the probes it affects.
    culler passIndex viewIndex _ kind bounds placement =
      case Map.lookup (passIndex, viewIndex) cullable of
        Just (mapping, extent, viewport) → chunkCulled mapping extent viewport kind bounds placement
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
    , ovClips = plannedClips planned
    , ovLayers =
        [ buildLayer passIndex viewIndex layerIndex (viewMaterials view) layer (Map.findWithDefault [] (passIndex, viewIndex, layerIndex) chunksOf) plannedLayer
        | (layerIndex, layer, plannedLayer) ← zip3 [0 ..] (viewLayers view) (plannedLayers planned)
        ]
    }

-- | A layer's instances in the order the plan draws them: each run in turn, a
-- chunk's cutout run read from the chunk and a ring run from the layer's ring
-- entries, which are its dynamic instances and the chunks' ordered ones.
buildLayer ∷ Int → Int → Int → Map MaterialRef MaterialData → Layer → [(ChunkRef, Chunk)] → PlannedLayer → OracleLayer
buildLayer passIndex viewIndex layerIndex materials layer chunks planned =
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
      DynamicInstance index →
        let candidate = dynamic ! index
         in Drawn (AtInstance passIndex viewIndex layerIndex index) candidate path (viewModelData candidate)
      ChunkInstance position index → case nth position chunks >>= \(_, held) → fmap ((,) held) (chunkInstanceAt held index) of
        Just (held, candidate) → Drawn (AtChunkInstance passIndex viewIndex layerIndex position index) candidate path (chunkModelData held candidate)
        Nothing → error "the plan names a chunk instance the layer's chunks do not hold"
    -- The record an instance's parameter word indexes: the view's records for a
    -- dynamic instance, the chunk's own for a chunk's.
    viewModelData candidate =
      let held = Map.lookup (instanceMaterial candidate) materials
       in ModelData (recordAt (maybe [] materialRecords held) candidate) (maybe ByteString.empty materialPushBlock held)
    chunkModelData built candidate =
      ModelData (recordAt (Map.findWithDefault [] (instanceMaterial candidate) (chunkRecords built)) candidate) (viewPush candidate)
    viewPush candidate = maybe ByteString.empty materialPushBlock (Map.lookup (instanceMaterial candidate) materials)
    recordAt records candidate = case drop (fromIntegral (instanceParameter candidate)) records of
      found : _ → found
      [] → MaterialRecord [] []
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
        | drawn@(Drawn _ instanceValue path _) ← olInstances layer
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
needsMapping (Drawn _ instanceValue _ _) = not (instanceIsSingular (instanceTransform instanceValue))

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
instanceFragment oracle spec x y view mapping space (Drawn location instanceValue path given)
  | instanceIsSingular transform = Nothing
  | otherwise = case placement of
      Nothing → Just (Bad (PlacementNotRepresentable location))
      Just placed
        | isDegenerate placed || not (representable placed) → Just (Bad (PlacementNotRepresentable location))
        | otherwise → case clipStandingOf of
            -- Outside its clip an instance gives nothing, whatever its quad does.
            Just ClipOutside → Nothing
            standing → case coverage placed centre of
              Outside → Nothing
              NearEdge → Just (Unsure (NearQuadEdge location))
              Inside local
                | standing == Just ClipNearEdge → Just (Unsure (NearClipEdge location))
                | onCutoutPath → Just (cutoutSampled oracle spec view given instanceValue location placed local)
                | otherwise → Just (sampled oracle spec view given instanceValue location placed local)
  where
    -- How the pixel centre stands to the instance's clip, if it has one: the
    -- selected entry's resolved rectangle, an empty one holding no point and
    -- having no edge.
    clipStandingOf = case clipEntryOfIndex (instanceClip instanceValue) of
      Nothing → Nothing
      Just entryIndex → case drop entryIndex (ovClips view) of
        clip : _
          | clipIsEmpty clip → Just ClipOutside
          | otherwise →
              let r = toRational
                  layerPlacement = place layerTransform identity Nothing
               in if isDegenerate layerPlacement
                    then Just ClipOutside
                    else Just (clipStanding layerPlacement (r (resolvedLeft clip), r (resolvedTop clip), r (resolvedRight clip), r (resolvedBottom clip)) centre)
        -- A validated snapshot selects an entry its table holds.
        [] → Just ClipOutside
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
sampled ∷ Oracle → TargetSpec → OracleView → ModelData → Instance → Location → Placement → (Rational, Rational) → Fragment
sampled oracle spec view given instanceValue location placed local =
  either id (Draws . lit) (materialColour oracle spec view given instanceValue location placed local)
  where
    lit = shade (instanceTint instanceValue) (settingBrightness (ovSettings view)) (instanceAdditive instanceValue)

-- | The fragment a cutout-path instance gives at such a pixel: the cutout
-- variant's rule (design D-26) on the material's colour.
cutoutSampled ∷ Oracle → TargetSpec → OracleView → ModelData → Instance → Location → Placement → (Rational, Rational) → Fragment
cutoutSampled oracle spec view given instanceValue location placed local =
  case materialColour oracle spec view given instanceValue location placed local of
    Left fragment → fragment
    Right colour → case cutout (instanceTint instanceValue) (settingBrightness (ovSettings view)) colour of
      Discarded → Discards
      Survives source → Draws source
      AtThreshold → Unsure (NearCutoutThreshold location)

-- | The colour the instance's material gives at a pixel its quad covers: the
-- texel itself for the default material, and otherwise the material's model
-- applied to the texel, the coordinates, the parameter word, the record and the
-- push block. Or the fragment that says why there is none.
materialColour ∷ Oracle → TargetSpec → OracleView → ModelData → Instance → Location → Placement → (Rational, Rational) → Either Fragment Source
materialColour oracle spec view given instanceValue location placed local@(lx, ly)
  | material == defaultMaterial = texel
  | otherwise = case Map.lookup material (oracleModels oracle) of
      Nothing → Left (Bad (MissingMaterialModel location material))
      Just model → do
        primary ← texel
        let input =
              MaterialInput
                { materialTexel = colourOf primary
                , materialUv = (fromRational u, fromRational v)
                , materialParameter = instanceParameter instanceValue
                , materialRecord = modelRecord given
                , materialPush = modelPush given
                , materialSample = \handle (su, sv) → sampleAnother handle (toRational su, toRational sv) (1, 1) (own su sv)
                , materialSampleScaled = \handle (su, sv) (ku, kv) → sampleAnother handle (toRational su, toRational sv) (toRational ku, toRational kv) True
                }
        case runMaterialModel model input of
          Left fault → Left (faultFragment location fault)
          Right output
            | not (finiteColour output) → Left (Bad (ModelOutputNotFinite location))
            | otherwise → Right (sourceOf output)
  where
    material = instanceMaterial instanceValue
    texel = sampleTexture oracle spec view instanceValue location placed (instanceTexture instanceValue) local
    UvRect u0 v0 u1 v1 = instanceUv instanceValue
    r = toRational
    u = r u0 + (r u1 - r u0) * lx
    v = r v0 + (r v1 - r v0) * ly
    -- A texture sampled at coordinates of the model's choosing: with the same
    -- placement, the rate of change of its coordinates is the instance's own.
    sampleAnother handle at scale ownCoordinates = case sampleTextureAt oracle spec view instanceValue location placed handle at scale ownCoordinates of
      Left fragment → Left (modelFaultOf handle fragment)
      Right source → Right (colourOf source)
    -- Whether the coordinates are the fragment's own, to the precision of a
    -- 'Double'.
    own su sv = abs (toRational su - u) <= 1 / 1000000000 && abs (toRational sv - v) <= 1 / 1000000000

-- | A source as the colour a model reads.
colourOf ∷ Source → Colour
colourOf (Quad red green blue alpha) = Colour (channel red) (channel green) (channel blue) (channel alpha)
  where
    channel = fromRational . chanValue

-- | The source a model's colour is: its components, none of them exact unless
-- they are exactly zero or one.
sourceOf ∷ Colour → Source
sourceOf (Colour red green blue alpha) = Quad (channel red) (channel green) (channel blue) (channel alpha)
  where
    channel value = pinChan (Chan (toRational value) False)

finiteColour ∷ Colour → Bool
finiteColour (Colour red green blue alpha) = all (\value → not (isNaN value || isInfinite value)) [red, green, blue, alpha]

-- | The fragment a fault of a model's own sampling comes to.
faultFragment ∷ Location → ModelFault → Fragment
faultFragment location = \case
  SampleNearTexelBoundary _ → Unsure (NearTexelBoundary location)
  SampleMinifiedNotAxisAligned _ → Unsure (MinifiedNotAxisAligned location)
  SampleMinifiedFractionalLevel _ → Unsure (MinifiedFractionalLevel location)
  SampleMalformedImage handle fault → Bad (MalformedImage location handle fault)
  SampleCoordinatesUnrelated _ → Unsure (UnrelatedSecondaryCoordinates location)

-- | The fault a fragment that says why there is no sample comes to.
modelFaultOf ∷ TextureHandle → Fragment → ModelFault
modelFaultOf handle = \case
  Unsure (MinifiedNotAxisAligned _) → SampleMinifiedNotAxisAligned handle
  Unsure (MinifiedFractionalLevel _) → SampleMinifiedFractionalLevel handle
  Unsure (UnrelatedSecondaryCoordinates _) → SampleCoordinatesUnrelated handle
  Bad (MalformedImage _ _ fault) → SampleMalformedImage handle fault
  _ → SampleNearTexelBoundary handle

-- | The texel an instance samples at local coordinates @(lx, ly)@, or the
-- fragment that says why there is none.
sampleTexture ∷ Oracle → TargetSpec → OracleView → Instance → Location → Placement → TextureHandle → (Rational, Rational) → Either Fragment Source
sampleTexture oracle spec view instanceValue location placed handle (lx, ly) =
  sampleTextureAt oracle spec view instanceValue location placed handle (u, v) (1, 1) True
  where
    UvRect u0 v0 u1 v1 = instanceUv instanceValue
    r = toRational
    u = r u0 + (r u1 - r u0) * lx
    v = r v0 + (r v1 - r v0) * ly

-- | A texture sampled at these texture coordinates, with the instance's sampler
-- choice, and the level selected by the instance's rate of change of texture
-- coordinates times this factor in each direction. Coordinates that are not the
-- fragment's own and carry no declared factor ('False') are unrelated to that
-- rate, which decides the level of a texture of more than one level, so for such
-- a texture they are the indeterminate case.
sampleTextureAt ∷ Oracle → TargetSpec → OracleView → Instance → Location → Placement → TextureHandle → (Rational, Rational) → (Rational, Rational) → Bool → Either Fragment Source
sampleTextureAt oracle spec view instanceValue location placed handle (u, v) (scaleU, scaleV) ownCoordinates =
  case oracleTextures oracle handle of
    Nothing → Right placeholder
    Just decoded → case checkImage decoded of
      Left fault → Left (Bad (MalformedImage location handle fault))
      Right image → case imageLevels image of
        [] → Left (Bad (MalformedImage location handle (LevelCountInvalid 0)))
        Level width0 height0 _ : _
          | not ownCoordinates && length (imageLevels image) > 1 → Left (Unsure (UnrelatedSecondaryCoordinates location))
          | otherwise →
          let slopes = derivatives (inverseLinear placed) (r u0 * scaleU, r v0 * scaleV, r u1 * scaleU, r v1 * scaleV) (width0, height0)
           in case chooseLevel (length (imageLevels image)) slopes of
                Left NotAxisAligned → Left (Unsure (MinifiedNotAxisAligned location))
                Left FractionalLevel → Left (Unsure (MinifiedFractionalLevel location))
                Right level → case sampleLevel (formatIsSrgb (specFormat spec)) filtering image level (u, v) of
                  Left AtTexelBoundary → Left (Unsure (NearTexelBoundary location))
                  Right source → Right source
  where
    UvRect u0 v0 u1 v1 = instanceUv instanceValue
    r = toRational
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
