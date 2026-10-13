-- | The recorder's pure layout decisions (R2D-7): what the shaders read and
-- how the host feeds them, written once so the shader interfaces, the
-- recorder and the device-free tests all name the same numbers.
--
-- * The instance, as the vertex stage reads it: one binding advancing per
--   instance at render-2d's 64-byte stride, each attribute at its offset in
--   #414's layout ('instanceVertexInput').
-- * The push block both stages declare: the view's transform, the attachment's
--   extent, the view's brightness, its default filter and whether it snaps,
--   where the view's clip table starts, the inverse of the transform's linear
--   part and the point the clip comparison is made around
--   ('packViewPush', 'pushMembers').
-- * The clip table a batch binds as set 2: one 16-byte entry per clip, in the
--   resolved rectangle's four edges taken about a reference point, std430
--   ('packClipTable', 'clipEntryBytes', 'clipReference', 'rebaseClip').
-- * The depth an instance's key gives ('depthFromKey'), which is what the vertex
--   stage writes (R2D-9).
-- * The sampler an instance resolves to ('shaderSamplerIndex'), which is what
--   the fragment stage computes.
-- * The scissor of a view, exactly the pixels whose centres its viewport
--   contains ('viewScissor').
--
-- Everything here is pure and total.
--
-- = The push block
--
-- Both stages declare one block, in std430 order, 72 bytes:
--
-- > offset  size  member
-- >      0    16  vec4 viewLinear          a, b, c, d of the layer's transform
-- >     16     8  vec2 viewTranslation     tx, ty
-- >     24     8  vec2 extent              the attachment's width and height, in pixels
-- >     32     4  float brightness
-- >     36     4  uint filtering           the view's default filter: 1 nearest, 2 linear
-- >     40     4  uint snap                1 when the view snaps instance origins
-- >     44     4  uint clipBase            the layer's clip table's first entry, in entries
-- >     48    16  vec4 inverseLinear       a, b, c, d of the transform's inverse
-- >     64     8  vec2 clipCentre          the target-pixel point the clip test is taken about
--
-- The transform maps @(x, y)@ to @(a·x + c·y + tx, b·x + d·y + ty)@, the
-- coefficients of "Hetoimasia.Math.Affine2" in column-major order. The block is
-- pushed per layer, so the transform and its inverse are those of the layer's
-- space, the world's or the UI's, exactly as 'Hetoimasia.Render.TwoD.Mapping'
-- gives them, with the world's translation snapped when the view snaps. Only
-- the inverse's linear part is pushed: the clip test is made about
-- @clipCentre@, not about the origin, so that it never forms an absolute
-- coordinate in the layer's space (see below).
--
-- = The clip table (R2D-12)
--
-- A batch writes the clip tables of every view that draws into one ring region
-- (claimed with the backend's table alignment) and binds it as set 2, binding 0,
-- a read-only std430 buffer of @vec4@s. A view's table is its resolved entries
-- ('Hetoimasia.Render.TwoD.Clip.resolveClips') in table order, each as one
-- @vec4@ of 16 bytes, little-endian:
--
-- > offset  size  field
-- >      0     4  float left    the half-open rectangle about the reference point,
-- >      4     4  float top     a point inside when left ≤ x < right and
-- >      8     4  float right   top ≤ y < bottom; an empty clip is all zeros
-- >     12     4  float bottom
--
-- __The reference point.__ An edge is written as its distance, in the layer's
-- space, from the layer-space point under the centre of the view's scissor
-- ('clipReference'), and the fragment stage tests the fragment's offset from
-- that centre, carried to the layer's space by the inverse's linear part, so
-- no coordinate it compares is an absolute position in the layer's space.
-- That is what keeps the test exact where a view looks at a distant place: a
-- single-precision absolute coordinate near 65536 is spaced 1/128 apart, which
-- at a zoom of 100 is most of a pixel, whereas an edge near the viewport is
-- a small number about the reference whatever the camera's position. The
-- difference is taken in double precision, from the resolved floats and the
-- transform's own coefficients, and rounded once. A table is written once for
-- each space, world or UI, a view's layers select clips from: the reference
-- depends on the layer's transform, so one table cannot serve both, and a
-- space no layer selects a clip from gets none.
--
-- The tables follow one another with no padding, in pass and view order (a
-- view's world table before its UI table when both exist): a 16-byte entry
-- needs none, and the region's own start is aligned by the claim. The
-- @clipBase@ member of the push block is the index of a layer's table's first
-- entry within the region, in entries (units of 16 bytes), so an instance
-- whose flags word holds clip index @k > 0@ reads entry @clipBase + k − 1@,
-- and a view's index @k@ always means that view's own entry @k − 1@. Clip
-- index 0 reads nothing, so a layer none of whose instances selects a clip
-- pushes a base of 0 and never looks. A batch that draws but writes no clip
-- entry at all still binds a region of one zero entry, because a layout
-- holding set 2 refuses a draw until set 2 is bound; the region's size, and
-- the window it must fit, are in 'clipEntryBytes' times the entries.
module Hetoimasia.Render.TwoD.Vulkan.Layout
  ( -- * The instance as vertex input
    instanceStride
  , instanceVertexInput
  , depthFromKey
    -- * The push block
  , ViewPush (..)
  , pushMembers
  , pushBytes
  , packViewPush
  , filterCode
    -- * The clip table
  , clipEntryBytes
  , packClipTable
  , clipReference
  , rebaseClip
  , clipRepresentable
    -- * Sampler choice
  , shaderSamplerIndex
  , instanceSamplerBits
    -- * Views
  , viewScissor
  ) where

import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as Lazy
import Data.ByteString.Builder (floatLE, toLazyByteString, word32LE)
import Data.Word (Word32)
import Hetoimasia.GPU.Vulkan.Native.Recording
  ( InputRate (..)
  , Rect (..)
  , TableSampler (..)
  , VertexAttribute (..)
  , VertexBinding (..)
  , VertexFormat (..)
  , VertexInput (..)
  , tableSamplerIndex
  )
import Hetoimasia.GPU.Vulkan.Native.Shader.Interface (PushMember (..))
import Hetoimasia.Math.Affine2 (Affine2, toColumnMajor)
import Hetoimasia.Math.Vector (V2 (..))
import GHC.Float (double2Float, float2Double)
import Hetoimasia.Render.TwoD.Clip (ResolvedClip (..), clipIsEmpty, emptyClip)
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..))
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..), depthKeyLimit)

-- | The bytes of one instance: render-2d's 'Hetoimasia.Render.TwoD.Encoding.instanceStride'.
instanceStride ∷ Word32
instanceStride = 64

-- | Binding 0, per instance, 'instanceStride' bytes a step, and the attributes
-- the vertex stage reads from it, at the offsets of render-2d's instance
-- encoding:
--
-- > location  offset  format          field
-- >        0       0  four floats     the transform's a, b, c, d
-- >        1      16  two floats      the transform's tx, ty
-- >        2      24  four floats     the UV rectangle (u0, v0, u1, v1)
-- >        3      40  uint            the handle's lookup index
-- >        4      44  uint            the handle's generation
-- >        5      52  four unorm bytes  the tint, red first
-- >        6      56  uint            the flags word
-- >        7      60  uint            the material parameter word
-- >        8      48  uint            the depth key
--
-- The depth key at offset 48 is read as 'depthFromKey' reads it: the vertex
-- stage writes it as the depth of every corner of the instance's quad (R2D-9),
-- and a pass with no depth attachment ignores it. The unit square's corners are
-- the shader's own.
instanceVertexInput ∷ VertexInput
instanceVertexInput =
  VertexInput
    [VertexBinding 0 instanceStride PerInstance]
    [ VertexAttribute 0 0 VertexFloat4 0
    , VertexAttribute 1 0 VertexFloat2 16
    , VertexAttribute 2 0 VertexFloat4 24
    , VertexAttribute 3 0 VertexUint 40
    , VertexAttribute 4 0 VertexUint 44
    , VertexAttribute 5 0 VertexRgba8Unorm 52
    , VertexAttribute 6 0 VertexUint 56
    , VertexAttribute 7 0 VertexUint 60
    , VertexAttribute 8 0 VertexUint 48
    ]

-- | The depth a key gives, @(2²⁴ − 1 − k) / 2²⁴@ (design D-23): in [0, 1), a
-- larger key nearer, and exact in a 32-bit float because the numerator has 24
-- bits at most and the denominator is a power of two. It is what the vertex
-- stage computes as @float(0xFFFFFF − k) / 16777216.0@. A key at or past
-- 'depthKeyLimit', which a validated snapshot never holds, has none.
depthFromKey ∷ Word32 → Maybe Float
depthFromKey key
  | key >= depthKeyLimit = Nothing
  | otherwise = Just (fromIntegral (depthKeyLimit - 1 - key) / fromIntegral depthKeyLimit)

-- | What a view's draws need beyond the instance: the transform of the layer's
-- space and its inverse, the attachment's extent, the view's settings and where
-- its clip table starts.
data ViewPush = ViewPush
  { pushTransform ∷ !Affine2
    -- ^ The world or UI transform, to target pixels.
  , pushInverse ∷ !Affine2
    -- ^ Its inverse, from target pixels back to the layer's space, which the
    -- fragment stage clips in.
  , pushClipBase ∷ !Word32
    -- ^ The index, in entries, of the layer's clip table's first entry in the
    -- batch's clip region.
  , pushClipCentre ∷ !(Float, Float)
    -- ^ The target-pixel point the fragment stage's clip test is taken about:
    -- the centre of the view's scissor, where the table's edges are measured
    -- from the layer-space point under it.
  , pushExtent ∷ !(Word32, Word32)
    -- ^ The attachment's width and height.
  , pushBrightness ∷ !Float
  , pushFilter ∷ !TextureFilter
    -- ^ The view's default filter, which an instance with sampler choice 0 takes.
  , pushSnap ∷ !Bool
  }
  deriving (Eq, Show)

-- | The block's members, in declaration order: the description both stages'
-- checked interfaces declare.
pushMembers ∷ [PushMember]
pushMembers =
  [ PushMember 0 16
  , PushMember 16 8
  , PushMember 24 8
  , PushMember 32 4
  , PushMember 36 4
  , PushMember 40 4
  , PushMember 44 4
  , PushMember 48 16
  , PushMember 64 8
  ]

-- | The block's size in bytes.
pushBytes ∷ Int
pushBytes = 72

-- | The block, little-endian, 'pushBytes' bytes.
packViewPush ∷ ViewPush → ByteString
packViewPush view =
  Lazy.toStrict . toLazyByteString $
    foldMap floatLE (toColumnMajor (pushTransform view))
      <> floatLE (fromIntegral width)
      <> floatLE (fromIntegral height)
      <> floatLE (pushBrightness view)
      <> word32LE (filterCode (pushFilter view))
      <> word32LE (if pushSnap view then 1 else 0)
      <> word32LE (pushClipBase view)
      <> foldMap floatLE (take 4 (toColumnMajor (pushInverse view)))
      <> floatLE centreX
      <> floatLE centreY
  where
    (width, height) = pushExtent view
    (centreX, centreY) = pushClipCentre view

-- | The size of one clip table entry in bytes: 16, a @vec4@.
clipEntryBytes ∷ Int
clipEntryBytes = 16

-- | A view's resolved clip table as the batch's region holds it:
-- 'clipEntryBytes' per entry, in table order, each the edges left, top, right
-- and bottom as little-endian floats.
packClipTable ∷ [ResolvedClip] → ByteString
packClipTable =
  Lazy.toStrict . toLazyByteString . foldMap (\(ResolvedClip left top right bottom) → foldMap floatLE [left, top, right, bottom])

-- | The layer-space point under a target-pixel point, for the transform that
-- takes the layer's space to target pixels: the exact inverse of the transform,
-- applied to the point, computed over 'Rational's from the transform's float
-- coefficients and rounded once to double precision. A transform that has no
-- inverse gives the origin: its view draws nothing, since a mapping that exists
-- for a non-empty viewport is invertible.
clipReference ∷ Affine2 → (Float, Float) → (Double, Double)
clipReference transform (centreX, centreY) = case map toRational (toColumnMajor transform) of
  [a, b, c, d, tx, ty]
    | a * d - b * c /= 0 →
        let determinant = a * d - b * c
            ia = d / determinant
            ib = negate b / determinant
            ic = negate c / determinant
            id' = a / determinant
            itx = negate (ia * tx + ic * ty)
            ity = negate (ib * tx + id' * ty)
         in (fromRational (ia * cx + ic * cy + itx), fromRational (ib * cx + id' * cy + ity))
  _ → (0, 0)
  where
    cx = toRational centreX
    cy = toRational centreY

-- | A resolved clip with its edges taken about a layer-space reference point
-- ('clipReference'): each edge minus the reference, in double precision and
-- rounded once to a float, and clamped to the finite range, so that no edge is
-- infinite however far from the reference it lies (an edge past the largest
-- float is beyond anything the fragment stage's offsets reach: see
-- 'clipRepresentable'). The empty clip stays empty, and so does a clip the
-- rounding leaves no area (a region narrower than the spacing of floats about
-- the reference, or one wholly beyond the finite range on one side).
rebaseClip ∷ (Double, Double) → ResolvedClip → ResolvedClip
rebaseClip (rx, ry) clip@(ResolvedClip left top right bottom)
  | clipIsEmpty clip = emptyClip
  | clipIsEmpty rebased = emptyClip
  | otherwise = rebased
  where
    rebased = ResolvedClip (shifted left rx) (shifted top ry) (shifted right rx) (shifted bottom ry)
    shifted edge origin = double2Float (max (negate largest) (min largest (float2Double edge - origin)))
    largest = float2Double (encodeFloat 16777215 104)

-- | Whether the fragment stage's clip arithmetic stays within the finite
-- floats for a layer whose transform has this inverse, over a scissor of this
-- size: the layer-space offset of a fragment's centre from the scissor's centre
-- is at most the inverse's linear part applied to half the scissor's size, per
-- axis, and that bound must not exceed half the largest finite float, so that
-- neither the offset nor the sum of its two products can overflow (an overflow
-- would admit a fragment whose edge test then compares infinities). It holds
-- whenever the scene is within the floats' own range: a view whose zoom is so
-- small that its scissor spans more than about 10³⁸ units of the layer is the
-- case it refuses.
clipRepresentable ∷ Affine2 → (Word32, Word32) → Bool
clipRepresentable inverse (width, height) = case map float2Double (toColumnMajor inverse) of
  [a, b, c, d, _, _] →
    let halfWidth = fromIntegral width / 2
        halfHeight = fromIntegral height / 2
        reachX = abs a * halfWidth + abs c * halfHeight
        reachY = abs b * halfWidth + abs d * halfHeight
     in max reachX reachY <= float2Double (encodeFloat 16777215 104) / 2
  _ → False

-- | A filter's code in the block, which is also the sampler choice code of an
-- instance that names it: 1 nearest, 2 linear.
filterCode ∷ TextureFilter → Word32
filterCode = \case
  FilterNearest → 1
  FilterLinear → 2

-- | The sampler-choice bits of a flags word: its low two bits, 0 for the
-- view's default, 1 nearest, 2 linear.
instanceSamplerBits ∷ Word32 → Word32
instanceSamplerBits flags = flags .&. 3

-- | The table sampler an instance samples with, from its flags word and the
-- view's pushed filter code: what the fragment stage computes. A choice of 1
-- takes nearest and 2 linear whatever the view's default is; 0 takes the
-- view's default; 3, which render-2d never produces, takes it too. Nearest is
-- the table's sampler 0 (nearest, clamp to edge) and linear its sampler 2
-- (linear, clamp to edge), so no choice reaches a repeating sampler.
shaderSamplerIndex ∷ Word32 → Word32 → Word32
shaderSamplerIndex flags pushedFilter = case effective of
  2 → tableSamplerIndex LinearClamp
  _ → tableSamplerIndex NearestClamp
  where
    choice = instanceSamplerBits flags
    effective
      | choice == 1 || choice == 2 = choice
      | otherwise = pushedFilter

-- | The scissor of a view in an attachment of this width and height: exactly
-- the pixels whose centres the view's viewport contains, which is
-- 'Hetoimasia.Render.TwoD.Mapping.viewportContains' pixel by pixel. Per axis
-- the pixels @i@ with @x ≤ i + ½ < x + w@, that is @[ceil(x − ½), ceil(x + w −
-- ½))@, clamped to the attachment, computed exactly. 'Nothing' when no pixel
-- is left, and for a viewport with a component that is not finite.
viewScissor ∷ Viewport → (Word32, Word32) → Maybe Rect
viewScissor (Viewport (V2 x y) (V2 w h)) (width, height)
  | any (\component → isNaN component || isInfinite component) [x, y, w, h] = Nothing
  | x1 <= x0 || y1 <= y0 = Nothing
  | otherwise = Just (Rect (fromInteger x0) (fromInteger y0) (fromInteger (x1 - x0)) (fromInteger (y1 - y0)))
  where
    (x0, x1) = span' x w width
    (y0, y1) = span' y h height
    span' origin extent limit =
      let low = ceiling (toRational origin - 1 / 2) ∷ Integer
          high = ceiling (toRational origin + toRational extent - 1 / 2) ∷ Integer
       in (clamp limit low, clamp limit high)
    clamp limit value = max 0 (min (toInteger limit) value)
