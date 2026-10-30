-- | What the full-product build of the root suite adds to the console examples: the @Run@ group, and the
-- child entry its signal examples launch. The default and CPU builds have the module of this name in
-- @test-cpu/@.
module Test.Engine.Variant
  ( variantSpec
  , childEntry
  ) where

import qualified Test.Engine.Run.Child as Child
import qualified Test.Engine.Run.Spec as Run
import Test.Hspec (Spec)

variantSpec ∷ Spec
variantSpec = Run.spec

-- | Run as the signal child when the suite launched this process as one; answers whether it did.
childEntry ∷ IO Bool
childEntry = Child.childEntry
