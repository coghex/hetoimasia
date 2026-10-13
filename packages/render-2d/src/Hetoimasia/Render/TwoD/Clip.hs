-- | Clip tables: the rectangles an instance's clip index selects, and the pure
-- resolver that nests them (R2D-12).
--
-- A view carries an ordered table of 'ClipEntry' values. Entry @i@ is the one
-- an instance with clip index @i + 1@ selects (clip index 0 means none), and
-- names an optional parent: the zero-based index of an /earlier/ entry of the
-- same table, so a chain can only run toward lower indices and cycles cannot
-- occur. The entry's rectangle is axis-aligned in the space of the layer whose
-- instances reference it, in world units for a world layer and in UI logical
-- pixels for a UI layer, so it moves, turns and zooms with that layer's content
-- under the view's transform (see "Hetoimasia.Render.TwoD.Mapping"). A table's
-- entries are referenced from layers of one space only: validation refuses an
-- entry reached from both, through its own instances or through a descendant's.
--
-- __Rectangles.__ A 'ClipRect' is an origin and an extent in its layer's space.
-- Membership is half-open: a point is inside when @left ≤ x < right@ and
-- @top ≤ y < bottom@, where @right = left + width@ and @bottom = top + height@.
-- A rectangle with a zero width or height therefore holds no point, and clips
-- everything; a negative extent, or a coordinate that is not finite, is refused
-- by validation ('Hetoimasia.Render.TwoD.Validation.ClipRectInvalid').
--
-- __Resolving.__ 'resolveClips' intersects every entry with its whole parent
-- chain, in the entry's space, and answers one 'ResolvedClip' per entry, in
-- table order. The intersection is computed exactly, over 'Rational's, and
-- rounded once to 32-bit floats, so the result does not depend on the depth of
-- a chain. An empty intersection is kept as the empty rectangle
-- ('emptyClip'), which holds no point, and an entry whose ancestor is empty is
-- empty however its own rectangle lies. Finite coordinates whose sum overflows
-- a float are clamped to the largest finite float, so a resolved field is never
-- infinite or NaN because of finite endpoints. An endpoint is rounded to the
-- nearest float, so a region narrower than the spacing of floats at its
-- position resolves as empty.
--
-- __Totality.__ The resolver is total and deterministic over any list of
-- entries, valid or not: a parent that is not an earlier entry is ignored (the
-- entry resolves as if it had none), and a rectangle that is not finite or has a
-- negative extent resolves as empty. Validation refuses both before a snapshot
-- is drawn, so the rules matter only to a caller resolving a candidate.
--
-- __Dependencies.__ @base@, @array@, @hetoimasia-math@ for the vector, and this
-- package's finiteness test.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Clip
  ( -- * Entries
    ClipRect (..)
  , ClipEntry (..)

    -- * Clip indices
  , clipEntryOfIndex

    -- * Resolving
  , ResolvedClip (..)
  , emptyClip
  , clipIsEmpty
  , clipContains
  , resolveClips
  ) where

import Data.Array (Array, listArray, (!))
import Data.Word (Word16)
import Hetoimasia.Math.Vector (V2 (..))
import Hetoimasia.Render.TwoD.Internal.Check (allFinite)

-- | A rectangle in a layer's space: its upper-left corner and its extent. Both
-- must be finite and the extent not negative; a zero extent holds no point.
data ClipRect = ClipRect
  { clipOrigin ∷ !V2
  , clipExtent ∷ !V2
  }
  deriving stock (Eq, Show)

-- | One entry of a view's clip table: a rectangle and the optional parent whose
-- rectangle it is intersected with, which is the zero-based index of an
-- earlier entry of the same table. An entry @i@ may name only @p@ with
-- @0 ≤ p < i@.
data ClipEntry = ClipEntry
  { clipRect ∷ !ClipRect
  , clipParent ∷ !(Maybe Int)
  }
  deriving stock (Eq, Show)

-- | The table entry a clip index selects: 'Nothing' for index 0, which means no
-- clip, and entry @k − 1@ for a clip index @k@. The entry may lie beyond the
-- table, which validation refuses ('Hetoimasia.Render.TwoD.Validation.ClipIndexUnknown').
clipEntryOfIndex ∷ Word16 → Maybe Int
clipEntryOfIndex 0 = Nothing
clipEntryOfIndex index = Just (fromIntegral index - 1)

-- | An entry resolved against its parent chain: the four edges of the half-open
-- rectangle in the entry's layer space, as the table the recorder writes holds
-- them. A point is inside when @left ≤ x < right@ and @top ≤ y < bottom@. An
-- empty clip is always 'emptyClip', whatever made it empty.
data ResolvedClip = ResolvedClip
  { resolvedLeft ∷ !Float
  , resolvedTop ∷ !Float
  , resolvedRight ∷ !Float
  , resolvedBottom ∷ !Float
  }
  deriving stock (Eq, Show)

-- | The clip that holds no point: every edge zero.
emptyClip ∷ ResolvedClip
emptyClip = ResolvedClip 0 0 0 0

-- | Whether a resolved clip holds no point: a right edge not past the left or a
-- bottom edge not past the top.
clipIsEmpty ∷ ResolvedClip → Bool
clipIsEmpty (ResolvedClip left top right bottom) = not (left < right && top < bottom)

-- | Whether a point of the entry's space is inside the clip, with the half-open
-- rule: the left and top edges are inside and the right and bottom edges are
-- outside. Evaluated on the resolved floats, exactly.
clipContains ∷ ResolvedClip → V2 → Bool
clipContains (ResolvedClip left top right bottom) (V2 x y) =
  left <= x && x < right && top <= y && y < bottom

-- | Resolve a table: every entry intersected with its parent chain, in table
-- order. See the module header for the rules, the empty case and totality.
resolveClips ∷ [ClipEntry] → [ResolvedClip]
resolveClips entries = [maybe emptyClip rounded (exact ! index) | index ← [0 .. count - 1]]
  where
    count = length entries
    -- The exact intersection of every entry with its chain, lazily: an entry
    -- reads only earlier ones. 'Nothing' is the empty set.
    exact ∷ Array Int (Maybe Box)
    exact = listArray (0, count - 1) [boxOf index entry | (index, entry) ← zip [0 ..] entries]
    boxOf index entry =
      case ownBox (clipRect entry) of
        Nothing → Nothing
        Just own → case clipParent entry of
          Just parent | parent >= 0 && parent < index → exact ! parent >>= intersect own
          _ → Just own

-- | A non-empty half-open rectangle, exactly: left, top, right, bottom, with
-- the left edge before the right and the top before the bottom.
data Box = Box !Rational !Rational !Rational !Rational

-- | The rectangle a 'ClipRect' holds, or 'Nothing' when it holds no point: a
-- zero or negative extent, or a coordinate that is not finite.
ownBox ∷ ClipRect → Maybe Box
ownBox (ClipRect (V2 x y) (V2 width height))
  | not (allFinite [x, y, width, height]) = Nothing
  | width <= 0 || height <= 0 = Nothing
  | otherwise = Just (Box left top (left + toRational width) (top + toRational height))
  where
    left = toRational x
    top = toRational y

-- | The intersection of two boxes, 'Nothing' when it holds no point.
intersect ∷ Box → Box → Maybe Box
intersect (Box l0 t0 r0 b0) (Box l1 t1 r1 b1)
  | left < right && top < bottom = Just (Box left top right bottom)
  | otherwise = Nothing
  where
    left = max l0 l1
    top = max t0 t1
    right = min r0 r1
    bottom = min b0 b1

-- | A box as the floats the table holds: each edge rounded to the nearest
-- float, clamped to the finite range, and the empty clip when the rounding
-- leaves no area.
rounded ∷ Box → ResolvedClip
rounded (Box left top right bottom)
  | clipIsEmpty clip = emptyClip
  | otherwise = clip
  where
    clip = ResolvedClip (toFloat left) (toFloat top) (toFloat right) (toFloat bottom)

-- | A rational as the nearest finite float: a magnitude past the largest float
-- is that float.
toFloat ∷ Rational → Float
toFloat value
  | value >= limit = maxFloat
  | value <= negate limit = negate maxFloat
  | otherwise = fromRational value
  where
    limit = toRational maxFloat

maxFloat ∷ Float
maxFloat = encodeFloat 16777215 104
