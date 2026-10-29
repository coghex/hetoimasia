-- | The window provider on real windows: the production host, the production port and the process main
-- thread serving the owner loop, with the windows actually created, attached, admitted and destroyed.
--
-- What these examples add to the controlled lifecycle suite's matrix is the other side of the port: that the
-- facts the provider reads are the facts the production hosts publish. They do not replace the race matrix, and
-- they claim no pixel and no completed GPU frame: a window is ready when the owner admitted its target and an
-- empty scene can be published to it, which is all the provider promises.
--
-- The windows open on whatever the run's consent selected: an isolated X11 display on Linux, the desktop on
-- macOS under the run's own consent. Every example ends with the windows it made destroyed, because the
-- texture examples of this suite assert that no window exists.
module Test.LuaEngine.Graphics.Native.Windows (spec) where

import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Monad (forM_, unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import qualified Data.Text.Read as Text
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.GLFW.NativeCheck (NativeCloseAnswer (..), requestNativeClose)
import Hetoimasia.GPU.Vulkan.GLFW (VulkanHost (..))
import Hetoimasia.LuaEngine.Graphics.Scene.Ledger (GraphicsScene, initialGraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Window.Host (PortReading (..), WindowTarget (..), newHostPort)
import Hetoimasia.LuaEngine.Graphics.Window.Port (Fatal, Port (..), WindowToken (..))
import Hetoimasia.LuaEngine.Graphics.Window.Provider
import Hetoimasia.Runtime.GLFW (TargetStanding (..), WindowScenePublication (..), hostWindowIdentities, readTargetStanding)
import System.Timeout (timeout)
import Test.HUnit.Lang (assertFailure)
import Test.Hspec
import Test.LuaEngine.Graphics.Native.Session
import Test.LuaEngine.Graphics.Windows

spec ∷ Env → Spec
spec env = describe "window provider" $ do
  it "creates two visible windows for two instances, verifies each admission and an empty scene, and ends one while the other stays usable" $
    within 120 . withWindows env Nothing $ \comp vm stops fatals port _ → do
      admit comp vm PresentationRole "a"
      admit comp vm PresentationRole "b"
      commandOpen comp vm "a" "a" "native one" (320, 240)
      commandOpen comp vm "b" "a" "native two" (400, 300)
      command comp vm "a" "wait_take" "a"
      command comp vm "b" "wait_take" "a"
      one ← awaitNoteContaining comp "a wait_take a"
      two ← awaitNoteContaining comp "b wait_take a"
      one `shouldSatisfy` Text.isInfixOf "status=success"
      two `shouldSatisfy` Text.isInfixOf "status=success"
      -- Two actual windows exist, one for each instance.
      windowCount env >>= (`shouldBe` 2)
      noteWindows env 2
      forM_ ["a", "b"] $ \name → publishesEmptyScene env comp vm port name
      -- Ending one instance destroys only its window, after its retirement; its peer stays usable and nothing
      -- asked the session to stop.
      stopInstance comp vm "a"
      awaitWindowCount env 1
      atomically (readTVar stops) >>= (`shouldBe` (0 ∷ Int))
      publishesEmptyScene env comp vm port "b"
      stopInstance comp vm "b"
      awaitWindowCount env 0
      readTVarIO fatals >>= (`shouldBe` [])
      evidence env "two instances, two actual windows: each success followed the owner's admission, an empty scene was published to each, one instance ended with the peer usable, then the peer ended; no session stop was requested"

  it "retires a real creation that was cancelled before its result was collected, and lets the instance ask again" $
    within 120 $ do
      gate ← newTVarIO False
      withWindows env (Just gate) $ \comp vm _ fatals _ reading → do
        admit comp vm PresentationRole "a"
        commandOpen comp vm "a" "a" "cancelled" (320, 240)
        _ ← awaitNoteContaining comp "a start a started"
        -- The native window is created by the host while the provider has not collected the ticket.
        awaitWindowCount env 1
        noteWindows env 1
        command comp vm "a" "cancel" "a"
        line ← awaitNoteContaining comp "a cancel a"
        line `shouldSatisfy` Text.isInfixOf "cancelled"
        owner ← ownerOf vm "a"
        atomically (ownerSlotHeld owner) >>= (`shouldBe` True)
        atomically (modifyTVar' gate (const True))
        -- The late native result is closed and destroyed, and only then is the slot reusable.
        awaitWindowCount env 0
        atomically (ownerSlotHeld owner >>= \held → if held then retry else pure ())
        commandOpen comp vm "a" "b" "fresh" (320, 240)
        awaitNoteCount' comp "a start b started"
        command comp vm "a" "wait_take" "b"
        fresh ← awaitNoteContaining comp "a wait_take b"
        fresh `shouldSatisfy` Text.isInfixOf "status=success"
        noteWindows env 1
        stopInstance comp vm "a"
        awaitWindowCount env 0
        readTVarIO fatals >>= (`shouldBe` [])
        -- The production port keeps nothing of windows that retired whole: two creations (one cancelled, one
        -- ended) leave no ticket and no window record behind, though the identities are never reissued.
        atomically (reading >>= \now → unless (now == PortReading 0 0) retry)

  it "routes a genuine native close request to one session stop, separately from the instance's own cleanup close" $
    within 120 . withWindows env Nothing $ \comp vm stops fatals _ _ → do
      admit comp vm PresentationRole "a"
      commandOpen comp vm "a" "a" "closing" (320, 240)
      command comp vm "a" "wait_take" "a"
      line ← awaitNoteContaining comp "a wait_take a"
      line `shouldSatisfy` Text.isInfixOf "status=success"
      noteWindows env 1
      atomically (readTVar stops) >>= (`shouldBe` (0 ∷ Int))
      [window] ← atomically (hostWindowIdentities (vulkanWindowHost (envHost env)))
      -- The platform delivers the request as the close button would; the window's own callback latches it.
      answer ← onMain env (requestNativeClose (vulkanWindowHost (envHost env)) window)
      answer `shouldBe` NativeCloseDelivered
      atomically (readTVar stops >>= \n → unless (n >= 1) retry)
      -- The window is still there: a close request destroys nothing, and Lua cannot veto the stop.
      windowCount env >>= (`shouldBe` 1)
      -- The instance's own end closes the window, and that is not a second request.
      stopInstance comp vm "a"
      awaitWindowCount env 0
      atomically (readTVar stops) >>= (`shouldBe` 1)
      readTVarIO fatals >>= (`shouldBe` [])

-- | The scene a ready window can be published: empty, to its own incarnation, after the owner admitted it.
publishesEmptyScene ∷ Env → WinComp (WindowTarget GraphicsScene) → WinVm (WindowTarget GraphicsScene) → Port (WindowTarget GraphicsScene) → Text.Text → IO ()
publishesEmptyScene env comp vm port name = do
  command comp vm name "use" "a"
  line ← awaitNoteContaining comp (name <> " use a")
  token ← case Text.decimal (last (Text.words line)) of
    Right (number, _) → pure number
    Left _ → assertFailure ("the window handle's identity could not be read from: " <> Text.unpack line)
  found ← atomically (portTarget port (WindowToken token))
  target ← maybe (assertFailure "a ready window offered no scene publication") pure found
  atomically (targetUsable target) >>= (`shouldBe` True)
  readTargetStanding (vulkanGraphicsOwner (envHost env)) (targetAttachment target) `shouldReturnSTM` Just TargetUsable
  scene ← prepare initialGraphicsScene
  targetPublish target scene >>= \case
    WindowScenePublished _ _ → pure ()
    other → assertFailure ("the scene was not accepted: " <> show other)
  where
    shouldReturnSTM action expected = atomically action >>= (`shouldBe` expected)

-- | A provider over the production port (optionally with its creation outcomes withheld by a gate the example
-- opens), inside the real composition, with the main thread serving the provider's handovers.
withWindows
  ∷ Env
  → Maybe (TVar Bool)
  → (WinComp (WindowTarget GraphicsScene) → WinVm (WindowTarget GraphicsScene) → TVar Int → TVar [Fatal] → Port (WindowTarget GraphicsScene) → STM PortReading → IO a)
  → IO a
withWindows env gate body = do
  stops ← newTVarIO 0
  fatals ← newTVarIO []
  (port, reading) ← newHostPort (envHost env)
  provider ← newIORef (Nothing ∷ Maybe (IO ()))
  let gated = maybe port (gateCreation port) gate
      config = WindowConfig 2 (atomically (modifyTVar' stops (+ 1))) (\found → atomically (modifyTVar' fatals (found :)))
  serveMain env (readIORef provider >>= maybe (pure ()) id) $
    withWinComp config gated $ \comp _ runtime → do
      writeIORef provider (Just (windowMainStep (wcProvider comp)))
      vm ← startWinVm comp runtime "native-window-vm"
      body comp vm stops fatals gated reading

-- | The production port with creation outcomes withheld until the gate opens: the adapter's coordinated seam
-- for a cancellation that overtakes a real native creation.
gateCreation ∷ Port target → TVar Bool → Port target
gateCreation port gate =
  port
    { portCreateOutcome = \token → do
        open ← readTVar gate
        if open then portCreateOutcome port token else pure Nothing
    }

within ∷ Int → IO a → IO a
within seconds action =
  timeout (seconds * 1000000) action >>= \case
    Just value → pure value
    Nothing → assertFailure ("the example did not finish within " <> show seconds <> " seconds")

windowCount ∷ Env → IO Int
windowCount env = length <$> atomically (hostWindowIdentities (vulkanWindowHost (envHost env)))

awaitWindowCount ∷ Env → Int → IO ()
awaitWindowCount env wanted = atomically $ do
  windows ← hostWindowIdentities (vulkanWindowHost (envHost env))
  unless (length windows == wanted) retry

awaitNoteCount' ∷ WinComp target → Text.Text → IO ()
awaitNoteCount' comp needle = () <$ awaitNoteContaining comp needle

evidence ∷ Env → Text.Text → IO ()
evidence env line = atomically (modifyTVar' (envEvidence env) (line :))
