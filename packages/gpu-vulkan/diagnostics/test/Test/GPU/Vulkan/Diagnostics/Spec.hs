-- | The diagnostics suite, composed from its component specs.
--
-- One top-level group, @Vulkan diagnostics@, so the whole package's coverage is
-- selectable with @--match 'Vulkan diagnostics'@ and each component inside it
-- by its own name. A new example belongs in the component that owns the
-- contract it asserts; this module only composes.
module Test.GPU.Vulkan.Diagnostics.Spec (spec) where

import qualified Test.GPU.Vulkan.Diagnostics.Capture as Capture
import qualified Test.GPU.Vulkan.Diagnostics.Config as Config
import qualified Test.GPU.Vulkan.Diagnostics.Lifetime as Lifetime
import qualified Test.GPU.Vulkan.Diagnostics.Outcome as Outcome
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "Vulkan diagnostics" $ do
  Config.spec
  Capture.spec
  Lifetime.spec
  Outcome.spec
