-- | The headless engine suite, composed from its component specs.
--
-- The root package owns only the console executable's integration, so the tree
-- is the one @Console@ group, selectable with @--match Console@. A new example
-- belongs in the component that owns the behaviour it asserts; this module only
-- composes.
--
-- The foundation's examples are registered by
-- @hetoimasia-foundation:foundation-tests@, the runtime's by
-- @hetoimasia-runtime:runtime-tests@, and GLFW's headless examples by
-- @hetoimasia-glfw:glfw-tests@, not here.
module Test.Engine.Spec (spec) where

import qualified Test.Engine.Console.Spec as Console
import Test.Hspec (Spec)

spec ∷ Spec
spec = Console.spec
