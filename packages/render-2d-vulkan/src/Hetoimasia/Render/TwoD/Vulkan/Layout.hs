-- | The recorder's pure layout decisions (R2D-7): what the shaders read and
-- how the host feeds them, written once so the shader interfaces, the
-- recorder and the device-free tests all name the same numbers.
--
-- * The instance, as the vertex stage reads it: one binding advancing per
--   instance at render-2d's 64-byte stride, each attribute at its offset in
--   #414's layout ('instanceVertexInput').
-- * The push block both stages declare: the view's transform, the attachment's
--   extent, the view's brightness, its default filter and whether it snaps
--   ('packViewPush', 'pushMembers').
-- * The sampler an instance resolves to ('shaderSamplerIndex'), which is what
--   the fragment stage computes.
-- * The scissor of a view, exactly the pixels whose centres its viewport
--   contains ('viewScissor').
--
-- Everything here is pure and total.
--
-- = The push block
--
-- Both stages declare one block, in std430 order, 44 bytes:
--
-- > offset  size  member
-- >      0    16  vec4 viewLinear       a, b, c, d of the view's transform
-- >     16     8  vec2 viewTranslation  tx, ty
-- >     24     8  vec2 extent           the attachment's width and height, in pixels
-- >     32     4  float brightness
-- >     36     4  uint filtering        the view's default filter: 1 nearest, 2 linear
-- >     40     4  uint snap             1 when the view snaps instance origins
--
-- The transform maps @(x, y)@ to @(a·x + c·y + tx, b·x + d·y + ty)@, the
-- coefficients of "Hetoimasia.Math.Affine2" in column-major order.
module Hetoimasia.Render.TwoD.Vulkan.Layout
  ( -- * The instance as vertex input
    instanceStride
  , instanceVertexInput
    -- * The push block
  , ViewPush (..)
  , pushMembers
  , pushBytes
  , packViewPush
  , filterCode
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
import Hetoimasia.Render.TwoD.Settings (TextureFilter (..))
import Hetoimasia.Render.TwoD.Snapshot (Viewport (..))

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
--
-- The depth key at offset 48 is not read: the ordered path sorts by it on the
-- host, and no depth attachment exists until R2D-9. The unit square's corners
-- are the shader's own.
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
    ]

-- | What a view's draws need beyond the instance: the transform of the layer's
-- space, the attachment's extent, and the view's settings.
data ViewPush = ViewPush
  { pushTransform ∷ !Affine2
    -- ^ The world or UI transform, to target pixels.
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
  ]

-- | The block's size in bytes.
pushBytes ∷ Int
pushBytes = 44

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
  where
    (width, height) = pushExtent view

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
