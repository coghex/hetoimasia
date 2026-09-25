{-# LANGUAGE AllowAmbiguousTypes #-}

-- | The roots' ownership decisions over a stand-in native layer.
--
-- Every example asserts the order of recorded native calls, or what the roots
-- answered, never a time. Nothing here creates a Vulkan object.
module Test.GPU.Vulkan.Native.Roots (spec) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, writeTVar)
import Control.Exception (AsyncException, Exception, SomeException, fromException, try)
import Control.Monad (void)
import qualified Data.ByteString as ByteString
import Data.Either (isRight)
import Data.Maybe (isJust)
import Data.Word (Word64)
import Hetoimasia.GPU.Model (SessionFailureCause (DeviceLost), SessionState (..), sessionState)
import Hetoimasia.GPU.Model.Budget (BudgetKind (TargetRecordBudget))
import Hetoimasia.GPU.Model.Identity (TargetClass (..), TargetId)
import Hetoimasia.GPU.Vulkan.Native.Naming (NativeObjectKind (..), maximumNameBytes, surfaceName)
import Hetoimasia.GPU.Vulkan.Native.Profile (NoCompatibleDevice (..), TargetRejection (..))
import Hetoimasia.GPU.Vulkan.Native.Roots
import Test.GPU.Vulkan.Native.StandIn
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "Roots" $ do
  describe "construction" $ do
    it "creates the instance, then the messenger, then the device against the bootstrap surface" $ do
      (standIn, roots) ← fresh
      _ ← startRoots roots standardRequest
      answer ← admitRootTarget roots RequiredTarget (surfaceNumbered standIn 10)
      answer `shouldSatisfy` isRight
      calls standIn
        `shouldReturn` [ OfferedInstance
                       , CreatedInstance
                           [ "VK_KHR_surface"
                           , "VK_KHR_stand_in_surface"
                           , "VK_EXT_debug_utils"
                           , "VK_KHR_get_surface_capabilities2"
                           , "VK_EXT_surface_maintenance1"
                           , "VK_KHR_portability_enumeration"
                           ]
                       , CreatedMessenger
                       , QueriedDevices 10
                       , CreatedDevice "stand-in device" 0
                       ]

    it "refuses to start twice" $ do
      (_, roots) ← fresh
      _ ← startRoots roots standardRequest
      raised @RootsAlreadyStarted (startRoots roots standardRequest) `shouldReturn` True

    it "refuses a target before the instance exists, leaving its surface with its creator" $ do
      (standIn, roots) ← fresh
      raised @RootsNotStarted (admitRootTarget roots RequiredTarget (surfaceNumbered standIn 10)) `shouldReturn` True
      calls standIn `shouldReturn` []

    describe "rolls back exactly what exists, child before parent, whichever step fails" $ do
      let failingAt at expected = do
            (standIn, roots) ← fresh
            script standIn at Fails
            outcome ← try @SomeException $ do
              _ ← startRoots roots standardRequest
              admitRootTarget roots RequiredTarget (surfaceNumbered standIn 10)
            outcome `shouldSatisfy` either (isJust . fromException @StandInFailure) (const False)
            before ← length <$> calls standIn
            _ ← try @SomeException (retireRoots roots)
            _ ← try @SomeException (destroyRoots roots)
            drop before <$> calls standIn `shouldReturn` expected
      it "at the instance" $ failingAt AtCreateInstance []
      it "at the messenger" $ failingAt AtCreateMessenger [DestroyedInstance]
      it "at the device query" $ failingAt AtQueryDevices [DestroyedMessenger, DestroyedInstance]
      it "at the device" $ failingAt AtCreateDevice [DestroyedMessenger, DestroyedInstance]

    it "fails startup structurally when no device can serve the bootstrap surface, and rolls back" $ do
      (standIn, roots) ← fresh
      _ ← startRoots roots standardRequest
      outcome ← try (admitRootTarget roots RequiredTarget (surfaceNumbered standIn unsupportedSurface))
      case outcome of
        Left (NoCompatibleDevice [(name, _)]) → name `shouldBe` "stand-in device"
        other → fail ("expected no compatible device, but: " <> either show (const "an admission") other)
      _ ← retireRoots roots
      _ ← destroyRoots roots
      calls standIn
        `shouldReturn'` [QueriedDevices unsupportedSurface, DestroyedMessenger, DestroyedInstance]

    it "owns every handle it created even when a cancellation arrives at the creation's handoff" $ do
      -- The messenger's creation holds, as a native call does, until it is
      -- released; a cancellation aimed at it meanwhile is delivered after it
      -- returns, whenever that turns out to be, and the handle is owned either
      -- way.
      (standIn, roots) ← fresh
      gate ← newTVarIO False
      script standIn AtCreateMessenger (HoldsUntil gate)
      finished ← newEmptyMVar
      starter ← forkIO (try @SomeException (startRoots roots standardRequest) >>= putMVar finished)
      awaitCall standIn CreatedMessenger
      _ ← forkIO (killThread starter)
      atomically (writeTVar gate True)
      _ ← takeMVar finished
      view ← atomically (readRootsView roots)
      viewMessenger view `shouldBe` RootLive
      _ ← retireRoots roots
      _ ← destroyRoots roots
      reverse . take 2 . reverse <$> calls standIn `shouldReturn` [DestroyedMessenger, DestroyedInstance]

  describe "targets" $ do
    it "keys every admitted target by the model's identity and records its designation" $ do
      (standIn, roots) ← started
      first ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      second ← admitted roots OptionalTarget (surfaceNumbered standIn 11)
      first `shouldSatisfy` (/= second)
      views ← atomically (readRootTargets roots)
      map (\view → (targetViewIdentity view, targetViewClass view, targetViewSurface view)) views
        `shouldBe` [(first, RequiredTarget, 10), (second, OptionalTarget, 11)]

    it "rejects a surface the session's queue family cannot present to, leaving everything else as it was" $ do
      (standIn, roots) ← started
      first ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      before ← atomically (readRootsView roots)
      rejected ← admitRootTarget roots RequiredTarget (surfaceNumbered standIn unsupportedSurface)
      after ← atomically (readRootsView roots)
      fmap (const ()) rejected `shouldBe` Left (TargetSurfaceUnsupported 0)
      after `shouldBe` before
      viewTargets after `shouldBe` [first]
      -- No second device was created for it, and its surface was not the
      -- roots' to destroy.
      devicesCreated standIn `shouldReturn` 1
      surfacesDestroyed standIn `shouldReturn` []

    it "never lets the bootstrap target own the device: retiring it leaves the device serving the others" $ do
      (standIn, roots) ← started
      bootstrap ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      second ← admitted roots RequiredTarget (surfaceNumbered standIn 11)
      retireRootTarget roots bootstrap
      view ← atomically (readRootsView roots)
      viewDevice view `shouldBe` RootLive
      viewTargets view `shouldBe` [second]
      third ← admitRootTarget roots OptionalTarget (surfaceNumbered standIn 12)
      third `shouldSatisfy` isRight
      devicesCreated standIn `shouldReturn` 1

    it "frees a retired target's record for a later one" $ do
      standIn ← newStandIn
      roots ← newStandInRoots standIn (testBudgets 1)
      _ ← startRoots roots standardRequest
      first ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      refused ← admitRootTarget roots RequiredTarget (surfaceNumbered standIn 11)
      fmap (const ()) refused `shouldBe` Left (TargetBudgetExhausted TargetRecordBudget)
      retireRootTarget roots first
      admitRootTarget roots RequiredTarget (surfaceNumbered standIn 12) >>= (`shouldSatisfy` isRight)

  describe "destruction" $ do
    it "destroys every surface, then the device, then the messenger, then the instance" $ do
      (standIn, roots) ← started
      first ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      second ← admitted roots OptionalTarget (surfaceNumbered standIn 11)
      before ← length <$> calls standIn
      retireRootTarget roots first
      retireRootTarget roots second
      _ ← retireRoots roots
      destroyRoots roots `shouldReturn` Just ()
      drop before <$> calls standIn
        `shouldReturn` [DestroyedSurface 10, DestroyedSurface 11, DestroyedDevice, DestroyedMessenger, DestroyedInstance]

    it "refuses to destroy the device while a target remains, destroying nothing" $ do
      (standIn, roots) ← started
      target ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      before ← length <$> calls standIn
      retained ← try (retireRoots roots)
      fmap (const ()) retained `shouldBe` Left (TargetsRemain [target])
      raised @RootsRetained (destroyRoots roots) `shouldReturn` True
      drop before <$> calls standIn `shouldReturn` []

    it "retains the device and the instance behind a surface whose destruction failed, and never retries it" $ do
      (standIn, roots) ← started
      target ← admitted roots RequiredTarget (surfaceFailing standIn 10)
      raised @SurfaceDestructionFailed (retireRootTarget roots target) `shouldReturn` True
      raised @SurfaceDestructionFailed (retireRootTarget roots target) `shouldReturn` True
      raised @RootsRetained (retireRoots roots) `shouldReturn` True
      raised @RootsRetained (destroyRoots roots) `shouldReturn` True
      surfacesDestroyed standIn `shouldReturn` [10]
      times standIn DestroyedDevice `shouldReturn` 0
      times standIn DestroyedInstance `shouldReturn` 0
      targets ← atomically (readRootTargets roots)
      map targetViewUncertain targets `shouldSatisfy` all isJust

    it "records a surface destruction that raised outright as uncertain, and never runs it again" $ do
      (standIn, roots) ← started
      target ← admitted roots RequiredTarget (surfaceThrowing standIn 10)
      raised @SurfaceDestructionFailed (retireRootTarget roots target) `shouldReturn` True
      raised @SurfaceDestructionFailed (retireRootTarget roots target) `shouldReturn` True
      surfacesDestroyed standIn `shouldReturn` [10]
      targets ← atomically (readRootTargets roots)
      map targetViewUncertain targets `shouldSatisfy` all isJust
      raised @RootsRetained (retireRoots roots) `shouldReturn` True

    it "records a surface destruction a cancellation ended part-way as uncertain, and never runs it again" $ do
      (standIn, roots) ← started
      gate ← newTVarIO False
      target ← admitted roots RequiredTarget (surfaceWaiting standIn 10 gate)
      finished ← newEmptyMVar
      retiring ← forkIO (try @SomeException (retireRootTarget roots target) >>= putMVar finished)
      awaitCall standIn (DestroyedSurface 10)
      killThread retiring
      outcome ← takeMVar finished
      outcome `shouldSatisfy` either (isJust . fromException @AsyncException) (const False)
      targets ← atomically (readRootTargets roots)
      map targetViewUncertain targets `shouldSatisfy` all isJust
      atomically (writeTVar gate True)
      raised @SurfaceDestructionFailed (retireRootTarget roots target) `shouldReturn` True
      surfacesDestroyed standIn `shouldReturn` [10]

    it "retains the messenger and the instance behind a device whose destruction failed, and never retries it" $ do
      (standIn, roots) ← started
      target ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      retireRootTarget roots target
      script standIn AtDestroyDevice Fails
      raised @RootDestructionFailed (retireRoots roots) `shouldReturn` True
      raised @RootsRetained (retireRoots roots) `shouldReturn` True
      raised @RootsRetained (destroyRoots roots) `shouldReturn` True
      times standIn DestroyedDevice `shouldReturn` 1
      times standIn DestroyedMessenger `shouldReturn` 0
      times standIn DestroyedInstance `shouldReturn` 0

    it "retains the instance behind a messenger whose destruction failed" $ do
      (standIn, roots) ← started
      script standIn AtDestroyMessenger Fails
      _ ← retireRoots roots
      raised @RootDestructionFailed (destroyRoots roots) `shouldReturn` True
      raised @RootsRetained (destroyRoots roots) `shouldReturn` True
      times standIn DestroyedMessenger `shouldReturn` 1
      times standIn DestroyedInstance `shouldReturn` 0

    it "answers nothing to prove for roots whose instance was never created" $ do
      (_, roots) ← fresh
      _ ← retireRoots roots
      destroyRoots roots `shouldReturn` Nothing

  describe "device loss" $ do
    it "closes admission at once, fails the session, and raises the loss as itself" $ do
      (standIn, roots) ← started
      first ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      script standIn AtSupport Loses
      lost ← try (admitRootTarget roots RequiredTarget (surfaceNumbered standIn 11))
      case lost of
        Left loss → lostDuring loss `shouldBe` "vkGetPhysicalDeviceSurfaceSupportKHR"
        Right _ → fail "the loss was not raised"
      before ← length <$> calls standIn
      closed ← admitRootTarget roots RequiredTarget (surfaceNumbered standIn 12)
      fmap (const ()) closed `shouldBe` Left TargetAdmissionClosed
      -- Refused before any native call: nothing is recreated or retried.
      drop before <$> calls standIn `shouldReturn` []
      model ← atomically (readRootsModel roots)
      sessionState model `shouldBe` SessionFailed DeviceLost
      raised @GraphicsDeviceLost (checkRoots roots) `shouldReturn` True
      view ← atomically (readRootsView roots)
      viewAdmitting view `shouldBe` False
      viewTargets view `shouldBe` [first]

    it "still retires child before parent after a loss, destroying the lost device without recreating it" $ do
      (standIn, roots) ← started
      first ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      script standIn AtSupport Loses
      void (try @GraphicsDeviceLost (admitRootTarget roots RequiredTarget (surfaceNumbered standIn 11)))
      before ← length <$> calls standIn
      retireRootTarget roots first
      retireRoots roots `shouldReturn` "destroyed the device stand-in device after its loss"
      _ ← destroyRoots roots
      drop before <$> calls standIn
        `shouldReturn` [DestroyedSurface 10, DestroyedDevice, DestroyedMessenger, DestroyedInstance]
      devicesCreated standIn `shouldReturn` 1

    it "treats an unknown outcome as neither success nor loss" $ do
      (standIn, roots) ← started
      _ ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      script standIn AtSupport Fails
      raised @StandInFailure (admitRootTarget roots RequiredTarget (surfaceNumbered standIn 11)) `shouldReturn` True
      view ← atomically (readRootsView roots)
      viewLoss view `shouldBe` Nothing
      viewAdmitting view `shouldBe` True
      length (viewTargets view) `shouldBe` 1
      model ← atomically (readRootsModel roots)
      sessionState model `shouldBe` SessionRunning
      checkRoots roots `shouldReturn` ()

  describe "names" $ do
    it "names the messenger, the device, its queue and every surface from existing identities once the device exists" $ do
      (standIn, roots) ← fresh
      offerNaming standIn
      _ ← startRoots roots standardRequest
      first ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      second ← admitted roots OptionalTarget (surfaceNumbered standIn 11)
      namesGiven standIn
        `shouldReturn` [ (ObjectMessenger, 2, "hetoimasia messenger")
                       , (ObjectDevice, 3, "hetoimasia device")
                       , (ObjectQueue, 4, "hetoimasia queue family 0 index 0")
                       , (ObjectSurface, 10, surfaceName first)
                       , (ObjectSurface, 11, surfaceName second)
                       ]
      (map (\(_, _, name) → ByteString.length name) <$> namesGiven standIn) `shouldReturn'''` all (<= maximumNameBytes)
      -- Nothing is named before the device that names it exists, and each
      -- root is named once.
      recorded ← calls standIn
      takeWhile (not . isNamed) recorded `shouldSatisfy` elem (CreatedDevice "stand-in device" 0)
      times standIn (QueriedQueue 0) `shouldReturn` 1
      surfaceName first `shouldBe` "target 0.1 surface"

    it "names nothing, asks for no queue and fails nothing when the device offers no naming" $ do
      (standIn, roots) ← started
      _ ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      _ ← admitted roots RequiredTarget (surfaceNumbered standIn 11)
      namesGiven standIn `shouldReturn` []
      times standIn (QueriedQueue 0) `shouldReturn` 0

    it "leaves a surface whose naming raised unadmitted and its creator's, and admits it named later" $ do
      (standIn, roots) ← fresh
      offerNaming standIn
      _ ← startRoots roots standardRequest
      _ ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      failNaming standIn ObjectSurface
      raised @NamingFailure (admitRootTarget roots OptionalTarget (surfaceNumbered standIn 11)) `shouldReturn` True
      -- The roots hold no record of it and never destroy it: it is still its
      -- creator's.
      map targetViewSurface <$> atomically (readRootTargets roots) `shouldReturn` [10]
      surfacesDestroyed standIn `shouldReturn` []
      restoreNaming standIn ObjectSurface
      target ← admitted roots OptionalTarget (surfaceNumbered standIn 11)
      map targetViewSurface <$> atomically (readRootTargets roots) `shouldReturn` [10, 11]
      last <$> namesGiven standIn `shouldReturn` (ObjectSurface, 11, surfaceName target)

    it "keeps a device whose naming raised owned for retirement, and names it again at the next admission" $ do
      (standIn, roots) ← fresh
      offerNaming standIn
      _ ← startRoots roots standardRequest
      failNaming standIn ObjectDevice
      raised @NamingFailure (admitRootTarget roots RequiredTarget (surfaceNumbered standIn 10)) `shouldReturn` True
      view ← atomically (readRootsView roots)
      viewDevice view `shouldBe` RootLive
      viewTargets view `shouldBe` []
      restoreNaming standIn ObjectDevice
      _ ← admitted roots RequiredTarget (surfaceNumbered standIn 10)
      map (\(kind, _, _) → kind) <$> namesGiven standIn
        `shouldReturn` [ObjectMessenger, ObjectDevice, ObjectMessenger, ObjectDevice, ObjectQueue, ObjectSurface]
      devicesCreated standIn `shouldReturn` 1

-- | Fresh roots over a fresh stand-in, with the default budgets.
fresh ∷ IO (StandIn, StandInRoots)
fresh = do
  standIn ← newStandIn
  roots ← newStandInRoots standIn (testBudgets 16)
  pure (standIn, roots)

-- | Fresh roots whose instance and messenger exist.
started ∷ IO (StandIn, StandInRoots)
started = do
  (standIn, roots) ← fresh
  _ ← startRoots roots standardRequest
  pure (standIn, roots)

-- | Admit one target, failing the example if it was refused.
admitted ∷ StandInRoots → TargetClass → TargetSurface → IO TargetId
admitted roots classification surface =
  admitRootTarget roots classification surface >>= either (fail . ("the target was refused: " <>) . show) pure

-- | Whether the action raised this exception type.
raised ∷ ∀ e a. Exception e ⇒ IO a → IO Bool
raised action = either (isJust . fromException @e) (const False) <$> try @SomeException action

isNamed ∷ Call → Bool
isNamed = \case
  Named {} → True
  _ → False

shouldReturn''' ∷ IO a → (a → Bool) → IO ()
shouldReturn''' action predicate = action >>= \value → predicate value `shouldBe` True

-- | How many devices the roots have created.
devicesCreated ∷ StandIn → IO Int
devicesCreated standIn = length . filter created <$> calls standIn
  where
    created = \case
      CreatedDevice _ _ → True
      _ → False

-- | Every surface destruction, in order.
surfacesDestroyed ∷ StandIn → IO [Word64]
surfacesDestroyed standIn = (\recorded → [handle | DestroyedSurface handle ← recorded]) <$> calls standIn

-- | How many times this exact call was made.
times ∷ StandIn → Call → IO Int
times standIn call = length . filter (== call) <$> calls standIn

shouldReturn' ∷ IO [Call] → [Call] → IO ()
shouldReturn' action expected = do
  recorded ← action
  filter (`elem` expected) recorded `shouldBe` expected
