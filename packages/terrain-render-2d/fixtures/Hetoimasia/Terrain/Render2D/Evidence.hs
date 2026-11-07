-- | Scenes and independent expectations for the terrain material's evidence
-- (TRA-8): the cells of a fixture, the camera it is seen from, and what a
-- viewer must see at every pixel centre, worked out here without the planner,
-- its faces, its depth keys or its picking.
--
-- The CPU suite and the native evidence scenario both build their scenes and
-- their hand-stated expectations from this component, through the public terrain
-- and planner interfaces, so neither imports the other's spec. It is a test
-- component's support library; no engine library depends on it.
--
-- == The independent model
--
-- A cell is the closed convex solid under its top surface: the unit footprint,
-- from its base up to the lower envelope of one 45° ramp for each lowered side
-- (north @z <= y@, east @z <= 1 - x@, south @z <= 1 - y@, west @z <= x@, in the
-- cell's frame) and the flat top at 1. The identities are stated by hand: bit 1
-- is north, 2 east, 4 south, 8 west; 0 and 15 are both flat. A view turns the
-- scene by whole quarter turns about the anchor tile, taking north to east to
-- south to west and an offset @(dx, dy)@ to @(-dy, dx)@; the cell keeps its
-- identity and the viewer sees its turned mask.
--
-- A pixel centre is a point of the render world (the camera's centre plus the
-- pixel's offset from the target's centre over the zoom). Its line of sight
-- through the relative frame is @(a + t, b + t, 3t)@ with
-- @a = (sx/48 + sy/24)/2@ and @b = (sy/24 - sx/48)/2@, and a larger @t@ is
-- nearer. The line meets a cell's solid in an interval of @t@ that this module
-- clips against each half-space exactly, in 'Rational'; the nearest cell by the
-- interval's end is the geometric frontmost, and the colour is the art texel at
-- the pixel's place in that cell's sheet, falling through to the next cell
-- behind where the texel is transparent. A pixel whose line only grazes a solid,
-- or ends on two cells' edges at once, is 'Ambiguous', never a guess.
--
-- Hidden faces need no model: a face covered by a neighbour lies behind its
-- cell's own frontmost surface along every line of sight that reaches it. A
-- scene whose art has transparent texels must not have two solids in contact,
-- because the planner does not emit the covered face and the line of sight
-- would otherwise land on it; 'contacts' reports them.
--
-- State, ownership and lifetime: none. Every value is immutable.
module Hetoimasia.Terrain.Render2D.Evidence
  ( -- * Scenes
    Cell (..)
  , Scene (..)
  , Mode (..)
  , newScene
  , sceneSource
  , sceneFacts
  , sceneCamera
  , sceneCameraFollowed
  , sceneSetup
  , scenePlan
  , sceneMaterials
  , contacts

    -- * Art
  , Rgba
  , ArtPixels (..)
  , diagnosticSheet

    -- * Expectations
  , Hit (..)
  , Kind (..)
  , Expected (..)
  , expectedAt
  , expectedAtFast
  , expectedImage
  , handSides
  , handTurnSide
  , pixelWorldPoint
  ) where

import Data.List (nub, sort, sortOn)
import Data.Ord (Down (..))
import Data.Word (Word8)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (targetToWorld, viewportContains)
import Hetoimasia.Render.TwoD.Metrics (PixelExtent (..), TargetMetrics (..))
import Hetoimasia.Render.TwoD.Settings (ViewSettings (..), defaultViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))
import Hetoimasia.Terrain.Changes (emptyChanges)
import Hetoimasia.Terrain.Coordinate (axisFromInteger, axisValue)
import Hetoimasia.Terrain.Render2D.Camera
import Hetoimasia.Terrain.Render2D.Facts
import Hetoimasia.Terrain.Render2D.Plan
import Hetoimasia.Terrain.Render2D.Projection (ViewSetup (..), rvMapping, rvSetup)
import Hetoimasia.Terrain.Shape (ViewFacing (..))
import Hetoimasia.Terrain.Source

-- ---------------------------------------------------------------------------
-- Scenes

-- | A run of levels @[cellZ0, cellZ1)@ of one shape and material at a column.
data Cell = Cell
  { cellX ∷ !Integer
  , cellY ∷ !Integer
  , cellZ0 ∷ !Integer
  , cellZ1 ∷ !Integer
  , cellShape ∷ !Int
  , cellMaterial ∷ !String
  }
  deriving stock (Eq, Ord, Show)

-- | How a scene's camera is set.
data Mode
  = -- | Manual at a slice level, the vertical reference at the top plane of another level.
    ManualAt !Integer !Integer
  | -- | Following the surface of the anchor column, with the automatic headroom.
    FollowSurface
  deriving stock (Eq, Show)

-- | A scene: cells, and the view they are seen through.
data Scene = Scene
  { sceneName ∷ !String
  , sceneCells ∷ ![Cell]
  , sceneAnchor ∷ !(Integer, Integer)
  , sceneMode ∷ !Mode
  , sceneFacing ∷ !ViewFacing
  , sceneZoom ∷ !Float
  , scenePan ∷ !(Double, Double)
  -- ^ A pan from the anchor tile's centre, in tiles on the world axes.
  , sceneTarget ∷ !(Int, Int)
  -- ^ The target's framebuffer extent in pixels.
  , sceneLogical ∷ !(Int, Int)
  -- ^ The extent window coordinates are measured in; equal to the target's
  -- unless the content scale is not 1.
  , sceneScale ∷ !Float
  -- ^ The target's content scale.
  , sceneViewport ∷ !(Float, Float, Float, Float)
  -- ^ Origin and extent in framebuffer pixels.
  , sceneSnap ∷ !Bool
  -- ^ Whether the view snaps to the device pixel grid.
  }
  deriving stock (Eq, Show)

-- | A scene of these cells in the target of this extent, whole target as the
-- viewport, anchored at the origin, manual at slice 0, facing south at native
-- scale.
newScene ∷ String → [Cell] → (Int, Int) → Scene
newScene name cells (w, h) =
  Scene
    { sceneName = name
    , sceneCells = cells
    , sceneAnchor = (0, 0)
    , sceneMode = ManualAt 0 0
    , sceneFacing = FaceSouth
    , sceneZoom = 1
    , scenePan = (0, 0)
    , sceneTarget = (w, h)
    , sceneLogical = (w, h)
    , sceneScale = 1
    , sceneViewport = (0, 0, fromIntegral w, fromIntegral h)
    , sceneSnap = False
    }

-- | The authored materials of a scene's cells, each once.
sceneMaterials ∷ Scene → [String]
sceneMaterials = nub . map cellMaterial . sceneCells

-- | The source holding exactly a scene's cells.
sceneSource ∷ Scene → Source
sceneSource sc =
  either (\e → error ("scene source refused: " <> show e)) id $
    mkSource
      defaultSourceLimits
      SourceSpec
        { specMaterials = sceneMaterials sc
        , specLayers = []
        , specPatches = [PatchSpec (cellX c) (cellY c) (cellZ0 c) (cellZ1 c) (SpecSolid (cellMaterial c) (cellShape c)) | c ← sceneCells sc]
        }

sceneFacts ∷ Scene → TerrainFacts
sceneFacts sc = TerrainFacts (Versions 1 1 1) (sceneSource sc) emptyChanges AllKnown

-- | The camera of a scene: its anchor, the slice and reference or the follow,
-- the facing, the zoom and the pan.
sceneCamera ∷ Scene → CameraState
sceneCamera sc = foldl step start commands
  where
    (ax, ay) = sceneAnchor sc
    facts = sceneFacts sc
    axis n = either (\e → error ("scene axis: " <> show e)) id (axisFromInteger n)
    start = either (\e → error ("scene camera: " <> show e)) id (newCamera defaultCameraConfig (axis ax) (axis ay) (axis initial))
    initial = case sceneMode sc of
      ManualAt _ ref → ref
      FollowSurface → 0
    commands =
      [SelectSlice (axis cut) | ManualAt cut _ ← [sceneMode sc]]
        <> [SetFacing (sceneFacing sc), SetZoom (sceneZoom sc), uncurry Pan (scenePan sc)]
    step camera command = either (\e → error ("scene camera command: " <> show e)) stepCamera (applyCommand defaultCameraConfig facts command camera)

-- | The scene's view setup.
sceneSetup ∷ Scene → ViewSetup
sceneSetup sc =
  ViewSetup
    { setupMetrics = TargetMetrics (PixelExtent lw lh) (PixelExtent w h) (sceneScale sc) (sceneScale sc)
    , setupViewport = Viewport (V2 vx vy) (V2 vw vh)
    , setupSettings = defaultViewSettings {settingPixelSnap = sceneSnap sc}
    }
  where
    (w, h) = sceneTarget sc
    (lw, lh) = sceneLogical sc
    (vx, vy, vw, vh) = sceneViewport sc

-- | The camera of a scene as planning leaves it: following scenes adopt their
-- anchor column's surface.
scenePlan ∷ Scene → Either PlanError Plan
scenePlan sc =
  planTerrain
    PlanRequest
      { requestVersions = Versions 1 1 1
      , requestMaterialVersion = 1
      , requestCamera = camera
      , requestSetup = sceneSetup sc
      , requestConfig = defaultPlanConfig
      }
    (sceneFacts sc)
  where
    camera = sceneCameraFollowed sc

-- | 'sceneCamera', then, for a following scene, the adoption of the surface.
sceneCameraFollowed ∷ Scene → CameraState
sceneCameraFollowed sc = case sceneMode sc of
  FollowSurface → either (\e → error ("scene follow: " <> show e)) stepCamera (refollow defaultCameraConfig (sceneFacts sc) (sceneCamera sc))
  ManualAt _ _ → sceneCamera sc

-- | Pairs of unit cells of a scene that share a face of positive area: one
-- coordinate differing by one and the other two equal. Edge and vertex contact
-- covers no face and is not reported.
contacts ∷ Scene → [(Cell, Cell)]
contacts sc =
  [ (a, b)
  | (i, (a, za)) ← indexed
  , (j, (b, zb)) ← indexed
  , i < j
  , let differences = [abs (cellX a - cellX b), abs (cellY a - cellY b), abs (za - zb)]
  , sort differences == [0, 0, 1]
  ]
  where
    indexed = zip [0 ∷ Int ..] [(c, z) | c ← sceneCells sc, z ← [cellZ0 c .. cellZ1 c - 1]]

-- ---------------------------------------------------------------------------
-- Art

type Rgba = (Word8, Word8, Word8, Word8)

-- | A sheet's texels as bytes: its extent and the texel at a column and a row.
data ArtPixels = ArtPixels
  { artWidth ∷ !Int
  , artHeight ∷ !Int
  , artTexel ∷ Int → Int → Rgba
  }

-- | A technical diagnostic sheet, not artwork: 96 × 64, every opaque texel
-- unique to its place (red grows with the column, green with the row, blue with
-- their sum), so a mirrored, flipped, shifted or transposed sampling cannot
-- agree with it; blocks of 6 × 6 texels on a lattice of 24 × 20 from (9, 5) are
-- transparent (binary alpha), the places a transparent part of a quad must
-- show what lies behind.
diagnosticSheet ∷ ArtPixels
diagnosticSheet = ArtPixels 96 64 texel
  where
    texel x y
      | (x - 9) `mod` 24 < 6 && (y - 5) `mod` 20 < 6 && x >= 9 && y >= 5 = (0, 0, 0, 0)
      | otherwise = (byte (2 * x + 20), byte (3 * y + 30), byte (x + y + 40), 255)
    byte ∷ Int → Word8
    byte = fromIntegral

-- ---------------------------------------------------------------------------
-- The independent model

-- | The lowered sides of a stored shape identity, by hand: bit 1 north, 2 east,
-- 4 south, 8 west; identity 15 has a flat top and so no ramp.
handSides ∷ Int → [Char]
handSides shape
  | shape == 15 = []
  | otherwise = [name | (bit, name) ← [(1, 'N'), (2, 'E'), (4, 'S'), (8, 'W')], shape `div` bit `mod` 2 == 1]

-- | A side after a number of positive quarter turns: north to east to south to
-- west to north.
handTurnSide ∷ Int → Char → Char
handTurnSide count side = order !! ((index + count) `mod` 4)
  where
    order = "NESW"
    index = length (takeWhile (/= side) order)

-- | The positive quarter turns a facing applies: south 0, west 3, north 2, east 1.
turnsOf ∷ ViewFacing → Int
turnsOf = \case
  FaceSouth → 0
  FaceWest → 3
  FaceNorth → 2
  FaceEast → 1

-- | One quarter turn of an offset between tile centres, repeated.
turnPair ∷ Int → (Integer, Integer) → (Integer, Integer)
turnPair count (dx, dy) = iterate (\(a, b) → (negate b, a)) (dx, dy) !! (count `mod` 4)

-- | Which face of the view-frame solid a line of sight leaves by.
data Kind = Top | EastWall | SouthWall
  deriving stock (Eq, Ord, Show)

-- | The cell a line of sight meets and where.
data Hit = Hit
  { hitCell ∷ !(Integer, Integer, Integer)
  -- ^ The world tile.
  , hitKind ∷ !Kind
  , hitSurface ∷ !Char
  -- ^ The plane the line leaves by, by hand: @F@ the flat top, @N@, @E@, @S@ or
  -- @W@ a ramp (the view-frame side it is lowered on), @e@ the East wall, @s@ the South wall.
  , hitExit ∷ !Rational
  -- ^ The line parameter at which it leaves the solid: larger is nearer.
  }
  deriving stock (Eq, Show)

-- | What a pixel centre shows.
data Expected
  = -- | Nothing: the clear colour.
    ExpectedClear
  | -- | The frontmost solid by geometry, and the texel the viewer sees: the
    -- frontmost whose texel is not transparent.
    ExpectedHit
      { expectedFront ∷ !Hit
      -- ^ What a pick finds: the geometric frontmost.
      , expectedAll ∷ ![Hit]
      -- ^ Every solid on the line of sight, nearest first.
      , expectedShown ∷ !(Maybe (Hit, Rgba))
      -- ^ What is drawn; 'Nothing' when every solid on the line has a transparent texel there.
      }
  | -- | The line grazes a solid or ends on two faces at once.
    Ambiguous !String
  deriving stock (Eq, Show)

-- | The render-world point of a pixel's centre, through the view's own mapping
-- (render-2d's, which has its own tests and oracle), or 'Nothing' outside the
-- viewport.
pixelWorldPoint ∷ Plan → (Int, Int) → Maybe (Rational, Rational)
pixelWorldPoint plan (px, py)
  | not (viewportContains (setupViewport (rvSetup view)) target) = Nothing
  | otherwise = case targetToWorld (rvMapping view) target of
      Just (V2 x y) → Just (toRational x, toRational y)
      Nothing → Nothing
  where
    view = planView plan
    target = V2 (fromIntegral px + 0.5) (fromIntegral py + 0.5)

-- | What the pixel at this column and row shows, given a scene, its camera, the
-- plan the camera and setup produce (only its view centre is read from it) and
-- each material's art.
expectedAt ∷ (String → Maybe ArtPixels) → Scene → CameraState → Plan → (Int, Int) → Expected
expectedAt art sc camera plan pixel = case pixelWorldPoint plan pixel of
  Nothing → ExpectedClear
  Just (sx, sy) → expectedAtPoint art sc camera (sx, sy)

-- | 'expectedAt' in 'Double' arithmetic, for every pixel of an image: the same
-- model, each decision made at the same margin (a fraction of a hundredth of a
-- pixel, far above the arithmetic's error), so a pixel the exact model decides
-- and this one does not is rare and never a disagreement. The CPU suite holds the
-- two to each other.
expectedAtFast ∷ (String → Maybe ArtPixels) → Scene → CameraState → Plan → (Int, Int) → Expected
expectedAtFast art sc camera plan pixel = case pixelWorldPoint plan pixel of
  Nothing → ExpectedClear
  Just (sx, sy) → expectedAtPoint art sc camera (fromRational sx ∷ Double, fromRational sy ∷ Double)

expectedAtPoint ∷ (RealFrac a) ⇒ (String → Maybe ArtPixels) → Scene → CameraState → (a, a) → Expected
expectedAtPoint art sc camera (sx, sy) =
  case (ambiguity, geometric) of
    (Just why, _) → Ambiguous why
    (_, []) → ExpectedClear
    (_, front : _) → case firstOpaque geometric of
      Left why → Ambiguous why
      Right shown →
        ExpectedHit
          { expectedFront = fst front
          , expectedAll = map fst geometric
          , expectedShown = shown
          }
  where
    anchorX = toInteger (axisValue (camAnchorX camera))
    anchorY = toInteger (axisValue (camAnchorY camera))
    clip = toInteger (axisValue (camClip camera))
    ref = camRef camera
    count = turnsOf (camFacing camera)
    a0 = (sx / 48 + sy / 24) / 2
    b0 = (sy / 24 - sx / 48) / 2
    -- Every level of every cell at or below the cut whose hexagon (a pixel
    -- wider) holds the point: the other cells cannot be on the line of sight.
    unitCells = [(c, z) | c ← sceneCells sc, z ← [cellZ0 c .. cellZ1 c - 1], z <= clip, inHexagon c z]
    inHexagon c z =
      let (vx, vy) = turnPair count (cellX c - anchorX, cellY c - anchorY)
          ox = 48 * fromInteger (vx - vy)
          oy = 24 * (fromInteger (vx + vy) - 1) - 16 * fromInteger (z - ref)
       in sx >= ox - 49 && sx <= ox + 49 && sy >= oy - 17 && sy <= oy + 49
    results = [(c, z, intersect c z) | (c, z) ← unitCells]
    geometric =
      sortOn (Down . hitExit . fst)
        [ (hit, (c, z))
        | (c, z, Right (Just hit)) ← results
        ]
    ambiguity = case [why | (_, _, Left why) ← results] of
      why : _ → Just why
      [] → case geometric of
        (first, _) : (second, _) : _ | abs (hitExit first - hitExit second) < margin → Just "two solids leave the line of sight at the same point"
        _ → Nothing
    -- The nearest solid whose texel is not transparent; ambiguous when a texel is
    -- within a sixteenth of a texel of its boundary, where nearest sampling is
    -- not decided by the line of sight alone.
    firstOpaque candidates = case candidates of
      [] → Right Nothing
      (hit, (c, z)) : rest → case texelAt c z of
        Left why → Left why
        Right rgba
          | opaque rgba → Right (Just (hit, rgba))
          | otherwise → firstOpaque rest
    opaque (_, _, _, alpha) = alpha /= 0
    -- The texel of a cell's sheet at the pixel's place: the sheet is placed at
    -- the cell origin's projection less (48, 16).
    texelAt c z = case art (cellMaterial c) of
      Nothing → Left ("no sheet for " <> cellMaterial c)
      Just sheet →
        let (vx, vy) = turnPair count (cellX c - anchorX, cellY c - anchorY)
            ox = 48 * (fromInteger vx - 1 / 2 - (fromInteger vy - 1 / 2))
            oy = 24 * ((fromInteger vx - 1 / 2) + (fromInteger vy - 1 / 2)) - 16 * fromInteger (z - ref)
            fu = sx - (ox - 48)
            fv = sy - (oy - 16)
            u = floor fu ∷ Integer
            v = floor fv ∷ Integer
            nearBoundary t = let f = t - fromInteger (floor t) in f < 1 / 16 || f > 15 / 16
         in
          if u < 0 || v < 0 || u >= toInteger (artWidth sheet) || v >= toInteger (artHeight sheet)
            then Left "the line of sight leaves the sheet"
            else
              if nearBoundary fu || nearBoundary fv
                then Left "a texel boundary"
                else Right (artTexel sheet (fromInteger u) (fromInteger v))
    intersect c z =
      let (vx, vy) = turnPair count (cellX c - anchorX, cellY c - anchorY)
          sides = map (handTurnSide count) (handSides (cellShape c))
          zrel = fromInteger (z - ref)
          lx0 = a0 - fromInteger vx + 1 / 2
          ly0 = b0 - fromInteger vy + 1 / 2
          lowers = [negate lx0, negate ly0, zrel / 3]
          uppers =
            [(1 - lx0, (EastWall, 'e')), (1 - ly0, (SouthWall, 's')), ((1 + zrel) / 3, (Top, 'F'))]
              <> [ case side of
                     'N' → ((ly0 + zrel) / 2, (Top, 'N'))
                     'E' → ((1 - lx0 + zrel) / 4, (Top, 'E'))
                     'S' → ((1 - ly0 + zrel) / 4, (Top, 'S'))
                     _ → ((lx0 + zrel) / 2, (Top, 'W'))
                 | side ← sides
                 ]
          tlo = maximum lowers
          thi = minimum (map fst uppers)
          binding = nub [face | (value, face) ← uppers, value - thi < margin]
       in if thi < tlo - margin
            then Right Nothing
            else
              if abs (thi - tlo) <= margin
                then Left "the line of sight only grazes a solid"
                else case binding of
                  [(kind, surface)] → Right (Just (Hit (cellX c, cellY c, z) kind surface (toRational thi)))
                  _ → Left "the line of sight leaves a solid along an edge between faces"

-- | How near, in line-of-sight units (a pixel is about a fiftieth), two answers
-- must be to be called the same point: a fraction of a hundredth of a pixel,
-- where a 32-bit device may decide either way.
margin ∷ Fractional a ⇒ a
margin = 1 / 4096

-- | The expectation at every pixel of a scene's target, row by row, top to bottom.
expectedImage ∷ (String → Maybe ArtPixels) → Scene → [[Expected]]
expectedImage art sc = [[expectedAt art sc camera plan (x, y) | x ← [0 .. w - 1]] | y ← [0 .. h - 1]]
  where
    camera = sceneCameraFollowed sc
    plan = either (\e → error ("scene plan: " <> show e)) id (scenePlan sc)
    (w, h) = sceneTarget sc
