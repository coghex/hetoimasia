-- | The headless engine suite, composed from its component specs.
--
-- Each component roots exactly one top-level group, so the tree is @Console@
-- and @GLFW@ and each is selectable on its own with @--match@. A new example
-- belongs in the component that owns the behaviour it asserts; this module only
-- composes.
--
-- The foundation's examples are registered by
-- @hetoimasia-foundation:foundation-tests@, and the runtime's by
-- @hetoimasia-runtime:runtime-tests@, not here.
module Test.Engine.Spec (spec) where

import qualified Test.Engine.Console.Spec as Console
import qualified Test.Engine.GLFW.Spec as GLFW
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Console.spec
  GLFW.spec
