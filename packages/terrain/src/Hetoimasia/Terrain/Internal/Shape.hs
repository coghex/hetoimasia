-- | The shape catalog's representation behind "Hetoimasia.Terrain.Shape".
--
-- Private to the package: the constructors of 'ShapeId', 'CornerMask' and
-- 'ShapeKey' are reachable only from here and from the geometry that derives a
-- solid from them. A client obtains a 'ShapeId' only through 'mkShapeId', which
-- refuses every identity outside the 16-shape catalog, and a 'CornerMask' only
-- through 'mkCornerMask', which refuses every mask outside @0..15@; nothing
-- normalizes an unsupported value to flat or to air.
--
-- State, ownership and lifetime: none. Pure, immutable values.
module Hetoimasia.Terrain.Internal.Shape
  ( ShapeId (..)
  , ShapeError (..)
  , CornerMask (..)
  , mkCornerMask
  , cornerMaskValue
  , ShapeKey (..)
  , sideKey
  , resolveCorner
  , allShapeKeys
  , rotateKey
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

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.Word (Word8)

-- | One of the 16 catalog identities, @0..15@. The constructor is private.
newtype ShapeId = ShapeId Word8
  deriving stock (Eq, Ord, Show)

-- | Why a shape identity or corner mask was refused.
data ShapeError
  = -- | A side identity outside @0..15@.
    UnsupportedShapeId Int
  | -- | A corner mask outside @0..15@.
    UnsupportedCornerMask Int
  deriving stock (Eq, Show)

-- | A checked corner mask, @0..15@: bit 1 is the north-west corner, 2 the
-- north-east, 4 the south-east and 8 the south-west, and a set bit is a corner
-- that reaches the next level. The constructor is private.
newtype CornerMask = CornerMask Word8
  deriving stock (Eq, Ord, Show)

-- | Check a corner mask against @0..15@.
mkCornerMask ∷ Int → Either ShapeError CornerMask
mkCornerMask value
  | value < 0 || value > 15 = Left (UnsupportedCornerMask value)
  | otherwise = Right (CornerMask (fromIntegral value))

-- | The numeric mask, @0..15@.
cornerMaskValue ∷ CornerMask → Int
cornerMaskValue (CornerMask value) = fromIntegral value

-- | The identity of one occupied shape: a family and a value within it. The
-- constructors are private, so every key is a side identity or a nonzero
-- corner mask, and a side identity never equals a corner mask. Side @0@ and
-- corner mask @15@ are two different full blocks, and side @15@ keeps its
-- apex.
data ShapeKey = SideKey !ShapeId | CornerKey !CornerMask
  deriving stock (Eq, Ord, Show)

-- | The key of a side identity.
sideKey ∷ ShapeId → ShapeKey
sideKey = SideKey

-- | The key of a corner mask: 'Nothing' for mask zero, which is air, and the
-- tagged key of every other mask.
resolveCorner ∷ CornerMask → Maybe ShapeKey
resolveCorner (CornerMask 0) = Nothing
resolveCorner mask = Just (CornerKey mask)

-- | Every occupied key exactly once: the 16 side identities, then the 15
-- nonzero corner masks. The order carries no identity.
allShapeKeys ∷ [ShapeKey]
allShapeKeys = map SideKey allShapeIds <> map CornerKey [CornerMask mask | mask ← [1 .. 15]]

-- | Rotate a key by quarter turns. A side key rotates as 'rotateShape' does. A
-- corner key moves each set corner one place per turn, north-west to
-- north-east to south-east to south-west, which is the left rotation of the
-- four-bit mask. Four turns restore the key.
rotateKey ∷ Turns → ShapeKey → ShapeKey
rotateKey count (SideKey shape) = SideKey (rotateShape count shape)
rotateKey (Turns count) (CornerKey (CornerMask mask)) =
  CornerKey (CornerMask (((mask `shiftL` count) .|. (mask `shiftR` (4 - count))) .&. 15))

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
