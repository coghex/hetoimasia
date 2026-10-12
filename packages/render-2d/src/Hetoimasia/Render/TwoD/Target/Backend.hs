-- | The backend-facing view of an offscreen target reference: build one from
-- an index and a generation, and read both back.
--
-- __Audience.__ The backend that owns offscreen targets mints these references,
-- and a test that stands in for one does the same. Game code imports
-- "Hetoimasia.Render.TwoD.Target" for the type and does not import this module.
--
-- __Pure and total.__ Every pair of 'Word32' values is a reference. Building
-- one performs no native acquisition and starts no lifetime: what an index and
-- a generation mean, and whether a reference is still live, belong to the
-- backend, which later slices define.
--
-- __Dependencies.__ @base@ and the package's hidden representation module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Target.Backend
  ( targetRef
  , targetRefIndex
  , targetRefGeneration
  ) where

import Data.Word (Word32)
import Hetoimasia.Render.TwoD.Internal.Target (TargetRef (..), targetRefGeneration, targetRefIndex)

-- | The reference with this index and this generation.
targetRef ∷ Word32 → Word32 → TargetRef
targetRef = TargetRef
