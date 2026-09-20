-- | The GPU model suite, composed from its component specs.
--
-- One top-level group, @GPU model@, so the whole package's coverage is
-- selectable with @--match 'GPU model'@ and each component inside it is
-- selectable by its own name. A new example belongs in the component that owns
-- the contract it asserts; this module only composes.
module Test.GPU.Model.Spec (spec) where

import qualified Test.GPU.Model.Budgets as Budgets
import qualified Test.GPU.Model.Frames as Frames
import qualified Test.GPU.Model.Holds as Holds
import qualified Test.GPU.Model.Identities as Identities
import qualified Test.GPU.Model.Opacity as Opacity
import qualified Test.GPU.Model.Progress as Progress
import qualified Test.GPU.Model.Recovery as Recovery
import qualified Test.GPU.Model.Sequences as Sequences
import Test.Hspec (Spec, describe)

spec ∷ Spec
spec = describe "GPU model" $ do
  Identities.spec
  Holds.spec
  Frames.spec
  Budgets.spec
  Opacity.spec
  Recovery.spec
  Progress.spec
  Sequences.spec
