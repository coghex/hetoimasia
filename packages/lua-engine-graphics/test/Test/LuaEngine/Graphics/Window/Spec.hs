-- | The window provider's examples, over the gated fake port, the real request admission, the real
-- instance leases and a real Lua owner. They need no window, display or GLFW session: the real windows are
-- the native suite's.
module Test.LuaEngine.Graphics.Window.Spec (spec) where

import Control.Concurrent.STM (atomically)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Vulkan.Diagnostics (defaultCaptureConfig)
import Hetoimasia.GPU.Vulkan.GLFW (VulkanHostConfig (..), vulkanHostConfig)
import Hetoimasia.LuaEngine.Graphics.Window.Configuration
import Hetoimasia.Runtime.GLFW (HostConfig (..), defaultHostConfig)
import Hetoimasia.LuaEngine.Graphics.Window.Port
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Test.Hspec
import qualified Test.LuaEngine.Graphics.Window.Request as Request
import Test.LuaEngine.Graphics.Window.Fake
import Test.LuaEngine.Graphics.Window.Rig
import Test.LuaEngine.Graphics.Windows

spec ∷ Spec
spec = describe "window provider" $ do
  Request.spec
  configuration
  admission
  stages
  cancellation
  retirement
  closing
  abandonment
  faults
  pressure

-- Admission -----------------------------------------------------------------------------------------------

admission ∷ Spec
admission = describe "admission" $ do
  it "refuses a logical instance's request as an ordinary error with no native work and nothing reserved" $
    withWRig 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) LogicalRole "a"
      command (wrComp rig) (wrVm rig) "a" "pstart" "b"
      line ← awaitNoteContaining (wrComp rig) "a pstart b"
      line `shouldSatisfy` Text.isInfixOf "error"
      events (wrFake rig) >>= (`shouldBe` [])
      slotHeld rig "a" >>= (`shouldBe` False)
      reading ← atomically (providerReading (wcProvider (wrComp rig)))
      (readingRecords reading, readingAcquisitions reading) `shouldBe` (0, 0)

  it "makes a second request of an instance with an occupied slot a permanent error, distinct from busy even when the records bank is full" $
    withWRig 1 [HoldCreate] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      admit (wrComp rig) (wrVm rig) PresentationRole "b"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "first" (640, 480)
      _ ← awaitNoteContaining (wrComp rig) "a start a started"
      -- The bank is full (one record, held) and a's slot is occupied: a's second request is the permanent error.
      command (wrComp rig) (wrVm rig) "a" "pstart" "b"
      second ← awaitNoteContaining (wrComp rig) "a pstart b"
      second `shouldSatisfy` Text.isInfixOf "error"
      second `shouldSatisfy` (not . Text.isInfixOf "busy")
      -- b, whose slot is free, meets the temporary bank: busy, with nothing left behind.
      commandOpen (wrComp rig) (wrVm rig) "b" "a" "peer" (640, 480)
      busy ← awaitNoteContaining (wrComp rig) "b start a"
      busy `shouldSatisfy` Text.isInfixOf "busy:busy"
      slotHeld rig "b" >>= (`shouldBe` False)
      reading ← atomically (providerReading (wcProvider (wrComp rig)))
      readingRecords reading `shouldBe` 1
      eventCount rig "issue create" >>= (`shouldSatisfy` (<= 1))

  it "lets two instances each own one window: there is no global one-window restriction" $
    withWRig 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      admit (wrComp rig) (wrVm rig) PresentationRole "b"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "one" (640, 480)
      commandOpen (wrComp rig) (wrVm rig) "b" "a" "two" (800, 600)
      _ ← awaitNoteContaining (wrComp rig) "a start a started"
      _ ← awaitNoteContaining (wrComp rig) "b start a started"
      awaitFake (wrFake rig) ((== 2) . readingWindows)
      attachNow rig
      command (wrComp rig) (wrVm rig) "a" "wait_take" "a"
      command (wrComp rig) (wrVm rig) "b" "wait_take" "a"
      one ← awaitNoteContaining (wrComp rig) "a wait_take a"
      two ← awaitNoteContaining (wrComp rig) "b wait_take a"
      one `shouldSatisfy` Text.isInfixOf "status=success"
      two `shouldSatisfy` Text.isInfixOf "status=success"
      seen ← events (wrFake rig)
      seen `shouldSatisfy` any (Text.isInfixOf "issue create one 640x480")
      seen `shouldSatisfy` any (Text.isInfixOf "issue create two 800x600")

-- Stages --------------------------------------------------------------------------------------------------

stages ∷ Spec
stages = describe "readiness" $ do
  it "settles success only after creation, attachment and the owner's admission, each held separately" $
    withWRig 2 [HoldCreate, HoldAttach, HoldAdmit] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      _ ← awaitNoteContaining (wrComp rig) "a start a started"
      let notReady count = do
            command (wrComp rig) (wrVm rig) "a" "ready" "a"
            awaitNoteCount rig "a ready a false" count
      -- The creation is issued but its ticket is held: nothing is ready.
      awaitEvent (wrFake rig) "issue create"
      notReady 1
      release (wrFake rig) HoldCreate
      awaitEvent (wrFake rig) "created w"
      -- A native window exists and is tracked: still not ready, and still not attached.
      notReady 2
      attachNow rig
      eventCount rig "attach" >>= (`shouldBe` 0) -- the held handover answered that the owner is not ready
      release (wrFake rig) HoldAttach
      attachNow rig
      eventCount rig "attach" >>= (`shouldBe` 1)
      -- Handed over: an attachment exists but the owner has not admitted the target.
      notReady 3
      release (wrFake rig) HoldAdmit
      command (wrComp rig) (wrVm rig) "a" "wait_take" "a"
      line ← awaitNoteContaining (wrComp rig) "a wait_take a"
      line `shouldSatisfy` Text.isInfixOf "status=success"
      line `shouldSatisfy` Text.isInfixOf "value=<userdata>"
      command (wrComp rig) (wrVm rig) "a" "use" "a"
      used ← awaitNoteContaining (wrComp rig) "a use a"
      used `shouldSatisfy` (not . Text.isInfixOf "error")

  it "owns a success nobody took: the instance's end retires it with no Lua cooperation" $
    withWRig 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      awaitFake (wrFake rig) ((== 1) . readingAttached)
      stopInstance (wrComp rig) (wrVm rig) "a"
      awaitEvent (wrFake rig) "close w"
      _ ← awaitFailure (wrComp rig) "a"
      awaitProvider rig ((== 0) . readingAcquisitions)
      slotHeld rig "a" >>= (`shouldBe` False)

-- Cancellation --------------------------------------------------------------------------------------------

cancellation ∷ Spec
cancellation = describe "cancellation" $ do
  it "withdraws a request that no command was issued for, with no native work, and lets the instance ask again" $
    withWRig 2 [] $ \rig → do
      setCreateFull (wrFake rig) True
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      _ ← awaitNoteContaining (wrComp rig) "a start a started"
      command (wrComp rig) (wrVm rig) "a" "cancel" "a"
      line ← awaitNoteContaining (wrComp rig) "a cancel a"
      line `shouldSatisfy` Text.isInfixOf "cancelled"
      awaitProvider rig ((== 0) . readingAcquisitions)
      slotHeld rig "a" >>= (`shouldBe` False)
      eventCount rig "issue create" >>= (`shouldBe` 0)
      setCreateFull (wrFake rig) False
      commandOpen (wrComp rig) (wrVm rig) "a" "b" "again" (320, 240)
      awaitNoteCount rig "a start b started" 1

  it "closes a late native result once, and frees the slot only after native retirement" $
    withWRig 2 [HoldCreate, HoldNative] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      _ ← awaitNoteContaining (wrComp rig) "a start a started"
      awaitEvent (wrFake rig) "issue create"
      command (wrComp rig) (wrVm rig) "a" "cancel" "a"
      line ← awaitNoteContaining (wrComp rig) "a cancel a"
      line `shouldSatisfy` Text.isInfixOf "cancelled"
      -- The command is issued and its ticket held: the slot is occupied until actual retirement.
      slotHeld rig "a" >>= (`shouldBe` True)
      command (wrComp rig) (wrVm rig) "a" "pstart" "c"
      refused ← awaitNoteContaining (wrComp rig) "a pstart c"
      refused `shouldSatisfy` Text.isInfixOf "error"
      release (wrFake rig) HoldCreate
      awaitFake (wrFake rig) ((== 1) . readingClosing)
      -- Created, suppressed and closing; the native window is not yet destroyed.
      slotHeld rig "a" >>= (`shouldBe` True)
      eventCount rig "attach" >>= (`shouldBe` 0)
      release (wrFake rig) HoldNative
      awaitProvider rig ((== 0) . readingAcquisitions)
      slotHeld rig "a" >>= (`shouldBe` False)
      eventCount rig "close w" >>= (`shouldBe` 1)
      commandOpen (wrComp rig) (wrVm rig) "a" "b" "fresh" (640, 480)
      awaitNoteCount rig "a start b started" 1

  it "cancels after the attachment and before admission: the attachment retires before the native window, once" $
    withWRig 2 [HoldAdmit, HoldGraphics] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      awaitFake (wrFake rig) ((== 1) . readingAttached)
      command (wrComp rig) (wrVm rig) "a" "cancel" "a"
      _ ← awaitNoteContaining (wrComp rig) "a cancel a cancelled"
      awaitFake (wrFake rig) ((== 1) . readingClosing)
      slotHeld rig "a" >>= (`shouldBe` True)
      release (wrFake rig) HoldGraphics
      awaitProvider rig ((== 0) . readingAcquisitions)
      slotHeld rig "a" >>= (`shouldBe` False)
      eventCount rig "close w" >>= (`shouldBe` 1)

  it "answers already_settled once success settled, and cannot close the successful window" $
    withWRig 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      openAndSettle rig "a" "t"
      command (wrComp rig) (wrVm rig) "a" "cancel" "a"
      line ← awaitNoteContaining (wrComp rig) "a cancel a"
      line `shouldSatisfy` Text.isInfixOf "already_settled"
      eventCount rig "close w" >>= (`shouldBe` 0)

-- Retirement ----------------------------------------------------------------------------------------------

retirement ∷ Spec
retirement = describe "retirement" $ do
  it "ends only its own instance's window, frees the slot only after graphics and native retire, and leaves a peer serviceable" $
    withWRig 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      admit (wrComp rig) (wrVm rig) PresentationRole "b"
      openAndReady rig "a" "one"
      openAndReady rig "b" "two"
      hold (wrFake rig) HoldGraphics
      hold (wrFake rig) HoldNative
      stopInstance (wrComp rig) (wrVm rig) "a"
      awaitFake (wrFake rig) ((== 1) . readingClosing)
      slotHeld rig "a" >>= (`shouldBe` True)
      -- The peer is serviceable while the first retires.
      command (wrComp rig) (wrVm rig) "b" "use" "a"
      used ← awaitNoteContaining (wrComp rig) "b use a"
      used `shouldSatisfy` (not . Text.isInfixOf "error")
      release (wrFake rig) HoldGraphics
      slotHeld rig "a" >>= (`shouldBe` True)
      release (wrFake rig) HoldNative
      awaitProvider rig ((== 1) . readingAcquisitions)
      slotHeld rig "a" >>= (`shouldBe` False)
      slotHeld rig "b" >>= (`shouldBe` True)
      stopsNow rig >>= (`shouldBe` 0)
      fatalsNow rig >>= (`shouldBe` [])
      awaitFake (wrFake rig) (\r → readingClosing r == 1 && readingWindows r == 2)

  it "keeps the slot and escalates a failed native destruction, and never reports it as retired" $
    raisesWindowDefect . withWRig 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      openAndReady rig "a" "t"
      failNativeDisposal (wrFake rig)
      stopInstance (wrComp rig) (wrVm rig) "a"
      awaitFake (wrFake rig) ((== 1) . readingClosing)
      awaitFatalCount rig 1
      atomically (providerFatal (wcProvider (wrComp rig))) >>= (`shouldSatisfy` (/= Nothing))
      slotHeld rig "a" >>= (`shouldBe` True)
      eventCount rig "close w" >>= (`shouldBe` 1)

-- Close ----------------------------------------------------------------------------------------------------

closing ∷ Spec
closing = describe "close routing" $ do
  it "routes a genuine close during pending setup to one session stop, even with ordinary request capacity full" $
    withWRig 1 [HoldAdmit] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      awaitFake (wrFake rig) ((== 1) . readingAttached)
      nativeClose (wrFake rig) 1
      awaitStops rig 1
      -- The same request is not routed twice, however many times the provider is nudged.
      release (wrFake rig) HoldAdmit
      command (wrComp rig) (wrVm rig) "a" "wait_take" "a"
      _ ← awaitNoteContaining (wrComp rig) "a wait_take a"
      stopsNow rig >>= (`shouldBe` 1)
      -- A newer request is routed again (the stop is idempotent).
      nativeClose (wrFake rig) 1
      awaitStops rig 2

  it "does not stop the session or a peer when only an instance's cleanup closes its window" $
    withWRig 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      admit (wrComp rig) (wrVm rig) PresentationRole "b"
      openAndReady rig "a" "one"
      openAndReady rig "b" "two"
      stopInstance (wrComp rig) (wrVm rig) "a"
      awaitProvider rig ((== 1) . readingAcquisitions)
      stopsNow rig >>= (`shouldBe` 0)
      command (wrComp rig) (wrVm rig) "b" "use" "a"
      used ← awaitNoteContaining (wrComp rig) "b use a"
      used `shouldSatisfy` (not . Text.isInfixOf "error")

  it "does not lose a genuine close that races the cleanup close" $
    withWRig 2 [HoldGraphics] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      openAndReady rig "a" "t"
      stopInstance (wrComp rig) (wrVm rig) "a"
      awaitFake (wrFake rig) ((== 1) . readingClosing)
      nativeClose (wrFake rig) 1
      awaitStops rig 1

-- Abandoned offers and raised effects ---------------------------------------------------------------------

abandonment ∷ Spec
abandonment = describe "abandonment and failed effects" $ do
  it "takes apart a window whose offered result was never built because the request was cancelled first, without the result being taken" $
    withWRigWrapped swallowAdoption 2 [] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      -- The provider offered the result once the owner admitted the target; the host never builds it.
      awaitFake (wrFake rig) ((== 1) . readingAttached)
      eventCount rig "close w" >>= (`shouldBe` 0)
      command (wrComp rig) (wrVm rig) "a" "cancel" "a"
      line ← awaitNoteContaining (wrComp rig) "a cancel a"
      line `shouldSatisfy` Text.isInfixOf "cancelled"
      -- Nobody takes the cancelled result: the window is closed, retired and the slot freed all the same.
      awaitProvider rig ((== 0) . readingAcquisitions)
      slotHeld rig "a" >>= (`shouldBe` False)
      eventCount rig "close w" >>= (`shouldBe` 1)

  it "issues again when the host queue drained between the refusal and the waiter, and closes likewise" $
    withWRig 2 [] $ \rig → do
      setCreateFull (wrFake rig) True
      drainOnNextFull (wrFake rig)
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      command (wrComp rig) (wrVm rig) "a" "wait_take" "a"
      line ← awaitNoteContaining (wrComp rig) "a wait_take a"
      line `shouldSatisfy` Text.isInfixOf "status=success"
      eventCount rig "issue create" >>= (`shouldBe` 1)
      setCloseFull (wrFake rig) True
      stopInstance (wrComp rig) (wrVm rig) "a"
      -- Closing is refused for a full queue; opening the queue lets it through and the window retires.
      awaitFake (wrFake rig) ((== 1) . readingWindows)
      setCloseFull (wrFake rig) False
      awaitProvider rig ((== 0) . readingAcquisitions)

  it "raises a retained retirement failure at a clean scope exit and lets the pump stop, with no earlier exception" $
    raisesWindowDefect . withWRig 2 [HoldAdmit] $ \rig → do
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      awaitFake (wrFake rig) ((== 1) . readingAttached)
      failNativeDisposal (wrFake rig)
      command (wrComp rig) (wrVm rig) "a" "cancel" "a"
      _ ← awaitNoteContaining (wrComp rig) "a cancel a cancelled"
      awaitFatalCount rig 1
      slotHeld rig "a" >>= (`shouldBe` True)

  it "never repeats a failed effect: an issue that raised is attempted once, before or after admission" $
    mapM_ raised [RaiseBeforeIssue, RaiseAfterIssue]
  where
    raised how = raisesWindowDefect . withWRig 2 [] $ \rig → do
      raiseOnIssue (wrFake rig) how
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      awaitFatalCount rig 1
      -- Unrelated progress gives the pump every chance to choose the same acquisition again.
      admit (wrComp rig) (wrVm rig) PresentationRole "b"
      commandOpen (wrComp rig) (wrVm rig) "b" "a" "peer" (320, 240)
      _ ← awaitNoteContaining (wrComp rig) "b start a started"
      eventCount rig "attempt issue" >>= (`shouldSatisfy` (<= 2))
      fatalsNow rig >>= \found → length found `shouldSatisfy` (<= 2)
      slotHeld rig "a" >>= (`shouldBe` True)

-- Faults ---------------------------------------------------------------------------------------------------

faults ∷ Spec
faults = describe "failures" $ do
  it "answers a clean creation refusal as window_error and fails the instance whether or not it is read" $
    withWRig 2 [] $ \rig → do
      scriptCreate (wrFake rig) [CreateRefusedClean "the window could not be created"]
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      failure ← awaitFailure (wrComp rig) "a"
      fmap fst (instanceFailure failure) `shouldBe` Just "window"
      fatalsNow rig >>= (`shouldBe` [])
      slotHeld rig "a" >>= (`shouldBe` False)

  it "answers a target refused with a verified rollback as window_error, and still takes the window apart" $
    withWRig 2 [] $ \rig → do
      scriptStanding (wrFake rig) (StandingRefusedClean "the surface cannot be presented to")
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      failure ← awaitFailure (wrComp rig) "a"
      fmap fst (instanceFailure failure) `shouldBe` Just "window"
      awaitProvider rig ((== 0) . readingAcquisitions)
      eventCount rig "close w" >>= (`shouldBe` 1)
      fatalsNow rig >>= (`shouldBe` [])

  it "keeps a fatal creation fault out of window_error, busy and retries" $
    raisesWindowDefect . withWRig 2 [] $ \rig → do
      scriptCreate (wrFake rig) [CreateFatal (Fatal "the creation was interrupted")]
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      awaitFatalCount rig 1
      notes (wrComp rig) >>= \seen → filter (Text.isInfixOf "window_error") seen `shouldBe` []
      eventCount rig "issue create" >>= (`shouldBe` 1)

  it "latches an owner failure as fatal" $
    raisesWindowDefect . withWRig 2 [] $ \rig → do
      failOwner (wrFake rig) (Fatal "the graphics owner failed")
      awaitFatalCount rig 1

-- Pressure -------------------------------------------------------------------------------------------------

pressure ∷ Spec
pressure = describe "pressure" $ do
  it "keeps accepted work pending under a full command queue, never busy, and proceeds when the queue changes" $
    withWRig 2 [] $ \rig → do
      setCreateFull (wrFake rig) True
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      line ← awaitNoteContaining (wrComp rig) "a start a"
      line `shouldSatisfy` Text.isInfixOf "started"
      eventCount rig "issue create" >>= (`shouldBe` 0)
      setCreateFull (wrFake rig) False
      attachNow rig
      command (wrComp rig) (wrVm rig) "a" "wait_take" "a"
      ready <- awaitNoteContaining (wrComp rig) "a wait_take a"
      ready `shouldSatisfy` Text.isInfixOf "status=success"

  it "keeps a deferred announcement under bounded progress on the same window, never a second window" $
    withWRig 2 [] $ \rig → do
      scriptAttach (wrFake rig) [AttachDeferred]
      admit (wrComp rig) (wrVm rig) PresentationRole "a"
      commandOpen (wrComp rig) (wrVm rig) "a" "a" "t" (640, 480)
      attachNow rig
      -- Deferred: the main thread still owes it a turn.
      attachNow rig
      command (wrComp rig) (wrVm rig) "a" "wait_take" "a"
      line <- awaitNoteContaining (wrComp rig) "a wait_take a"
      line `shouldSatisfy` Text.isInfixOf "status=success"
      eventCount rig "issue create" >>= (`shouldBe` 1)
      atomically (readFake (wrFake rig)) >>= (`shouldBe` 1) . readingWindows

-- Configuration -------------------------------------------------------------------------------------------

configuration ∷ Spec
configuration = describe "host configuration" $ do
  it "refuses a single-window, shared-scene host as the sample configures it, and accepts the profile's" $ do
    initial ← prepare ()
    let plain = vulkanHostConfig (defaultHostConfig []) defaultCaptureConfig budgets initial
        single = plain {vulkanHost = (vulkanHost plain) {hostWindowLimit = 1, hostCommandCapacity = 1}}
    checkWindowHost single `shouldBe` [HostWindowLimitTooSmall 1, HostCommandCapacityTooSmall 1, HostScenesShared]
    checkWindowHost (configureWindows single) `shouldBe` []
    -- Configuring never shrinks a host that already carries more.
    let larger = plain {vulkanHost = (vulkanHost plain) {hostWindowLimit = 8, hostCommandCapacity = 64}}
    hostWindowLimit (vulkanHost (configureWindows larger)) `shouldBe` 8
    hostCommandCapacity (vulkanHost (configureWindows larger)) `shouldBe` 64
  where
    budgets = either (error . show) id (validateBudgets defaultBudgetRequest)
