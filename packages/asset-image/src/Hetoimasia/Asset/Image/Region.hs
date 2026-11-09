-- | Checked rectangular regions of one decoded image and their shared coverage (TRA-17).
--
-- Every texture a consumer samples is an atlas: a single image is the same contract with one
-- region that covers the whole image. A 'RegionView' names a rectangle of one parent image's
-- 'CoveragePlane' and nothing else. It holds the parent's plane by reference, so a region, a
-- quad and a cell never copy a bit of it, and it is checked once, when it is made, so a lookup
-- afterwards cannot read outside the parent.
--
-- Nothing here knows terrain, a game, a graphics device, a Lua engine or an account.
--
-- = Checks
--
-- 'mkImageRegion' refuses a zero extent and any rectangle whose far edge is not representable.
-- 'mkRegionView' refuses a rectangle that is not inside the parent plane, so an overflowing,
-- negative-by-wraparound or out-of-bounds rectangle never yields a view. The parent's version
-- (the texture generation the plane was built for) and an opaque layout identity are carried
-- with the view; a consumer that holds a second parent's version compares them with
-- 'regionViewParentVersion' and 'regionViewLayout' before use, and
-- 'regionViewIdentity' folds the rectangle, both facts and the parent extent into one value a
-- cache or a snapshot compares in constant time, so a rectangle change on the same parent
-- invalidates a stale identity.
--
-- = Sampling
--
-- 'texelIndex' is THE texel-index rule of every terrain consumer, stated here once. For a
-- region of width @w@ and a normalized coordinate @u@,
--
-- > i = min (w - 1) (floor (clamp u 0 1 × w + texelBias))      texelBias = 1/128
--
-- and the same for the other axis. The bias is the owner's 2026-11-09 Q-13 decision: without
-- it float32 interpolation selects the lower texel at exact interior boundaries on the device (and
-- 1/10000 was measured too small at pixel-snapped zooms 9/8 and 5/4: the device read the lower texel
-- within 1.02e-4 texel of a boundary; amendment v2 of the same day chose 1/128).
-- The shader's colour and normal samples, CPU coverage and picking and the independent
-- expected model all use this one rule, evaluated here and in the expected model exactly, in
-- rational arithmetic. An interior texel boundary selects the higher index, the region's outer
-- edge selects its last texel, and a coordinate more than the bias below a boundary still
-- selects the lower texel. The index is applied /before/ the origin is added:
-- 'regionViewCoverageAt' reads parent texel @(originX + i, originY + j)@, so a coordinate
-- never reaches a neighbouring region. A coordinate outside a rasterized quad is not claimed
-- by this module. ('Hetoimasia.Asset.Image.DataMap.sampleIndex' is the asset-level rule without
-- the bias and is not what a terrain region samples with.)
--
-- State, ownership and lifetime: none. Immutable values; the plane's owner decides how long it
-- lives, and a view keeps it alive only while the view is.
module Hetoimasia.Asset.Image.Region
  ( -- * Rectangles
    ImageRegion
  , regionOriginX
  , regionOriginY
  , regionWidth
  , regionHeight
  , RegionRefusal (..)
  , regionRefusalText
  , mkImageRegion

    -- * Views over a parent's coverage
  , RegionView
  , mkRegionView
  , mkRegionViewWith
  , regionViewContent
  , fullImageViewWith
  , fullImageView
  , regionViewRegion
  , regionViewParent
  , regionViewParentVersion
  , regionViewLayout
  , regionViewParentExtent
  , RegionIdentity
  , regionViewIdentity

    -- * Sampling
  , texelBias
  , texelIndex
  , texelIndexExact
  , regionLocalIndex
  , regionViewCoverageAt
  , regionViewCoverageSample
  ) where

import Data.Bits (rotateL, xor)
import Data.Ratio ((%))
import Data.Word (Word32, Word64)
import Hetoimasia.Asset.Image.DataMap (CoveragePlane, coverageAt, coverageHeight, coverageWidth)

-- | A positive-extent rectangle of an image, in texels, top row first: its origin is its top-left
-- texel. Only 'mkImageRegion' makes one.
data ImageRegion = ImageRegion
  { regionOriginX ∷ !Word32
  , regionOriginY ∷ !Word32
  , regionWidth ∷ !Word32
  , regionHeight ∷ !Word32
  }
  deriving stock (Eq, Ord, Show)

-- | Why a rectangle or a view was refused.
data RegionRefusal
  = -- | A width or a height of zero.
    RegionEmpty !Word32 !Word32
  | -- | The origin plus the extent does not fit 32 bits on an axis, so the rectangle is not
    -- representable.
    RegionOverflow !Word32 !Word32 !Word32 !Word32
  | -- | The rectangle is not inside the parent extent: the region, then the parent's width and
    -- height.
    RegionOutOfBounds !ImageRegion !Word32 !Word32
  deriving stock (Eq, Show)

-- | The refusal as bounded text.
regionRefusalText ∷ RegionRefusal → String
regionRefusalText = \case
  RegionEmpty w h → "a region needs a positive extent, not " <> show w <> " x " <> show h
  RegionOverflow x y w h → "the region at (" <> show x <> ", " <> show y <> ") of " <> show w <> " x " <> show h <> " overflows 32 bits"
  RegionOutOfBounds region pw ph →
    "the region at ("
      <> show (regionOriginX region)
      <> ", "
      <> show (regionOriginY region)
      <> ") of "
      <> show (regionWidth region)
      <> " x "
      <> show (regionHeight region)
      <> " is not inside the parent image of "
      <> show pw
      <> " x "
      <> show ph

-- | A rectangle from its origin and extent. The extent must be positive and the far edge of each
-- axis must fit in 32 bits, which is checked on wide integers.
mkImageRegion ∷ Word32 → Word32 → Word32 → Word32 → Either RegionRefusal ImageRegion
mkImageRegion x y w h
  | w == 0 || h == 0 = Left (RegionEmpty w h)
  | toInteger x + toInteger w > limit || toInteger y + toInteger h > limit = Left (RegionOverflow x y w h)
  | otherwise = Right (ImageRegion x y w h)
  where
    limit = toInteger (maxBound ∷ Word32)

-- | A rectangle of one parent plane: the parent's coverage held by reference, the version of the
-- texture it was built for, an opaque layout identity and the checked rectangle. The constructor
-- is private.
data RegionView = RegionView
  { rvParent ∷ !CoveragePlane
  , rvVersion ∷ !Word64
  , rvLayout ∷ !Word64
  , rvContent ∷ !Word64
  -- ^ A digest of the parent image's decoded content, so two different images of one version and
  -- extent are distinct parents; zero where the caller supplies none.
  , rvRegion ∷ !ImageRegion
  }
  deriving stock (Eq, Show)

-- | A view of a rectangle of a parent plane. The rectangle must lie inside the plane. The
-- version is the parent texture's, the layout the opaque identity of the arrangement the
-- rectangle came from (a manifest's digest, for instance); neither is interpreted here.
mkRegionView ∷ Word64 → Word64 → CoveragePlane → ImageRegion → Either RegionRefusal RegionView
mkRegionView = mkRegionViewWith 0

-- | 'mkRegionView' for a parent whose decoded content has this digest.
mkRegionViewWith ∷ Word64 → Word64 → Word64 → CoveragePlane → ImageRegion → Either RegionRefusal RegionView
mkRegionViewWith content version layout plane region
  | far (regionOriginX region) (regionWidth region) > toInteger pw || far (regionOriginY region) (regionHeight region) > toInteger ph =
      Left (RegionOutOfBounds region pw ph)
  | otherwise = Right (RegionView plane version layout content region)
  where
    pw = coverageWidth plane
    ph = coverageHeight plane
    far origin extent = toInteger origin + toInteger extent

-- | The view of a whole image: its one region covers the parent from the origin. A single image
-- is a one-region atlas, with layout identity zero.
fullImageView ∷ Word64 → CoveragePlane → Either RegionRefusal RegionView
fullImageView = fullImageViewWith 0

-- | 'fullImageView' of an image whose decoded content has this digest.
fullImageViewWith ∷ Word64 → Word64 → CoveragePlane → Either RegionRefusal RegionView
fullImageViewWith content version plane = do
  region ← mkImageRegion 0 0 (coverageWidth plane) (coverageHeight plane)
  mkRegionViewWith content version 0 plane region

regionViewRegion ∷ RegionView → ImageRegion
regionViewRegion = rvRegion

-- | The parent's coverage plane, shared and never copied.
regionViewParent ∷ RegionView → CoveragePlane
regionViewParent = rvParent

regionViewParentVersion ∷ RegionView → Word64
regionViewParentVersion = rvVersion

regionViewLayout ∷ RegionView → Word64
regionViewLayout = rvLayout

-- | The parent's content digest (zero if none was supplied).
regionViewContent ∷ RegionView → Word64
regionViewContent = rvContent

-- | The parent image's width and height.
regionViewParentExtent ∷ RegionView → (Word32, Word32)
regionViewParentExtent view = (coverageWidth (rvParent view), coverageHeight (rvParent view))

-- | A digest of everything that decides what a view reads: the parent's version and extent, the
-- layout identity and the rectangle. Two views have equal identities exactly when they read the
-- same rectangle of the same parent version under the same layout, up to the collision of
-- independent 64-bit digests, which is not a security boundary: a stale identity is a wrong
-- answer, not an attack.
data RegionIdentity = RegionIdentity !Word64 !Word64
  deriving stock (Eq, Ord, Show)

regionViewIdentity ∷ RegionView → RegionIdentity
regionViewIdentity view = RegionIdentity (digest 14695981039346656037 fnv) (digest 7809847782465536322 mix)
  where
    (pw, ph) = regionViewParentExtent view
    region = rvRegion view
    inputs =
      [ rvVersion view
      , rvLayout view
      , rvContent view
      , fromIntegral pw
      , fromIntegral ph
      , fromIntegral (regionOriginX region)
      , fromIntegral (regionOriginY region)
      , fromIntegral (regionWidth region)
      , fromIntegral (regionHeight region)
      ]
    digest seed step = foldl' step seed inputs
    fnv h w = (h `xor` w) * 1099511628211
    mix h w = rotateL (h `xor` w) 23 * 0x9E3779B97F4A7C15 + w

-- | The texel bias of the sampling rule, in texels: @1/128@. Named here once; the shader's
-- literal is made from it and every other consumer applies 'texelIndex' or 'texelIndexExact'.
texelBias ∷ Rational
texelBias = 1 % 128

-- | The rule for an exact coordinate: @min (n - 1) (floor (clamp u 0 1 × n + texelBias))@, in an
-- extent of @n@ (at least 1) texels.
texelIndexExact ∷ Word32 → Rational → Word32
texelIndexExact n u = fromInteger (min (toInteger n - 1) (floor (clamped * toRational n + texelBias)))
  where
    clamped = min 1 (max 0 u)

-- | The rule for a 'Double' coordinate, evaluated exactly (the coordinate's own value, never a
-- rounded product): 'Nothing' for a coordinate that is not a number and for an extent of zero.
texelIndex ∷ Word32 → Double → Maybe Word32
texelIndex n u
  | n == 0 || isNaN u = Nothing
  | otherwise = Just (texelIndexExact n (toRational (min 1 (max 0 u))))

-- | The local texel indices a normalized coordinate pair selects in the region's own extent, or
-- 'Nothing' for a coordinate that is not a number. The origin is not added.
regionLocalIndex ∷ ImageRegion → Double → Double → Maybe (Word32, Word32)
regionLocalIndex region u v = (,) <$> texelIndex (regionWidth region) u <*> texelIndex (regionHeight region) v

-- | Whether the region's own texel @(i, j)@ is covered: the parent's texel at the origin plus
-- the local index. 'Nothing' outside the region, so a local index never reaches a neighbour.
regionViewCoverageAt ∷ RegionView → Word32 → Word32 → Maybe Bool
regionViewCoverageAt view i j
  | i >= regionWidth region || j >= regionHeight region = Nothing
  | otherwise = coverageAt (rvParent view) (regionOriginX region + i) (regionOriginY region + j)
  where
    region = rvRegion view

-- | Whether the texel a normalized coordinate pair selects in the region is covered.
regionViewCoverageSample ∷ RegionView → Double → Double → Maybe Bool
regionViewCoverageSample view u v = do
  (i, j) ← regionLocalIndex (rvRegion view) u v
  regionViewCoverageAt view i j
