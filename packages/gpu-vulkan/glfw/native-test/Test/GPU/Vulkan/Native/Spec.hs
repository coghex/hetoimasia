-- | The Vulkan native suite's examples, in the order they run.
--
-- The first two groups need no consent and enter no session: the consent
-- rules themselves, and the migrated proof's release, construction,
-- publication and loader-selection decisions over stand-in native layers.
-- The last two are native: the shared roots, and the cases that need roots of
-- their own in a child process. Each native example asks the consent gate
-- before its body runs.
module Test.GPU.Vulkan.Native.Spec (spec) where

import Data.IORef (IORef)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Test.GPU.Vulkan.Native.Consent (Consent (..), Refusal (..), consentFrom)
import Test.GPU.Vulkan.Native.Fixture (Fixture)
import Test.GPU.Vulkan.Native.Gate (Gate)
import Test.GPU.Vulkan.Native.Private (ChildRun)
import qualified Test.GPU.Vulkan.Native.Private as Private
import qualified Test.GPU.Vulkan.Native.Shared as Shared
import qualified Test.Vulkan.Proof.ConstructionSpec as Construction
import qualified Test.Vulkan.Proof.LoaderSpec as Loader
import qualified Test.Vulkan.Proof.PublicationSpec as Publication
import qualified Test.Vulkan.Proof.RetentionSpec as Retention

spec ∷ Gate → Fixture → IORef [ChildRun] → Spec
spec gate fixture timings = describe "Vulkan native" $ do
  describe "the native opt-in" consent
  describe "without a native session" $ do
    Retention.spec
    Construction.spec
    Publication.spec
    Loader.spec
  Shared.spec fixture
  Private.spec gate timings

-- | The consent rules, read from a given environment rather than this
-- process's, so they are checked without a session.
consent ∷ Spec
consent = do
  it "accepts the desktop opt-in for one run, on either platform" $ do
    consentFrom "darwin" [("HETOIMASIA_NATIVE_SESSION", "desktop")] `shouldBe` Right Desktop
    consentFrom "linux" [("HETOIMASIA_NATIVE_SESSION", "desktop")] `shouldBe` Right Desktop

  it "accepts an isolated X11 display only on Linux, and only for the display it names" $ do
    consentFrom "linux" [("HETOIMASIA_NATIVE_SESSION", "isolated-x11::7"), ("DISPLAY", ":7")] `shouldBe` Right (IsolatedX11 ":7")
    consentFrom "linux" [("HETOIMASIA_NATIVE_SESSION", "isolated-x11::7"), ("DISPLAY", ":8")] `shouldSatisfy` refused
    consentFrom "darwin" [("HETOIMASIA_NATIVE_SESSION", "isolated-x11::7"), ("DISPLAY", ":7")] `shouldSatisfy` refused

  it "takes nothing else as consent: an unset or empty variable, another value, a bare DISPLAY, or CI" $ do
    consentFrom "linux" [] `shouldBe` Left NoConsent
    consentFrom "linux" [("HETOIMASIA_NATIVE_SESSION", "")] `shouldBe` Left NoConsent
    consentFrom "linux" [("HETOIMASIA_NATIVE_SESSION", "isolated-wayland:wayland-1")] `shouldSatisfy` refused
    consentFrom "linux" [("DISPLAY", ":0"), ("CI", "true")] `shouldBe` Left NoConsent
  where
    refused = either (const True) (const False)
