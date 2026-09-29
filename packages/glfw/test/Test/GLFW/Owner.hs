-- | Examples for the supervised graphics owner: its cross-thread handoffs, its
-- own scheduling, its cancellation and retirement, and the D-33 exit order it
-- composes with the protected host.
--
-- This module only composes them. Each behavior group's scenarios live in
-- its own @Test.GLFW.Owner.*@ spec module, beside the helpers only they use;
-- the fake backend, the journal, the scripted timer, the host rig, and the
-- helpers more than one spec module shares live in the
-- @Test.GLFW.Owner.Fixture.*@ modules. No spec module imports another's.
--
-- Nothing here initializes GLFW, opens a window, needs a display, or sleeps
-- for a concurrency outcome: every example asserts an order of recorded facts
-- or an observed state, and coordinates threads with STM and 'MVar's.
module Test.GLFW.Owner (spec) where

import qualified Test.GLFW.Owner.Cancellation as Cancellation
import qualified Test.GLFW.Owner.Discipline as Discipline
import qualified Test.GLFW.Owner.Exit.Retirement as ExitRetirement
import qualified Test.GLFW.Owner.Exit.Settlement as ExitSettlement
import qualified Test.GLFW.Owner.Extent as Extent
import qualified Test.GLFW.Owner.Failure.Cancellation as FailureCancellation
import qualified Test.GLFW.Owner.Failure.Evidence as FailureEvidence
import qualified Test.GLFW.Owner.Failure.Interruption as FailureInterruption
import qualified Test.GLFW.Owner.Failure.Reporting as FailureReporting
import qualified Test.GLFW.Owner.Handover as Handover
import qualified Test.GLFW.Owner.Port as Port
import qualified Test.GLFW.Owner.Progress as Progress
import Test.Hspec (Spec, describe)

-- | The whole group, in the order the examples have always run. A behavior
-- group split across modules composes them here, in that same order, under
-- the one heading it has always had.
spec ∷ Spec
spec = describe "GLFW graphics owner" $ do
  describe "handing a target over" Handover.spec
  describe "independent progress" Progress.spec
  describe "the bounded lifetime port" Port.spec
  describe "cancellation" Cancellation.spec
  describe "the D-33 exit" $ do
    ExitRetirement.spec
    ExitSettlement.spec
  describe "failure" $ do
    FailureEvidence.spec
    FailureCancellation.spec
    FailureReporting.spec
    FailureInterruption.spec
  describe "the owner's GLFW discipline" Discipline.spec
  describe "the extent seam" Extent.spec
