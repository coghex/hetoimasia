-- | The terrain material's window-free evidence (TRA-17, Q-13): the cell-quad plans of the terrain
-- arena, adapted through the existing fixed-quad and material ABI over two atlas textures, drawn
-- into offscreen colour targets with a real @D32_SFLOAT@ depth image in a surface-free session,
-- every batch awaited to its actual completion before its readback, every pixel judged twice
-- against @hetoimasia-render-2d-oracle@ given the terrain material's pure model and against a
-- hand-stated expectation that shares no code with the planner, the picker, the atlas adaptation,
-- the material or the oracle ("Test.GPU.Vulkan.Native.TerrainJudge"), and the pure pick compared
-- with that expectation.
--
-- The art is the committed packed atlases, decoded by the bounded PNG decoder (the colour atlas as
-- colour, the normal atlas as data), uploaded as @Rgba8Srgb@ and @Rgba8Linear@ with the decoded
-- binary-alpha mark; the independent expectation reads the source images decoded on their own.
-- The fixtures are the scenes of "Hetoimasia.Terrain.Render2D.Scenes" and
-- "Hetoimasia.Terrain.Render2D.Evidence", the same the CPU suite judges.
--
-- = The two profiles
--
-- @tra17-terrain@ is the complete qualification: every fixture and every negative control, run
-- directly (the runner imposes no deadline on a direct run). @tra17-terrain-ci@ is the bounded
-- selection the required profile runs inside the child deadline: the same code on a subset.
--
-- = What a fixture is judged by
--
-- The oracle judges every pixel it can decide; every pixel it cannot is listed with its reason and
-- counted for nothing. The independent expectation judges every pixel it can decide, the same way.
-- A named probe for each behaviour the fixture exists to show must be determinate for the oracle and
-- differ from its contrast. A control is a draw broken once, which the same judge must reject at
-- its named probes. The depth requirement is never relaxed: where the device chooses another depth
-- format the run is reported as unable to qualify (a failure, never a skip).
module Test.GPU.Vulkan.Native.TerrainPath
  ( terrainSuite
  , runTerrain
  , terrainFixtureCount
  , Profile (..)
  ) where

import Control.Concurrent.STM (atomically, check, orElse, readTVar, registerDelay, retry)
import Control.Exception (evaluate)
import Control.Monad (foldM, forM)
import Crypto.Hash.SHA256 (hash)
import Data.Array (Array, bounds, inRange, listArray, range, (!))
import qualified Data.ByteString as ByteString
import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

import Hetoimasia.GPU.Vulkan.GLFW
  ( ImageDescription (..)
  , ImageFormat (..)
  , ImageKind (TextureImage)
  , Refusal (..)
  , UploadRequest (..)
  , constructDepthFormat
  , constructImage
  , validateTableConfig
  )
import Hetoimasia.GPU.Vulkan.Native.Shader (CheckedShader (..), CheckedShaders (..))
import Hetoimasia.Math.Vector (V2 (..))
import qualified Hetoimasia.Render.Api.Texture as Api
import Hetoimasia.Render.TwoD.Chunk (BoundsRequest (..), ChunkKind (..), ChunkRef)
import Hetoimasia.Render.TwoD.DrawPlan (DrawPlan (..), DrawRun (..), PlannedLayer (..), PlannedPass (..), PlannedView (..), planSnapshot)
import Hetoimasia.Render.TwoD.Material (MaterialRecord (..), MaterialRef)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..))
import Hetoimasia.Render.TwoD.Oracle
  ( Expectation (..)
  , Indeterminate (..)
  , Verdict (..)
  , OracleInput (..)
  , Probe (..)
  , TargetSpec (..)
  , expect
  , newOracleWith
  )
import Hetoimasia.Render.TwoD.Oracle.Colour (Rgba8 (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..))
import Hetoimasia.Render.TwoD.Snapshot
import Hetoimasia.Render.TwoD.Validation (Location (..), validateSnapshotWith)
import qualified Hetoimasia.Render.TwoD.Vulkan as Render
import Hetoimasia.Render.TwoD.Vulkan.Chunks
  ( ChunkStanding (..)
  , Retained
  , buildRetainedChunkWith
  , chunkStandingSTM
  , liveChunks
  , newRetained
  , releaseChunkNow
  , retainedBuffers
  , retainedChunks
  )
import Hetoimasia.Render.TwoD.Vulkan.Material (DefinedMaterial (..))
import Hetoimasia.Render.TwoD.Vulkan.Textures
  ( MarkPolicy (..)
  , Textures
  , newTextures
  , registerTexture
  , markReleased
  , isReleased
  , registeredMark
  , registeredMarks
  , releaseTextureNow
  )
import Hetoimasia.Terrain.Coordinate (TileCoord (..), axisValue)
import Hetoimasia.Terrain.Render2D.Camera (CameraState, camClip, camFacing, camRef)
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Render2D.Evidence
import Hetoimasia.Terrain.Render2D.Scenes
import Hetoimasia.Terrain.Render2D.Vulkan.Material (terrainMaterial, terrainMaterialEquivalent, terrainMaterialInsetControl, terrainMaterialStaleBiasControl, terrainMaterialUnbiasedControl)
import Hetoimasia.Terrain.Shape (allViewFacings)
import Test.GPU.Vulkan.Native.OrderedPath
  ( Evidence
  , FixtureResult (..)
  , ProbeResult (..)
  , Suite (..)
  , awaitPlaceholder
  , configuration
  , finishEvidence
  )
import qualified Test.GPU.Vulkan.Native.OrderedPath as OrderedPath
import Test.GPU.Vulkan.Native.OrderedPath.Fixtures (Fixture (..), NamedProbe (..), TargetShape (..), colourFormatOf, depthShape)
import Test.GPU.Vulkan.Native.RetainedPath (RetainedHost (..), buildersWith)
import Test.GPU.Vulkan.Native.TerrainJudge

import Hetoimasia.Asset.Image (DecodedImage (..))
import Hetoimasia.Terrain.Render2D.AtlasFixtures (AtlasStyle (..), SingleImages (..), bindSingleImages, holedStyle, loadAtlasStyle, loadSingleImages)
import Hetoimasia.Terrain.Render2D.CellPick (CellHit (..), CellPickQuery (..), CellPickResult (..), pickCells)
import Hetoimasia.Terrain.Render2D.Cells
import Hetoimasia.Terrain.Render2D.Material
import Hetoimasia.Terrain.Atlas.Manifest (AtlasEntry (..), AtlasManifest (..), RegionEntry (..), layoutIdentityHex)
import Hetoimasia.Terrain.Render2D.Presentation (LightInput (..), LightSettings, mkLightSettings, pushBytes)
import Hetoimasia.Terrain.Shape (ViewFacing (..))

-- ---------------------------------------------------------------------------
-- The fixtures

-- | Which fixtures a run draws.
data Profile = Full | Bounded
  deriving stock (Eq, Show)

-- | The presentation settings of a fixture, stated twice from the same numbers: as the checked
-- settings the adaptation packs and as the plain values the independent expectation uses.
data Light = Light
  { lightLabel ∷ !String
  , lightSettings ∷ !LightSettings
  , lightHand ∷ !HandLight
  }

mkLight ∷ String → Double → Double → Double → Double → Integer → Double → Double → (Double, Double, Double) → Light
mkLight label azimuth elevation ambient strength depthRange darkening haze colour =
  Light
    label
    (either (\e → error ("light " <> label <> ": " <> show e)) id (mkLightSettings (LightInput azimuth elevation ambient strength depthRange darkening haze colour)))
    (HandLight azimuth elevation ambient strength (fromInteger depthRange) darkening haze colour)

-- | The approved defaults.
defaultLight ∷ Light
defaultLight = mkLight "default" 225 45 0.35 1 250 0.15 0.60 (0.72, 0.85, 0.95)

-- | How a scene's quads are submitted, or how a control breaks the draw.
data Variant
  = -- | One material, the instances in plan order.
    Dynamic
  | -- | One material, the instances in a scrambled order.
    Scrambled
  | -- | The quads split between two registered materials of identical behaviour, scrambled.
    TwoMaterials
  | -- | Two retained chunks and a dynamic remainder, the chunks built from scrambled instances.
    Retained
  | -- | The colour atlas registered unmarked, so the same instances take the ordered path.
    OrderedWrapper
  | -- | The same terrain drawn while its original texture ownership is released between the submission
    -- of the frame and its completion (the device work pending): the frame must still complete and read
    -- back correctly, and the releases are real only after completion.
    ReleasedWhilePending
  | -- | 'ReleasedWhilePending' for retained chunks: two retained chunks and a dynamic remainder.
    RetainedReleasedWhilePending
  | -- | The same terrain drawn with transparent holes punched in the colour art of loam and granite
    -- (a colour atlas of its own, its coverage and assets rebuilt): a pixel is covered only where the
    -- colour texel and the map texel are both opaque, and the holes are independent of the maps'.
    ColourHoles
  | -- | A control: drawn from the plain atlas and plan, judged against the holed art (colour holes ignored).
    HolesIgnored
  | -- | A control: the depth keys' order inverted.
    ReversedKeys
  | -- | A control: every quad's map region is the full-block map (the whole-cell mask).
    WholeCellMask
  | -- | A control: the push block's sun is that of another facing.
    WrongFacingLight
  | -- | A control: every depth word is zero (the depth effects reset).
    DepthReset
  | -- | A control: the loam and granite colour regions' origins are swapped.
    SwappedColourOrigins
  | -- | A control: the normal region is the whole atlas, so the UV spans neighbours (whole-atlas
    -- clamping instead of the region's own).
    WholeAtlasRegion
  | -- | A control: the normal atlas is bound as colour (sRGB, decoded on sampling).
    WrongTreatment
  | -- | The same terrain drawn from 49 single images, each a full-image parent bound to its own
    -- texture, instead of the two packed atlases: it must draw and pick as the packed style does.
    FromSingleImages
  | -- | A control: the region coordinate interpolated between half-texel-inset endpoints, which
    -- shifts the interior texel boundaries (a third, control-only material).
    HalfTexelInset
  | -- | A control: the shader's texel index without the 1/128 bias (a fourth, control-only material),
    -- the rule the Q-13 counterexample was measured under; judged on the exact-boundary scenes.
    UnbiasedIndex
  | -- | A control: the shader's texel index with the first amendment's 1/10000 bias (a fifth,
    -- control-only material), which the device measured too small at pixel-snapped zooms 9/8 and 5/4.
    StaleBias
  | -- | A control: every quad's map region is the next region of the normal atlas (a wrong, in effect
    -- rotated, mask: another shape's silhouette and normals).
    WrongMapRegion
  | -- | A control: drawn correctly, but the pick answers through a fog quad to the known solid behind it.
    PickThroughFog
  | -- | A control: drawn correctly, but a pick that is loading (pending information could lie in front)
    -- answers as a miss.
    PickLoadingAsMiss
  | -- | A control: drawn correctly, but the pick answers through the farthest covered quad.
    BackmostPick
  deriving stock (Eq, Show)

suffixOf ∷ Variant → String
suffixOf = \case
  Dynamic → ""
  Scrambled → "-scrambled"
  TwoMaterials → "-two-materials"
  Retained → "-retained"
  OrderedWrapper → "-ordered-wrapper"
  ReversedKeys → "-control-reversed-overlap"
  ColourHoles → "-colour-holes"
  HolesIgnored → "-control-colour-holes-ignored"
  ReleasedWhilePending → "-released-while-pending"
  RetainedReleasedWhilePending → "-retained-released-while-pending"
  WholeCellMask → "-control-whole-cell-mask"
  WrongFacingLight → "-control-wrong-facing-light"
  DepthReset → "-control-depth-reset"
  SwappedColourOrigins → "-control-swapped-region-origins"
  WholeAtlasRegion → "-control-whole-atlas-clamping"
  WrongTreatment → "-control-normal-as-colour"
  FromSingleImages → "-single-images"
  WrongMapRegion → "-control-wrong-map-region"
  PickThroughFog → "-control-pick-through-fog"
  HalfTexelInset → "-control-half-texel-inset"
  UnbiasedIndex → "-control-unbiased-index"
  StaleBias → "-control-stale-bias-1e-4"
  BackmostPick → "-control-pick-through-nearer"
  PickLoadingAsMiss → "-control-loading-as-miss"

isControl ∷ Variant → Bool
isControl variant = variant `elem` [ReversedKeys, WholeCellMask, WrongFacingLight, DepthReset, SwappedColourOrigins, WholeAtlasRegion, WrongTreatment, HalfTexelInset, HolesIgnored, UnbiasedIndex, StaleBias, WrongMapRegion, PickThroughFog, PickLoadingAsMiss, BackmostPick]

-- | What a fixture must show, each by a named probe that is determinate for the oracle and differs
-- from its contrast.
data Need = Foreground | Overlap | Reveal | Clipped | SnapSensitive | Varies | LightsDiffer | Restores
  deriving stock (Eq, Show)

data Spec = Spec
  { specName ∷ !String
  , specScenes ∷ ![Scene]
  -- ^ One pass each, into a target of its own.
  , specVariant ∷ !Variant
  , specLight ∷ !Light
  , specNeeds ∷ ![Need]
  , specLater ∷ ![Light]
  -- ^ The lights of the second and later scenes of a fixture (the first scene has 'specLight'); a
  -- scene without one uses 'specLight'. Each pass's view holds the push block of its own light.
  , specCamera ∷ !(Maybe (Integer, Integer))
  -- ^ The cut level and vertical reference the scene's camera must come to, stated here by hand.
  }

-- | A fixture of one scene.
spec ∷ Light → [Need] → Variant → Scene → Spec
spec light needs variant sc = Spec (sceneName sc <> (if lightLabel light == "default" then "" else "@" <> lightLabel light) <> suffixOf variant) [sc] variant light needs [] Nothing

-- | The light of the scene at this index of a fixture.
lightOf ∷ Spec → Int → Light
lightOf s index = case drop (index - 1) (specLater s) of
  light : _ | index > 0 → light
  _ → specLight s

-- | A fixture that draws one scene twice, in two passes whose views hold different lights: the
-- first under the default light, the second under this one, so that a pixel of one differs from
-- the same pixel of the other and two views sharing a registered material keep their own pushes.
twoLights ∷ Light → Scene → Spec
twoLights second sc = Spec (sceneName sc <> "@" <> lightLabel second <> "-beside-default") [sc, sc] Dynamic defaultLight [Foreground, LightsDiffer] [second] Nothing

expecting ∷ (Integer, Integer) → Spec → Spec
expecting camera s = s {specCamera = Just camera}

-- | A fixture of several scenes, each drawn in a pass of its own into a small target.
specMany ∷ String → [Need] → [Scene] → Spec
specMany name needs scs = Spec name scs Dynamic defaultLight needs [] Nothing

mixedScene ∷ ViewFacing → Scene
mixedScene facing =
  atZoom 0.25 $
    (newScene ("mixed-" <> show facing) cells (64, 64))
      { sceneFacing = facing
      , sceneAnchor = (1, 1)
      , sceneKnow = [((0, 0, 0), KnownSolid), ((2, 0, 0), Undisc), ((1, 2, 0), KnownSolid)]
      , sceneFogOnly = [(3, 1, 0)]
      }
  where
    cells = [Cell 0 0 0 1 5 "loam", Cell 1 0 0 1 9 "granite", Cell 2 0 0 1 3 "loam", Cell 1 2 0 1 12 "granite", Cell 1 1 0 1 0 "loam"]

-- | A confirmed undiscovered cell in front of a known solid on one view ray, so a pick that passes
-- through the fog has a known cell to land on.
fogOverKnown ∷ ViewFacing → Scene
fogOverKnown facing =
  atZoom 0.25 $
    (newScene ("fog-over-known-" <> show facing) [Cell 0 0 0 1 0 "loam", Cell 1 1 0 1 0 "granite", Cell 1 1 1 2 0 "loam"] (64, 64))
      { sceneFacing = facing
      , sceneAnchor = (0, 0)
      , sceneMode = ManualAt 1 1
      , sceneKnow = [((1, 1, 1), Undisc)]
      }

lights ∷ [Light]
lights =
  [ mkLight "sun-only" 225 45 0 1 250 0 0 (0.72, 0.85, 0.95)
  , mkLight "ambient-only" 225 45 0.35 0 250 0 0 (0.72, 0.85, 0.95)
  , mkLight "dark" 225 45 0 0 250 0 0 (0.72, 0.85, 0.95)
  , mkLight "horizon" 225 0 0.35 1 250 0 0 (0.72, 0.85, 0.95)
  , mkLight "below-horizon" 225 (-30) 0.35 1 250 0 0 (0.72, 0.85, 0.95)
  , mkLight "west-low" 270 10 0 1 250 0 0 (0.72, 0.85, 0.95)
  , mkLight "north-high" 0 80 0.2 0.8 250 0 0 (0.72, 0.85, 0.95)
  ]

depthLights ∷ [Light]
depthLights =
  [ mkLight "neither-effect" 225 45 0.35 1 4 0 0 (0.72, 0.85, 0.95)
  , mkLight "darkening-only" 225 45 0.35 1 4 0.5 0 (0.72, 0.85, 0.95)
  , mkLight "haze-only" 225 45 0.35 1 4 0 0.8 (0.72, 0.85, 0.95)
  , mkLight "both-short-range" 225 45 0.35 1 4 0.5 0.8 (0.72, 0.85, 0.95)
  , mkLight "black-under-haze" 225 45 0 0 4 0 0.8 (0.72, 0.85, 0.95)
  , mkLight "haze-no-light" 225 45 0 0 4 0.3 0 (0.72, 0.85, 0.95)
  ]

-- | The fixtures, in the order they are rendered.
specs ∷ Profile → [Spec]
specs profile = case profile of
  Bounded →
    [specMany ("matrix-FaceSouth-0.25") [Foreground, Varies] [shapeMatrixCell shape FaceSouth 0.25 | shape ← [0 .. 15]]]
      <> [spec defaultLight [Foreground, Varies] Dynamic (mixedScene FaceSouth)]
      <> [spec defaultLight [Foreground, Varies] FromSingleImages (mixedScene FaceSouth)]
      <> [spec defaultLight [Foreground, Overlap] variant (atZoom 0.125 (roofOverCavity 1 FaceWest)) | variant ← [Dynamic, Scrambled, TwoMaterials, Retained, OrderedWrapper]]
      <> [spec defaultLight [Foreground, Overlap, Varies] Dynamic (atZoom 0.125 (rampsCorners FaceEast))]
      <> [spec (mkLight "black-under-haze" 225 45 0 0 4 0 0.8 (0.72, 0.85, 0.95)) [Foreground, Varies] Dynamic (depthStack FaceSouth)]
      <> [spec defaultLight [Foreground, Overlap] ReversedKeys (atZoom 0.125 (disconnectedSpans FaceSouth))]
  Full →
    [specMany ("matrix-" <> show facing <> "-0.25") [Foreground, Varies] [shapeMatrixCell shape facing 0.25 | shape ← [0 .. 15]] | facing ← allViewFacings]
      <> [specMany "native-scale-FaceSouth-1" [Foreground] [shapeMatrixCell shape FaceSouth 1 | shape ← [0, 7]]]
      <> [spec defaultLight [Foreground, Varies] Dynamic (mixedScene facing) | facing ← allViewFacings]
      -- The same shapes and roles from single images: every identity its own parent and texture.
      <> [(specMany ("matrix-" <> show facing <> "-0.25-single-images") [Foreground, Varies] [shapeMatrixCell shape facing 0.25 | shape ← [0 .. 15]]) {specVariant = FromSingleImages} | facing ← allViewFacings]
      <> [spec defaultLight [Foreground, Varies] FromSingleImages (mixedScene facing) | facing ← allViewFacings]
      <> [ spec defaultLight [Foreground, Overlap] Dynamic (atZoom 0.125 (roofOverCavity 2 FaceSouth))
         , spec defaultLight [Foreground, Overlap] Dynamic (atZoom 0.125 (roofOverCavity 1 FaceSouth))
         ]
      <> [spec defaultLight [Foreground, Overlap] variant (atZoom 0.125 (roofOverCavity 1 FaceWest)) | variant ← [Dynamic, Scrambled, TwoMaterials, Retained, OrderedWrapper]]
      <> [ spec defaultLight [Foreground, Overlap] Dynamic (atZoom 0.125 (disconnectedSpans FaceNorth))
         , spec defaultLight [Foreground, Overlap, Varies] Dynamic (atZoom 0.125 (rampsCorners FaceEast))
         ]
      <> [spec defaultLight [Foreground] Dynamic (atZoom 0.125 (staircase cut FaceSouth)) | cut ← [1, 3, 5]]
      <> [exactBoundaryFixture shape facing | (shape, facing) ← exactBoundaryCases]
      <> [edgeFixture zoom shape facing | (zoom, shape, facing) ← edgeCases]
      <> matrixExtensions
      <> [ expecting (28, 4) (spec defaultLight [Foreground] Dynamic (atZoom 0.125 (followHeadroom FaceSouth)))
         , expecting (0, -33) (spec defaultLight [Foreground, Varies] Dynamic (deepFloor FaceSouth))
         ]
      <> [spec defaultLight [Foreground] Dynamic (capTarget (96, 64) (zoomEndpoint zoom)) | zoom ← [0.125, 8]]
      <> [ spec defaultLight [Foreground] Dynamic (atZoom 0.1875 fractionalCamera)
         , spec defaultLight [Foreground, Clipped] Dynamic (viewportOffset 0.125)
         , spec defaultLight [Foreground] Dynamic (capTarget (96, 64) (atZoom 0.125 scaledTarget))
         , spec defaultLight [Foreground] Dynamic snappedZoom2
         ]
      -- At a WHOLE scale (8) every texel and quad edge is the origin plus whole pixels, so rounding the origin
      -- by less than half a pixel moves no pixel centre across an edge except at an exact tie: snapping
      -- cannot be discriminated there, and the fixture is judged exactly, every pixel decided, without that
      -- need. At 9/8, 5/4 and 63/8 it can and is.
      <> [spec defaultLight (if sceneZoom sc == 8 then [Foreground] else [Foreground, SnapSensitive]) Dynamic sc | sc ← snappedScenes]
      -- Lighting: the fixed world sun with the camera turned, and the sun varied at a fixed camera.
      <> [spec defaultLight [Foreground, Varies] Dynamic (atZoom 0.125 (rampsCorners facing)) | facing ← [FaceSouth, FaceWest]]
      <> [spec light [Foreground, Varies] Dynamic (atZoom 0.125 (rampsCorners FaceSouth)) | light ← lights, lightLabel light /= "dark"]
      <> [twoLights light (atZoom 0.125 (rampsCorners FaceSouth)) | light ← lights, lightLabel light == "dark"]
      -- Depth effects at the configured range, with the effects separately and together.
      <> [spec light [Foreground, Varies] Dynamic (depthStack FaceSouth) | light ← depthLights, lightLabel light /= "haze-no-light"]
      <> [twoLights light (depthStack FaceSouth) | light ← depthLights, lightLabel light == "haze-no-light"]
      <> [spec light [Foreground, Varies] Dynamic (depthStack FaceNorth) | light ← take 2 (reverse depthLights), lightLabel light /= "haze-no-light"]
      -- Negative controls, each a draw broken once, on the scene that makes the protected behaviour matter.
      <> [ spec defaultLight [Foreground, Overlap] ReversedKeys (atZoom 0.125 (disconnectedSpans FaceSouth))
         , spec defaultLight [Foreground, Varies] WholeCellMask (atZoom 0.125 (rampsCorners FaceSouth))
         , spec defaultLight [Foreground, Varies] WrongFacingLight (atZoom 0.125 (rampsCorners FaceWest))
         , spec (mkLight "neither-effect-haze" 225 45 0.35 1 4 0.5 0.8 (0.72, 0.85, 0.95)) [Foreground, Varies] DepthReset (depthStack FaceSouth)
         , spec defaultLight [Foreground, Varies] SwappedColourOrigins (atZoom 0.25 (shapeMatrix FaceSouth 1))
         , spec defaultLight [Foreground, Varies] WholeAtlasRegion (atZoom 0.125 (rampsCorners FaceSouth))
         , spec defaultLight [Foreground, Varies] WrongTreatment (atZoom 0.125 (rampsCorners FaceSouth))
         , spec defaultLight [Foreground, Varies] HalfTexelInset (atZoom 0.125 (rampsCorners FaceSouth))
         , spec defaultLight [Foreground, Varies] WrongMapRegion (atZoom 0.125 (rampsCorners FaceSouth))
         , spec defaultLight [Foreground, Varies] PickThroughFog (fogOverKnown FaceSouth)
         , spec defaultLight [Foreground, Overlap] BackmostPick (atZoom 0.125 (disconnectedSpans FaceSouth))
         ]
      -- The Q-13 negative control: the same exact-boundary fixtures drawn without the texel bias.
      <> [spec defaultLight [Foreground] PickLoadingAsMiss (pendingScene FaceSouth)]
      <> [spec defaultLight [Foreground, Varies] HolesIgnored (shapeMatrixCell 5 FaceSouth 1)]
      <> [exactBoundaryWith UnbiasedIndex shape facing | (shape, facing) ← exactBoundaryCases]
      <> [staleBiasFixture sc | sc ← staleBiasScenes]
      -- Last: these release the atlases' ownership (marked while their frames are pending), so nothing may
      -- draw from the atlases after them.
      <> [ spec defaultLight [Foreground, Overlap] RetainedReleasedWhilePending (atZoom 0.125 (roofOverCavity 1 FaceWest))
         , spec defaultLight [Foreground, Varies] ReleasedWhilePending (mixedScene FaceSouth)
         ]

-- | The ramps and corners with pixel snapping on at zoom 1, the camera a fraction of a pixel off
-- the pixel grid. At a whole-number scale a nearest-sampled quad cannot change when the view is
-- shifted by less than half a pixel (the sampled texel is the same), so this fixture judges that
-- snapping leaves the picture correct and does not claim to discriminate it from an ignored setting.
-- At the fractional snap-compatible scales (9/8 and 5/4) the device agrees with the independent
-- expectation at every decided pixel and the reusable oracle disagrees at about a hundred
-- boundary-adjacent pixels; that discrepancy is recorded in the evidence, not hidden by a looser
-- tolerance or a dropped fixture.
snappedZoom2 ∷ Scene
snappedZoom2 = snapped

-- | A single cell of a shape at zoom 1/2 in an even target with no pan, so the canvas corner lies on
-- a whole device pixel and every pixel centre lies exactly on a texel boundary of the canvas (a
-- pixel is two texels wide). The expectation is the rule itself, in exact arithmetic.
exactBoundary ∷ Int → ViewFacing → Scene
exactBoundary shape facing = (newScene ("exact-boundary-" <> show shape <> "-" <> show facing) [Cell 0 0 0 1 shape "loam"] (64, 48)) {sceneFacing = facing, sceneZoom = 0.5}

-- | The snapped scenes at the fractional scales where 1/10000 was measured too small, with the
-- reference's own names, and their fixtures: judged exactly and drawn by the terrain material; drawn
-- by the stale-bias control after an ordinary pass, which must be rejected on the snapped pass.
snappedScenes ∷ [Scene]
snappedScenes = [snappedAt label zoom | (label, zoom) ← [("1-8", 0.125), ("9-8", 1.125), ("5-4", 1.25), ("63-8", 7.875), ("8", 8)]]

-- | The two scales where the measured counterexample lay: the stale-bias control is drawn at them.
staleBiasScenes ∷ [Scene]
staleBiasScenes = take 2 (drop 1 snappedScenes)

-- | The edge and diagonal fixture: an ordinary pass whose named probes the oracle decides, then the
-- edge scene.
edgeFixture ∷ Float → Int → ViewFacing → Spec
edgeFixture zoom shape facing =
  Spec (sceneName sc <> "-beside-ordinary") [shapeMatrixCell 0 FaceSouth 1, sc] Dynamic defaultLight [Foreground] [] Nothing
  where
    sc = edgeScene zoom shape facing

-- | The scales and shapes of the edge fixtures: the minified endpoint 1/8, 1/2 and native scale.
edgeCases ∷ [(Float, Int, ViewFacing)]
edgeCases = [(0.125, 0, FaceSouth), (0.125, 15, FaceEast), (0.5, 0, FaceSouth), (0.5, 9, FaceWest), (1, 0, FaceSouth), (1, 5, FaceNorth)]
staleBiasFixture ∷ Scene → Spec
staleBiasFixture sc =
  Spec (sceneName sc <> "-beside-ordinary" <> suffixOf StaleBias) [shapeMatrixCell 0 FaceSouth 1, sc] StaleBias defaultLight [Foreground] [] Nothing

-- | Seams across the region lattice, legal-coordinate extremes and coherent supplied snapshot sequences
-- (the issue's matrix beyond the shapes): every pass is judged by the independent exact expectation, the
-- sequences that end where they began must draw that state again pixel for pixel.
matrixExtensions ∷ [Spec]
matrixExtensions =
  [spec defaultLight [Foreground] Dynamic (seamScene facing) | facing ← allViewFacings]
    <> [spec defaultLight [Foreground] Dynamic (seamScenesNegative facing) | facing ← [FaceSouth, FaceNorth]]
    <> [spec defaultLight [Foreground, Varies] Dynamic (extremeScene high facing) | high ← [True, False], facing ← [FaceSouth, FaceEast]]
    <> [spec defaultLight [Foreground, Varies] Dynamic (pendingScene facing) | facing ← allViewFacings]
    -- Transparent holes in the colour art, independent of the maps' holes: native scale for visible holes,
    -- the matrix, ramps and mixed parts at the usual scales.
    <> [spec defaultLight [Foreground, Varies] ColourHoles (shapeMatrixCell shape facing 1) | (shape, facing) ← [(5, FaceSouth), (9, FaceWest), (0, FaceEast)]]
    <> [(specMany "matrix-FaceSouth-0.25-colour-holes" [Foreground, Varies] [shapeMatrixCell shape FaceSouth 0.25 | shape ← [0 .. 15]]) {specVariant = ColourHoles}]
    <> [spec defaultLight [Foreground, Varies] ColourHoles (atZoom 0.125 (rampsCorners FaceSouth)), spec defaultLight [Foreground, Varies] ColourHoles (mixedScene FaceSouth)]
    <> sequences

-- | The base of the supplied sequences: ramps and corners at zoom 1/8.
sequenceBase ∷ Scene
sequenceBase = atZoom 0.125 (rampsCorners FaceSouth)

sequences ∷ [Spec]
sequences =
  [ specMany "sequence-pan" [Foreground, Varies] [shiftPan (k * 0.5, k * 0.25) sequenceBase | k ← [0, 1, 2, 3]]
  , specMany "sequence-zoom" [Foreground, Varies] [atZoom z (rampsCorners FaceSouth) | z ← [0.125, 0.1875, 0.25, 0.375]]
  , specMany "sequence-rotation" [Foreground, Varies] [atZoom 0.125 (rampsCorners facing) | facing ← [FaceSouth, FaceWest, FaceNorth, FaceEast]]
  , restoring "sequence-manual-follow-manual" [sequenceBase, sequenceBase {sceneMode = FollowSurface}, sequenceBase]
  , restoring "sequence-jump" [sequenceBase, sequenceBase {sceneAnchor = (2, 2)}, sequenceBase {sceneAnchor = (2, 2), sceneMode = ManualAt 2 2}, sequenceBase]
  , specMany "sequence-reveal" [Foreground, Varies] (revealStages (mixedScene FaceSouth))
  , restoring "sequence-unload-reload" [sequenceBase, sequenceBase {sceneCells = take 1 (sceneCells sequenceBase), sceneAnchor = (0, 0)}, sequenceBase]
  ]
  where
    restoring name scs = (specMany name [Foreground, Varies, Restores] scs)

-- | Knowledge arriving: first nothing known, then the known solids beside undiscovered voids, then everything discovered.
revealStages ∷ Scene → [Scene]
revealStages sc =
  [ sc {sceneKnow = [(c, Undisc) | c ← unitCells], sceneFogOnly = []}
  , sc
  , sc {sceneKnow = [], sceneFogOnly = []}
  ]
  where
    unitCells = [(cellX c, cellY c, z) | c ← sceneCells sc, z ← [cellZ0 c .. cellZ1 c - 1]]

-- | The shapes and facings of the exact-boundary fixtures and of their negative control.
exactBoundaryCases ∷ [(Int, ViewFacing)]
exactBoundaryCases = [(0, FaceSouth), (5, FaceSouth), (15, FaceWest), (9, FaceEast)]

-- | A fixture of two passes: the first an ordinary scene whose named probes the oracle decides, the
-- second the exact-boundary scene the oracle cannot decide and the independent expectation does.
exactBoundaryFixture ∷ Int → ViewFacing → Spec
exactBoundaryFixture = exactBoundaryWith Dynamic

-- | The same fixture drawn by a variant: with 'UnbiasedIndex' it is the Q-13 negative control, which
-- must be rejected on the exact-boundary pass on the device where the counterexample was measured.
exactBoundaryWith ∷ Variant → Int → ViewFacing → Spec
exactBoundaryWith variant shape facing =
  Spec ("exact-boundary-" <> show shape <> "-" <> show facing <> "-beside-ordinary" <> suffixOf variant) [shapeMatrixCell 0 FaceSouth 1, exactBoundary shape facing] variant defaultLight [Foreground] [] Nothing

-- | One cell of a shape in a facing at a zoom, in a target sized to its hexagon.
shapeMatrixCell ∷ Int → ViewFacing → Float → Scene
shapeMatrixCell shape facing zoom = atZoom zoom (singleShape shape facing)

terrainFixtureCount ∷ Profile → Int
terrainFixtureCount = length . specs

-- | The suite: its fixtures are the specs, counted for the record's verdict.
terrainSuite ∷ Profile → Suite
terrainSuite profile = Suite name (name <> "-probes.json") [] (map placeholder (specs profile)) True
  where
    name = case profile of
      Full → "tra17-terrain"
      Bounded → "tra17-terrain-ci"
    placeholder s = Fixture (Text.pack (specName s)) [] [] (const (Snapshot [])) []

-- ---------------------------------------------------------------------------
-- The session

data Ctx = Ctx
  { ctxProfile ∷ !Profile
  , ctxHost ∷ !RetainedHost
  , ctxDirectory ∷ !FilePath
  , ctxRenderer ∷ !Render.Renderer
  , ctxTextures ∷ !Textures
  , ctxRetained ∷ !Retained
  , ctxStyle ∷ !AtlasStyle
  , ctxAtlas ∷ !AtlasTextures
  -- ^ The marked colour atlas and the normal atlas, the style's own textures.
  , ctxColourH ∷ !Api.TextureHandle
  , ctxNormalH ∷ !Api.TextureHandle
  , ctxSingle ∷ !SingleImages
  , ctxSingleTextures ∷ !AtlasTextures
  , ctxSubPixelBits ∷ !Int
  -- ^ The device's queried @subPixelPrecisionBits@ (never assumed), which sets the width of the band in
  -- which an unsnapped fractional fixture's sample is undecided.
  , ctxHoled ∷ !AtlasStyle
  -- ^ The style with transparent colour holes, its colour atlas registered as a texture of its own.
  , ctxHoledAtlas ∷ !AtlasTextures
  , ctxHoledH ∷ !Api.TextureHandle
  , ctxUnmarked ∷ !Api.TextureHandle
  -- ^ The colour atlas registered a second time with its cutout mark overridden off.
  , ctxNormalAsColour ∷ !Api.TextureHandle
  , ctxAll ∷ ![Api.TextureHandle]
  , ctxDecoded ∷ !(Map.Map Api.TextureHandle DecodedImage)
  , ctxPrimary ∷ !MaterialRef
  , ctxSecond ∷ !MaterialRef
  , ctxInset ∷ !MaterialRef
  , ctxUnbiased ∷ !MaterialRef
  , ctxStale ∷ !MaterialRef
  , ctxDevice ∷ !Text
  }

-- | The renderer's configuration for this case: the shared one with a texture table of 128 slots,
-- because the single-image style registers two atlases, two control registrations and 49 images at
-- once. This is the harness's table capacity for the case, not a texture-admission bank.
terrainConfiguration ∷ Render.Configuration
terrainConfiguration = configuration {Render.configurationTable = either (error . show) id (validateTableConfig 128 8 4)}

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

sha256Hex ∷ ByteString.ByteString → String
sha256Hex = concatMap two . ByteString.unpack . hash
  where
    two byte = (if byte < 16 then "0" else "") <> showHex byte ""

-- | The session's depth must be @D32_SFLOAT@; a fixture is never rendered over anything lower, and
-- nothing is skipped.
runTerrain ∷ Profile → RetainedHost → IO (Maybe Text) → IO (Maybe Int) → FilePath → IO Evidence
runTerrain profile host deviceName subPixelBitsOf directory = do
  started ← getCurrentTime
  createDirectoryIfMissing True directory
  depth ← OrderedPath.hostAct (retainedBase host) "choosing the depth format" constructDepthFormat
  device ← fromMaybe "unknown" <$> deviceName
  case depth of
    Left why → finish Nothing (Just why) []
    Right format
      | format /= Depth32Float → finish (Just format) (Just ("this device cannot qualify the terrain material: it chose the depth format " <> tshow format <> ", never a lower-precision substitute for D32_SFLOAT; nothing was rendered")) []
      | otherwise → do
          style ← loadAtlasStyle 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
          singles ← loadSingleImages 5 [("loam", "colour.loam"), ("granite", "colour.granite")]
          queried ← subPixelBitsOf
          case queried of
           Nothing → finish (Just format) (Just "the device's subPixelPrecisionBits could not be queried, and the undecided band of an unsnapped fractional fixture is set by it: nothing was judged on an assumed value") []
           Just bits → prepare profile host directory device bits style singles >>= \case
            Left why → finish (Just format) (Just why) []
            Right ctx → do
              results ← foldM (\done s → (: done) <$> timed (runSpec ctx s)) [] (specs profile)
              teardown ctx
              ended ← getCurrentTime
              let ordered = reverse results
              writeRecord ctx format (realToFrac (diffUTCTime ended started)) ordered
              finish (Just format) Nothing (map fst ordered)
  where
    finish format failure results = finishEvidence (terrainSuite profile) directory format Nothing failure results

-- | A fixture's run, with where the seconds went.
timed ∷ IO (FixtureResult, Extra) → IO (FixtureResult, Extra)
timed action = do
  started ← getCurrentTime
  (result, extra) ← action
  acted ← getCurrentTime
  _ ← evaluate (OrderedPath.fixturePassed result)
  oracled ← getCurrentTime
  _ ← evaluate (maybe 0 indMismatchCount (extraIndependent extra))
  independent ← getCurrentTime
  _ ← evaluate (extraPickMismatches extra)
  ended ← getCurrentTime
  let seconds a b = realToFrac (diffUTCTime b a)
  pure (result, extra {extraSeconds = [seconds started acted, seconds acted oracled, seconds oracled independent, seconds independent ended]})

-- | Make the renderer, the registries, the textures and both materials.
prepare ∷ Profile → RetainedHost → FilePath → Text → Int → AtlasStyle → SingleImages → IO (Either Text Ctx)
prepare profile host directory device subPixelBits style singles = do
  let holedOf = either (error . ("the holed style: " <>)) id (holedStyle style)
      images =
        [ (styleColourImage style, Rgba8Srgb, DefaultMark)
        , (styleNormalImage style, Rgba8Linear, DefaultMark)
        , (styleColourImage style, Rgba8Srgb, OverrideMark False)
        , (styleNormalAsColour style, Rgba8Srgb, DefaultMark)
        ]
          <> [(decoded, if take 7 identity == "colour." then Rgba8Srgb else Rgba8Linear, DefaultMark) | (identity, decoded, _) ← singleImages singles]
          <> [(styleColourImage holedOf, Rgba8Srgb, DefaultMark)]
  made ← OrderedPath.hostAct (retainedBase host) "making the renderer and the atlas textures" $ \construction → do
    renderer ← Render.makeRenderer (buildersWith (retainedSubmit host) construction) terrainConfiguration
    made' ← traverse (\(decoded, format, _) → constructImage construction (ImageDescription TextureImage format (decodedWidth decoded) (decodedHeight decoded) 1)) images
    pure ((,) <$> renderer <*> sequence made')
  case made of
    Left failure → pure (Left failure)
    Right (renderer, gpuImages) → do
      uploads ← traverse (\((decoded, _, _), image) → OrderedPath.hostUpload (retainedBase host) (UploadImage image (decodedLevels decoded))) (zip images gpuImages)
      case sequence uploads of
        Left failure → pure (Left ("an upload did not complete: " <> failure))
        Right _ →
          awaitPlaceholder (retainedBase host) (200 ∷ Int) >>= \case
            Left failure → pure (Left failure)
            Right () → do
              textures ← newTextures
              registered ← OrderedPath.hostAct (retainedBase host) "registering the atlases" $ \construction →
                fmap sequence . forM (zip images gpuImages) $ \((decoded, _, policy), image) →
                  registerTexture (buildersWith (retainedSubmit host) construction) textures image decoded policy >>= \case
                    Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                    Right handle → pure (Right (handle, decoded))
              case registered of
                Left failure → pure (Left failure)
                Right entries@((colourH, colourD) : (normalH, normalD) : (unmarkedH, unmarkedD) : (asColourH, asColourD) : rest)
                  | length rest == length (singleImages singles) + 1
                  , Just (holedEntry, _) ← Just (case reverse rest of lastEntry : _ → (lastEntry, ()); [] → error "no holed atlas entry") →
                      let singleHandles = Map.fromList (zip [identity | (identity, _, _) ← singleImages singles] (map fst rest))
                       in case ((,,,) <$> either (Left . show) Right (bindColourParent (styleColour style) colourH) <*> either (Left . show) Right (bindDataParent (styleNormal style) normalH) <*> bindSingleImages singles singleHandles <*> either (Left . show) Right (bindColourParent (styleColour holedOf) (fst holedEntry))) of
                 Left refused → pure (Left ("a parent could not be bound to its texture: " <> Text.pack refused))
                 Right (colourBound, normalBound, singleBound, holedColourBound) → do
                  retained ← newRetained
                  primary ← Render.registerMaterial renderer terrainMaterial
                  second ← Render.registerMaterial renderer terrainMaterialEquivalent
                  inset ← Render.registerMaterial renderer terrainMaterialInsetControl
                  unbiased ← Render.registerMaterial renderer terrainMaterialUnbiasedControl
                  stale ← Render.registerMaterial renderer terrainMaterialStaleBiasControl
                  pure
                    ( Right
                        Ctx
                          { ctxProfile = profile
                          , ctxHost = host
                          , ctxDirectory = directory
                          , ctxRenderer = renderer
                          , ctxTextures = textures
                          , ctxRetained = retained
                          , ctxStyle = style
                          , ctxAtlas = packedTextures colourBound normalBound
                          , ctxColourH = colourH
                          , ctxNormalH = normalH
                          , ctxSingle = singles
                          , ctxSingleTextures = singleBound
                          , ctxSubPixelBits = subPixelBits
                          , ctxHoled = holedOf
                          , ctxHoledAtlas = packedTextures holedColourBound normalBound
                          , ctxHoledH = fst holedEntry
                          , ctxUnmarked = unmarkedH
                          , ctxNormalAsColour = asColourH
                          , ctxAll = map fst entries
                          , ctxDecoded = Map.fromList ([(colourH, colourD), (normalH, normalD), (unmarkedH, unmarkedD), (asColourH, asColourD)] <> [(h, d) | ((h, _), (_, d, _)) ← zip rest (singleImages singles)] <> [(fst holedEntry, snd holedEntry)])
                          , ctxPrimary = primary
                          , ctxSecond = second
                          , ctxInset = inset
                          , ctxUnbiased = unbiased
                          , ctxStale = stale
                          , ctxDevice = device
                          }
                    )
                Right _ → pure (Left "the atlas registration did not return a handle for every texture")

-- | Release what the run made: the retained chunks it still holds, and the atlases.
teardown ∷ Ctx → IO ()
teardown ctx = do
  live ← liveChunks (ctxRetained ctx)
  _ ← OrderedPath.hostAct (retainedBase (ctxHost ctx)) "releasing the retained chunks" $ \construction → do
    let builders = buildersWith (retainedSubmit (ctxHost ctx)) construction
    results ← traverse (releaseChunkNow builders (ctxRetained ctx)) live
    pure (sequence_ results)
  _ ← OrderedPath.hostAct (retainedBase (ctxHost ctx)) "releasing the atlases" $ \construction → do
    let builders = buildersWith (retainedSubmit (ctxHost ctx)) construction
    results ← traverse (releaseTextureNow builders (ctxTextures ctx)) (ctxAll ctx)
    pure (sequence_ results)
  pure ()

-- ---------------------------------------------------------------------------
-- One fixture

-- | What a fixture's record keeps besides its probes.
data Extra = Extra
  { extraSpec ∷ !Spec
  , extraQuads ∷ ![Int]
  , extraRecords ∷ ![Int]
  , extraIdentity ∷ ![String]
  , extraRuns ∷ ![(String, Int, String)]
  , extraMarks ∷ ![(String, Maybe Bool)]
  , extraIndependent ∷ !(Maybe Independent)
  , extraBand ∷ ![PassBand]
  -- ^ For each pass, its undecided band in texels (amendment v3, from the device's queried
  -- @subPixelPrecisionBits@ and the pass's own view scale), whether it is eligible, its undecided and
  -- covered counts and its raster margin.
  , extraPassMismatches ∷ ![(Int, [String])]
  -- ^ For each pass, its independent mismatch count and its first mismatches.
  , extraPickCompared ∷ !Int
  , extraPickUndecided ∷ !Int
  -- ^ Sampled pixels the picking contract leaves undecided: the one-device-pixel conservative ring
  -- around a nearer pending cell's canvas. Never compared.
  , extraPickMismatches ∷ !Int
  , extraPickFirst ∷ ![String]
  , extraRejected ∷ !(Maybe Bool)
  , extraControlDiffers ∷ !(Maybe Bool)
  , extraTargets ∷ ![(Int, Int)]
  , extraSnapDifferences ∷ !(Maybe Int)
  , extraSeconds ∷ ![Double]
  }

emptyExtra ∷ Spec → Extra
emptyExtra s = Extra s [] [] [] [] [] Nothing [] [] 0 0 0 [] Nothing Nothing [] Nothing []

failed ∷ String → String → FixtureResult
failed name why = FixtureResult (Text.pack name) [] [] [] (Just (Text.pack why))

-- | A deterministic scramble: neither plan order, nor reversed, nor sorted by anything the planner
-- or the renderer uses.
scramble ∷ [a] → [a]
scramble items = map snd (sortOn fst [(((i * 2654435761) `mod` 4294967291) ∷ Int, item) | (i, item) ← zip [1 ..] items])

-- | One scene of a fixture: its plan, its camera, the target it is drawn into and the pass.
data Part = Part
  { partScene ∷ !Scene
  , partPlan ∷ !CellPlan
  , partCamera ∷ !CameraState
  , partShape ∷ !TargetShape
  , partPass ∷ !Pass
  , partAdapted ∷ !Adapted
  }

-- | The next facing, for the wrong-facing control.
otherFacing ∷ ViewFacing → ViewFacing
otherFacing = \case
  FaceSouth → FaceEast
  FaceEast → FaceNorth
  FaceNorth → FaceWest
  FaceWest → FaceSouth

-- | A control's mutation of an adaptation: the records and the push block it breaks, and nothing
-- else. The plan, the assets and the expectation stay the true ones, so the judge sees only the
-- broken draw.
broken ∷ Variant → ViewFacing → Ctx → Adapted → Adapted
broken variant facing ctx adapted = case variant of
  WholeCellMask → withWords (\ws → take 6 ws <> [0, 0, 96, 64, 768, 384] <> drop 12 ws)
  WholeAtlasRegion → withWords (\ws → take 6 ws <> [0, 0, 768, 384] <> drop 10 ws)
  DepthReset → withWords (\ws → take 12 ws <> [0])
  SwappedColourOrigins → withWords (\ws → case ws of x : rest → (if x == 96 then 0 else if x == 0 then 96 else x) : rest; [] → [])
  WrongFacingLight → adapted {adaptedPush = pushBytes (otherFacing facing) (adaptedSettings adapted)}
  WrongMapRegion →
    let origins = [(regionX r, regionY r) | a ← manifestAtlases (styleManifest (ctxStyle ctx)), atlasName a == "normal", r ← atlasRegions a]
        next origin = case dropWhile (/= origin) (origins <> take 1 origins) of
          _ : following : _ → following
          _ → origin
     in withWords (\ws → case drop 6 ws of
          ox : oy : _ → take 6 ws <> [fst (next (ox, oy)), snd (next (ox, oy))] <> drop 8 ws
          _ → ws)
  WrongTreatment → adapted {adaptedRecords = [MaterialRecord [c, ctxNormalAsColour ctx] ws | MaterialRecord [c, _] ws ← adaptedRecords adapted]}
  _ → adapted
  where
    withWords f = adapted {adaptedRecords = [MaterialRecord hs (f ws) | MaterialRecord hs ws ← adaptedRecords adapted]}

runSpec ∷ Ctx → Spec → IO (FixtureResult, Extra)
runSpec ctx s = case traverse planOf (zip [1 ..] (specScenes s)) of
  Left why → pure (failed (specName s) why, emptyExtra s)
  Right planned → case specVariant s of
    variant' | variant' `elem` [Retained, RetainedReleasedWhilePending] → case planned of
      [(_, sc, plan, shape)] → retainedFixture ctx s sc plan shape
      _ → pure (failed (specName s) "a retained fixture draws one scene", emptyExtra s)
    variant → do
      let drawn = traverse (draw variant) planned
      case drawn of
        Left why → pure (failed (specName s) why, emptyExtra s)
        Right parts → renderSnapshot ctx s parts
  where
    assets = case specVariant s of
      ColourHoles → styleAssets (ctxHoled ctx)
      FromSingleImages → singleAssets (ctxSingle ctx)
      _ → styleAssets (ctxStyle ctx)
    planOf (index, sc) = case scenePlan assets sc of
      Left refused → Left ("the scene " <> sceneName sc <> "'s plan was refused: " <> show refused)
      Right plan → Right (index - 1, sc, plan, shapeOf index sc)
    texturesFor variant = case variant of
      FromSingleImages → ctxSingleTextures ctx
      ColourHoles → ctxHoledAtlas ctx
      OrderedWrapper → withColourHandle (ctxUnmarked ctx) (ctxAtlas ctx)
      _ → ctxAtlas ctx
    draw variant (index, sc, plan, shape) = do
      let camera = sceneCameraFollowed sc
      adaptedTrue ← either (\refused → Left ("the quads could not be adapted: " <> describeMaterialRefusal refused)) Right (adaptCells (texturesFor variant) (lightSettings (lightOf s index)) assets plan)
      let adapted = broken variant (camFacing camera) ctx adaptedTrue
          entries = adaptedQuads adapted
          materialFor entry = case quadCell (adaptedQuad entry) of
            Just tile | odd (axisValue (tileX tile)) → ctxSecond ctx
            _ → ctxPrimary ctx
          instances = case variant of
            TwoMaterials → [adaptedInstance (materialFor e) adapted e | e ← scramble entries]
            Scrambled → [adaptedInstance (ctxPrimary ctx) adapted e | e ← scramble entries]
            ReversedKeys → [reversedKey (adaptedInstance (ctxPrimary ctx) adapted e) | e ← entries]
            HalfTexelInset → [adaptedInstance (ctxInset ctx) adapted e | e ← entries]
            UnbiasedIndex → [adaptedInstance (ctxUnbiased ctx) adapted e | e ← entries]
            StaleBias → [adaptedInstance (ctxStale ctx) adapted e | e ← entries]
            _ → [adaptedInstance (ctxPrimary ctx) adapted e | e ← entries]
          held = [(ref, adaptedMaterialData adapted) | ref ← [ctxPrimary ctx, ctxSecond ctx, ctxInset ctx, ctxUnbiased ctx, ctxStale ctx]]
      view ← either (\refused → Left ("the view: " <> describeMaterialRefusal refused)) Right (terrainView plan adapted held [WorldLayer DepthEnabled instances])
      pure (Part sc plan camera shape (Pass (OffscreenTarget (shapeRef shape)) (ClearColour 0 0 0 1) [view]) adapted)
    reversedKey inst = inst {instanceDepthKey = 16777215 - instanceDepthKey inst}

-- | The target scene number @index@ is drawn into: its framebuffer extent, the metrics of its view
-- setup, and a depth image of its extent.
shapeOf ∷ Int → Scene → TargetShape
shapeOf index sc = (depthShape (fromIntegral (index ∷ Int)) Rgba8Srgb (fromIntegral w) (fromIntegral h)) {shapeMetrics = setupMetrics (sceneSetup sc)}
  where
    (w, h) = sceneTarget sc

-- ---------------------------------------------------------------------------
-- The retained variant

-- | Two retained chunks, of the cells of even X and of odd X with even Y, built from scrambled
-- instances, and the rest dynamic, in one depth-enabled layer.
retainedFixture ∷ Ctx → Spec → Scene → CellPlan → TargetShape → IO (FixtureResult, Extra)
retainedFixture ctx s sc plan shape =
  case adaptCells (ctxAtlas ctx) (lightSettings (specLight s)) (styleAssets (ctxStyle ctx)) plan of
    Left refused → pure (failed (specName s) ("the quads could not be adapted: " <> describeMaterialRefusal refused), emptyExtra s)
    Right adapted → do
      marks ← registeredMarks (ctxTextures ctx)
      let camera = sceneCameraFollowed sc
          entries = adaptedQuads adapted
          records = adaptedRecords adapted
          held = [(ref, adaptedMaterialData adapted) | ref ← [ctxPrimary ctx, ctxSecond ctx]]
          instanceFor e = adaptedInstance (ctxPrimary ctx) adapted e
          cellX' e = maybe 0 (\tile → axisValue (tileX tile)) (quadCell (adaptedQuad e))
          cellY' e = maybe 0 (\tile → axisValue (tileY tile)) (quadCell (adaptedQuad e))
          (even', odd') = partition (even . cellX') entries
          (chunkB, dynamic) = partition (even . cellY') odd'
          built group = OrderedPath.hostAct (retainedBase (ctxHost ctx)) "building a retained chunk" $ \construction →
            buildRetainedChunkWith
              (buildersWith (retainedSubmit (ctxHost ctx)) construction)
              (ctxRetained ctx)
              marks
              ChunkWorldDepth
              DeriveBounds
              (Map.singleton (ctxPrimary ctx) records)
              (map instanceFor (scramble group))
              >>= \case
                Left refusal → pure (Left (RefusedIllegal (tshow refusal)))
                Right reference → pure (Right reference)
      firstChunk ← built even'
      secondChunk ← built chunkB
      case (firstChunk, secondChunk) of
        (Right a, Right b) → do
          ready ← and <$> traverse (awaitChunk (ctxRetained ctx)) [a, b]
          if not ready
            then pure (failed (specName s) "a retained chunk's upload did not complete", emptyExtra s)
            else case terrainView plan adapted held [WorldLayerWith DepthEnabled [a, b] (map instanceFor (scramble dynamic))] of
              Left refused → pure (failed (specName s) ("the view: " <> describeMaterialRefusal refused), emptyExtra s)
              Right view → do
                outcome ← renderSnapshot ctx s [Part sc plan camera shape (Pass (OffscreenTarget (shapeRef shape)) (ClearColour 0 0 0 1) [view]) adapted]
                _ ← OrderedPath.hostAct (retainedBase (ctxHost ctx)) "releasing the fixture's chunks" $ \construction → do
                  let builders = buildersWith (retainedSubmit (ctxHost ctx)) construction
                  results ← traverse (releaseChunkNow builders (ctxRetained ctx)) [a, b]
                  pure (sequence_ results)
                pure outcome
        (Left why, _) → pure (failed (specName s) ("a retained chunk was not built: " <> Text.unpack why), emptyExtra s)
        (_, Left why) → pure (failed (specName s) ("a retained chunk was not built: " <> Text.unpack why), emptyExtra s)

-- | Wait, on the chunk's own upload state and not on a clock's ordering, for it to be ready or to
-- fail; a deadline only bounds a hung upload.
awaitChunk ∷ Retained → ChunkRef → IO Bool
awaitChunk retained reference = do
  deadline ← registerDelay 10000000
  atomically $
    ( chunkStandingSTM retained reference >>= \case
        Just ChunkReady → pure True
        Just (ChunkFailed _) → pure False
        _ → retry
    )
      `orElse` (readTVar deadline >>= check >> pure False)

-- ---------------------------------------------------------------------------
-- Rendering and judging

-- | One pass's undecided band, eligibility, counts and raster margin, for the record.
data PassBand = PassBand
  { pbBand ∷ !Double
  , pbEligible ∷ !Bool
  , pbUndecided ∷ !Int
  , pbCovered ∷ !Int
  , pbMargin ∷ !(Maybe (Double, Double))
  }

-- | A pick as the judge compares it: nothing selectable, or a known cell and the part of it.
data PickSummary = SNoHit | SLoading | SHit (Integer, Integer, Integer) Role
  deriving stock (Eq, Show)

-- | What a correct pick finds where the expectation decided: the frontmost covered quad.
pickExpected ∷ Expected → Maybe PickSummary
pickExpected = \case
  ExpectedClear → Just SNoHit
  Ambiguous _ → Nothing
  ExpectedHit {expectedFront = q} → Just (summaryOf q)

summaryOf ∷ HandQuad → PickSummary
summaryOf q = case hqRole q of
  FullFog → SNoHit
  MixedFog → SNoHit
  role → SHit (hqCell q) role

-- | The wrong pick of the control: through the farthest covered quad.
pickThroughNearer ∷ Expected → Maybe PickSummary
pickThroughNearer = \case
  ExpectedClear → Just SNoHit
  Ambiguous _ → Nothing
  ExpectedHit {expectedFront = q, expectedBehind = behind} → Just (summaryOf (case reverse behind of far : _ → far; [] → q))

-- | The wrong pick of the fog control: a fog front is answered with the known solid behind it.
pickThroughFog ∷ Expected → Maybe PickSummary
pickThroughFog = \case
  ExpectedClear → Just SNoHit
  Ambiguous _ → Nothing
  ExpectedHit {expectedFront = q, expectedBehind = behind}
    | hqRole q `elem` [FullFog, MixedFog] → Just (case [b | b ← behind, hqRole b `elem` [Ordinary, MixedKnown]] of known : _ → summaryOf known; [] → summaryOf q)
    | otherwise → Just (summaryOf q)

-- | What a correct pick finds at a pixel: loading where the contract says pending information could lie
-- in front, nothing where the contract leaves a conservative ring undecided, else the frontmost covered quad.
pickWanted ∷ ArtSource → HandLight → Part → Array (Int, Int) Expected → (Int, Int) → Maybe PickSummary
pickWanted art light part grid pixel = case loadingAt art light (partScene part) (partCamera part) (partPlan part) pixel of
  Just True → Just SLoading
  Just False → pickExpected (grid ! pixel)
  Nothing → Nothing

-- | What the picker finds at a pixel of a plan.
pickerAt ∷ Part → (Int, Int) → PickSummary
pickerAt part (px, py) =
  case pickCells (partPlan part) (CellPickQuery (cellPlanIdentity (partPlan part)) (V2 ((fromIntegral px + 0.5) / scale) ((fromIntegral py + 0.5) / scale))) of
    Left _ → SLoading
    Right CellPickNoHit → SNoHit
    Right CellPickLoading → SLoading
    Right (CellPickHit hit) →
      SHit (toInteger (axisValue (tileX (hitCell hit))), toInteger (axisValue (tileY (hitCell hit))), toInteger (axisValue (tileZ (hitCell hit)))) (case hitPart hit of PartKnown → MixedKnown; _ → Ordinary)
  where
    scale = sceneScale (partScene part)

-- | Render the parts of a fixture, one pass each, and judge every pixel of every target.
renderSnapshot ∷ Ctx → Spec → [Part] → IO (FixtureResult, Extra)
renderSnapshot ctx s parts = do
  let snapshot = Snapshot (map partPass parts)
  held ← retainedChunks (ctxRetained ctx)
  case validateSnapshotWith held snapshot of
    Left refused → pure (failed name ("the snapshot was refused: " <> show refused), baseExtra)
    Right valid → do
      marks ← registeredMarks (ctxTextures ctx)
      buffers ← retainedBuffers (ctxRetained ctx)
      let shapes = map partShape parts
          models = Map.fromList ([(ref, terrainModel) | ref ← [ctxPrimary ctx, ctxSecond ctx]] <> [(ctxInset ctx, terrainModelInsetControl), (ctxUnbiased ctx, terrainModelUnbiasedControl), (ctxStale ctx, terrainModelStaleBiasControl)])
          decodedAt = (`Map.lookup` ctxDecoded ctx)
          art = case specVariant s of
            ColourHoles → styleArt (ctxHoled ctx)
            HolesIgnored → styleArt (ctxHoled ctx)
            _ → styleArt (ctxStyle ctx)
          light = lightHand (specLight s)
          -- Two grids per pass from the same exact expectation: the one the device read-back is judged
          -- by (an unsnapped scene's pixel near an interior threshold is 'Ambiguous' there, and
          -- nowhere else) and the exact one the pure pick is compared with at EVERY pixel.
          grids = zipWith (gridOf (expectedForDevice (ctxSubPixelBits ctx) 3)) [0 ..] parts
          -- The oracle path's band is judged by the oracle's own tolerance (one 8-bit step): texels that
          -- differ by two or three steps are the same to the independent judge and different to the oracle.
          oracleGrids = zipWith (gridOf (expectedForDevice (ctxSubPixelBits ctx) 1)) [0 ..] parts
          exactGrids = zipWith (gridOf expectedAt) [0 ..] parts
          gridOf expectation index part =
            let sc = partScene part
                (gw, gh) = sceneTarget sc
                lightHere = lightHand (lightOf s index)
             in listArray ((0, 0), (gw - 1, gh - 1)) [expectation art lightHere sc (partCamera part) (partPlan part) (x, y) | x ← [0 .. gw - 1], y ← [0 .. gh - 1]] ∷ Array (Int, Int) Expected
          oracle = newOracleWith models (oracleInput valid marks shapes decodedAt)
          determinate probe = case expect oracle probe of
            e@(Expected _ _) → Just e
            _ → Nothing
          firstGrid = case grids of
            g : _ → g
            [] → listArray ((0, 0), (0, 0)) [ExpectedClear]
          alternative part need = case need of
            Clipped → altGrid part (partScene part) {sceneViewport = let (aw, ah) = sceneTarget (partScene part) in (0, 0, fromIntegral aw, fromIntegral ah)}
            SnapSensitive → altGrid part (partScene part) {sceneSnap = False}
            _ → Nothing
          altGrid part alt = case scenePlan (styleAssets (ctxStyle ctx)) alt of
            Right altPlan →
              let (gw, gh) = sceneTarget alt
               in Just ((listArray ((0, 0), (gw - 1, gh - 1)) [expectedForDevice (ctxSubPixelBits ctx) 3 art light alt (partCamera part) altPlan (x, y) | x ← [0 .. gw - 1], y ← [0 .. gh - 1]] ∷ Array (Int, Int) Expected) !)
            Left _ → Nothing
          named = case parts of
            part : _ → chooseNamed (partScene part) (firstGrid !) (case grids of _ : g : _ → Just (g !); _ → Nothing) (alternative part) determinate (specNeeds s)
            [] → []
          cameraProblems =
            [ "the camera came to cut " <> show (axisValue (camClip (partCamera part)), camRef (partCamera part)) <> " (cut, reference), expected " <> show wanted <> ": it was panned off its column or follows another surface"
            | Just wanted <- [specCamera s]
            , part ← parts
            , (toInteger (axisValue (camClip (partCamera part))), camRef (partCamera part)) /= wanted
            ]
          missing = [need | need ← specNeeds s, need `notElem` (SnapSensitive : Restores : map fst named)]
          runFacts = runsOf (planSnapshot marks valid)
          expectedPath = if specVariant s == OrderedWrapper then "Ordered" else "Cutout"
          pathProblems = ["a run took the " <> path <> " path, expected " <> expectedPath | (path, _, _) ← runFacts, path /= expectedPath]
      markFacts ← traverse (\(label, handle) → (,) label <$> registeredMark (ctxTextures ctx) handle) [("colour atlas", ctxColourH ctx), ("normal atlas", ctxNormalH ctx), ("colour atlas, mark overridden off", ctxUnmarked ctx)]
      -- For a variant that releases ownership while the work is pending, the atlases' original
      -- ownership is released between the submission and the wait; the frame must then complete and
      -- read back as if nothing had happened (the draw holds what it reads), and the release is real
      -- only after completion (teardown's table release). Nothing else changes.
      let releasing = specVariant s `elem` [ReleasedWhilePending, RetainedReleasedWhilePending]
          between
            | releasing = do
                -- A handle's release is marked once: an earlier retention fixture of the run already did, and
                -- the handle then stands released already (it is still registered, and its table release is
                -- teardown's, after every frame), which this one accepts and a stale or unregistered handle
                -- never satisfies.
                before ← atomically (traverse (isReleased (ctxTextures ctx)) [ctxColourH ctx, ctxNormalH ctx])
                marked ← traverse (markReleased (ctxTextures ctx)) [ctxColourH ctx, ctxNormalH ctx]
                standing ← atomically (traverse (isReleased (ctxTextures ctx)) [ctxColourH ctx, ctxNormalH ctx])
                pure $
                  if and standing && and (zipWith (||) marked before)
                    then Right ()
                    else Left "the atlases' original ownership was not released while the frame was pending"
            | otherwise = pure (Right ())
      result0 ← OrderedPath.runValidatedBetween models (retainedBase (ctxHost ctx)) (terrainSuite (ctxProfile ctx)) (ctxDirectory ctx) Depth32Float (ctxRenderer ctx) marks buffers decodedAt between (Text.pack name) shapes (map snd named) valid
      -- The oracle path applies the same band as the independent judge (amendment v3): where the exact
      -- expectation leaves a pixel undecided (an unsnapped pass, within the pass's delta of an interior
      -- biased threshold, between texels that differ) the oracle's probe is the model fault
      -- NearTexelBoundary, counted and never compared. Outside that set an oracle mismatch stands as a
      -- failure (a further sampling counterexample). The oracle's generic bands are unchanged.
      let bandedProbe probed = case drop (probePass (probeAt probed)) oracleGrids of
            grid : _
              | inRange (bounds grid) (probeX (probeAt probed), probeY (probeAt probed))
              , Ambiguous _ ← grid ! (probeX (probeAt probed), probeY (probeAt probed)) →
                  let indeterminate = NearTexelBoundary (AtPass (probePass (probeAt probed)))
                   in probed {probeExpectation = Indeterminate indeterminate, probeVerdict = ProbeIndeterminate indeterminate}
            _ → probed
          result = result0 {resultProbes = map bandedProbe (resultProbes result0)}
      let perPass = splitPasses (map (sceneTarget . partScene) parts) (resultProbes result)
          independents = [judgeIndependent (sceneTarget (partScene part)) (grid !) (observedFrom (fst (sceneTarget (partScene part))) probes) | (part, grid, probes) ← zip3 parts grids perPass]
          independent = foldr1 plus independents
          snapDifferences = case (SnapSensitive `elem` specNeeds s, perPass) of
            (True, firstProbes : _) →
              let unsnappedSnapshot = Snapshot [pass' {passViews = [v {viewSettings = (viewSettings v) {settingPixelSnap = False}} | v ← passViews pass']} | pass' ← snapshotPasses snapshot]
               in case validateSnapshotWith held unsnappedSnapshot of
                    Left _ → 0
                    Right unsnappedValid →
                      let unsnappedOracle = newOracleWith models (oracleInput unsnappedValid marks shapes decodedAt)
                          (gw, _) = sceneTarget (partScene (case parts of { part : _ → part; [] → error "a fixture without a part" }))
                          near (Rgba8 a b c d) (Rgba8 e f g h') = all (\(x, y) → abs (fromIntegral x - fromIntegral y) <= tolerance) [(a, e), (b, f), (c, g), (d, h')]
                       in length
                            [ ()
                            | (index, probed) ← zip [0 ∷ Int ..] firstProbes
                            , Expected with _ ← [probeExpectation probed]
                            , Just seen ← [probeObserved probed]
                            , Expected without _ ← [expect unsnappedOracle (Probe 0 (index `mod` gw) (index `div` gw))]
                            , near with seen
                            , not (near without seen)
                            ]
            _ → 0
          plus a b = Independent (indCompared a + indCompared b) (indAmbiguous a + indAmbiguous b) (indCovered a + indCovered b) (indReveals a + indReveals b) (indOverlaps a + indOverlaps b) (indMismatchCount a + indMismatchCount b) (take 12 (indMismatches a <> indMismatches b))
          -- The pick against the hand expectation on a stride of every pass's pixels.
          pickResults =
            [ (length judged, [show pixel <> ": the pick found " <> show got <> ", expected " <> show want | (pixel, want, got) ← judged, got /= want], length [() | (_, SLoading, _) ← judged], length [() | pixel ← pixels, Nothing ← [pickWanted art light part grid pixel]])
            | (part, grid) ← zip parts exactGrids
            , let (gw, gh) = sceneTarget (partScene part)
            , let step = max 1 ((gw * gh) `div` 600)
            , let pixels = [(x, y) | (i, (x, y)) ← zip [0 ∷ Int ..] [(x, y) | y ← [0 .. gh - 1], x ← [0 .. gw - 1]], i `mod` step == 0]
            , let judged = [(pixel, want, got) | pixel ← pixels, Just want ← [pickWanted art light part grid pixel], let got = case specVariant s of { PickLoadingAsMiss → (case pickerAt part pixel of { SLoading → SNoHit; other → other }); BackmostPick → fromMaybe want (pickThroughNearer (grid ! pixel)); PickThroughFog → fromMaybe want (pickThroughFog (grid ! pixel)); _ → pickerAt part pixel }]
            ]
          pickCompared = sum [n | (n, _, _, _) ← pickResults]
          pickProblems = concat [p | (_, p, _, _) ← pickResults]
          pickLoadingSeen = sum [n | (_, _, n, _) ← pickResults]
          pickUndecided = sum [n | (_, _, _, n) ← pickResults]
          pendingProblems = ["a scene with pending cells whose sampled pixels hold no loading pick: it exercises nothing" | any (not . null . pendingCells . partScene) parts, pickLoadingSeen == 0]
          rejected
            | isControl (specVariant s) = Just (indMismatchCount independent > 0 || not (null pickProblems))
            | otherwise = Nothing
          observedFirst = case (parts, perPass) of
            (part : _, probes : _) → observedFrom (fst (sceneTarget (partScene part))) probes
            _ → \_ _ → Nothing
          mismatchAt (x, y) = case (expectedRgba (firstGrid ! (x, y)), observedFirst x y) of
            (Just (er, eg, eb, ea), Just (Rgba8 r g b a)) → not (all (\(e, o) → abs (fromIntegral e - fromIntegral o) <= tolerance) [(er, r), (eg, g), (eb, b), (ea, a)])
            _ → False
          -- The named probes' pixels and the hundred covered pixels nearest the centre: a control
          -- must differ where the behaviour it breaks is judged, and one lighting control may
          -- break a surface only slightly at a single pixel.
          namedPixels =
            concat [[(probeX p, probeY p), (probeX c, probeY c)] | (_, NamedProbe _ p c) ← named]
              <> take 100 (sortOn centreOf [pixel | pixel ← range ((0, 0), (gridW - 1, gridH - 1)), ExpectedHit {} ← [firstGrid ! pixel]])
          (gridW, gridH) = case parts of
            part : _ → sceneTarget (partScene part)
            [] → (1, 1)
          centreOf (x, y) = (x - gridW `div` 2) ^ (2 ∷ Int) + (y - gridH `div` 2) ^ (2 ∷ Int)
          controlDiffers
            | specVariant s `elem` [BackmostPick, PickThroughFog, PickLoadingAsMiss] = Just (not (null pickProblems))
            | specVariant s `elem` [UnbiasedIndex, StaleBias] = Just (any ((> 0) . indMismatchCount) (drop 1 independents))
            | isControl (specVariant s) = Just (any mismatchAt namedPixels)
            | otherwise = Nothing
          -- A sequence that ends in the state it began in must draw that state again, pixel for pixel: the
          -- same terrain, knowledge, camera and style restore the same picture with no seam or residue.
          restoreProblems = case (perPass, parts) of
            (firstProbes : (_ : _ : _) , firstPart : _)
              | Restores `elem` specNeeds s →
                  let lastProbes = last perPass
                      lastPart = last parts
                      (rw, rh) = sceneTarget (partScene firstPart)
                      seenFirst = observedFrom rw firstProbes
                      seenLast = observedFrom (fst (sceneTarget (partScene lastPart))) lastProbes
                      differing = length [() | y ← [0 .. rh - 1], x ← [0 .. rw - 1], seenFirst x y /= seenLast x y]
                   in [ "the final pass does not restore the first: " <> show differing <> " pixels differ" | differing > 0 || sceneTarget (partScene firstPart) /= sceneTarget (partScene lastPart) || partScene firstPart /= partScene lastPart ]
            _ → []
          passBands =
            [ PassBand
                { pbBand = fromRational (undecidedBand bits (partScene part)) ∷ Double
                , pbEligible = deviceEligible bits (partScene part) (partCamera part) (partPlan part)
                , pbUndecided = indAmbiguous one'
                , pbCovered = indCovered one'
                , pbMargin = fmap (\(m, e) → (fromRational m ∷ Double, fromRational e ∷ Double)) (rasterMargin bits (partScene part) (partCamera part) (partPlan part))
                }
            | (part, one') ← zip parts independents
            ]
          bits = ctxSubPixelBits ctx
          -- An eligible pass's quad edges must keep every pixel centre farther than what the rasterizer's
          -- vertex quantisation can move them (never banded: the band covers texel thresholds only).
          rasterProblems =
            [ "pass " <> show pass <> ": a quad edge lies " <> show margin <> " pixels from a pixel centre, within the " <> show epsilon <> " the vertex quantisation can move it: redesign the pass (it is never banded)"
            | (pass, PassBand {pbMargin = Just (margin, epsilon)}) ← zip [0 ∷ Int ..] passBands
            , margin <= epsilon
            ]
          readbackMissing = not (completeReadback (map (sceneTarget . partScene) parts) (resultProbes result))
          problems
            | readbackMissing = [maybe "the readback holds fewer pixels than the targets" Text.unpack (resultFailure result)]
            | otherwise =
                [ "the independent expectation found " <> show (indMismatchCount independent) <> " mismatches, e.g. " <> show (take 3 (indMismatches independent))
                | not (isControl (specVariant s))
                , indMismatchCount independent > 0
                ]
                  <> ["the pick disagreed with the expectation at " <> show (length pickProblems) <> " pixels, e.g. " <> show (take 3 pickProblems) | not (isControl (specVariant s)), not (null pickProblems)]
                  <> cameraProblems
                  <> restoreProblems
                  <> [problem | not (isControl (specVariant s)), problem ← rasterProblems]
                  <> pendingProblems
                  <> pathProblems
                  <> ["pixel snapping changed " <> show snapDifferences <> " pixels the readback shows, fewer than the 20 that discriminate it from a view that ignores the setting" | SnapSensitive `elem` specNeeds s, snapDifferences < 20]
                  <> ["no determinate probe for " <> show need | need ← missing]
                  <> ["the independent expectation compared no pixel the scene covers" | indCovered independent == 0]
                  <> ["pass " <> show pass <> " covers no compared pixel: a pass judged on nothing" | (pass, one') ← zip [0 ∷ Int ..] independents, indCovered one' == 0, not (isControl (specVariant s))]
                  <> ["more than half the pixels were ambiguous: " <> show (indAmbiguous independent) <> " of " <> show (indAmbiguous independent + indCompared independent) | indAmbiguous independent > indCompared independent]
                  <> ["the control was not rejected: the judge found no disagreement with a draw broken on purpose" | rejected == Just False]
                  <> ["the control did not differ at its named probes, so it did not exercise what it breaks" | controlDiffers == Just False]
                  <> [Text.unpack reason | Just reason ← [resultFailure result]]
          assessed = case problems of
            [] → result
            _ → result {resultFailure = Just (Text.pack (concatMap (<> "; ") problems))}
          -- The unbiased-index control draws exact-boundary pixels the oracle, which states no float32
          -- interpolation, cannot decide (it reads the exact boundary as the higher texel and the
          -- device the lower on the pixels the counterexample found), so the oracle's verdicts on the
          -- control's exact pass are not what judges it: the independent exact expectation rejects it
          -- ('rejected' and 'controlDiffers', above), and only the first, ordinary pass keeps its
          -- oracle verdicts.
          finished
            | specVariant s `elem` [UnbiasedIndex, StaleBias] = assessed {resultProbes = concat (take 1 perPass)}
            | otherwise = assessed
          factsExtra =
            Extra
              { extraSpec = s
              , extraQuads = [length (adaptedQuads (partAdapted part)) | part ← parts]
              , extraRecords = [length (adaptedRecords (partAdapted part)) | part ← parts]
              , extraIdentity = [take 200 (show (cellPlanIdentity (partPlan part))) | part ← parts]
              , extraRuns = runFacts
              , extraMarks = markFacts
              , extraIndependent = Just independent
              , extraBand = passBands
              , extraPassMismatches = [(indMismatchCount i, take 4 (indMismatches i)) | i ← independents]
              , extraPickCompared = pickCompared
              , extraPickUndecided = pickUndecided
              , extraPickMismatches = length pickProblems
              , extraPickFirst = take 4 pickProblems
              , extraRejected = rejected
              , extraControlDiffers = controlDiffers
              , extraTargets = map (sceneTarget . partScene) parts
              , extraSnapDifferences = if SnapSensitive `elem` specNeeds s then Just snapDifferences else Nothing
              , extraSeconds = []
              }
      pure (finished, factsExtra)
  where
    name = specName s
    baseExtra = (emptyExtra s) {extraTargets = map (sceneTarget . partScene) parts}
    probeX (Probe _ x _) = x
    probeY (Probe _ _ y) = y
    oracleInput valid marks shapes decodedAt =
      OracleInput
        { inputSnapshot = valid
        , inputCutoutMarks = marks
        , inputWindow = Nothing
        , inputOffscreen = Map.fromList [(shapeRef shape, TargetSpec (shapeMetrics shape) (colourFormatOf (shapeFormat shape)) (PixelExtent (fromIntegral (shapeWidth shape)) (fromIntegral (shapeHeight shape)))) | shape ← shapes]
        , inputTextures = decodedAt
        }

-- | The draw path of each run the plan made, with the material's reference and the number of its instances.
runsOf ∷ DrawPlan → [(String, Int, String)]
runsOf plan =
  [ (show (runPath run), runCount run, show (runMaterial run))
  | PlannedPass {plannedViews = views} ← planPasses plan
  , PlannedView {plannedLayers = layers} ← views
  , layer ← layers
  , run ← plannedRuns layer
  ]

-- | The named probes the fixture's needs ask for: for each, a pixel the scene's hand-stated
-- expectation says shows the behaviour and a contrast where it is absent, both determinate for the
-- oracle and expected to differ.
chooseNamed
  ∷ Scene
  → ((Int, Int) → Expected)
  → Maybe ((Int, Int) → Expected)
  → (Need → Maybe ((Int, Int) → Expected))
  → (Probe → Maybe Expectation)
  → [Need]
  → [(Need, NamedProbe)]
chooseNamed sc expectedAtPixel secondGrid alternative determinate = concatMap one
  where
    (w, h) = sceneTarget sc
    pixels = [(x, y) | y ← [0 .. h - 1], x ← [0 .. w - 1]]
    centreDistance (x, y) = (x - w `div` 2) ^ (2 ∷ Int) + (y - h `div` 2) ^ (2 ∷ Int)
    probeAt (x, y) = Probe 0 x y
    ok pixel = isJust (determinate (probeAt pixel))
    differs a b = case (determinate (probeAt a), determinate (probeAt b)) of
      (Just (Expected one' _), Just (Expected other _)) → one' /= other
      _ → False
    covered = sortOn centreDistance [p | p ← pixels, ExpectedHit {} ← [expectedAtPixel p]]
    clear = filter ok (sortOn centreDistance [p | p ← pixels, expectedAtPixel p == ExpectedClear])
    pair need behaviour candidates contrasts =
      listToMaybe
        [ (need, NamedProbe behaviour (probeAt a) (probeAt b))
        | a ← take 5 (filter ok candidates)
        , b ← take 5 (filter ok contrasts)
        , differs a b
        ]
    one = \case
      Foreground → maybe [] pure (pair Foreground "a quad's art covers the pixels its colour and map hold and nothing beside them" covered (clear <> reverse covered))
      Overlap →
        let overlapped = [p | p ← covered, ExpectedHit {expectedBehind = _ : _} ← [expectedAtPixel p]]
            single = [p | p ← covered, ExpectedHit {expectedBehind = [], expectedSkipped = []} ← [expectedAtPixel p]]
         in maybe [] pure (pair Overlap "the nearer quad hides the farther where their canvases overlap" overlapped single)
      Varies → maybe [] pure (pair Varies "the lighting and the art differ across the covered surface" covered (reverse covered))
      Reveal → []
      Restores → []
      LightsDiffer → case secondGrid of
        Just other →
          -- The same covered pixel in the first pass (default light) and in the second (another
          -- light): the oracle must expect different colours, the readback must show both.
          maybe [] pure . listToMaybe $
            [ (LightsDiffer, NamedProbe "two views sharing one registered material keep their own lighting" (probeAt a) (Probe 1 (fst a) (snd a)))
            | a ← take 8 (filter ok covered)
            , ExpectedHit {} ← [other a]
            , Just (Expected one' _) ← [determinate (probeAt a)]
            , Just (Expected two _) ← [determinate (Probe 1 (fst a) (snd a))]
            , one' /= two
            ]
        Nothing → []
      Clipped → case alternative Clipped of
        Just unclipped →
          let clippedAway = [p | p ← pixels, expectedAtPixel p == ExpectedClear, ExpectedHit {} ← [unclipped p]]
           in maybe [] pure (pair Clipped "a viewport away from the corner clips the scene and leaves the rest of the target clear" covered clippedAway)
        Nothing → []
      SnapSensitive → case alternative SnapSensitive of
        Just unsnapped →
          let movedIn = [p | p ← pixels, ExpectedHit {} ← [expectedAtPixel p], unsnapped p == ExpectedClear]
              movedOut = [p | p ← pixels, expectedAtPixel p == ExpectedClear, ExpectedHit {} ← [unsnapped p]]
           in maybe [] pure (pair SnapSensitive "pixel snapping moves the image: a pixel covered only when snapping, against one covered only when not" movedIn movedOut)
        Nothing → []

-- ---------------------------------------------------------------------------
-- The record

-- | The fixture record, one JSON document beside the probe record: the build and device, the shader
-- and atlas identities, and for every fixture its scene, plan identity, draw path, counts, tolerance
-- and outcome.
writeRecord ∷ Ctx → ImageFormat → Double → [(FixtureResult, Extra)] → IO ()
writeRecord ctx format seconds results = do
  revision ← lookupEnv "HETOIMASIA_VULKAN_REVISION"
  digest ← lookupEnv "HETOIMASIA_VULKAN_SOURCE_DIGEST"
  let style = ctxStyle ctx
      manifest = styleManifest style
      shaderHash definition = case definition of
        Just checked → JString (sha256Hex (checkedSpirv (checkedFragment checked)))
        Nothing → JNull
      scenario = case ctxProfile ctx of
        Full → "tra17-terrain"
        Bounded → "tra17-terrain-ci"
      document =
        JObject
          [ ("record", JString (scenario <> " fixture record"))
          , ("source_revision", maybe JNull JString revision)
          , ("source_digest", maybe JNull JString digest)
          , ("backend_device", JString (Text.unpack (ctxDevice ctx)))
          , ("depth_format", JString (show format))
          , ("target_format", JString (show Rgba8Srgb))
          , ("scenario_seconds", JNumber (show seconds))
          , ("tolerance_per_channel", JNumber (show tolerance))
          , ("reproduce", JString ("HETOIMASIA_NATIVE_SESSION=desktop bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --private-roots " <> scenario))
          , ( "shaders"
            , JObject
                [ ("terrain_material_cutout_fragment_sha256", shaderHash (definedCutout terrainMaterial))
                , ("terrain_material_translucent_fragment_sha256", JString (sha256Hex (checkedSpirv (checkedFragment (definedTranslucent terrainMaterial)))))
                , ("equivalent_material_cutout_fragment_sha256", shaderHash (definedCutout terrainMaterialEquivalent))
                , ("note", JString "SPIR-V of the checked variants; the glslang that compiled them is the one tools/vulkan/run.sh reports")
                ]
            )
          , ( "atlases"
            , JArray
                [ JObject
                    [ ("name", JString (atlasName a))
                    , ("file", JString (atlasFile a))
                    , ("sha256", JString (atlasSha256 a))
                    , ("width", JNumber (show (atlasWidth a)))
                    , ("height", JNumber (show (atlasHeight a)))
                    , ("kind", JString (atlasKind a))
                    , ("profile", JString (atlasProfile a))
                    , ("regions", JNumber (show (length (atlasRegions a))))
                    ]
                | a ← manifestAtlases manifest
                ]
            )
          , ("layout_identity", JString (layoutIdentityHex (manifestLayout manifest)))
          , ("fixtures", JArray (map fixtureJson results))
          ]
  writeFile (ctxDirectory ctx </> (scenario <> "-fixtures.json")) (renderJson document <> "\n")
  where
    fixtureJson (result, extra) =
      let sp = extraSpec extra
          sc = case specScenes sp of
            first : _ → first
            [] → error "a fixture without a scene"
          probes = resultProbes result
          determinate = length [() | p ← probes, OrderedPath.isDeterminate p]
          (zoomValue, (panX, panY)) = (sceneZoom sc, scenePan sc)
       in JObject
            [ ("name", JString (specName sp))
            , ("passed", JBool (OrderedPath.fixturePassed result))
            , ("failure", maybe JNull (JString . Text.unpack) (resultFailure result))
            , ("snap_discriminating_pixels", maybe JNull (JNumber . show) (extraSnapDifferences extra))
            , ("seconds", JNumber (show (sum (extraSeconds extra))))
            , ("seconds_by_stage", JObject (zip ["render_and_readback", "oracle_verdicts", "independent_expectation", "pick_judge"] (map (JNumber . show) (extraSeconds extra))))
            , ("variant", JString (show (specVariant sp)))
            , ("light", JString (lightLabel (specLight sp)))
            , ("control_expected_rejected", maybe JNull JBool (extraRejected extra))
            , ("control_differs_at_named_probes", maybe JNull JBool (extraControlDiffers extra))
            , ( "scene"
              , JObject
                  [ ("facing", JString (show (sceneFacing sc)))
                  , ("zoom", JNumber (show zoomValue))
                  , ("pan_tiles", JArray [JNumber (show panX), JNumber (show panY)])
                  , ("mode", JString (show (sceneMode sc)))
                  , ("anchor", JArray [JNumber (show (fst (sceneAnchor sc))), JNumber (show (snd (sceneAnchor sc)))])
                  , ("scenes", JArray [JString (sceneName c) | c ← specScenes sp])
                  , ("targets_framebuffer", JArray [JArray [JNumber (show tw), JNumber (show th)] | (tw, th) ← extraTargets extra])
                  , ("content_scale", JNumber (show (sceneScale sc)))
                  , ("viewport", JString (show (sceneViewport sc)))
                  , ("pixel_snap", JBool (sceneSnap sc))
                  , ("cells", JArray [JString (show c) | c ← sceneCells sc])
                  , ("knowledge_overrides", JArray [JString (show k) | k ← sceneKnow sc])
                  , ("hidden_air_fog_cells", JArray [JString (show k) | k ← sceneFogOnly sc])
                  ]
              )
            , ("plans", JArray [JObject [("quads", JNumber (show quads)), ("records", JNumber (show records)), ("identity", JString identity)] | (quads, records, identity) ← zip3 (extraQuads extra) (extraRecords extra) (extraIdentity extra)])
            , ("draw_path", JArray [JObject [("path", JString path), ("instances", JNumber (show n)), ("material", JString ref)] | (path, n, ref) ← extraRuns extra])
            , ("cutout_marks", JArray [JObject [("texture", JString label), ("binary_alpha_mark", maybe JNull JBool mark)] | (label, mark) ← extraMarks extra])
            , ( "oracle"
              , JObject
                  [ ("probes", JNumber (show (length probes)))
                  , ("determinate", JNumber (show determinate))
                  , ("indeterminate", JNumber (show (length probes - determinate)))
                  , ("named", JArray [JString (Text.unpack (OrderedPath.namedName n)) | n ← resultNamed result])
                  ]
              )
            , ( "independent"
              , case extraIndependent extra of
                  Nothing → JNull
                  Just i →
                    JObject
                      [ ("compared", JNumber (show (indCompared i)))
                      , ("ambiguous", JNumber (show (indAmbiguous i)))
                      , ("covered", JNumber (show (indCovered i)))
                      , ("transparent_reveals", JNumber (show (indReveals i)))
                      , ("overlaps_hidden_by_front", JNumber (show (indOverlaps i)))
                      , ("mismatches", JNumber (show (indMismatchCount i)))
                      , ("first_mismatches", JArray (map JString (indMismatches i)))
                      ]
              )
            , ( "device_undecided_by_pass"
              , JArray
                  [ JObject
                      [ ("pass", JNumber (show pass))
                      , ("device", JString (Text.unpack (ctxDevice ctx)))
                      , ("sub_pixel_precision_bits", JNumber (show (ctxSubPixelBits ctx)))
                      , ("band_texels", JNumber (show (pbBand pb)))
                      , ("eligible_unsnapped_off_grid", JBool (pbEligible pb))
                      , ("undecided", JNumber (show (pbUndecided pb)))
                      , ("covered", JNumber (show (pbCovered pb)))
                      , ("undecided_share_of_covered", JNumber (show (if pbCovered pb == 0 then 0 else fromIntegral (pbUndecided pb) / fromIntegral (pbCovered pb) ∷ Double)))
                      , ("raster_margin_px", maybe JNull (JNumber . show . fst) (pbMargin pb))
                      , ("raster_epsilon_px", maybe JNull (JNumber . show . snd) (pbMargin pb))
                      ]
                  | (pass, pb) ← zip [0 ∷ Int ..] (extraBand extra)
                  ]
              )
            , ( "mismatches_by_pass"
              , JArray [JObject [("pass", JNumber (show pass)), ("mismatches", JNumber (show n)), ("first", JArray (map JString firsts))] | (pass, (n, firsts)) ← zip [0 ∷ Int ..] (extraPassMismatches extra)]
              )
            , ( "pick_against_expectation"
              , JObject
                  [ ("compared", JNumber (show (extraPickCompared extra)))
                  , ("undecided_conservative_ring", JNumber (show (extraPickUndecided extra)))
                  , ("mismatches", JNumber (show (extraPickMismatches extra)))
                  , ("first_mismatches", JArray (map JString (extraPickFirst extra)))
                  ]
              )
            ]
