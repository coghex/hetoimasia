-- | An independent reference for the TRA-14 maps: the frontmost visible
-- surface of a shape at a canvas position, worked out from the P-9 height table
-- alone.
--
-- It shares nothing with the baker. The solid is the list of closed half-spaces
-- the table states (@z <= N, E, S, W@ per set bit, or @z <= 1@, inside the unit
-- footprint and above the base), the points that project to one canvas position
-- are the line @(x0 + z/3, y0 + z/3, z)@, and the frontmost is found by trying
-- every height at which the line meets one constraint's plane and keeping the
-- highest feasible one, rather than by clipping an interval or casting a ray at
-- the production solid. The expected bytes of each facet are hand-stated, not
-- computed.
module Test.TerrainRender2D.MapAssets.Reference
  ( RefFacet (..)
  , RefHit (..)
  , RefMixed (..)
  , refFrontmost
  , refMixed
  , refNormal
  , expectedBytes
  , solidConstraints
  , facingCamera
  ) where

import Hetoimasia.Terrain.Shape (ShapeId, Side (..), shapeFromSides, shapeIdValue)

-- | A facet by what bounds the solid there.
data RefFacet
  = -- | A top facet: the ramp of a set side, or 'Nothing' for the flat top.
    RefTop (Maybe Side)
  | RefWall Side
  | RefBottom
  deriving stock (Eq, Show)

-- | @(a, b, c, d)@ with @a x + b y + c z <= d@, and its facet.
type Constraint = (RefFacet, (Rational, Rational, Rational), Rational)

-- | The outward plane normal of a facet.
refNormal ∷ RefFacet → (Rational, Rational, Rational)
refNormal (RefTop Nothing) = (0, 0, 1)
refNormal (RefTop (Just North)) = (0, -1, 1)
refNormal (RefTop (Just East)) = (1, 0, 1)
refNormal (RefTop (Just South)) = (0, 1, 1)
refNormal (RefTop (Just West)) = (-1, 0, 1)
refNormal (RefWall North) = (0, -1, 0)
refNormal (RefWall East) = (1, 0, 0)
refNormal (RefWall South) = (0, 1, 0)
refNormal (RefWall West) = (-1, 0, 0)
refNormal RefBottom = (0, 0, -1)

-- | The profile bytes of a facet's unit normal, stated by hand:
-- @round (128 + 127 n)@ with @n@ one of 0, ±1 or ±1/sqrt 2 (0.70711, giving 90 or 218 and 38).
expectedBytes ∷ RefFacet → (Int, Int, Int)
expectedBytes (RefTop Nothing) = (128, 128, 255)
expectedBytes (RefTop (Just North)) = (128, 38, 218)
expectedBytes (RefTop (Just East)) = (218, 128, 218)
expectedBytes (RefTop (Just South)) = (128, 218, 218)
expectedBytes (RefTop (Just West)) = (38, 128, 218)
expectedBytes (RefWall North) = (128, 1, 128)
expectedBytes (RefWall East) = (255, 128, 128)
expectedBytes (RefWall South) = (128, 255, 128)
expectedBytes (RefWall West) = (1, 128, 128)
expectedBytes RefBottom = (128, 128, 1)

-- | The closed half-spaces of a shape's solid in canonical facet order: the tops
-- in the order of the set bits N, E, S, W (or the one flat top), the walls North,
-- East, South, West, then the base.
solidConstraints ∷ ShapeId → [Constraint]
solidConstraints shape = tops <> walls <> [(RefBottom, (0, 0, -1), 0)]
  where
    bits = shapeIdValue shape
    set mask = bits `div` mask `mod` 2 == 1
    sides = [side | (side, mask) ← [(North, 1), (East, 2), (South, 4), (West, 8)], set mask]
    tops
      | null sides = [(RefTop Nothing, (0, 0, 1), 1)]
      | otherwise = [(RefTop (Just side), (a, b, c), d) | side ← sides, let ((a, b, c), d) = ramp side]
    -- z <= y, z <= 1 - x, z <= 1 - y, z <= x.
    ramp North = ((0, -1, 1), 0)
    ramp East = ((1, 0, 1), 1)
    ramp South = ((0, 1, 1), 1)
    ramp West = ((-1, 0, 1), 0)
    walls =
      [ (RefWall North, (0, -1, 0), 0)
      , (RefWall East, (1, 0, 0), 1)
      , (RefWall South, (0, 1, 0), 1)
      , (RefWall West, (-1, 0, 0), 0)
      ]

-- | Whether a facet's outward normal faces the camera, which looks along
-- @(1, 1, 3)@.
facingCamera ∷ RefFacet → Bool
facingCamera facet = let (a, b, c) = refNormal facet in a + b + 3 * c > 0

-- | What the reference finds on the line through a canvas position.
data RefHit = RefHit
  { refFacet ∷ !RefFacet
  -- ^ The facet the tie rule gives the frontmost point.
  , refTight ∷ !Int
  -- ^ How many constraints hold with equality there: 1 for the interior of a
  -- facet.
  , refSpan ∷ !(Rational, Rational)
  -- ^ The lowest and highest heights of the line inside the solid.
  , refPoint ∷ !(Rational, Rational, Rational)
  }
  deriving stock (Eq, Show)

-- | The cell-frame points of a canvas position: @x = x0 + z / 3@, @y = y0 + z / 3@.
lineAt ∷ (Rational, Rational) → (Rational, Rational)
lineAt (u, v) = ((along + across) / 2, (along - across) / 2)
  where
    across = (u - 48) / 48
    along = (v - 16) / 24

-- | The frontmost point of the closed solid on the line through a canvas
-- position, by the tie rule: a line that runs through the solid takes, of the
-- facets tight at its nearest point, the first facing the camera in canonical
-- order; a line that only touches the closed solid takes the first tight facet.
refFrontmost ∷ [Constraint] → (Rational, Rational) → Maybe RefHit
refFrontmost constraints position = case feasible of
  [] → Nothing
  _ →
    Just
      RefHit
        { refFacet = case (if bottom < top then filter facingCamera tight else tight) of
            first : _ → first
            [] → RefBottom
        , refTight = length tight
        , refSpan = (bottom, top)
        , refPoint = (x0 + top / 3, y0 + top / 3, top)
        }
  where
    (x0, y0) = lineAt position
    -- a x + b y + c z <= d along the line: alpha + beta z <= 0.
    along (_, (a, b, c), d) = (a * x0 + b * y0 - d, (a + b) / 3 + c)
    holds z constraint = let (alpha, beta) = along constraint in alpha + beta * z <= 0
    candidates = [negate alpha / beta | constraint ← constraints, let (alpha, beta) = along constraint, beta /= 0]
    feasible = [z | z ← candidates, all (holds z) constraints]
    top = maximum feasible
    bottom = minimum feasible
    tight = [facet | constraint@(facet, _, _) ← constraints, let (alpha, beta) = along constraint, alpha + beta * top == 0]

-- | The visible part at a canvas position of a shape's solid plus cover.
data RefMixed = RefClear | RefKnown RefFacet | RefFog RefFacet
  deriving stock (Eq, Show)

-- | The frontmost point of the unit cube (solid plus opaque cover), classified by
-- whether it lies in the closed solid; its facet is the cube's.
refMixed ∷ ShapeId → (Rational, Rational) → RefMixed
refMixed shape position = case refFrontmost (solidConstraints (shapeFromSides [])) position of
  Nothing → RefClear
  Just hit
    | inSolid (refPoint hit) → RefKnown (refFacet hit)
    | otherwise → RefFog (refFacet hit)
  where
    inSolid (x, y, z) = all (\(_, (a, b, c), d) → a * x + b * y + c * z <= d) (solidConstraints shape)
