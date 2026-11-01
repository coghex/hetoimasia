{-# LANGUAGE OverloadedStrings #-}

-- | The `Lua native milestone` subgroup (LFE-25, #540): the native windows, the independent retirement of one of two
-- instances, and the whole-session quit, qualified on a real device.
--
-- Two kinds of case share the group. The two-instance cases compose one UI VM with two engine-owned instances of the
-- shipped quad content and an independent logical owner through the public Haskell interfaces over a host this suite
-- composes with the validation layer and synchronization validation enabled ("Test.Run.Native.Peers"); both instances
-- request the same PNG path from the same content root. The actual-command cases run the built full-product command
-- as an owned child.
--
-- Every wait is on an observed fact and bounded. No case sleeps, none relies on an outcome of the platform it did not
-- observe, and none infers GPU retirement from a timeout, a callback, a cancellation or a capture: the resources and
-- the windows stay live until the host's and the adapter's own readings say they are gone.
module Test.Run.Native.Milestone (spec) where

import Control.Concurrent.STM (atomically, readTVar, readTVarIO, retry)
import Control.Exception (onException, try)
import Data.List (isInfixOf)
import Test.HUnit.Lang (HUnitFailure (..))
import Control.Monad (forM, forM_, unless)
import Data.Text (Text)
import System.IO (hPutStrLn, stderr)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Hetoimasia.GLFW.NativeCheck (NativeCloseAnswer (..), requestNativeClose)
import Hetoimasia.GPU.Vulkan.GLFW (FrameEvent (..), VulkanHost (..))
import Hetoimasia.Runtime.GLFW (attachmentWindow)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (..))
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture (BackendReading (..), TextureGraphics (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe, shouldSatisfy)
import Test.Run.Native.Env (Env (..), evidence)
import Test.Run.Native.Library (copyTree, shippedContent)
import Hetoimasia.GLFW.Window (WindowId)
import Test.Run.Native.Capture (Bound (..), bindNew, ownPid, snap, viewableNow)
import qualified Test.Run.Native.X11 as X11
import Test.Run.Native.Checkpoint (checkpoint)
import Test.Run.Native.Observe
import Hetoimasia.GLFW.Command (Disposition (Performed), observeWindowCommand)
import Test.Run.Native.Peers

spec ∷ Env → Spec
spec env = describe "Lua native milestone" $ do
  it "has the isolated-X11 evidence helper ready and seeing the display before any window exists (Linux), and says so elsewhere" $
    case envX11 env of
      Nothing → evidence env "X11 evidence helper: not applicable in this session (macOS has no OS capture; the owner's confirmations are pending); no isolated-X11 consent"
      Just helper → do
        pid ← ownPid
        note ("preflight: the helper looks for windows of pid " <> show pid)
        X11.prepare helper
        none ← X11.candidates helper pid
        note ("preflight: the helper answered " <> show (length none) <> " windows")
        none `shouldBe` []
        evidence env "X11 evidence helper: libX11 and every entry point loaded, the display is the isolated one, and the suite's process owned no window before the first case"
  it "loads the same PNG for two instances independently, ends one while its accepted scene still holds its released texture, and keeps the other updating with its texture and window" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        -- A's window is created first and B's second: with creation outcomes withheld from the provider, each new
        -- native window is the only one that appeared since the instance was admitted, so it is that instance's.
        (a, windowA, boundA, b, windowB, boundB) ← startTwo env peers
        spIdentity a `shouldNotBe` spIdentity b
        spInstance a `shouldNotBe` spInstance b
        windowA `shouldNotBe` windowB
        forM_ [windowA, windowB] $ \window → awaitAdopted peers window 1
        snap env peers "two-instances--a-quad" boundA
        snap env peers "two-instances--b-quad" boundB
        checkpoint env "two-instances-quads" "the owner confirms the textured quad is visible in both windows, the same picture in each" =<< factsFor peers [("A", windowA), ("B", windowB)]
        -- Two textures were allocated, uploaded and registered: the same path was never coalesced.
        awaitLiveTextures peers 2
        -- Ending A through its public lifecycle control closes only its window, and is never a user close.
        stopUi peers a
        awaitWindowCount peers 1
        remaining ← windowsNow peers
        remaining `shouldBe` [windowB]
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        -- B continues: another frame of what it holds, with the same revision, and nothing reloaded.
        mark ← frameMark peers
        demandFrame peers windowB
        awaitFrame peers windowB 1 mark
        awaitLiveTextures peers 1
        publishedRevisionOf peers windowB >>= (`shouldBe` Just 1)
        -- B's quad is still right on the display, and its texture was never reloaded (one live texture throughout).
        snap env peers "two-instances--b-after-a-ended" boundB
        checkpoint env "peer-survival" "the owner confirms A's window is gone and B's window still shows the correct quad, never reloaded" =<< factsFor peers [("B", windowB)]
        stopUi peers b
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        -- Every cleanup close has happened by now: none of them was a user close.
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        reading ← atomically (graphicsReading (peGraphics peers))
        readingLiveTextures reading `shouldBe` 0
        evidence env (Text.pack ("two instances: instances " <> show (spIdentity a, spIdentity b) <> ", windows " <> show (windowA, windowB) <> "; ended A with B live; no user close; validation layer and synchronization validation enabled on this host"))

  it "ends one instance while its texture read is held at the pool's reader: the peer keeps updating, the ended instance settles stopped only after the read returns and delivers nothing, and a later instance loads the same path" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        holdNextReads peers quadPath 1
        known0 ← viewableNow env
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        boundA ← bindNew env peers windowA known0
        placeWindow env peers windowA 0
        readsEntered peers quadPath 1
        b ← admitUi peers
        windowB ← awaitNewWindow peers [windowA]
        boundB ← bindNew env peers windowB (known0 <> map boundX (maybe [] pure boundA))
        placeWindow env peers windowB 1
        awaitAdopted peers windowB 1
        atomically (readsHeld peers quadPath) >>= (`shouldBe` 1)
        -- A is ended with its read borrowed by a worker: it cannot settle until the read returns.
        stopUi peers a
        step "A's phase to become Stopping" . atomically $ instancePhaseOf peers a >>= \phase → unless (phase == Just Stopping) retry
        mark ← frameMark peers
        demandFrame peers windowB
        awaitFrame peers windowB 1 mark
        snap env peers "pending-read--b-while-a-stopping" boundB
        atomically (readsHeld peers quadPath) >>= (`shouldBe` 1)
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        -- Only now is the read let go; whatever it produces belongs to nobody.
        releaseReadsOf peers quadPath
        instanceStoppedCleanly a >>= (`shouldBe` True)
        forgetEnded peers a
        awaitWindowCount peers 1
        awaitLiveTextures peers 1
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        -- The reservation came back exactly: a later instance loads the same path and shows its quad.
        c ← admitUi peers
        windowC ← awaitNewWindow peers [windowB]
        placeWindow env peers windowC 0
        awaitAdopted peers windowC 1
        awaitLiveTextures peers 2
        mapM_ (stopUi peers) [b, c]
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        -- Every cleanup close has happened by now: none of them was a user close.
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        evidence env (Text.pack ("pending read: A=" <> show (spIdentity a) <> " ended with its read held (Stopping), B=" <> show (spIdentity b) <> " kept updating, A settled Stopped only after the read was released, no user close, C=" <> show (spIdentity c) <> " then loaded the same path; windows " <> show (windowA, windowB, windowC)))

  it "ends one instance while its window creation outcome is withheld from the provider: the host's window stays tracked until the late result is closed and destroyed, the peer is unaffected and no orphan window or texture remains" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        withholdNextCreations peers 1
        known0 ← viewableNow env
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        boundA ← bindNew env peers windowA known0
        placeWindow env peers windowA 0
        b ← admitUi peers
        windowB ← awaitNewWindow peers [windowA]
        boundB ← bindNew env peers windowB (known0 <> map boundX (maybe [] pure boundA))
        placeWindow env peers windowB 1
        awaitAdopted peers windowB 1
        atomically (creationsWithheld peers) >>= (`shouldBe` 1)
        stopUi peers a
        -- A's accepted window work is still pending: its native window is tracked until the provider collects the
        -- outcome and retires it, and the peer neither notices nor stops.
        mark ← frameMark peers
        demandFrame peers windowB
        awaitFrame peers windowB 1 mark
        snap env peers "pending-window--b-while-a-pending" boundB
        windowsNow peers >>= (`shouldBe` [windowA, windowB])
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        releaseCreations peers
        instanceStoppedCleanly a >>= (`shouldBe` True)
        awaitWindowCount peers 1
        windowsNow peers >>= (`shouldBe` [windowB])
        awaitLiveTextures peers 1
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        stopUi peers b
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        -- Every cleanup close has happened by now: none of them was a user close.
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        evidence env (Text.pack ("pending window: A=" <> show (spIdentity a) <> " ended while its creation outcome (window " <> show windowA <> ") was withheld; it stayed tracked until the outcome was released and then retired, B=" <> show (spIdentity b) <> " (window " <> show windowB <> ") unaffected, no user close"))


  it "keeps an unchanged published scene while the window is made smaller, larger, minimized and restored, and records what the platform reported rather than what was requested" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        (a, windowA, boundA, b, windowB, _boundB) ← startTwo env peers
        forM_ [windowA, windowB] $ \window → awaitAdopted peers window 1
        parkWindow env peers windowB
        initial ← windowMetrics peers windowA
        snap env peers "view--initial" boundA
        -- The scene is the one accepted publication, and nothing below republishes: its revision is the evidence.
        let unchanged label = do
              published ← publishedRevisionOf peers windowA
              adopted ← adoptedRevision peers windowA
              (label, published, adopted) `shouldBe` (label, Just 1, Just 1)
            renders label = do
              mark ← frameMark peers
              demandFrame peers windowA
              awaitFrame peers windowA 1 mark `onException` (windowMetrics peers windowA >>= \m → hPutStrLn stderr ("no frame after " <> label <> "; the window reports " <> show m))
              unchanged label
            resizeTo label (width, height) = do
              disposition ← requestSize peers windowA (width, height)
              (label, attempted disposition) `shouldBe` (label, True)
              reached ← awaitMetrics peers windowA (label <> " to be reported") (\m → metricsLogical m == Just (width, height) || (metricsLogical m /= metricsLogical initial && metricsRevision m > metricsRevision initial))
              renders label
              snap env peers ("view--" <> Text.pack label) boundA
              checkpoint env (Text.pack ("resize-" <> label)) (Text.pack ("the owner confirms, in the " <> label <> " window, that the quad keeps its size and its top-left position (clipped where the window is too small, never stretched or re-centred)")) =<< factsFor peers [("subject", windowA)]
              pure reached
        smaller ← resizeTo "smaller" (320, 240)
        larger ← resizeTo "larger" (800, 600)
        minimized ← requestMinimize peers windowA
        attempted minimized `shouldBe` True
        iconified ← awaitMetrics peers windowA "the minimize to be reported" (\m → metricsIconified m /= Just False)
        let area = maybe Nothing (\(w, h) → Just (w * h)) . metricsFramebuffer
        zeroNative ← case area iconified of
          Just 0 → do
            -- A native zero-area framebuffer: drawing is suspended for this window while the peer, which keeps its
            -- size, is still presented and its presentations still retire; no frame of this window's is requested.
            mark ← frameMark peers
            demandFrame peers windowA
            demandFrame peers windowB
            awaitFrame peers windowB 1 mark
            fresh ← freshEvents peers mark
            [() | FramePresentRequested attachment _ _ _ ← fresh, attachmentWindow attachment == windowA] `shouldBe` []
            step "a presentation to retire while the window is suspended" . atomically $ do
              (count, events) ← readTVar (peFrames peers)
              unless (or [True | PresentationRetired _ ← take (max 0 (count - mark)) events]) retry
            pure True
          _ → pure False
        restored ← requestRestore peers windowA
        attempted restored `shouldBe` True
        -- What the platform's own callbacks reported once the restore took effect, before anything samples again.
        reported ← awaitMetrics peers windowA "the restore to be reported" (\m → metricsIconified m == Just False)
        -- Eligibility to draw is the observation exactly (docs/glfw.md), so the case does not assume the callback's
        -- reading is the window's state: it takes the public explicit sample and requires that one to be drawable.
        sampled ← controlWindow peers windowA (observeWindowCommand windowA)
        (case sampled of Performed _ → True; _ → False) `shouldBe` True
        back ← awaitMetrics peers windowA "a drawable sample after the restore" (\m → metricsRevision m > metricsRevision reported && metricsIconified m == Just False && metricsVisible m /= Just False && maybe True (\(w, h) → w * h > 0) (metricsFramebuffer m))
        renders "restored"
        snap env peers "view--restored" boundA
        checkpoint env "restore" "the owner confirms the restored window shows the quad again" =<< factsFor peers [("subject", windowA)]
        awaitLiveTextures peers 2
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        mapM_ (stopUi peers) [a, b]
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        -- Every cleanup close has happened by now: none of them was a user close.
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        evidence env . Text.pack $
          "view adaptation (window "
            <> show windowA
            <> ", scene revision 1 published and adopted unchanged throughout, no republish, no Lua size read): initial "
            <> show initial
            <> "; smaller (requested 320x240) reported "
            <> show smaller
            <> "; larger (requested 800x600) reported "
            <> show larger
            <> "; minimized reported "
            <> show iconified
            <> "; restored: the callbacks reported "
            <> show reported
            <> (if metricsVisible reported == Just False then " (visible still False: the callback-driven observation was stale and the window stayed ineligible to draw until the explicit sample; filed as issue #581)" else "")
            <> ", the explicit sample "
            <> show back
            <> "; native zero-area framebuffer "
            <> (if zeroNative then "OBSERVED: drawing was suspended and resumed after restore" else "UNEXERCISED on this platform (the framebuffer was never reported with zero area): the controlled zero-metrics coverage is the owning prerequisites' (LFE-18, LFE-20 and the host's suspended-target cases), not claimed as native")


  it "unwinds by itself, and raises its own failure unchanged, when the scenario fails with a read held, a creation withheld and a window live" $
    withinCase env 120 . withOwnedContent $ \folder → do
      -- Only the scenario's own assertion failure is expected here, and it is matched by its type and its words: any
      -- other exception, or a hang in the unwinding (a gate left closed), fails this example.
      outcome ← try @HUnitFailure . withPeers (envStart env) folder $ \peers → do
        holdNextReads peers quadPath 1
        withholdNextCreations peers 1
        _ ← admitUi peers
        _ ← awaitNewWindow peers []
        readsEntered peers quadPath 1
        expectationFailure "the scenario failed on purpose"
      case outcome of
        Left (HUnitFailure _ reason) → show reason `shouldSatisfy` isInfixOf "the scenario failed on purpose"
        Right () → expectationFailure "the scenario's failure was swallowed"
      evidence env "unwinding control: a scenario that failed while a read was held at the pool's reader, a window creation was withheld and a native window was live raised its own failure after the gates were released and the instance, window and texture were retired within the bound"


  it "answers an INJECTED clean refusal of one window's standing as that instance's required window failure, retires the window the host really made and the instance's texture, and leaves the live peer unaffected" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        -- The peer is fully live first, so what happens to the refused instance can only be seen not to reach it.
        b ← admitUi peers
        windowB ← awaitNewWindow peers []
        awaitAdopted peers windowB 1
        refuseNextStandings peers 1
        a ← admitUi peers
        windowA ← awaitNewWindow peers [windowB]
        failure ← instanceFailureText a
        failure `shouldSatisfy` maybe False (isInfixOf "window_error")
        -- The real native window the host made for A is closed and destroyed; A's texture request is retired with it.
        awaitWindowCount peers 1
        windowsNow peers >>= (`shouldBe` [windowB])
        awaitLiveTextures peers 1
        mark ← frameMark peers
        demandFrame peers windowB
        awaitFrame peers windowB 1 mark
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        stopUi peers b
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        -- Every cleanup close has happened by now: none of them was a user close.
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        evidence env (Text.pack ("INJECTED clean refusal: the production port answered window " <> show windowA <> "'s standing as a clean refusal (a window_error, a required failure); instance " <> show (spIdentity a) <> " failed with " <> show failure <> ", its real window was destroyed and its texture retired; the live peer " <> show (spIdentity b) <> " (window " <> show windowB <> ") kept its window and texture and no session stop was requested. The exit status 1 of a session that meets this is the owning tests' (LFE-23 'Integrated endings', the session's failure policy), not claimed here"))

  forM_ [("the first", 0 ∷ Int), ("the second", 1)] $ \(which, index) →
    it ("routes a user close of " <> which <> " live window to one whole-session quit request, which retires both instances and windows, unlike ending one instance") $
      withinCase env 120 . withOwnedContent $ \folder →
        withPeers (envStart env) folder $ \peers → do
          (a, windowA, boundA, b, windowB, boundB) ← startTwo env peers
          forM_ [windowA, windowB] $ \window → awaitAdopted peers window 1
          snap env peers (Text.pack ("user-close-" <> show index <> "--a-quad")) boundA
          snap env peers (Text.pack ("user-close-" <> show index <> "--b-quad")) boundB
          let closed = [windowA, windowB] !! index
          atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
          answer ← onMain peers (requestNativeClose (vulkanWindowHost (peHost peers)) closed)
          answer `shouldBe` NativeCloseDelivered
          step "the session's stop endpoint" . atomically $ readTVar (peStops peers) >>= \n → unless (n >= 1) retry
          -- A close request destroys nothing: both windows are still there until the session retires them.
          windowsNow peers >>= (`shouldBe` [windowA, windowB])
          -- The session answers the request by ending every instance, each through its own cleanup.
          mapM_ (stopUi peers) [a, b]
          awaitWindowCount peers 0
          awaitLiveTextures peers 0
          atomically (readTVar (peStops peers)) >>= (`shouldBe` 1)
          readTVarIO (peFatals peers) >>= (`shouldBe` [])
          evidence env (Text.pack ("user close of " <> which <> " window (" <> show closed <> "), a genuine platform-delivered close (native-check), not an injected one: exactly one stop request; both windows stayed until the instances were ended, then both retired and the textures were proved retired"))


-- | The case bound: the receipt's, or, in the supervised run that holds for the owner's confirmations, a long one.
withinCase ∷ Env → Int → IO a → IO a
withinCase env seconds = within (maybe seconds (const 3600) (envHold env))

-- | The windows' identities and the metrics the platform last reported, for a checkpoint's record.
factsFor ∷ Peers → [(Text, WindowId)] → IO Text
factsFor peers named = do
  facts ← forM named $ \(label, window) → do
    metrics ← windowMetrics peers window
    pure (label <> " window " <> Text.pack (show window) <> " " <> Text.pack (show metrics))
  pure (Text.intercalate "; " facts)

-- | Place a harness window in a slot of the desktop where no other harness window overlaps it, so that what the owner
-- looks at is that window's own pixels: side by side, through the public window command. (On the isolated X11 display a
-- capture isolates its own subject instead.)
placeWindow ∷ Env → Peers → WindowId → Int → IO ()
placeWindow env peers window slot = case envX11 env of
  Just _ → pure ()
  Nothing → do
    disposition ← requestPosition peers window position
    (window, attempted disposition) `shouldBe` (window, True)
  where
    -- On the isolated display the capture itself isolates its subject ('snap'), so nothing is placed here.
    position = (20 + 660 * slot, 60)

-- | Park a window out of the way, partly beyond the screen, when only its peer is looked at.
parkWindow ∷ Env → Peers → WindowId → IO ()
parkWindow env peers window = do
  disposition ← requestPosition peers window (case envX11 env of Just _ → (700, 720); Nothing → (1000, 500))
  (window, attempted disposition) `shouldBe` (window, True)

-- | Admit two instances so that each new native window is unambiguously its instance's: with the next two creation
-- outcomes withheld from the provider, the window that appears after A is admitted is A's and the one that appears
-- after B is admitted is B's (and, on the isolated X11 display, the one new viewable X window each time is bound to
-- it). The gate is released before the cases go on.
startTwo ∷ Env → Peers → IO (Spawned, WindowId, Maybe Bound, Spawned, WindowId, Maybe Bound)
startTwo env peers = do
  note "startTwo: withholding two creations"
  withholdNextCreations peers 2
  known0 ← viewableNow env
  note ("startTwo: admitting A; X windows known: " <> show known0)
  a ← admitUi peers
  windowA ← awaitNewWindow peers []
  note ("startTwo: host window for A: " <> show windowA)
  boundA ← bindNew env peers windowA known0
  placeWindow env peers windowA 0
  b ← admitUi peers
  windowB ← awaitNewWindow peers [windowA]
  note ("startTwo: host window for B: " <> show windowB)
  boundB ← bindNew env peers windowB (known0 <> map boundX (maybe [] pure boundA))
  placeWindow env peers windowB 1
  releaseCreations peers
  note "startTwo: creations released"
  pure (a, windowA, boundA, b, windowB, boundB)

quadPath ∷ ByteString
quadPath = "images/quad.png"

withOwnedContent ∷ (FilePath → IO a) → IO a
withOwnedContent use = withSystemTempDirectory "hetoimasia-native-milestone" $ \folder → do
  copyTree shippedContent folder
  unchanged ← ByteString.readFile (shippedContent <> "/lua/main.lua")
  copied ← ByteString.readFile (folder <> "/lua/main.lua")
  unchanged `shouldBe` copied
  use folder
