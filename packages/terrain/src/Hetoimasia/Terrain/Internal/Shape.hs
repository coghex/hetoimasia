-- | The shape catalog's representation behind "Hetoimasia.Terrain.Shape".
--
-- Private to the package: the constructor of 'ShapeId' is reachable only from
-- here and from the geometry that derives a solid from an identity. A client
-- obtains a 'ShapeId' only through 'mkShapeId', which refuses every identity
-- outside the 16-shape catalog; nothing normalizes an unsupported identity to
-- flat.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Shape
  ( ShapeId (..)
  , ShapeError (..)
  , Side (..)
  , allSides
  , sideBit
  , mkShapeId
  , shapeIdValue
  , allShapeIds
  , shapeSides
  , shapeFromSides
  , shapeName
  , Turns (..)
  , turns
  , turnCount
  , addTurns
  , inverseTurns
  , rotateSide
  , rotateShape
  ) where

import Data.Bits (shiftL, (.&.), (.|.))
import Data.Word (Word8)

-- | One of the 16 catalog identities, @0..15@. The constructor is private.
newtype ShapeId = ShapeId Word8
  deriving stock (Eq, Ord, Show)

-- | Why a shape identity was refused.
newtype ShapeError = UnsupportedShapeId Int
  deriving stock (Eq, Show)

-- | A cardinal side of a cell. North is toward negative Y and East toward
-- positive X, so South is positive Y and West negative X.
data Side = North | East | South | West
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The four sides in their canonical order, North, East, South, West: the
-- order of the mask bits, and of one positive quarter turn.
allSides ∷ [Side]
allSides = [minBound .. maxBound]

-- | The mask bit of a side: North 1, East 2, South 4, West 8.
sideBit ∷ Side → Word8
sideBit side = 1 `shiftL` fromEnum side

-- | Check an identity against the catalog @0..15@.
mkShapeId ∷ Int → Either ShapeError ShapeId
mkShapeId value
  | value < 0 || value > 15 = Left (UnsupportedShapeId value)
  | otherwise = Right (ShapeId (fromIntegral value))

-- | The numeric identity, @0..15@.
shapeIdValue ∷ ShapeId → Int
shapeIdValue (ShapeId value) = fromIntegral value

-- | The whole catalog in identity order.
allShapeIds ∷ [ShapeId]
allShapeIds = map ShapeId [0 .. 15]

-- | The sides whose mask bit is set, in the order North, East, South, West.
shapeSides ∷ ShapeId → [Side]
shapeSides (ShapeId mask) = [side | side ← allSides, mask .&. sideBit side /= 0]

-- | The identity whose set bits are exactly the given sides.
shapeFromSides ∷ [Side] → ShapeId
shapeFromSides sides = ShapeId (foldr ((.|.) . sideBit) 0 sides)

-- | The canonical name: @Flat@ for 0, the set sides in the order N, E, S, W
-- otherwise, and @NESW@ for 15 (the authored all-sides identity).
shapeName ∷ ShapeId → String
shapeName shape@(ShapeId mask)
  | mask == 0 = "Flat"
  | otherwise = concatMap letter (shapeSides shape)
  where
    letter North = "N"
    letter East = "E"
    letter South = "S"
    letter West = "W"

-- | A number of quarter turns, always normalized to @0..3@. One positive turn
-- takes North to East to South to West to North, a compass mapping that is
-- never inferred from an angle sign.
newtype Turns = Turns Int
  deriving stock (Eq, Ord, Show)

-- | Normalize any count, including a negative one, to @0..3@.
turns ∷ Int → Turns
turns count = Turns (count `mod` 4)

-- | The normalized count, @0..3@.
turnCount ∷ Turns → Int
turnCount (Turns count) = count

-- | The composition of two rotations.
addTurns ∷ Turns → Turns → Turns
addTurns (Turns a) (Turns b) = turns (a + b)

-- | The rotation that undoes a rotation.
inverseTurns ∷ Turns → Turns
inverseTurns (Turns a) = turns (negate a)

-- | Rotate a side by quarter turns: @rotateSide (turns 1) North == East@.
rotateSide ∷ Turns → Side → Side
rotateSide (Turns count) side = toEnum ((fromEnum side + count) `mod` 4)

-- | Rotate a shape by quarter turns: every set bit moves with its side. The
-- identities 0 and 15 are fixed, and North-South and East-West exchange.
rotateShape ∷ Turns → ShapeId → ShapeId
rotateShape count = shapeFromSides . map (rotateSide count) . shapeSides
