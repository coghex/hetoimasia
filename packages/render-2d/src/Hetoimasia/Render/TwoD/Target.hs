-- | The opaque reference to an offscreen target a pass draws into.
--
-- A reference names a target a backend owns, by an index and a generation the
-- backend issued. It is a plain value: it holds no native handle, constructing
-- one acquires nothing and Haskell code holding one keeps nothing alive. How a
-- backend creates a target, resolves a reference and retires one is outside
-- this package. This module is what game code imports: it exports the type and,
-- through its instances, comparison, ordering and 'show', and neither the
-- constructor nor a field reader. "Hetoimasia.Render.TwoD.Target.Backend"
-- builds and reads one.
--
-- __Dependencies.__ @base@ and the package's hidden representation module.
--
-- __State.__ The module owns none.
module Hetoimasia.Render.TwoD.Target
  ( TargetRef
  ) where

import Hetoimasia.Render.TwoD.Internal.Target (TargetRef)
