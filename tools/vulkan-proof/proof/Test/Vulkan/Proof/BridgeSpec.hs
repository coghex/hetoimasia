{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-5's verdict: pure assertions over what "Test.Vulkan.Proof.Bridge"
-- observed, computed after its session — and its instance — have ended.
--
-- A session that stopped fails every example with the reason it stopped.
module Test.Vulkan.Proof.BridgeSpec (spec) where

import qualified Data.Text as Text
import Foreign.Ptr (nullPtr)
import Test.Hspec

import Hetoimasia.GLFW.Session (IntegrationUse (..))
import Hetoimasia.Runtime.GLFW (FactAnswer (..))
import System.Info (os)
import Test.Vulkan.Proof.Bridge
import Test.Vulkan.Proof.Interop (Provenance (..))

spec ∷ BridgeOutcome → Spec
spec outcome = describe "VK-5 loader-aware surface bridge" $ do
  it "established every step of its session" $
    onFacts outcome (\_ → pure ())

  it "made the capability from the binding's own vkGetInstanceProcAddr" $
    onFacts outcome $ \facts → do
      facts.factsCapabilityEntry.provenanceAddress `shouldBe` facts.factsBindingEntry.provenanceAddress
      facts.factsCapabilityEntry.provenanceImage `shouldBe` facts.factsBindingEntry.provenanceImage
      facts.factsCapabilityEntry.provenanceImage `shouldNotBe` Nothing

  it "had GLFW resolve through that exact entry point while the session was live" $
    onFacts outcome $ \facts → do
      facts.factsUseDuring `shouldBe` IntegrationInstalled
      facts.factsInstalledDuring.provenanceAddress `shouldBe` facts.factsCapabilityEntry.provenanceAddress
      facts.factsGlfwEntry.provenanceAddress `shouldBe` facts.factsCapabilityEntry.provenanceAddress

  it "had GLFW and the binding resolve an instance entry point into one image" $
    onFacts outcome $ \facts → do
      facts.factsGlfwInstanceSample.provenanceImage `shouldNotBe` Nothing
      facts.factsGlfwInstanceSample.provenanceImage `shouldBe` facts.factsBindingInstanceSample.provenanceImage

  it "copied the platform's required instance extensions" $
    onFacts outcome $ \facts → do
      facts.factsExtensions `shouldContain` ["VK_KHR_surface"]
      facts.factsExtensions `shouldSatisfy` any (`elem` platformSurfaceExtensions)

  it "created a surface for the attached window, which the binding accepted" $
    onFacts outcome $ \facts → do
      facts.factsCreation `shouldSatisfy` Text.isPrefixOf "SurfaceCreated"
      facts.factsSurfaceHandle `shouldNotBe` 0
      facts.factsSurfaceQuery `shouldSatisfy` Text.isPrefixOf "presentation support"

  it "refused the attachment's disposal fact and the instance's release while the surface was owed" $
    onFacts outcome $ \facts → do
      facts.factsDisposedWhileOwed `shouldBe` Nothing
      facts.factsReleaseWhileOwed `shouldSatisfy` Text.isPrefixOf "InstanceRetained"

  it "destroyed the surface through Vulkan on another thread, and then granted both" $
    onFacts outcome $ \facts → do
      facts.factsDischarge `shouldBe` "SurfaceDestroyed"
      facts.factsDischargedOffOwner `shouldBe` True
      facts.factsDisposedAfter `shouldBe` Just AttachmentNowRetired
      facts.factsReleaseAfter `shouldBe` "InstanceReleasable"

  it "restored GLFW's default loader after termination" $
    onFacts outcome $ \facts → do
      facts.factsInstalledAfterTermination `shouldBe` nullPtr
      facts.factsUseAfterTermination `shouldBe` IntegrationRestored

  it "restored GLFW's default loader after a failed initialization, where the platform can fail one" $
    onFacts outcome $ \facts → case facts.factsFailedInitialization of
      FailedInitializationObserved _ _ entry use → do
        entry `shouldBe` nullPtr
        use `shouldBe` IntegrationRestored
      FailedInitializationUnreachable reason
        | failedInitializationBackend == Nothing → pendingWith (Text.unpack reason)
        | otherwise → expectationFailure (Text.unpack reason)
      FailedInitializationSucceeded reason → expectationFailure (Text.unpack reason)

-- | The surface extensions GLFW requires on the platforms the proof runs on.
platformSurfaceExtensions ∷ [Text.Text]
platformSurfaceExtensions
  | os == "darwin" = ["VK_EXT_metal_surface"]
  | otherwise = ["VK_KHR_xlib_surface", "VK_KHR_xcb_surface", "VK_KHR_wayland_surface"]

onFacts ∷ BridgeOutcome → (BridgeFacts → Expectation) → Expectation
onFacts outcome check = case outcome of
  BridgeStopped reason → expectationFailure ("the bridge session stopped: " <> Text.unpack reason)
  BridgeProved facts → check facts
