-- | An independent visibility oracle: the nearest face a line of sight meets in
-- a scene of cells, found by exact ray casting against the shared terrain
-- solids ('castRay'). It shares no code with the planner: it does not project
-- faces, order them or intersect polygons.
module Test.TerrainRender2D.Oracle
  ( Cell3
  , sceneSource
  , sceneHit
  , lattice
  , scenePlanTiles
  ) where

import Data.List (minimumBy)
import Data.Ord (comparing)
import Hetoimasia.Terrain.Coordinate (TileCoord)
import Hetoimasia.Terrain.Geometry
import Hetoimasia.Terrain.Render2D.Projection (viewOffset)
import Hetoimasia.Terrain.Shape (ViewFacing, mkShapeId, viewShape)
import Hetoimasia.Terrain.Source
import Test.TerrainRender2D.Fixtures (source, tileAt)

-- | A world cell: tile coordinates and a world shape identity.
type Cell3 = (Integer, Integer, Integer, Int)

-- | A source holding exactly these cells, one patch each.
sceneSource ∷ [Cell3] → Source
sceneSource cells =
  source
    SourceSpec
      { specMaterials = ["stone"]
      , specLayers = []
      , specPatches = [PatchSpec x y z (z + 1) (SpecSolid "stone" shape) | (x, y, z, shape) ← cells]
      }

-- | The world tile of every cell of a scene.
scenePlanTiles ∷ [Cell3] → [TileCoord]
scenePlanTiles cells = [tileAt x y z | (x, y, z, _) ← cells]

-- | The nearest solid a line of sight meets at a render-world point, for the
-- cells at or below a cut, seen from a facing about an anchor column at the
-- origin and a reference elevation. The answer is the tile and the face kind
-- in the view frame; 'Nothing' for open sky.
sceneHit ∷ ViewFacing → Integer → Integer → [Cell3] → (Rational, Rational) → Maybe (TileCoord, FaceKind)
sceneHit facing ref cut cells (sx, sy) = case hits of
  [] → Nothing
  _ → let (_, tile, kind) = minimumBy (comparing (\(t, _, _) → t)) hits in Just (tile, kind)
  where
    -- A point on the line of sight at relative height zero, and the far end
    -- of the line a long way toward the camera along (1, 1, 3).
    a = (sx / 48 + sy / 24) / 2
    b = (sy / 24 - sx / 48) / 2
    far = 400
    origin = V3 (a + far) (b + far) (3 * far)
    direction = V3 (-1) (-1) (-3)
    hits =
      [ (hitParameter hit, tileAt x y z, kind)
      | (x, y, z, shape) ← cells
      , z <= cut
      , let (vx, vy) = viewOffset facing (x, y)
      , let V3 ox oy oz = origin
      , let local = V3 (ox - (fromInteger vx - 1 / 2)) (oy - (fromInteger vy - 1 / 2)) (oz - fromInteger (z - ref))
      , Right ray ← [mkRay local direction]
      , Right sid ← [mkShapeId shape]
      , Just hit ← [castRay (shapeSolid (viewShape facing sid)) ray]
      , hitContact hit `elem` [Enters, StartsInside]
      , Just face ← [hitFace hit]
      , let kind = faceKind face
      ]

-- | Sample points over a box, each offset off the lattice lines so that none
-- falls on a projected edge.
lattice ∷ Integer → Integer → Integer → Integer → Integer → [(Rational, Rational)]
lattice x0 x1 y0 y1 step =
  [ (fromInteger x + 37 / 100, fromInteger y + 53 / 100)
  | x ← [x0, x0 + step .. x1]
  , y ← [y0, y0 + step .. y1]
  ]
