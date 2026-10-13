-- | The oracle's models of application materials (R2D-11, decision D-25).
--
-- An application material is a fragment function the engine wraps: the engine
-- applies tint, brightness and the cutout discard or the blend output around the
-- colour the material returns. The oracle models the same thing. A
-- 'MaterialModel' is a pure Haskell function of the same inputs the material's
-- GLSL function receives — the instance's sampled texel, its texture
-- coordinates, its parameter word and its record — and of the application push
-- block, and it returns the material's colour; the oracle then applies the same
-- wrapping to it that it applies to the default material's texel, which is the
-- built-in model: the texel itself.
--
-- = The inputs
--
-- A 'MaterialInput' holds:
--
-- * the primary texel, premultiplied, in linear light, as the texture's sampler
--   gives it;
-- * the texture coordinates the fragment interpolates, @(u, v)@, as 'Double's;
-- * the instance's parameter word, and the record it indexes (the view's, or the
--   chunk's, for the instance), with every handle a full handle;
-- * the bytes of the application push block the view holds for the material
--   ('pushFloat' and 'pushWord' read them at a byte offset, as the shader's
--   members are laid out);
-- * 'materialSample', which samples any texture at coordinates the way the
--   shader's sampling function does: through the same lookup and its generation
--   check, so a handle the oracle's texture lookup does not hold — a released
--   one, or one whose index has been reused for another generation — samples the
--   transparent placeholder, with the instance's sampler choice and the level
--   its screen-space rate of change selects.
--
-- = The output
--
-- The colour, premultiplied, in linear light, as 'Colour'. A model that cannot
-- answer returns a 'ModelFault' (the sampling of a texture the oracle declines to
-- guess at is the one way); the oracle reports it as the indeterminate case or
-- the input defect it is, naming the instance. A component that is not finite is
-- an input defect too.
--
-- = A cutout-capable material
--
-- A material declared cutout-capable promises that its output alpha is binary
-- wherever its primary texture's is, so the cutout variant's threshold at one
-- half is the texture's own. The oracle applies the threshold to the model's
-- alpha, and a model whose alpha is within two steps of an 8-bit alpha of the
-- threshold is indeterminate, as the default material's is.
--
-- __Dependencies.__ @base@, @bytestring@, @hetoimasia-render-api@,
-- @hetoimasia-render-2d@ and the oracle's image module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Oracle.Material
  ( -- * Models
    MaterialModel (..)
  , MaterialInput (..)
  , Colour (..)
  , ModelFault (..)

    -- * Reading the push block
  , pushFloat
  , pushWord

    -- * Colour helpers
  , mixColour
  , scaleColour
  ) where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.Word (Word32)
import GHC.Float (castWord32ToFloat)
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Material (MaterialRecord)
import Hetoimasia.Render.TwoD.Oracle.Internal.Image (ImageFault)

-- | A colour: red, green, blue and alpha, premultiplied, in linear light.
data Colour = Colour !Double !Double !Double !Double
  deriving stock (Eq, Show)

-- | Why a model cannot answer: the secondary texture it sampled, and why that
-- sample is not given.
data ModelFault
  = -- | A nearest-filtered coordinate within 1/16 texel of an interior boundary
    -- between texels that differ.
    SampleNearTexelBoundary !TextureHandle
  | -- | A minified sample whose derivatives are sheared or rotated by other than
    -- a quarter turn, on a texture with more than one level.
    SampleMinifiedNotAxisAligned !TextureHandle
  | -- | A minified, axis-aligned sample whose level of detail is between two
    -- levels.
    SampleMinifiedFractionalLevel !TextureHandle
  | -- | A texture the lookup returned that is not a well-formed image.
    SampleMalformedImage !TextureHandle !ImageFault
  | -- | A texture of more than one level sampled by 'materialSample' at
    -- coordinates other than the fragment's own: how fast they change is the
    -- model's to say ('materialSampleScaled'), and the level depends on it.
    SampleCoordinatesUnrelated !TextureHandle
  deriving stock (Eq, Show)

-- | What a model is given.
data MaterialInput = MaterialInput
  { materialTexel ∷ !Colour
  -- ^ The instance's own sampled texel.
  , materialUv ∷ !(Double, Double)
  -- ^ The texture coordinates at the fragment.
  , materialParameter ∷ !Word32
  -- ^ The instance's parameter word.
  , materialRecord ∷ !MaterialRecord
  -- ^ The record the parameter word indexes; empty for a material whose layout
  -- is.
  , materialPush ∷ !ByteString
  -- ^ The application push block the view holds for the material.
  , materialSample ∷ TextureHandle → (Double, Double) → Either ModelFault Colour
  -- ^ A texture sampled at these coordinates, as the shader's sampling function
  -- does: the instance's sampler choice, the placeholder for a handle the
  -- lookup does not hold, and the level the instance's rate of change of
  -- texture coordinates selects. That level is the right one only where the
  -- coordinates change as the fragment's own do, so for a texture of more than
  -- one level any other coordinates are a 'SampleCoordinatesUnrelated' fault;
  -- a model that offsets or scales the coordinates says so with
  -- 'materialSampleScaled'.
  , materialSampleScaled ∷ TextureHandle → (Double, Double) → (Double, Double) → Either ModelFault Colour
  -- ^ The same at coordinates the model derived from the fragment's own, given
  -- the factor by which it multiplied their rate of change in each direction:
  -- @(1, 1)@ for an offset, @(2, 2)@ for @uv * 2.0@. The level is selected by
  -- the instance's rate of change times that factor.
  }

-- | A pure model of one material, from the inputs its function receives to the
-- colour it returns.
newtype MaterialModel = MaterialModel
  { runMaterialModel ∷ MaterialInput → Either ModelFault Colour
  }

-- | The 32-bit float at this byte offset of a push block, little-endian; zero
-- past its end.
pushFloat ∷ ByteString → Int → Double
pushFloat bytes offset = realToFrac (castWord32ToFloat (pushWord bytes offset))

-- | The 32-bit word at this byte offset of a push block, little-endian; zero
-- for any byte past its end.
pushWord ∷ ByteString → Int → Word32
pushWord bytes offset =
  foldr (\byte acc → (acc `shiftL` 8) .|. fromIntegral byte) 0 [byteAt (offset + index) | index ← [0 .. 3]]
  where
    byteAt position
      | position < 0 || position >= ByteString.length bytes = 0
      | otherwise = ByteString.index bytes position

-- | @mix a b t = a × (1 − t) + b × t@, componentwise.
mixColour ∷ Colour → Colour → Double → Colour
mixColour (Colour ar ag ab aa) (Colour br bg bb ba) weight =
  Colour (blend ar br) (blend ag bg) (blend ab bb) (blend aa ba)
  where
    blend from to = from * (1 - weight) + to * weight

-- | Every component multiplied by a factor.
scaleColour ∷ Double → Colour → Colour
scaleColour factor (Colour r g b a) = Colour (r * factor) (g * factor) (b * factor) (a * factor)
