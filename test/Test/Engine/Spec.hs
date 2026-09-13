-- | The headless engine suite, composed from its component specs.
--
-- Each component roots exactly one top-level group, so the tree is @Logging@,
-- @Runtime@, @Resources@, and @Failures@ and each is selectable on its own with
-- @--match@. A new example belongs in the component that owns the behaviour it
-- asserts; this module only composes.
module Test.Engine.Spec (spec) where

import qualified Test.Engine.Failures.Spec as Failures
import qualified Test.Engine.Logging.Spec as Logging
import qualified Test.Engine.Resources.Spec as Resources
import qualified Test.Engine.Runtime.Spec as Runtime
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Logging.spec
  Runtime.spec
  Resources.spec
  Failures.spec
