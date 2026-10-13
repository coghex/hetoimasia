-- | Which path an instance takes (decisions D-3, D-22, D-24, D-25), written
-- once for the draw plan, which routes the instances a snapshot submits each
-- frame, and for a retained chunk, which routes its instances once, when it is
-- built.
--
-- __Ownership.__ A hidden module of @hetoimasia-render-2d@;
-- "Hetoimasia.Render.TwoD.DrawPlan" re-exports the marks.
--
-- __Dependencies.__ @base@, @containers@ for the set of marked handles,
-- @hetoimasia-render-api@ for the handle, and this package's material and
-- snapshot modules.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Internal.Routing
  ( CutoutMarks
  , cutoutMarks
  , noCutoutMarks
  , isMarkedCutout
  , routesToCutout
  ) where

import Data.Set (Set)
import qualified Data.Set as Set
import Hetoimasia.Render.Api.Texture (TextureHandle)
import Hetoimasia.Render.TwoD.Internal.Material (MaterialRef (..), MaterialFacts (..))
import Hetoimasia.Render.TwoD.Snapshot (Instance (..), Tint (..))

-- | The textures marked cutout-safe, each by its complete handle, generation
-- included. A handle that is not in the set is unmarked.
newtype CutoutMarks = CutoutMarks (Set TextureHandle)
  deriving stock (Eq, Show)

-- | The marks naming exactly these handles as cutout-safe.
cutoutMarks ∷ [TextureHandle] → CutoutMarks
cutoutMarks = CutoutMarks . Set.fromList

-- | No texture is marked: every instance takes the ordered path.
noCutoutMarks ∷ CutoutMarks
noCutoutMarks = CutoutMarks Set.empty

-- | Whether this exact handle, generation included, is marked cutout-safe.
isMarkedCutout ∷ CutoutMarks → TextureHandle → Bool
isMarkedCutout (CutoutMarks marked) handle = Set.member handle marked

-- | Whether an instance takes the cutout path, given whether its layer is a
-- depth-enabled world layer.
routesToCutout ∷ CutoutMarks → Bool → Instance → Bool
routesToCutout marks depthEnabled candidate =
  depthEnabled
    && isMarkedCutout marks (instanceTexture candidate)
    && factCutoutCapable (materialRefFacts (instanceMaterial candidate))
    && opaque (instanceTint candidate)
    && not (instanceTranslucent candidate)
    && not (instanceAdditive candidate)
  where
    opaque (Tint _ _ _ alpha) = alpha == 255
