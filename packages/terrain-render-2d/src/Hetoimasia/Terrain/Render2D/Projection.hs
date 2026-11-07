-- | The exact isometric projection of terrain and its composition with the
-- render-2d view mapping.
--
-- == Frames
--
-- * /World/: tile coordinates, X east, Y south, Z up ('TileCoord'). Exact.
-- * /View frame/: the world turned by the facing's quarter turns about the
--   centre of the anchor tile (the same compass turn as
--   'Hetoimasia.Terrain.Shape.rotateShape'), so a view looks along a fixed
--   direction whatever the facing. A cell keeps its authored world tile and
--   shape identity; only its offset from the anchor and the shape it presents
--   ('viewShape') turn.
-- * /Relative frame/: view-frame coordinates measured from the centre of the
--   anchor tile horizontally and from the camera's vertical reference
--   elevation ('anchorRef') vertically. Every difference is taken in 'Integer'
--   from exact tile values, so nothing is converted to a floating-point number
--   before it is a small bounded offset.
-- * /Render world/: isometric pixels at native artwork scale, in the relative
--   frame. This is the render-2d "world" of the view mapping: the view camera
--   sits at 'rvCentre' and zoom is render-2d's zoom.
--
-- == Equations
--
-- With a relative point @(x, y, z)@ in tile units (the unit cell is
-- @[0,1]^3@ above its base), the render-world position in pixels (Y down) is
--
-- > sx = 48 · (x − y)
-- > sy = 24 · (x + y) − 16 · z
--
-- so a tile's top diamond is 96 pixels wide and 48 pixels tall and one
-- elevation level is 16 pixels, the proportions of the selected baseline.
-- Points with equal @(sx, sy)@ differ by a multiple of @(1, 1, 3)@; the
-- camera lies in that direction, and a larger multiple is nearer.
--
-- The viewport centre shows the point @(anchorX + fracX, anchorY + fracY)@ at
-- elevation 'anchorRef', turned by the facing with the world. The camera
-- position handed to render-2d is the projection of the turned fractional
-- offset from the anchor tile's centre, a few dozen pixels at most, however far
-- the anchor is from the origin.
--
-- State, ownership and lifetime: none. Every value is immutable and every
-- function pure.
module Hetoimasia.Terrain.Render2D.Projection
  ( -- * Constants
    tileWidthPixels
  , tileTopPixels
  , elevationPixels
  , viewDirection

    -- * Facing turns
  , facingTurnCount
  , turnOffset
  , viewOffset
  , worldOffset
  , turnVector

    -- * Projection
  , isoProject
  , rationalToFloat

    -- * Rectangles
  , Rect (..)
  , rectsOverlap
  , rectContains

    -- * The render view
  , ViewSetup (..)
  , RenderView
  , rvSetup
  , rvZoom
  , rvFacing
  , rvCentre
  , rvMapping
  , ProjectionError (..)
  , mkRenderView
  , visibleRect
  ) where

import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Mapping (ViewMapping, targetToWorld, viewMapping, viewportIsEmpty)
import Hetoimasia.Render.TwoD.Metrics (TargetMetrics)
import Hetoimasia.Render.TwoD.Settings (ViewSettings)
import Hetoimasia.Render.TwoD.Snapshot (Camera (..), View (..), Viewport (..))
import Hetoimasia.Terrain.Shape (ViewFacing, facingTurns, turnCount)

-- | The width of a tile's top diamond in pixels at native scale.
tileWidthPixels ∷ Int
tileWidthPixels = 96

-- | The height of a tile's top diamond in pixels at native scale.
tileTopPixels ∷ Int
tileTopPixels = 48

-- | The pixels one elevation level rises.
elevationPixels ∷ Int
elevationPixels = 16

-- | The relative-frame direction along which projections coincide, toward the
-- camera: a larger multiple is nearer.
viewDirection ∷ (Rational, Rational, Rational)
viewDirection = (1, 1, 3)

-- | The positive quarter turns a facing applies to the world.
facingTurnCount ∷ ViewFacing → Int
facingTurnCount = turnCount . facingTurns

-- | One positive quarter turn count applied to an integer offset between tile
-- centres. One turn takes @(dx, dy)@ to @(−dy, dx)@, which takes East to South
-- as 'Hetoimasia.Terrain.Shape.rotateSide' does.
turnOffset ∷ Int → (Integer, Integer) → (Integer, Integer)
turnOffset count (dx, dy) = case count `mod` 4 of
  0 → (dx, dy)
  1 → (negate dy, dx)
  2 → (negate dx, negate dy)
  _ → (dy, negate dx)

-- | A world offset between tile centres as the view frame sees it.
viewOffset ∷ ViewFacing → (Integer, Integer) → (Integer, Integer)
viewOffset facing = turnOffset (facingTurnCount facing)

-- | The inverse of 'viewOffset'.
worldOffset ∷ ViewFacing → (Integer, Integer) → (Integer, Integer)
worldOffset facing = turnOffset (negate (facingTurnCount facing))

-- | The turn of a rational planar vector, as 'turnOffset'.
turnVector ∷ Int → (Rational, Rational) → (Rational, Rational)
turnVector count (u, v) = case count `mod` 4 of
  0 → (u, v)
  1 → (negate v, u)
  2 → (negate u, negate v)
  _ → (v, negate u)

-- | The render-world position of a relative-frame point.
isoProject ∷ (Rational, Rational, Rational) → (Rational, Rational)
isoProject (x, y, z) = (48 * (x - y), 24 * (x + y) - 16 * z)

-- | A rational as a 'Float', or 'Nothing' if it is not representable as a
-- finite one. The conversion rounds once and is applied only to bounded
-- relative values.
rationalToFloat ∷ Rational → Maybe Float
rationalToFloat r
  | isNaN f || isInfinite f = Nothing
  | otherwise = Just f
  where
    f = fromRational r ∷ Float

-- | A closed axis-aligned rectangle of render-world positions.
data Rect = Rect
  { rectMinX ∷ !Rational
  , rectMaxX ∷ !Rational
  , rectMinY ∷ !Rational
  , rectMaxY ∷ !Rational
  }
  deriving stock (Eq, Show)

-- | Whether two closed rectangles share a point.
rectsOverlap ∷ Rect → Rect → Bool
rectsOverlap (Rect a1 a2 b1 b2) (Rect c1 c2 d1 d2) = a1 <= c2 && c1 <= a2 && b1 <= d2 && d1 <= b2

-- | Whether a closed rectangle contains a point.
rectContains ∷ Rect → (Rational, Rational) → Bool
rectContains (Rect x1 x2 y1 y2) (x, y) = x1 <= x && x <= x2 && y1 <= y && y <= y2

-- | The target, viewport and settings a view draws with. These are the
-- caller's render-2d facts; zoom, facing and camera come from the camera.
data ViewSetup = ViewSetup
  { setupMetrics ∷ !TargetMetrics
  , setupViewport ∷ !Viewport
  , setupSettings ∷ !ViewSettings
  }
  deriving stock (Eq, Show)

-- | A view ready to draw and pick: the setup, zoom and facing it was built
-- from, the camera position in render-world pixels and the render-2d mapping.
-- The constructor is private, so every value passed 'mkRenderView'.
data RenderView = RenderView
  { vwSetup ∷ !ViewSetup
  , vwZoom ∷ !Float
  , vwFacing ∷ !ViewFacing
  , vwCentre ∷ !(Rational, Rational)
  , vwMapping ∷ !ViewMapping
  }
  deriving stock (Eq, Show)

-- Plain functions, not field labels, so a client cannot rewrite a view with
-- record-update syntax.

rvSetup ∷ RenderView → ViewSetup
rvSetup = vwSetup

rvZoom ∷ RenderView → Float
rvZoom = vwZoom

rvFacing ∷ RenderView → ViewFacing
rvFacing = vwFacing

rvCentre ∷ RenderView → (Rational, Rational)
rvCentre = vwCentre

rvMapping ∷ RenderView → ViewMapping
rvMapping = vwMapping

-- | Why a view could not be built.
data ProjectionError
  = -- | The render-2d mapping refused the view: an invalid camera, viewport,
    -- settings or metrics, or a transform that cannot be represented.
    ViewRefused
  | -- | The camera position is not representable as a finite 'Float'.
    UnrepresentableCamera
  deriving stock (Eq, Show)

-- | Build the view for a zoom, a facing and the fractional offset of the
-- camera from the anchor tile's origin (each in @[0, 1)@, in world axes).
mkRenderView ∷ ViewSetup → Float → ViewFacing → (Rational, Rational) → Either ProjectionError RenderView
mkRenderView setup zoom facing (fx, fy) = do
  let (ox, oy) = turnVector (facingTurnCount facing) (fx - 1 / 2, fy - 1 / 2)
      (cx, cy) = isoProject (ox, oy, 0)
  px ← maybe (Left UnrepresentableCamera) Right (rationalToFloat cx)
  py ← maybe (Left UnrepresentableCamera) Right (rationalToFloat cy)
  let camera = Camera {cameraPosition = V2 px py, cameraZoom = zoom, cameraRotation = Nothing}
      view = View camera (setupViewport setup) (setupSettings setup) [] []
  mapping ← maybe (Left ViewRefused) Right (viewMapping (setupMetrics setup) view)
  pure RenderView {vwSetup = setup, vwZoom = zoom, vwFacing = facing, vwCentre = (cx, cy), vwMapping = mapping}

-- | The render-world rectangle the viewport shows, grown by a margin of whole
-- pixels on every side, or 'Nothing' for a viewport that draws nothing. The
-- margin absorbs the mapping's 32-bit rounding and its pixel snap.
visibleRect ∷ Rational → RenderView → Maybe Rect
visibleRect margin view
  | viewportIsEmpty viewport = Nothing
  | otherwise = do
      let Viewport (V2 ox oy) (V2 w h) = viewport
          corners = [V2 ox oy, V2 (ox + w) oy, V2 ox (oy + h), V2 (ox + w) (oy + h)]
      worlds ← traverse (targetToWorld (vwMapping view)) corners
      let xs = [toRational x | V2 x _ ← worlds]
          ys = [toRational y | V2 _ y ← worlds]
      pure (Rect (minimum xs - margin) (maximum xs + margin) (minimum ys - margin) (maximum ys + margin))
  where
    viewport = setupViewport (vwSetup view)
