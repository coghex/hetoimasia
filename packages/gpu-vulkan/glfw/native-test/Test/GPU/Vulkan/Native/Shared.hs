{-# LANGUAGE OverloadedRecordDot #-}

-- | The initial required profile over the shared roots: #219's controller, run
-- through the fixture.
--
-- Every example shows which identity ran each native step from the calls
-- themselves, recorded where they ran: the instance, its messenger, the device
-- and every surface's destruction on the graphics owner's thread; every
-- surface's creation, and every dispatched operation, on the process main
-- thread. Each example's windows and targets are its own and are closed inside
-- it; the roots are shared, so a later example's target lands on the device an
-- earlier one caused to be created. What only the release of the roots can
-- show — their destruction order and the capture's final verdict — is checked
-- by the run once the session has been released, after Hspec has finished
-- ("Main").
module Test.GPU.Vulkan.Native.Shared (spec) where

import Control.Concurrent (isCurrentThreadBound, myThreadId)
import Control.Concurrent.STM (atomically)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe, shouldSatisfy)

import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.GLFW
  ( Readiness (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , handOverVulkanTarget
  , readReadiness
  , readVulkanRoots
  , readVulkanTargets
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (RootStanding (..), RootsView (..))
import Hetoimasia.Runtime.GLFW (GraphicsService, TargetStanding (..), graphicsAttachment, readTargetStanding)
import Test.GPU.Vulkan.Native.Fixture
import Test.Vulkan.Proof.Interop (osThread)
import Test.Vulkan.Proof.Roots (NativeCall (..))

spec ∷ Fixture → Spec
spec fixture = describe "the shared roots" $ do
  it "runs every dispatched operation on the process main thread that entered the session" $ do
    example ← myThreadId
    (thread, bound, os) ← onMain fixture (\_ → (,,) <$> myThreadId <*> isCurrentThreadBound <*> osThread)
    thread `shouldBe` fixtureMainThread fixture
    thread `shouldNotBe` example
    bound `shouldBe` True
    os `shouldBe` mainOsThread fixture

  it "creates the instance and its explicit messenger on the graphics owner's thread, never the main thread" $ do
    vulkan ← sharedHost fixture
    readiness ← awaitWithin 10 "the owner's startup" (settled <$> readReadiness (vulkanController vulkan))
    readiness `shouldBe` RootsReady
    calls ← nativeCalls fixture
    let created = [call | call ← calls, call.callName `elem` ["vkCreateInstance", "vkCreateDebugUtilsMessengerEXT"]]
    map (.callName) created `shouldBe` ["vkCreateInstance", "vkCreateDebugUtilsMessengerEXT"]
    ownerThreads calls created
    [call.callRaised | call ← created] `shouldBe` [Nothing, Nothing]

  it "hands two windows over as required targets on one shared device, and keeps the roots live when the first-created closes" $ do
    vulkan ← sharedHost fixture
    first ← createWindow fixture "hetoimasia VK-8 first"
    second ← createWindow fixture "hetoimasia VK-8 second"
    _ ← handOver fixture vulkan first
    secondService ← handOver fixture vulkan second
    before ← atomically (readVulkanRoots (vulkanController vulkan))
    targets ← atomically (readVulkanTargets (vulkanController vulkan))
    before.viewDevice `shouldBe` RootLive
    length before.viewTargets `shouldBe` 2
    length targets `shouldBe` 2
    calls ← nativeCalls fixture
    -- Surface creation is GLFW's, on the main thread; the device is the
    -- owner's, and there is one for the whole session.
    let surfaces = [call | call ← calls, call.callName == "glfwCreateWindowSurface"]
    length surfaces `shouldSatisfy` (>= 2)
    [call.callOsThread | call ← surfaces] `shouldSatisfy` all (== mainOsThread fixture)
    let devices = [call | call ← calls, call.callName == "vkCreateDevice"]
    length devices `shouldBe` 1
    ownerThreads calls devices

    closeWindow fixture first
    after ← atomically (readVulkanRoots (vulkanController vulkan))
    after.viewInstance `shouldBe` RootLive
    after.viewDevice `shouldBe` RootLive
    length after.viewTargets `shouldBe` 1
    standing vulkan secondService `shouldReturnJust` TargetUsable
    -- The closed window's surface went on the owner's thread.
    retired ← nativeCalls fixture
    let destroyed = [call | call ← retired, call.callName == "vkDestroySurfaceKHR"]
    destroyed `shouldSatisfy` (not . null)
    ownerThreads retired destroyed
    closeWindow fixture second

  it "serves a later example's target from the same device" $ do
    vulkan ← sharedHost fixture
    window ← createWindow fixture "hetoimasia VK-8 later"
    _ ← handOver fixture vulkan window
    view ← atomically (readVulkanRoots (vulkanController vulkan))
    view.viewDevice `shouldBe` RootLive
    calls ← nativeCalls fixture
    length [() | call ← calls, call.callName == "vkCreateDevice"] `shouldBe` 1
    closeWindow fixture window
  where
    settled = \case
      RootsPending → Nothing
      other → Just other
    -- Every call ran on one Haskell thread that is not the main one, and off
    -- the main OS thread. The owner is one serialized Haskell thread, not a
    -- promise of OS-thread affinity, so only the main thread is excluded.
    ownerThreads all' calls = do
      let owner = [call.callHaskellThread | call ← all', call.callName == "vkCreateInstance"]
      calls `shouldSatisfy` (not . null)
      [call.callHaskellThread | call ← calls] `shouldSatisfy` all (`elem` owner)
      [call.callHaskellThread | call ← calls] `shouldSatisfy` all (/= fixtureMainThread fixture)
      [call.callOsThread | call ← calls] `shouldSatisfy` all (/= mainOsThread fixture)

-- | Hand a window over as a required target on the main thread, and wait for
-- the owner to admit it.
handOver ∷ Fixture → VulkanHost () → WindowId → IO GraphicsService
handOver fixture vulkan window =
  onMain fixture (\host → handOverVulkanTarget host window RequiredTarget) >>= \case
    VulkanTargetHandedOver service → do
      admitted ←
        awaitWithin 10 "the target's admission" $
          readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service) >>= \case
            Nothing → pure Nothing
            Just TargetConstructing → pure Nothing
            Just other → pure (Just other)
      admitted `shouldBe` TargetUsable
      pure service
    other → do
      expectationFailure ("the window was not handed over: " <> show other)
      fail "unreachable"

standing ∷ VulkanHost () → GraphicsService → IO (Maybe TargetStanding)
standing vulkan service = atomically (readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service))

shouldReturnJust ∷ (Eq a, Show a) ⇒ IO (Maybe a) → a → IO ()
shouldReturnJust action expected = action >>= (`shouldBe` Just expected)
