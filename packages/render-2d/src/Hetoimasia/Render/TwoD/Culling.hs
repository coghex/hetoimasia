-- | Whether a view skips a retained chunk (R2D-10, decision D-31): a chunk whose
-- bounds, mapped through the view's transform, lie wholly outside the part of
-- the target the view draws to.
--
-- 'chunkCulled' is /conservative/. It answers 'True' only when no pixel the
-- chunk can reach is inside the view, and it never discards visible content:
-- anything it cannot decide, it keeps.
--
-- * The bounds are mapped by the layer's transform, 'worldTransform' for a world
--   chunk and 'uiTransform' for a UI one, and the mapped rectangle's extent is
--   taken over all four corners, so a rotation, a shear and a non-uniform scale
--   (a UI scale and a content scale included) enlarge it exactly as they
--   enlarge the chunk.
-- * An instance's origin is rounded to a device pixel when the view snaps
--   ('mappingPixelSnap'), which moves its quad rigidly by at most half a pixel
--   per axis; the mapped rectangle is widened by that half pixel when the view
--   snaps. The world transform's own translation is snapped already.
-- * The rectangle is widened further by a sixteenth of a pixel, the width of the
--   band in which a pixel's coverage is not decided, and by a relative slack for
--   the 32-bit arithmetic the shader maps with, so a chunk whose edge touches
--   the view is kept.
-- * The part of the target the view draws to is its viewport, taken as a
--   rectangle of the continuous plane, within the target: a superset of the
--   pixels whose centres the scissor admits.
--
-- Arithmetic is in 'Double' from the transform's 32-bit coefficients and the
-- bounds' 32-bit corners; a mapped value that is not finite keeps the chunk.
--
-- __Dependencies.__ @base@, @hetoimasia-math@ and this package's chunk, mapping
-- and snapshot modules.
--
-- __State.__ The module owns none; the function is pure and total.
module Hetoimasia.Render.TwoD.Culling
  ( chunkCulled
  ) where

import Data.Word (Word32)
import Hetoimasia.Math.Affine2 (columns)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Chunk (Bounds (..), ChunkKind (..))
import Hetoimasia.Render.TwoD.Mapping (ViewMapping, mappingPixelSnap, uiTransform, worldTransform)
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))

-- | Whether the view whose mapping, viewport and target extent these are skips
-- a chunk of this kind with these bounds.
chunkCulled ∷ ViewMapping → (Word32, Word32) → Viewport → ChunkKind → Bounds → Double → Bool
chunkCulled mapping (targetWidth, targetHeight) (Viewport (V2 originX originY) (V2 width height)) kind (Bounds (V2 x0 y0) (V2 x1 y1)) placement
  | not (all finite [lowX, lowY, highX, highY, viewLeft, viewTop, viewRight, viewBottom, errorX, errorY]) = False
  | otherwise =
      highX + marginX < viewLeft
        || lowX - marginX > viewRight
        || highY + marginY < viewTop
        || lowY - marginY > viewBottom
  where
    transform = case kind of
      ChunkUi → uiTransform mapping
      _ → worldTransform mapping
    (V2 fa fb, V2 fc fd, V2 ftx fty) = columns transform
    (a, b, c, d, tx, ty) = (wide fa, wide fb, wide fc, wide fd, wide ftx, wide fty)
    (bx0, by0, bx1, by1) = (wide x0, wide y0, wide x1, wide y1)
    wide = realToFrac ∷ Float → Double
    -- The extent of the mapped corners: each target axis is a sum of one term
    -- in x and one in y, lowest and highest where each term is.
    lowX = tx + min (a * bx0) (a * bx1) + min (c * by0) (c * by1)
    highX = tx + max (a * bx0) (a * bx1) + max (c * by0) (c * by1)
    lowY = ty + min (b * bx0) (b * bx1) + min (d * by0) (d * by1)
    highY = ty + max (b * bx0) (b * bx1) + max (d * by0) (d * by1)
    -- The viewport within the target, as a rectangle of the continuous plane.
    left = wide originX
    top = wide originY
    viewLeft = max 0 left
    viewTop = max 0 top
    viewRight = min (fromIntegral targetWidth) (left + wide width)
    viewBottom = min (fromIntegral targetHeight) (top + wide height)
    margin = (if mappingPixelSnap mapping then 0.5 else 0) + 0.0625
    marginX = margin + errorX
    marginY = margin + errorY
    -- The rounding of 32-bit arithmetic, at the size of its terms.
    scale = maximum (map abs [viewLeft, viewTop, viewRight, viewBottom, fromIntegral targetWidth, fromIntegral targetHeight])
    reachX = abs a * max (abs bx0) (abs bx1) + abs c * max (abs by0) (abs by1) + abs tx
    reachY = abs b * max (abs bx0) (abs bx1) + abs d * max (abs by0) (abs by1) + abs ty
    errorX = 16 * 2 ** (-24) * (reachX + (abs a + abs c) * placement + scale)
    errorY = 16 * 2 ** (-24) * (reachY + (abs b + abs d) * placement + scale)
    finite value = not (isNaN value || isInfinite value)
