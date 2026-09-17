-- | The foundation suite, composed from its component specs.
--
-- Each component roots exactly one top-level group, so the tree is @Logging@,
-- @Resources@, @Failures@, @Recovery@, @Workers@, @Messaging@, and @Time@ and each is
-- selectable on its own with @--match@. A new example belongs in the component
-- that owns the contract it asserts; this module only composes.
module Test.Foundation.Spec (spec) where

import qualified Test.Foundation.Failures.Spec as Failures
import qualified Test.Foundation.Logging.Spec as Logging
import qualified Test.Foundation.Messaging.Spec as Messaging
import qualified Test.Foundation.Recovery.Spec as Recovery
import qualified Test.Foundation.Resources.Spec as Resources
import qualified Test.Foundation.Time.Spec as Time
import qualified Test.Foundation.Workers.Spec as Workers
import Test.Hspec (Spec)

spec ∷ Spec
spec = do
  Logging.spec
  Resources.spec
  Failures.spec
  Recovery.spec
  Workers.spec
  Messaging.spec
  Time.spec
