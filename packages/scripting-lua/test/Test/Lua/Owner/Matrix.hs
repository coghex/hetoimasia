-- | The owner's exits and what each keeps.
--
-- Every example runs a whole lifetime through the package-private owner and
-- reads how it ended the way a supervisor does: the primary failure's type and
-- context, and the cleanup evidence its context carries
-- ('cleanupFailuresInContext'). Expected values are written here from the
-- contract, never from the owner: a body failure stays primary; a close failure
-- alone is primary and is also evidence, so it stays classifiable as cleanup;
-- both together keep the body's failure and retain every close failure, each
-- with its own context; and a callback a finalizer reaches runs with its
-- dependency live, the dependency released only after the close.
--
-- Cancellation, partial construction, the shutdown phase and ownership have
-- examples of their own beside this one.
module Test.Lua.Owner.Matrix (spec) where

import Control.Exception (SomeException, annotateIO, throwIO, try)
import Data.Either (isRight)
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailures)
import Hetoimasia.Scripting.Lua.Bridge (LuaFault)
import Hetoimasia.Scripting.Lua.Internal.Vm (Phase (Closed), vmPhase)
import Hetoimasia.Scripting.Lua.Internal.Owner (ownedInternalVm, withOwnedVm)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Test.Lua.Owner.Support

spec ∷ Spec
spec = describe "the exit and evidence matrix" $ do
  it "returns the body's result and reports nothing when the body and the close succeed" $ do
    finalizing ← newFinalizing
    outcome ← runOwner (finalizingConfig finalizing) (\_ → pure ("result" ∷ String))
    either (const Nothing) Just outcome `shouldBe` Just "result"
    -- The finalizer's callback ran with its dependency still held, and the
    -- dependency was released after the close, not before.
    events (finalizingEvents finalizing) >>= (`shouldBe` ["finalizer: dependency live", "release"])

  it "keeps a body failure as primary with no cleanup evidence when the close succeeds" $ do
    finalizing ← newFinalizing
    outcome ←
      runOwner
        (finalizingConfig finalizing)
        (\_ → annotateIO (Marker "body context") (throwIO (BodyBroke "body")) ∷ IO ())
    case outcome of
      Right () → expectationFailure "the body's failure was lost"
      Left failure → do
        causeOf failure `shouldBe` Just (BodyBroke "body")
        primaryMarkers failure `shouldBe` ["body context"]
        -- A close that succeeded is never reported.
        evidenceLabels failure `shouldBe` []
    events (finalizingEvents finalizing) >>= (`shouldBe` ["finalizer: dependency live", "release"])

  it "raises a close failure alone as the primary failure, and also as cleanup evidence a supervisor classifies as cleanup" $ do
    finalizing ← newFinalizing
    outcome ← runOwner (failingCloseConfig finalizing) (\_ → pure ())
    case outcome of
      Right () → expectationFailure "the close failures were dropped"
      Left failure → do
        -- The first close failure is primary, as when only a release fails in a
        -- scope: its own type and value, and not a script's error.
        causeOf failure `shouldBe` Just (CloseBroke "finalizer")
        primaryMarkers failure `shouldBe` ["finalizer context"]
        causeOf failure `shouldBe` (Nothing ∷ Maybe LuaFault)
        -- Every close failure, the first included, is retained under its source,
        -- finalizers' first and then releases', each with its own context.
        evidenceLabels failure `shouldBe` ["lua finalizer", "lua release"]
        evidenceCauses failure `shouldBe` [Just (CloseBroke "finalizer"), Just (CloseBroke "release")]
        evidenceMarkers failure `shouldBe` [["finalizer context"], ["release context"]]
    -- The ordinary finalizer and its release still ran, once each.
    events (finalizingEvents finalizing) >>= (`shouldBe` ["finalizer: dependency live", "release"])

  it "keeps the body's failure primary and retains every close failure beside it, each with its own context" $ do
    finalizing ← newFinalizing
    outcome ←
      runOwner
        (failingCloseConfig finalizing)
        (\_ → annotateIO (Marker "body context") (throwIO (BodyBroke "body")) ∷ IO ())
    case outcome of
      Right () → expectationFailure "the failures were lost"
      Left failure → do
        causeOf failure `shouldBe` Just (BodyBroke "body")
        primaryMarkers failure `shouldBe` ["body context"]
        evidenceLabels failure `shouldBe` ["lua finalizer", "lua release"]
        evidenceCauses failure `shouldBe` [Just (CloseBroke "finalizer"), Just (CloseBroke "release")]
        evidenceMarkers failure `shouldBe` [["finalizer context"], ["release context"]]

  it "reads the same evidence through the exception a caller above the owner catches" $ do
    finalizing ← newFinalizing
    outcome ← try @SomeException (withOwnedVm (failingCloseConfig finalizing) (\_ → throwIO (BodyBroke "body") ∷ IO ()))
    case outcome of
      Right () → expectationFailure "the failures were lost"
      Left raised → map cleanupFailureLabel (cleanupFailures raised) `shouldBe` ["lua finalizer", "lua release"]

  it "closes the VM it constructed on every exit, and refuses it afterwards" $ do
    finalizing ← newFinalizing
    kept ← newCaptured
    _ ← runOwner (finalizingConfig finalizing) $ \owned → capture kept (ownedInternalVm owned)
    captured kept >>= \case
      Nothing → expectationFailure "the body did not run"
      Just vm → vmPhase vm >>= (`shouldBe` Closed)
    -- And a lifetime that ended by failure closed its VM as well.
    failed ← newCaptured
    _ ← runOwner (finalizingConfig finalizing) $ \owned → capture failed (ownedInternalVm owned) >> throwIO (BodyBroke "body")
    captured failed >>= \case
      Nothing → expectationFailure "the body did not run"
      Just vm → vmPhase vm >>= (`shouldBe` Closed)

  it "does not run a second close or a second finalizer however the lifetime ended" $ do
    finalizing ← newFinalizing
    outcome ← runOwner (finalizingConfig finalizing) (\_ → throwIO (BodyBroke "body") ∷ IO ())
    isRight outcome `shouldBe` False
    events (finalizingEvents finalizing) >>= (`shouldBe` ["finalizer: dependency live", "release"])
