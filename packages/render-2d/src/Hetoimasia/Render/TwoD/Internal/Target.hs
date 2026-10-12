-- | The representation of an offscreen target reference.
--
-- __Ownership.__ A hidden module of @hetoimasia-render-2d@. Only the public
-- target module and the backend-facing one import it.
--
-- __Dependencies.__ @base@ alone.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Internal.Target
  ( TargetRef (..)
  ) where

import Data.Word (Word32)

-- | An index and a generation, which a backend issues and resolves. Holding
-- one acquires nothing and keeps nothing alive.
data TargetRef = TargetRef
  { targetRefIndex ∷ {-# UNPACK #-} !Word32
  , targetRefGeneration ∷ {-# UNPACK #-} !Word32
  }
  deriving stock (Eq, Ord, Show)
