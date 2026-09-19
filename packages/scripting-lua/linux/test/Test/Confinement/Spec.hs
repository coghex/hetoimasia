-- | The Linux confinement feasibility probe, composed.
--
-- One thing lives here rather than in the four groups below it: the record of
-- the machine this run happened on. Requirement 8 asks for the experiments in
-- two environments and for each to be recorded separately, and the only way a
-- reader of a CI log can tell which environment produced it is if the run says
-- so itself. The example below is what makes that record part of the evidence
-- rather than something a person reconstructs afterwards.
--
-- Nothing in this suite concludes that the profile is adequate. Every example
-- either proves its property here or says, in the line it prints, that it could
-- not be proved here and why. Turning those lines into a verdict is the verdict
-- document's job, and a green run of this suite is deliberately not that.
module Test.Confinement.Spec (spec) where

import Test.Confinement.Support
  ( Availability
  , Controls (controlInetSocket, controlInheritedDescriptor, controlModule, controlSentinels)
  , Environment (environmentDistribution, environmentKernel, environmentUser)
  , Ledger
  , announce
  , describeAvailability
  , describeEnvironment
  )
import qualified Test.Confinement.Isolation
import qualified Test.Confinement.Lifetime
import qualified Test.Confinement.Limits
import qualified Test.Confinement.Profile
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe)

spec ∷ Ledger → Controls → [FilePath] → Environment → Availability → Spec
spec ledger available sentinels machine installed = describe "Linux confinement" $ do
  describe "record" $ do
    it "names the machine, the permissions, and the command this run used" $ do
      environmentKernel machine `shouldNotBe` "unknown"
      environmentDistribution machine `shouldNotBe` ""
      environmentUser machine `shouldNotBe` "unknown"
      announce (describeEnvironment machine)
      announce (describeAvailability installed)
      announce
        ( "COMMAND cabal test hetoimasia-scripting-lua:linux-confinement-probe"
            <> " --test-show-details=direct"
        )

    it "established every control before drawing a conclusion from a denial" $ do
      -- A sentinel the parent could not read would make every child's failure
      -- to read it meaningless, and a module the parent could not load would
      -- do the same for the loader denial.
      controlSentinels available `shouldNotBe` []
      mapM_ (\(path, observed) → (path, observed) `shouldBe` (path, 0)) (controlSentinels available)
      -- An AF_INET socket, here, unconfined. The filter treats that domain
      -- differently from AF_UNIX, so the child's AF_UNIX control says nothing
      -- about it: without this line a machine with no network stack would
      -- refuse the child's attempt for its own reasons and the refusal would
      -- be read as the filter's work.
      controlInetSocket available `shouldBe` 0
      -- And a descriptor left open above any range a sweep might have guessed
      -- at, which the child must not be able to see.
      controlInheritedDescriptor available `shouldNotBe` 0
      case controlModule available of
        Just name →
          announce
            ( "CONTROLS sentinels=readable inet-socket=created native-module="
                <> name
                <> " inherited-descriptor="
                <> show (controlInheritedDescriptor available)
            )
        Nothing →
          expectationFailure
            "no shared library on this machine could be loaded, so the module denial has no control"

  Test.Confinement.Profile.spec ledger available sentinels machine installed
  Test.Confinement.Isolation.spec ledger available sentinels machine installed
  Test.Confinement.Limits.spec ledger available sentinels machine installed
  Test.Confinement.Lifetime.spec ledger available sentinels machine installed
