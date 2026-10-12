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
import Data.Word (Word8)
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
  , drawingOrder
  , planSnapshot
  , plannedRuns
  , plannedSpace
  , runCount
  , runPath
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
  ( Source
  , blend
  , clearPixel
  , pixelTolerance
  , pixelValue
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
import Hetoimasia.Render.TwoD.Validation (Location (..), ValidSnapshot, validSnapshot)

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
  | -- | An instance on the cutout path could cover the probe; depth
    -- expectations arrive with R2D-9.
    OnCutoutPath !Location
  | -- | A minified probe whose derivatives are sheared or rotated by other than
    -- a quarter turn, on a texture with more than one level.
    MinifiedNotAxisAligned !Location
  | -- | A minified, axis-aligned probe whose level of detail is between two
    -- levels.
    MinifiedFractionalLevel !Location
  | -- | A nearest-filtered coordinate within 1/16 texel of an interior boundary
    -- between texels that differ.
    NearTexelBoundary !Location
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
        [ buildPass input passIndex pass planned
        | (passIndex, pass, planned) ← zip3 [0 ..] (snapshotPasses snapshot) (planPasses plan)
        ]
    , oracleTextures = inputTextures input
    }
  where
    snapshot = validSnapshot (inputSnapshot input)
    plan = planSnapshot (inputCutoutMarks input) (inputSnapshot input)

buildPass ∷ OracleInput → Int → Pass → PlannedPass → OraclePass
buildPass input passIndex pass planned =
  OraclePass
    { opTarget = resolved
    , opClear = passClear pass
    , opViews =
        [ buildView passIndex viewIndex resolved view plannedView
        | (viewIndex, view, plannedView) ← zip3 [0 ..] (passViews pass) (plannedViews planned)
        ]
    }
  where
    resolved = resolveTarget input (passTarget pass)

buildView ∷ Int → Int → Either Failure TargetSpec → View → PlannedView → OracleView
buildView passIndex viewIndex resolved view planned =
  OracleView
    { ovLocation = AtView passIndex viewIndex
    , ovViewport = viewViewport view
    , ovSettings = viewSettings view
    , ovMapping = either (const Nothing) (\spec → viewMapping (specMetrics spec) view) resolved
    , ovLayers =
        [ buildLayer passIndex viewIndex layerIndex layer plannedLayer
        | (layerIndex, layer, plannedLayer) ← zip3 [0 ..] (viewLayers view) (plannedLayers planned)
        ]
    }

buildLayer ∷ Int → Int → Int → Layer → PlannedLayer → OracleLayer
buildLayer passIndex viewIndex layerIndex layer planned =
  OracleLayer
    { olSpace = plannedSpace planned
    , olInstances =
        [ Drawn (AtInstance passIndex viewIndex layerIndex index) (instances ! index) path
        | (index, path) ← zip (drawingOrder planned) paths
        ]
    }
  where
    list = layerInstances layer
    instances = listArray (0, length list - 1) list
    paths = concatMap (\run → replicate (runCount run) (runPath run)) (plannedRuns planned)

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
       in Expected (pixelValue final) (pixelTolerance final)

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
    near = nearBoundary (1 / 16) (viewportEdges viewport) (realToFrac centreX, realToFrac centreY)
    body = case ovMapping view of
      -- A mapping is needed by an instance that has area: a singular quad is
      -- known to cover nothing from its own transform.
      Nothing → [Bad (MappingNotRepresentable (ovLocation view)) | any needsMapping (concatMap olInstances (ovLayers view))]
      Just mapping →
        concat
          [ mapMaybe (instanceFragment oracle spec x y view mapping (olSpace layer)) (olInstances layer)
          | layer ← ovLayers view
          ]

-- | Whether an instance has area, so that drawing it needs the view's mapping.
needsMapping ∷ Drawn → Bool
needsMapping (Drawn _ instanceValue _) = not (instanceIsSingular (instanceTransform instanceValue))

-- | A viewport's four edges, in 'Double'.
viewportEdges ∷ Viewport → [((Double, Double), (Double, Double))]
viewportEdges (Viewport (V2 ox oy) (V2 width height)) =
  [(topLeft, topRight), (topRight, bottomRight), (bottomRight, bottomLeft), (bottomLeft, topLeft)]
  where
    left = realToFrac ox
    top = realToFrac oy
    right = left + realToFrac width
    bottom = top + realToFrac height
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
            NearEdge → Just (Unsure (if cutout then OnCutoutPath location else NearQuadEdge location))
            Inside local
              | cutout → Just (Unsure (OnCutoutPath location))
              | otherwise → Just (sampled oracle spec view instanceValue location placed local)
  where
    transform = instanceTransform instanceValue
    cutout = path == Cutout
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

-- | The fragment an instance draws at a pixel its quad covers, at local
-- coordinates @(lx, ly)@.
sampled ∷ Oracle → TargetSpec → OracleView → Instance → Location → Placement → (Rational, Rational) → Fragment
sampled oracle spec view instanceValue location placed (lx, ly) =
  case oracleTextures oracle handle of
    Nothing → Draws (lit placeholder)
    Just decoded → case checkImage decoded of
      Left fault → Bad (MalformedImage location handle fault)
      Right image → case imageLevels image of
        [] → Bad (MalformedImage location handle (LevelCountInvalid 0))
        Level width0 height0 _ : _ →
          let slopes = derivatives (inverseLinear placed) (r u0, r v0, r u1, r v1) (width0, height0)
           in case chooseLevel (length (imageLevels image)) slopes of
                Left NotAxisAligned → Unsure (MinifiedNotAxisAligned location)
                Left FractionalLevel → Unsure (MinifiedFractionalLevel location)
                Right level → case sampleLevel (formatIsSrgb (specFormat spec)) filtering image level (u, v) of
                  Left AtTexelBoundary → Unsure (NearTexelBoundary location)
                  Right source → Draws (lit source)
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
    lit = shade (instanceTint instanceValue) (settingBrightness settings) (instanceAdditive instanceValue)

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
