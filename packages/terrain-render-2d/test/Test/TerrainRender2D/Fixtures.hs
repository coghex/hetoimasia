-- | Small explicit terrain fixtures and request builders.
--
-- Every fixture is built from the public terrain interfaces. Nothing here calls
-- the planner to produce an expectation.
module Test.TerrainRender2D.Fixtures
  ( source
  , isolated
  , flatWorld
  , versions
  , factsOf
  , factsWith
  , setup
  , manualCamera
  , followCamera
  , request
  , plan
  , planWith
  , axis
  , column
  , tileAt
  , allFacings
  , faceCells
  ) where

import Data.Word (Word64)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), offscreenMetrics)
import Hetoimasia.Render.TwoD.Settings (defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))
import Hetoimasia.Terrain.Cell (Column (..))
import Hetoimasia.Terrain.Changes (Changes, emptyChanges)
import Hetoimasia.Terrain.Coordinate (AxisCoord, TileCoord (..), axisFromInteger, tileCoord)
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..))
import Hetoimasia.Terrain.Shape (ViewFacing, allViewFacings)
import Hetoimasia.Terrain.Source

source ∷ SourceSpec → Source
source spec = either (\e → error ("fixture source refused: " <> show e)) id (mkSource defaultSourceLimits spec)

-- | One cell of the given shape at the origin in an otherwise empty world.
isolated ∷ Int → Source
isolated shape =
  source
    SourceSpec
      { specMaterials = ["stone"]
      , specLayers = []
      , specPatches = [PatchSpec 0 0 0 1 (SpecSolid "stone" shape)]
      }

-- | Stone below level 1 everywhere: every column's highest solid cell is 0.
flatWorld ∷ Source
flatWorld =
  source
    SourceSpec
      { specMaterials = ["stone"]
      , specLayers = [LayerSpec Nothing (Just 1) "stone" 0]
      , specPatches = []
      }

versions ∷ Versions
versions = Versions 1 1 1

factsOf ∷ Source → TerrainFacts
factsOf s = TerrainFacts versions s emptyChanges AllKnown

factsWith ∷ Source → Changes → Availability → TerrainFacts
factsWith s c a = TerrainFacts versions s c a

-- | A target of the given logical size, equal to its framebuffer.
setup ∷ Int → Int → ViewSetup
setup w h =
  ViewSetup
    { setupMetrics = offscreenMetrics (PixelExtent w h)
    , setupViewport = Viewport (V2 0 0) (V2 (fromIntegral w) (fromIntegral h))
    , setupSettings = defaultViewSettings
    }

axis ∷ Integer → AxisCoord
axis n = either (\e → error ("fixture axis: " <> show e)) id (axisFromInteger n)

column ∷ Integer → Integer → Column
column x y = Column (axis x) (axis y)

tileAt ∷ Integer → Integer → Integer → TileCoord
tileAt x y z = either (\e → error ("fixture tile: " <> show e)) id (tileCoord x y z)

-- | A camera on a column in manual mode at an exact level, reference at the
-- level's top plane.
manualCamera ∷ Integer → Integer → Integer → CameraState
manualCamera x y level =
  case newCamera defaultCameraConfig (axis x) (axis y) (axis level) of
    Left e → error (show e)
    Right camera → case applyCommand defaultCameraConfig (factsOf flatWorld) (SelectSlice (axis level)) camera of
      Left e → error (show e)
      Right step → stepCamera step

-- | A following camera that has adopted the surface of the facts it is given.
followCamera ∷ TerrainFacts → Integer → Integer → CameraState
followCamera facts x y =
  case newCamera defaultCameraConfig (axis x) (axis y) (axis 0) of
    Left e → error (show e)
    Right camera → stepCamera (refollow defaultCameraConfig facts camera)

request ∷ ViewSetup → CameraState → PlanRequest
request vs camera =
  PlanRequest
    { requestVersions = versions
    , requestMaterialVersion = 7
    , requestCamera = camera
    , requestSetup = vs
    , requestConfig = defaultPlanConfig
    }

plan ∷ ViewSetup → CameraState → TerrainFacts → Plan
plan vs camera facts = either (\e → error ("fixture plan refused: " <> show e)) id (planTerrain (request vs camera) facts)

planWith ∷ (PlanRequest → PlanRequest) → ViewSetup → CameraState → TerrainFacts → Either PlanError Plan
planWith f vs camera = planTerrain (f (request vs camera))

allFacings ∷ [ViewFacing]
allFacings = allViewFacings

-- | The tile and view kind of every face of a plan, in draw order.
faceCells ∷ Plan → [(TileCoord, Word64)]
faceCells p = [(faceCell f, fromIntegral (faceDepthKey f)) | f ← planFaces p]
