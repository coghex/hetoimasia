-- | Examples for the loader integration capability a loader-aware session
-- takes, and for the instance-extension query it answers.
--
-- Every example enters a session over the test seam with a scripted
-- capability, which records its calls beside the native ones, so an example
-- asserts where the capability's loader is handed to GLFW — after the
-- initialization hints and before @glfwInit@ — where it is reset, and that a
-- refusal happened before any native call at all. Nothing here initializes
-- GLFW or finds a Vulkan loader.
module Test.GLFW.Interop (spec) where

import Control.Concurrent (forkIO)
import Control.Exception (ErrorCall (ErrorCall), SomeException, throwIO, try)
import qualified Data.ByteString as ByteString
import qualified Data.ByteString.Char8 as Char8
import Data.IORef (newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailures, withScoped)
import Hetoimasia.GLFW.Internal.Interop (InteropUnavailable (..), requiredInstanceExtensions)
import Hetoimasia.GLFW.Internal.Session (endSessionIntegration)
import Hetoimasia.GLFW.Seam
import Hetoimasia.GLFW.Session
import Test.GLFW.Support (boundedExample, caughtAs, entered, onThread, originOf, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = do
  describe "GLFW loader integration" $ do
    it "hands GLFW the capability's loader between the hints and glfwInit, and restores the default after termination"
      (boundedExample testOrderedInstallAndReset)
    it "makes no loader call at all in a window-only session"
      (boundedExample testWindowOnlyMakesNoLoaderCall)
    it "refuses a stale, a foreign, and an already-used capability before any native call"
      (boundedExample testRefusalsBeforeNativeEffect)
    it "restores the default after a failed initialization, with the guard vacant for the next session"
      (boundedExample testResetAfterFailedInitialization)
    it "leaves GLFW uninitialized and the guard vacant when the capability itself fails"
      (boundedExample testFailingCapability)
    it "retains the capability and poisons the guard when the reset raises"
      (boundedExample testUncertainReset)
    it "retains the capability and poisons the guard when termination could not be established"
      (boundedExample testUncertainTermination)
    it "keeps a capability whose scope ends while its session still holds it, until the session restores it"
      (boundedExample testScopeEndsWhileInstalled)

  describe "GLFW required instance extensions" $ do
    it "copies every name while the session is live, complete and readable after termination"
      (boundedExample testExtensionsCopied)
    it "refuses another thread and an ended session before any native call"
      (boundedExample testExtensionsOwnerOnly)
    it "refuses a window-only session without asking GLFW"
      (boundedExample testExtensionsNeedCapability)
    it "diagnoses a platform where GLFW finds no Vulkan loader, with what it reported"
      (boundedExample testExtensionsUnsupported)
    it "diagnoses a platform that answers no required extensions"
      (boundedExample testExtensionsNone)

-- ---------------------------------------------------------------------------
-- The capability

testOrderedInstallAndReset ∷ Expectation
testOrderedInstallAndReset = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  during ← asProcessMainThread seam (integrated seam integration (\_ → readIntegrationUse integration))
  during `shouldBe` IntegrationInstalled
  readIntegrationUse integration `shouldReturn` IntegrationRestored
  seamCalls seam
    `shouldReturn` [ QueryPlatformSupported X11
                   , CreateErrorCallback
                   , AttachErrorCallback
                   , SetInitHints X11
                   , InstallVulkanLoader
                   , Initialize
                   , QueryPlatform
                   , CreateMonitorCallback
                   , AttachMonitorCallback
                   , QueryMonitors
                   , QueryPrimaryMonitor
                   , DetachMonitorCallback
                   , Terminate
                   , ResetVulkanLoader
                   , DetachErrorCallback
                   , FreeErrorCallback
                   , FreeMonitorCallback
                   ]
  endSessionIntegration integration
  readIntegrationUse integration `shouldReturn` IntegrationEnded

testWindowOnlyMakesNoLoaderCall ∷ Expectation
testWindowOnlyMakesNoLoaderCall = do
  seam ← newSeam defaultScript
  asProcessMainThread seam (entered seam (\_ → pure ()))
  calls ← seamCalls seam
  filter (`elem` [InstallVulkanLoader, ResetVulkanLoader]) calls `shouldBe` []

testRefusalsBeforeNativeEffect ∷ Expectation
testRefusalsBeforeNativeEffect = do
  seam ← newSeam defaultScript
  other ← newSeam defaultScript
  stale ← seamIntegration seam defaultIntegrationScript
  endSessionIntegration stale
  foreignCapability ← seamIntegration other defaultIntegrationScript
  used ← seamIntegration seam defaultIntegrationScript
  refusals ← asProcessMainThread seam $ do
    (staleRefusal, staleCaught) ← caughtAs (integrated seam stale (\_ → pure ()))
    (foreignRefusal, _) ← caughtAs (integrated seam foreignCapability (\_ → pure ()))
    beforeUse ← seamCalls seam
    integrated seam used (\_ → pure ())
    afterUse ← length <$> seamCalls seam
    (usedRefusal, _) ← caughtAs (integrated seam used (\_ → pure ()))
    afterRefusal ← length <$> seamCalls seam
    pure (staleRefusal, originOf staleCaught, foreignRefusal, beforeUse, usedRefusal, afterUse == afterRefusal)
  let (staleRefusal, staleOrigin, foreignRefusal, beforeUse, usedRefusal, nothingMore) = refusals
  staleRefusal `shouldBe` IntegrationStale
  staleOrigin `shouldBe` Just ("glfw", "enter session", [("backend", "x11")])
  foreignRefusal `shouldBe` IntegrationForeign
  usedRefusal `shouldBe` IntegrationAlreadyUsed IntegrationRestored
  -- Neither the stale nor the foreign capability reached a native call, and
  -- the refused reuse added none either.
  beforeUse `shouldBe` []
  nothingMore `shouldBe` True
  -- A refused capability is left as it was found.
  readIntegrationUse foreignCapability `shouldReturn` IntegrationReady
  readIntegrationUse stale `shouldReturn` IntegrationEnded
  seamCalls other `shouldReturn` []
  -- Every refusal vacated the guard.
  asProcessMainThread seam (entered seam (\_ → pure ()))

testResetAfterFailedInitialization ∷ Expectation
testResetAfterFailedInitialization = do
  failing ← newIORef True
  seam ←
    newSeam
      defaultScript
        { scriptInitialize = \reporter → do
            fail' ← readIORef failing
            writeIORef failing False
            if fail'
              then reportError reporter 0x00010008 "X11: The DISPLAY environment variable is missing" >> pure False
              else pure True
        }
  integration ← seamIntegration seam defaultIntegrationScript
  (failure, _) ← asProcessMainThread seam (caughtAs (integrated seam integration (\_ → pure ())))
  nativeOutcome failure `shouldBe` NativeCallFailed
  readIntegrationUse integration `shouldReturn` IntegrationRestored
  seamCalls seam
    `shouldReturn` [ QueryPlatformSupported X11
                   , CreateErrorCallback
                   , AttachErrorCallback
                   , SetInitHints X11
                   , InstallVulkanLoader
                   , Initialize
                   , ResetVulkanLoader
                   , DetachErrorCallback
                   , FreeErrorCallback
                   ]
  -- The guard is vacant: a window-only session enters, and makes no loader call.
  asProcessMainThread seam (entered seam (\_ → pure ()))

testFailingCapability ∷ Expectation
testFailingCapability = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript {integrationInstall = \_ → throwIO (ErrorCall "loader refused")}
  (ErrorCall message, _) ← asProcessMainThread seam (caughtAs (integrated seam integration (\_ → pure ())))
  message `shouldBe` "loader refused"
  readIntegrationUse integration `shouldReturn` IntegrationRestored
  seamCalls seam
    `shouldReturn` [ QueryPlatformSupported X11
                   , CreateErrorCallback
                   , AttachErrorCallback
                   , SetInitHints X11
                   , InstallVulkanLoader
                   , ResetVulkanLoader
                   , DetachErrorCallback
                   , FreeErrorCallback
                   ]
  asProcessMainThread seam (entered seam (\_ → pure ()))

testUncertainReset ∷ Expectation
testUncertainReset = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript {integrationReset = \_ → throwIO (ErrorCall "reset lost")}
  (ErrorCall message, caught) ← asProcessMainThread seam (caughtAs (integrated seam integration (\_ → pure ())))
  message `shouldBe` "reset lost"
  -- The failed reset is the loader part's own release failure.
  map cleanupFailureLabel (cleanupFailures caught) `shouldBe` ["glfw vulkan loader"]
  readIntegrationUse integration `shouldReturn` IntegrationUncertain
  poisonedAfterwards seam
  -- A retained capability does not end with its scope.
  endSessionIntegration integration
  readIntegrationUse integration `shouldReturn` IntegrationUncertain

testUncertainTermination ∷ Expectation
testUncertainTermination = do
  seam ← newSeam defaultScript {scriptTerminate = \_ → throwIO (ErrorCall "terminate lost")}
  integration ← seamIntegration seam defaultIntegrationScript
  (ErrorCall message, _) ← asProcessMainThread seam (caughtAs (integrated seam integration (\_ → pure ())))
  message `shouldBe` "terminate lost"
  readIntegrationUse integration `shouldReturn` IntegrationUncertain
  calls ← seamCalls seam
  -- The reset still ran, after the termination that raised; what GLFW holds is
  -- unknown all the same, so the capability is retained.
  dropWhile (/= Terminate) calls `shouldSatisfy` (\rest → take 2 rest == [Terminate, ResetVulkanLoader])
  poisonedAfterwards seam

testScopeEndsWhileInstalled ∷ Expectation
testScopeEndsWhileInstalled = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  (still, _) ←
    asProcessMainThread seam $
      integrated seam integration (\_ → caughtAs (endSessionIntegration integration))
  still `shouldBe` IntegrationStillInstalled IntegrationInstalled
  readIntegrationUse integration `shouldReturn` IntegrationRestored
  endSessionIntegration integration
  readIntegrationUse integration `shouldReturn` IntegrationEnded

-- ---------------------------------------------------------------------------
-- Instance extensions

testExtensionsCopied ∷ Expectation
testExtensionsCopied = do
  seam ← newSeam defaultScript
  -- A name far longer than the throwaway proof shim's fixed stride, so a
  -- bounded copy could not pass.
  let long = Char8.pack ("VK_EXT_" <> replicate 300 'x')
      names = ["VK_KHR_surface", long, "VK_KHR_xlib_surface"]
  integration ← seamIntegration seam defaultIntegrationScript {integrationExtensions = \_ → pure (Just names)}
  copied ← asProcessMainThread seam (integrated seam integration requiredInstanceExtensions)
  copied `shouldBe` names
  map ByteString.length copied `shouldBe` [14, 307, 19]
  calls ← seamCalls seam
  takeWhile (/= DetachMonitorCallback) (dropWhile (/= QueryPrimaryMonitor) calls)
    `shouldBe` [QueryPrimaryMonitor, QueryVulkanSupported, QueryRequiredExtensions]

testExtensionsOwnerOnly ∷ Expectation
testExtensionsOwnerOnly = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript
  (fromWorker, afterEnd) ← asProcessMainThread seam $ do
    (worker, retained) ←
      integrated seam integration $ \session → do
        worker ← onThread forkIO (caughtAs (requiredInstanceExtensions session))
        pure (worker, session)
    ended ← caughtAs (requiredInstanceExtensions retained)
    pure (fst worker, fst ended)
  fromWorker `shouldBe` NotSessionOwner
  afterEnd `shouldBe` SessionEnded
  calls ← seamCalls seam
  filter (`elem` [QueryVulkanSupported, QueryRequiredExtensions]) calls `shouldBe` []

testExtensionsNeedCapability ∷ Expectation
testExtensionsNeedCapability = do
  seam ← newSeam defaultScript
  (refusal, caught) ← asProcessMainThread seam (entered seam (caughtAs . requiredInstanceExtensions))
  refusal `shouldBe` SessionNotLoaderAware
  originOf caught `shouldBe` Just ("glfw", "query required instance extensions", [])
  calls ← seamCalls seam
  filter (`elem` [QueryVulkanSupported, QueryRequiredExtensions]) calls `shouldBe` []

testExtensionsUnsupported ∷ Expectation
testExtensionsUnsupported = do
  seam ← newSeam defaultScript
  integration ←
    seamIntegration
      seam
      defaultIntegrationScript
        { integrationSupported = \reporter → do
            reportError reporter 0x00010006 "Vulkan: Loader not found"
            pure False
        }
  refusal ← asProcessMainThread seam (integrated seam integration (fmap fst . caughtAs . requiredInstanceExtensions))
  case refusal of
    VulkanUnsupported reports →
      map (\reported → (nativeErrorCode reported, nativeErrorDescription reported)) (reportedErrors reports)
        `shouldBe` [(0x00010006, "Vulkan: Loader not found")]
    other → unexpected ("the query was refused with " <> show other)
  calls ← seamCalls seam
  filter (== QueryRequiredExtensions) calls `shouldBe` []

testExtensionsNone ∷ Expectation
testExtensionsNone = do
  seam ← newSeam defaultScript
  integration ← seamIntegration seam defaultIntegrationScript {integrationExtensions = \_ → pure Nothing}
  refusal ← asProcessMainThread seam (integrated seam integration (fmap fst . caughtAs . requiredInstanceExtensions))
  refusal `shouldSatisfy` \case
    NoRequiredExtensions _ → True
    _ → False

-- ---------------------------------------------------------------------------
-- Fixtures

integrated ∷ Seam → SessionIntegration → (Session → IO r) → IO r
integrated seam integration = withScoped (seamIntegratedSession seam integration defaultSessionConfig)

-- | A later entry over the seam is refused as poisoned, before any native call.
poisonedAfterwards ∷ Seam → Expectation
poisonedAfterwards seam = do
  before ← length <$> seamCalls seam
  outcome ← asProcessMainThread seam (try (entered seam (\_ → pure ())))
  case outcome of
    Right () → unexpected "a later session entered a poisoned guard"
    Left (caught ∷ SomeException) → do
      (misuse, _) ← caughtAs (throwIO caught)
      misuse `shouldBe` SessionPoisoned
  after ← length <$> seamCalls seam
  after `shouldBe` before
