-- | The extent seam: the backend's concrete extent when it supplies one,
-- otherwise the last coherent observation, checked for eligibility and zero
-- area before it is clamped to the reported bounds.
module Test.GLFW.Owner.Extent (spec) where

import Hetoimasia.GLFW.Window (Extent (..))
import Hetoimasia.Runtime.GLFW
import Test.Hspec (Spec, it, shouldBe)

spec ∷ Spec
spec = do
  it "takes the backend's concrete extent when it supplies one"
    testExtentFromBackend
  it "falls back to the last coherent observation, clamped to the reported bounds"
    testExtentFromObservation
  it "checks eligibility and zero area before it clamps"
    testExtentWithheld
  it "keeps the last coherent observation when a later one reports none"
    testGeometryKeepsLastCoherent

testExtentFromBackend ∷ IO ()
testExtentFromBackend =
  chooseTargetExtent RenderEligible geometry (BackendSupplied (Extent 1280 720))
    `shouldBe` ExtentFromBackend (Extent 1280 720)
  where
    geometry = TargetGeometry (Just (Extent 100 100)) (Just (ExtentBounds (Extent 1 1) (Extent 200 200)))

testExtentFromObservation ∷ IO ()
testExtentFromObservation = do
  chooseTargetExtent RenderEligible geometry ApplicationChooses
    `shouldBe` ExtentFromObservation (Extent 200 200)
  chooseTargetExtent RenderEligible unbounded ApplicationChooses
    `shouldBe` ExtentFromObservation (Extent 640 480)
  chooseTargetExtent RenderEligible noTargetGeometry ApplicationChooses
    `shouldBe` ExtentWithheld ExtentUnobserved
  where
    geometry = TargetGeometry (Just (Extent 640 480)) (Just (ExtentBounds (Extent 1 1) (Extent 200 200)))
    unbounded = TargetGeometry (Just (Extent 640 480)) Nothing

testExtentWithheld ∷ IO ()
testExtentWithheld = do
  -- Suspended first: a clamp must never resume a target the observation
  -- suspended.
  chooseTargetExtent RenderSuspended blank ApplicationChooses
    `shouldBe` ExtentWithheld (ExtentNotEligible RenderSuspended)
  -- Then zero area, before the clamp that would otherwise raise it to the
  -- reported minimum.
  chooseTargetExtent RenderEligible blank ApplicationChooses
    `shouldBe` ExtentWithheld (ExtentZeroArea (Extent 0 480))
  chooseTargetExtent RenderEligible blank (BackendSupplied (Extent 0 0))
    `shouldBe` ExtentWithheld (ExtentZeroArea (Extent 0 0))
  where
    blank = TargetGeometry (Just (Extent 0 480)) (Just (ExtentBounds (Extent 16 16) (Extent 4096 4096)))

testGeometryKeepsLastCoherent ∷ IO ()
testGeometryKeepsLastCoherent = do
  geometryFramebuffer folded `shouldBe` Just (Extent 640 480)
  geometryBounds folded `shouldBe` Just (ExtentBounds (Extent 1 1) (Extent 8 8))
  where
    -- A later observation the platform could report neither for leaves both.
    folded = observeGeometry Nothing Nothing once
    once = observeGeometry (Just (Extent 640 480)) (Just (ExtentBounds (Extent 1 1) (Extent 8 8))) noTargetGeometry
