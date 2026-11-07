-- | The 16-shape catalog: checked identities, names and exact quarter turns.
--
-- A world shape identity is @0..15@ and is the four-bit mask of the reference
-- slope set: bit 1 is North, 2 East, 4 South and 8 West, with North toward
-- negative Y and East toward positive X. The canonical names are
-- @0 Flat; 1 N; 2 E; 3 NE; 4 S; 5 NS; 6 ES; 7 NES; 8 W; 9 NW; 10 EW;
-- 11 NEW; 12 SW; 13 NSW; 14 ESW; 15 NESW@. Identities 0 and 15 stay distinct
-- authored identities even though both have a flat top, and NS and EW stay
-- distinct from each other. An identity outside @0..15@ is refused by
-- 'mkShapeId'; it is never normalized to flat, and no other catalog is
-- substituted.
--
-- Rotation permutes the four bits. A positive quarter turn takes North to East
-- to South to West; four turns restore the starting shape. The world identity
-- never changes when a view turns: only the mask a view selects does
-- ('viewShape'), which reproduces the reference's facing order.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Shape
  ( -- * Identity
    ShapeId
  , ShapeError (..)
  , mkShapeId
  , shapeIdValue
  , allShapeIds
  , shapeName

    -- * Sides and the mask
  , Side (..)
  , allSides
  , sideBit
  , shapeSides
  , shapeFromSides

    -- * Quarter turns
  , Turns
  , turns
  , turnCount
  , addTurns
  , inverseTurns
  , rotateSide
  , rotateShape

    -- * View facings
  , ViewFacing (..)
  , allViewFacings
  , facingTurns
  , viewShape
  , worldShape
  ) where

import Hetoimasia.Terrain.Internal.Shape

-- | The reference's camera facings, in the reference's order. The world's
-- stored shape is expressed as seen from 'FaceSouth'.
data ViewFacing = FaceSouth | FaceWest | FaceNorth | FaceEast
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Every facing, in the reference's order.
allViewFacings ∷ [ViewFacing]
allViewFacings = [minBound .. maxBound]

-- | The positive quarter turns that take the stored mask to the mask a view at
-- that facing selects: South 0, West 3, North 2, East 1. Checked against the
-- reference's view mapping, in which an East mask becomes North at the West
-- facing, West at the North facing and South at the East facing.
facingTurns ∷ ViewFacing → Turns
facingTurns FaceSouth = turns 0
facingTurns FaceWest = turns 3
facingTurns FaceNorth = turns 2
facingTurns FaceEast = turns 1

-- | The mask a view at the given facing selects for a stored world shape. The
-- world shape is unchanged; only this selection depends on the view.
viewShape ∷ ViewFacing → ShapeId → ShapeId
viewShape facing = rotateShape (facingTurns facing)

-- | The inverse of 'viewShape': the stored world shape a view-selected mask
-- stands for.
worldShape ∷ ViewFacing → ShapeId → ShapeId
worldShape facing = rotateShape (inverseTurns (facingTurns facing))
