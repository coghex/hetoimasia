-- | Generating a mip chain's levels from level 0.
--
-- __The filter.__ Along an axis whose level 0 extent is @S@ and whose output
-- extent is @s@, output index @i@ covers [i·S, (i+1)·S) in units where each
-- level 0 texel is @s@ wide; level 0 texel @j@ covers [j·s, (j+1)·s), and its
-- weight is the overlap. A footprint's weights are integers summing to @S@,
-- so an output texel's weights, the products of its two axes' weights, sum
-- to W·H. That makes every alpha sum, and every channel sum of a linear
-- level, an exact integer.
--
-- __Coverage.__ A level's alpha sums are scaled together so that its
-- covered count — texels whose alpha byte is at least 128 — is as close as
-- any scale allows to its share of level 0's covered count, @t =
-- covered₀ × n ÷ (W·H)@ for a level of @n@ texels. A texel whose alpha sum
-- is zero is never covered, and texels with equal sums are covered
-- together, so the achievable counts are 0 and, for each distinct positive
-- sum @v@, the number of sums at least @v@. The scale is chosen thus:
--
-- * When the unscaled level already has a closest count, it is not scaled.
-- * Otherwise, of the closest counts (there are at most two) the one nearer
--   the unscaled count is chosen. For a count @k ≥ 1@, the scale puts the
--   least opaque covered texel exactly on the threshold, at 127.5 before
--   rounding, so it rounds to 128; for @k = 0@, it puts the most opaque
--   texel at exactly 127.
--
-- Scaled alpha is clamped to 255. In a premultiplied level each colour
-- channel is multiplied by the same factor alpha was, after the clamp
-- (scaled alpha ÷ averaged alpha, both before rounding), so the
-- un-premultiplied colour is unchanged; a straight level's colour is not
-- scaled. Alpha's arithmetic, scaling and rounding included, is exact
-- integer arithmetic.
module Hetoimasia.Asset.Image.Internal.MipChain
  ( Channels (..)
  , generatedLevels
  )
where

import Data.Bits (countLeadingZeros, finiteBitSize, shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Internal as ByteString (unsafeCreate)
import qualified Data.ByteString.Unsafe as ByteString
import qualified Data.Vector as Boxed
import qualified Data.Vector.Unboxed as Vector
import Data.Word (Word8)
import Foreign.Storable (pokeByteOff)

-- | How a level's colour channels are stored.
data Channels
  = -- | sRGB-encoded, premultiplied in linear light.
    SrgbPremultiplied
  | -- | Linear and straight.
    LinearStraight

-- | Levels 1 to the 1 × 1 level of a chain whose level 0 is @width@ ×
-- @height@ four-byte texels, held in @base@, whose length the caller has
-- checked. The flag says whether coverage is preserved.
generatedLevels ∷ Channels → Bool → Int → Int → ByteString → [ByteString]
generatedLevels channels preserve width height base =
  [generated (extent width l) (extent height l) | l ← [1 .. deepest]]
  where
    deepest = finiteBitSize width - countLeadingZeros (max width height) - 1
    extent e l = max 1 (e `shiftR` l)
    total = width * height
    covered0 = length (filter (>= 128) [ByteString.unsafeIndex base i | i ← [3, 7 .. 4 * total - 1]])
    generated w h = case channels of
      SrgbPremultiplied → premultipliedLevel preserve total covered0 (averaged linearised base width height w h)
      LinearStraight → straightLevel preserve total covered0 (averaged fromIntegral base width height w h)

-- | Level 0's texels along one axis that output index @i@ of an @out@-texel
-- axis covers, with their weights.
footprint ∷ Int → Int → Int → [(Int, Int)]
footprint source out i =
  [(j, min ((j + 1) * out) hi - max (j * out) lo) | j ← [lo `div` out .. (hi - 1) `div` out]]
  where
    lo = i * source
    hi = (i + 1) * source

data Sums a = Sums !a !a !a !Int

-- | Every output texel's weighted sums of its colour channels, each taken
-- through @channel@, and of its alpha, row by row.
averaged
  ∷ (Num a, Vector.Unbox a)
  ⇒ (Word8 → a) → ByteString → Int → Int → Int → Int → Vector.Vector (a, a, a, Int)
averaged channel base width height w h =
  Vector.generate (w * h) $ \k →
    let (y, x) = k `divMod` w
        Sums r g b a = foldl' (row (columns Boxed.! x)) (Sums 0 0 0 0) (rows Boxed.! y)
     in (r, g, b, a)
  where
    columns = Boxed.generate w (footprint width w)
    rows = Boxed.generate h (footprint height h)
    row xs acc (sy, wy) = foldl' (texel wy (sy * width)) acc xs
    texel wy start (Sums r g b a) (sx, wx) =
      let weight = wy * wx
          i = 4 * (start + sx)
          at n = ByteString.unsafeIndex base (i + n)
          scaled n = fromIntegral weight * channel (at n)
       in Sums (r + scaled 0) (g + scaled 1) (b + scaled 2) (a + weight * fromIntegral (at 3))
{-# INLINE averaged #-}

-- | A scale @p ÷ q@ applied to an alpha sum @S@ of a level 0 of @N@ texels,
-- written so that the scaled alpha in code values is @p·S ÷ q@: the unscaled
-- alpha is @Scale 1 N@.
data Scale = Scale !Int !Int

-- | The alpha byte of an alpha sum under a scale: rounded to nearest, halves
-- up, and clamped to 255.
alphaByte ∷ Scale → Int → Int
alphaByte (Scale p q) s = min 255 ((2 * p * s + q) `div` (2 * q))

-- | The scale for a level's alpha sums, as the module header describes.
chooseScale ∷ Bool → Int → Int → Vector.Vector Int → Scale
chooseScale preserve total covered0 alphas
  | not preserve || highest == 0 || distance unscaledCount == closest = unscaled
  | chosen == 0 = Scale 127 highest
  | otherwise = Scale 255 (2 * Vector.minimum (Vector.filter (>= threshold) alphas))
  where
    unscaled = Scale 1 total
    unscaledCount = coveredUnder unscaled
    n = Vector.length alphas
    highest = Vector.maximum alphas
    countWhere ∷ (Int → Bool) → Int
    countWhere f = Vector.foldl' (\c s → if f s then c + 1 else c) 0 alphas
    countFrom v = countWhere (>= v)
    coveredUnder scale = countWhere (\s → alphaByte scale s >= 128)
    -- |k − t|, scaled by W·H to stay an integer.
    distance k = abs (toInteger k * toInteger total - toInteger covered0 * toInteger n)
    atMostTarget v = toInteger (countFrom v) * toInteger total <= toInteger covered0 * toInteger n
    atLeastTarget v = toInteger (countFrom v) * toInteger total >= toInteger covered0 * toInteger n
    -- The smallest threshold whose count is at most t, and the largest whose
    -- count is at least t, if any.
    below = search atMostTarget 1 (highest + 1)
    above = if atLeastTarget 1 then Just (searchLast atLeastTarget 1 highest) else Nothing
    candidates = (below, countFrom below) : maybe [] (\v → [(v, countFrom v)]) above
    closest = minimum (map (distance . snd) candidates)
    (threshold, chosen) =
      snd (minimum [(abs (k - unscaledCount), (v, k)) | (v, k) ← candidates, distance k == closest])

-- | The least @v@ in [lo, hi] satisfying a monotone predicate, which @hi@
-- satisfies.
search ∷ (Int → Bool) → Int → Int → Int
search p lo hi
  | lo >= hi = hi
  | p mid = search p lo mid
  | otherwise = search p (mid + 1) hi
  where
    mid = lo + (hi - lo) `div` 2

-- | The greatest @v@ in [lo, hi] satisfying a predicate that holds up to
-- some point and not after it, which @lo@ satisfies.
searchLast ∷ (Int → Bool) → Int → Int → Int
searchLast p lo hi
  | lo >= hi = lo
  | p mid = searchLast p mid hi
  | otherwise = searchLast p lo (mid - 1)
  where
    mid = lo + (hi - lo + 1) `div` 2

premultipliedLevel ∷ Bool → Int → Int → Vector.Vector (Double, Double, Double, Int) → ByteString
premultipliedLevel preserve total covered0 sums = packed (Vector.length sums) texel
  where
    (rs, gs, bs, alphas) = Vector.unzip4 sums
    scale@(Scale p q) = chooseScale preserve total covered0 alphas
    texel k =
      let s = alphas Vector.! k
          -- Scaled alpha ÷ averaged alpha, before rounding, after the clamp,
          -- with the division by W·H that turns sums into averages.
          factor
            | s == 0 || p * s <= 255 * q = fromIntegral p / fromIntegral q
            | otherwise = 255 / fromIntegral s
          colour c = encoded (c * factor)
       in (colour (rs Vector.! k), colour (gs Vector.! k), colour (bs Vector.! k), alphaByte scale s)

straightLevel ∷ Bool → Int → Int → Vector.Vector (Int, Int, Int, Int) → ByteString
straightLevel preserve total covered0 sums = packed (Vector.length sums) texel
  where
    (rs, gs, bs, alphas) = Vector.unzip4 sums
    scale = chooseScale preserve total covered0 alphas
    plain = alphaByte (Scale 1 total)
    texel k = (plain (rs Vector.! k), plain (gs Vector.! k), plain (bs Vector.! k), alphaByte scale (alphas Vector.! k))

-- | A level of @count@ texels, each given as its four bytes.
packed ∷ Int → (Int → (Int, Int, Int, Int)) → ByteString
packed count texel = ByteString.unsafeCreate (count * 4) $ \pointer →
  let go k
        | k >= count = pure ()
        | otherwise = do
            let (r, g, b, a) = texel k
            pokeByteOff pointer (4 * k) (fromIntegral r ∷ Word8)
            pokeByteOff pointer (4 * k + 1) (fromIntegral g ∷ Word8)
            pokeByteOff pointer (4 * k + 2) (fromIntegral b ∷ Word8)
            pokeByteOff pointer (4 * k + 3) (fromIntegral a ∷ Word8)
            go (k + 1)
   in go 0

-- | A stored sRGB byte decoded to linear light.
linearised ∷ Word8 → Double
linearised byte = linearTable Vector.! fromIntegral byte

linearTable ∷ Vector.Vector Double
linearTable = Vector.generate 256 (\i → toLinear (fromIntegral i / 255))
{-# NOINLINE linearTable #-}

-- | A linear value encoded with the sRGB transfer function, clamped to
-- [0, 1], and rounded to nearest, halves up.
encoded ∷ Double → Int
encoded linear = min 255 (floor (255 * fromLinear (max 0 (min 1 linear)) + 0.5))

-- | The sRGB transfer function's decoding direction (IEC 61966-2-1).
toLinear ∷ Double → Double
toLinear v
  | v <= 0.04045 = v / 12.92
  | otherwise = ((v + 0.055) / 1.055) ** 2.4

-- | The sRGB transfer function's encoding direction.
fromLinear ∷ Double → Double
fromLinear l
  | l <= 0.0031308 = l * 12.92
  | otherwise = 1.055 * l ** (1 / 2.4) - 0.055
