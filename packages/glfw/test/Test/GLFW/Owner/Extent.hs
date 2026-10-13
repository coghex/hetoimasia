-- | The extent seam: the backend's concrete extent when it supplies one,
-- otherwise the last coherent observation, checked for eligibility and zero
-- area before it is clamped to the reported bounds.
module Test.GLFW.Owner.Extent (spec) where

import Hetoimasia.GLFW.Window (ContentScale (..), Extent (..))
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
  it "holds the logical extent and each content-scale axis as last reported, none until one is"
    testWindowMetricsKeepLast

testExtentFromBackend ∷ IO ()
testExtentFromBackend =
  chooseTargetExtent RenderEligible geometry (BackendSupplied (Extent 1280 720))
    `shouldBe` ExtentFromBackend (Extent 1280 720)
  where
    geometry = TargetGeometry (Just (Extent 100 100)) (Just (ExtentBounds (Extent 1 1) (Extent 200 200))) Nothing Nothing

testExtentFromObservation ∷ IO ()
testExtentFromObservation = do
  chooseTargetExtent RenderEligible geometry ApplicationChooses
    `shouldBe` ExtentFromObservation (Extent 200 200)
  chooseTargetExtent RenderEligible unbounded ApplicationChooses
    `shouldBe` ExtentFromObservation (Extent 640 480)
  chooseTargetExtent RenderEligible noTargetGeometry ApplicationChooses
    `shouldBe` ExtentWithheld ExtentUnobserved
  where
    geometry = TargetGeometry (Just (Extent 640 480)) (Just (ExtentBounds (Extent 1 1) (Extent 200 200))) Nothing Nothing
    unbounded = TargetGeometry (Just (Extent 640 480)) Nothing Nothing Nothing

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
    blank = TargetGeometry (Just (Extent 0 480)) (Just (ExtentBounds (Extent 16 16) (Extent 4096 4096))) Nothing Nothing

testGeometryKeepsLastCoherent ∷ IO ()
testGeometryKeepsLastCoherent = do
  geometryFramebuffer folded `shouldBe` Just (Extent 640 480)
  geometryBounds folded `shouldBe` Just (ExtentBounds (Extent 1 1) (Extent 8 8))
  where
    -- A later observation the platform could report neither for leaves both.
    folded = observeGeometry Nothing Nothing once
    once = observeGeometry (Just (Extent 640 480)) (Just (ExtentBounds (Extent 1 1) (Extent 8 8))) noTargetGeometry

testWindowMetricsKeepLast ∷ IO ()
testWindowMetricsKeepLast = do
  -- Nothing is invented before the platform reports: an unobserved target has
  -- no logical extent and no content scale.
  geometryLogical noTargetGeometry `shouldBe` Nothing
  geometryContentScale noTargetGeometry `shouldBe` Nothing
  geometryLogical once `shouldBe` Just (Extent 320 240)
  geometryContentScale once `shouldBe` Just (ContentScale 2 1.5)
  -- A later observation reporting neither leaves both, and one reporting a
  -- new logical extent alone replaces that alone.
  geometryLogical (observeWindowMetrics Nothing Nothing once) `shouldBe` Just (Extent 320 240)
  geometryContentScale (observeWindowMetrics Nothing Nothing once) `shouldBe` Just (ContentScale 2 1.5)
  geometryLogical resized `shouldBe` Just (Extent 400 300)
  geometryContentScale resized `shouldBe` Just (ContentScale 2 1.5)
  -- The framebuffer extent and the bounds are the geometry's own, untouched.
  geometryFramebuffer (observeWindowMetrics (Just (Extent 1 1)) (Just (ContentScale 1 1)) framebuffer) `shouldBe` Just (Extent 640 480)
  where
    once = observeWindowMetrics (Just (Extent 320 240)) (Just (ContentScale 2 1.5)) noTargetGeometry
    resized = observeWindowMetrics (Just (Extent 400 300)) Nothing once
    framebuffer = observeGeometry (Just (Extent 640 480)) Nothing noTargetGeometry
