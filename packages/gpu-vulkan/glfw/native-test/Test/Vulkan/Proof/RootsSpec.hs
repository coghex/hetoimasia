{-# LANGUAGE OverloadedRecordDot #-}

-- | VK-7's verdict: pure assertions over what "Test.Vulkan.Proof.Roots"
-- observed, computed after its session, its instance and its diagnostic
-- lifetime have all ended.
--
-- A session that stopped fails every example with the reason it stopped.
--
-- The thread examples read the OS thread each native call ran on, recorded at
-- the call itself. The graphics owner is one serialized Haskell thread, not a
-- promise of OS-thread affinity, so the owner's calls are required to share
-- one Haskell thread and each to run off the main OS thread, rather than all
-- to share one OS thread.
module Test.Vulkan.Proof.RootsSpec (spec) where

import Data.List (nub)
import qualified Data.Text as Text
import Test.Hspec

import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticVerdict (..)
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (RootStanding (..), RootsView (..))
import Hetoimasia.Runtime.GLFW (TargetStanding (..))
import Test.Vulkan.Proof.Roots

spec ∷ RootsOutcome → Spec
spec outcome = describe "VK-7 Vulkan roots" $ do
  it "established every step of its session" $
    onFacts outcome (\_ → pure ())

  it "made no native call that raised" $
    onFacts outcome $ \facts →
      [(call.callName, reason) | call ← facts.rootsCalls, Just reason ← [call.callRaised]] `shouldBe` []

  it "created each window's surface through GLFW on the process main thread" $
    onFacts outcome $ \facts → do
      let created = named "glfwCreateWindowSurface" facts
      length created `shouldBe` 2
      map (.callOsThread) created `shouldSatisfy` all (== facts.rootsMainOsThread)
      map (.callHaskellThread) created `shouldSatisfy` all (== facts.rootsMainHaskellThread)

  it "made every root's creation and destruction, and every surface's destruction, on the graphics owner's thread" $
    onFacts outcome $ \facts → do
      let owned = filter ((`elem` ownerCalls) . (.callName)) facts.rootsCalls
      -- Instance, messenger, device query and creation, support query, two
      -- surface destructions, device, messenger and instance destruction.
      length owned `shouldBe` 10
      nub (map (.callHaskellThread) owned) `shouldSatisfy` (\threads → length threads == 1 && facts.rootsMainHaskellThread `notElem` threads)
      map (.callOsThread) owned `shouldSatisfy` all (/= facts.rootsMainOsThread)

  it "created the instance, then the explicit messenger, then one device against the first window's surface" $
    onFacts outcome $ \facts →
      filter (`elem` creationCalls) (map (.callName) facts.rootsCalls)
        `shouldBe` [ "vkCreateInstance"
                   , "vkCreateDebugUtilsMessengerEXT"
                   , "glfwCreateWindowSurface"
                   , "vkEnumeratePhysicalDevices"
                   , "vkCreateDevice"
                   , "glfwCreateWindowSurface"
                   , "vkGetPhysicalDeviceSurfaceSupportKHR"
                   ]

  it "admitted both windows' targets, each required, on that one shared device" $
    onFacts outcome $ \facts → do
      map fst facts.rootsTargets `shouldBe` [RequiredTarget, RequiredTarget]
      nub (map snd facts.rootsTargets) `shouldSatisfy` ((== 2) . length)
      map snd facts.rootsTargets `shouldSatisfy` notElem 0
      facts.rootsBeforeClose.viewDevice `shouldBe` RootLive
      length facts.rootsBeforeClose.viewTargets `shouldBe` 2

  it "retired the first-created window's target alone, leaving the device, the instance and the second target live" $
    onFacts outcome $ \facts → do
      facts.rootsAfterClose.viewDevice `shouldBe` RootLive
      facts.rootsAfterClose.viewInstance `shouldBe` RootLive
      facts.rootsAfterClose.viewDeviceName `shouldBe` facts.rootsBeforeClose.viewDeviceName
      length facts.rootsAfterClose.viewTargets `shouldBe` 1
      facts.rootsSecondAfterClose `shouldBe` Just TargetUsable
      facts.rootsWindowsAfterClose `shouldBe` 1

  it "destroyed every surface, then the device, then the explicit messenger, then the instance" $
    onFacts outcome $ \facts →
      filter (`elem` destructionCalls) (map (.callName) facts.rootsCalls)
        `shouldBe` ["vkDestroySurfaceKHR", "vkDestroySurfaceKHR", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]

  it "delivered every report, both messengers' teardown reports included, with the instance's destruction as the quiescence evidence" $
    onFacts outcome $ \facts → do
      let verdict = facts.rootsVerdict
          counters = verdict.verdictStatus.statusCounters
      -- No fixed count: how many reports a driver and the layer produce during
      -- teardown is platform-dependent. What is required is that the capture
      -- stayed live through both kinds and lost none of them.
      verdict.verdictQuiescent `shouldBe` True
      verdict.verdictUndelivered `shouldBe` 0
      verdict.verdictDelivered `shouldBe` counters.countAdmitted
      counters.countDropped `shouldBe` 0
      counters.countCaptureFailed `shouldBe` 0
      verdict.verdictConsumer `shouldSatisfy` \case
        ConsumerCompleted → True
        _ → False
      let (explicit, createInfo) = teardownReports facts.rootsCalls
      explicit + createInfo `shouldSatisfy` (<= counters.countOffered)

  it "reported no validation error" $
    onFacts outcome $ \facts →
      facts.rootsVerdict.verdictStatus.statusErrorLatched `shouldBe` False
  where
    named name facts = filter ((== name) . (.callName)) facts.rootsCalls
    ownerCalls =
      [ "vkCreateInstance"
      , "vkCreateDebugUtilsMessengerEXT"
      , "vkEnumeratePhysicalDevices"
      , "vkCreateDevice"
      , "vkGetPhysicalDeviceSurfaceSupportKHR"
      , "vkDestroySurfaceKHR"
      , "vkDestroyDevice"
      , "vkDestroyDebugUtilsMessengerEXT"
      , "vkDestroyInstance"
      ]
    creationCalls =
      [ "vkCreateInstance"
      , "vkCreateDebugUtilsMessengerEXT"
      , "glfwCreateWindowSurface"
      , "vkEnumeratePhysicalDevices"
      , "vkCreateDevice"
      , "vkGetPhysicalDeviceSurfaceSupportKHR"
      ]
    destructionCalls = ["vkDestroySurfaceKHR", "vkDestroyDevice", "vkDestroyDebugUtilsMessengerEXT", "vkDestroyInstance"]

onFacts ∷ RootsOutcome → (RootsFacts → Expectation) → Expectation
onFacts outcome check = case outcome of
  RootsStopped reason _ → expectationFailure ("the roots session stopped: " <> Text.unpack reason)
  RootsProved facts → check facts
