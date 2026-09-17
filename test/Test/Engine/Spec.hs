-- | The headless engine suite, composed from its component specs.
--
-- Each component roots exactly one top-level group, so the tree is @Runtime@
-- and @GLFW@ and each is selectable on its own with @--match@. A new example
-- belongs in the component that owns the behaviour it asserts; this module only
-- composes.
--
-- The foundation's Logging, Resources, Failures, Recovery, Workers, and
-- Messaging examples are registered by the foundation package's own suite,
-- @hetoimasia-foundation:foundation-tests@, not here.
module Test.Engine.Spec (spec) where

import qualified Test.Engine.GLFW.Spec as GLFW
import qualified Test.Engine.Runtime.Spec as Runtime
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Runtime.spec
  GLFW.spec
