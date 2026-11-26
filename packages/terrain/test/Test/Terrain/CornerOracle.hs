-- | An independent reference for the folded height of a corner mask.
--
-- This is a translation, in exact 'Rational' arithmetic, of the approved
-- @surface_height@ function in the Widdershins record
-- @tracker/032-corner-defined-terrain.md@ (Python, there
-- 'surface_height(mask, x, y)'). It imports nothing from the engine and calls no
-- engine height, piece, key or rotation function, so agreement with the engine
-- is evidence and not a restatement.
--
-- The reference names the corners clockwise from the north-west with X
-- increasing east and Y south, and its mask bits are north-west 1, north-east
-- 2, south-east 4 and south-west 8.
module Test.Terrain.CornerOracle
  ( surfaceHeightReference
  , referenceMasks
  , referenceCoordinates
  ) where

import Data.Bits (shiftR, (.&.))

-- | The normalized height inside a corner-defined cell, or 'Nothing' for the
-- empty mask. The reference raises on a mask outside @0..15@ and on a point
-- outside the unit square, and so does this translation.
surfaceHeightReference ∷ Int → Rational → Rational → Maybe Rational
surfaceHeightReference mask x y
  | mask < 0 || mask > 15 || x < 0 || x > 1 || y < 0 || y > 1 =
      error "surfaceHeightReference: expected a four-bit mask and unit-cell coordinates"
  | mask == 0 = Nothing
  -- Each triangle is planar. For a lone high or low corner, the crease is
  -- between its two neighbours. For opposite high corners, join the lows.
  | nw == se && (ne /= sw || nw == 0) =
      Just
        ( if x >= y
            then (1 - x) * nw + (x - y) * ne + y * se
            else (1 - y) * nw + (y - x) * sw + x * se
        )
  | x + y <= 1 = Just ((1 - x - y) * nw + x * ne + y * sw)
  | otherwise = Just ((1 - y) * ne + (x + y - 1) * se + (1 - x) * sw)
  where
    corner bit = fromIntegral ((mask `shiftR` bit) .&. 1) ∷ Rational
    nw = corner 0
    ne = corner 1
    se = corner 2
    sw = corner 3

-- | Every mask the reference accepts.
referenceMasks ∷ [Int]
referenceMasks = [0 .. 15]

-- | The 17 sample coordinates @i/16@, @i = 0..16@, endpoints included.
referenceCoordinates ∷ [Rational]
referenceCoordinates = [fromIntegral i / 16 | i ← [0 .. 16 ∷ Int]]
