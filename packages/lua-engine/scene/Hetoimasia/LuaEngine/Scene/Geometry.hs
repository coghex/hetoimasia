-- | A sprite's rectangle: validated as Lua numbers, converted to the renderer's 32-bit floats, and
-- checked as 32-bit quad corners.
--
-- A coordinate is a finite Lua integer or float in the closed range of minus to plus the profile's
-- magnitude; an extent is finite, greater than zero and at most the profile's maximum. Fractions and
-- negative or offscreen positions are kept as they are: nothing is snapped, recentred, clamped or
-- resized, and a rectangle outside the view is the view's to clip, not an error.
--
-- Conversion to 32-bit floats is where a valid source value can still be unusable, so the quad is
-- checked as the renderer places it (the unit square through the sprite's transform, in the UI's
-- logical space): the origin, the origin plus the width, plus the height, and plus both. A positive
-- extent that is zero as a 32-bit float, a corner that is not finite, and a far edge that rounds back
-- onto the origin on either axis are refused, never made to disappear. The check is independent of any
-- window: how the renderer later maps the logical space to a target is its own contract and never
-- makes a prepared scene invalid.
module Hetoimasia.LuaEngine.Scene.Geometry
  ( coordinate
  , extent
  , rectangle
  , placement
  ) where

import GHC.Float (double2Float)
import Hetoimasia.LuaEngine.Scene.Limits (SceneLimits, sceneCoordinateLimit, sceneExtentLimit)
import Hetoimasia.LuaEngine.Scene.Types (SceneAxis (..), SceneReason (..), SceneRect (..))
import Hetoimasia.Math.Affine2 (Affine2, applyPoint, fromColumns)
import Hetoimasia.Math.Vector (V2 (V2))
import Hetoimasia.Scripting.Lua.Value (Value (VFloat, VInteger))

-- | A coordinate as a 32-bit float.
coordinate ∷ SceneLimits → Value → Either SceneReason Float
coordinate limits value = do
  let bound = sceneCoordinateLimit limits
  found ← number value
  if found < negate (fromIntegral bound) || found > fromIntegral bound
    then Left (CoordinateOutOfRange bound)
    else Right (double2Float found)

-- | A width or height as a 32-bit float: positive, within the maximum, and not zero once converted.
extent ∷ SceneLimits → Value → Either SceneReason Float
extent limits value = do
  let bound = sceneExtentLimit limits
  found ← number value
  if found <= 0
    then Left ExtentNotPositive
    else
      if found > fromIntegral bound
        then Left (ExtentOutOfRange bound)
        else
          let narrowed = double2Float found
           in if narrowed > 0 then Right narrowed else Left ExtentUnderflows

-- | The rectangle of four checked floats: its quad corners must be finite and each far edge must
-- differ from the origin.
rectangle ∷ Float → Float → Float → Float → Either SceneReason SceneRect
rectangle x y width height
  | not (all finiteCorner [farBoth, farX, farY]) = Left NotFinite
  | fst' farX == x = Left (FarEdgeCollapses AxisX)
  | snd' farY == y = Left (FarEdgeCollapses AxisY)
  | otherwise = Right (SceneRect x y width height)
  where
    transform = placement (SceneRect x y width height)
    farX = applyPoint transform (V2 1 0)
    farY = applyPoint transform (V2 0 1)
    farBoth = applyPoint transform (V2 1 1)
    fst' (V2 a _) = a
    snd' (V2 _ b) = b
    finiteCorner (V2 a b) = not (isNaN a || isInfinite a || isNaN b || isInfinite b)

-- | The transform that places the unit square at a rectangle: the columns are the width along x and
-- the height along y, and the translation is the origin.
placement ∷ SceneRect → Affine2
placement (SceneRect x y width height) = fromColumns (V2 width 0) (V2 0 height) (V2 x y)

-- A Lua number as a double: an integer is exact (every one in range is a 32-bit float's neighbour
-- anyway), a float must be finite. Nothing else is a number.
number ∷ Value → Either SceneReason Double
number = \case
  VInteger whole → Right (fromIntegral whole)
  VFloat found
    | isNaN found || isInfinite found → Left NotFinite
    | otherwise → Right found
  _ → Left NumberRequired
