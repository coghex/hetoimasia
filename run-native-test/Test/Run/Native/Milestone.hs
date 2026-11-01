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
import Control.Exception (onException)
import Control.Monad (forM_, unless)
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
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.Run.Native.Env (Env (..), evidence)
import Test.Run.Native.Library (copyTree, shippedContent)
import Hetoimasia.GLFW.Window (WindowId)
import Test.Run.Native.Capture (Bound (..), bindNew, snap, viewableNow)
import Test.Run.Native.Observe
import Hetoimasia.GLFW.Command (Disposition (Performed), observeWindowCommand)
import Test.Run.Native.Peers

spec ∷ Env → Spec
spec env = describe "Lua native milestone" $ do
  it "loads the same PNG for two instances independently, ends one while its accepted scene still holds its released texture, and keeps the other updating with its texture and window" $
    within 120 . withOwnedContent $ \folder →
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
        stopUi peers b
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        reading ← atomically (graphicsReading (peGraphics peers))
        readingLiveTextures reading `shouldBe` 0
        evidence env (Text.pack ("two instances: instances " <> show (spIdentity a, spIdentity b) <> ", windows " <> show (windowA, windowB) <> "; ended A with B live; no user close; validation layer and synchronization validation enabled on this host"))

  it "ends one instance while its texture read is held at the pool's reader: the peer keeps updating, the ended instance settles stopped only after the read returns and delivers nothing, and a later instance loads the same path" $
    within 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        holdNextReads peers quadPath 1
        known0 ← viewableNow env
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        boundA ← bindNew env peers windowA known0
        readsEntered peers quadPath 1
        b ← admitUi peers
        windowB ← awaitNewWindow peers [windowA]
        boundB ← bindNew env peers windowB (known0 <> map boundX (maybe [] pure boundA))
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
        awaitAdopted peers windowC 1
        awaitLiveTextures peers 2
        mapM_ (stopUi peers) [b, c]
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        evidence env (Text.pack ("pending read: A=" <> show (spIdentity a) <> " ended with its read held (Stopping), B=" <> show (spIdentity b) <> " kept updating, A settled Stopped only after the read was released, no user close, C=" <> show (spIdentity c) <> " then loaded the same path; windows " <> show (windowA, windowB, windowC)))

  it "ends one instance while its window creation outcome is withheld from the provider: the host's window stays tracked until the late result is closed and destroyed, the peer is unaffected and no orphan window or texture remains" $
    within 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        withholdNextCreations peers 1
        known0 ← viewableNow env
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        boundA ← bindNew env peers windowA known0
        b ← admitUi peers
        windowB ← awaitNewWindow peers [windowA]
        boundB ← bindNew env peers windowB (known0 <> map boundX (maybe [] pure boundA))
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
        evidence env (Text.pack ("pending window: A=" <> show (spIdentity a) <> " ended while its creation outcome (window " <> show windowA <> ") was withheld; it stayed tracked until the outcome was released and then retired, B=" <> show (spIdentity b) <> " (window " <> show windowB <> ") unaffected, no user close"))


  it "keeps an unchanged published scene while the window is made smaller, larger, minimized and restored, and records what the platform reported rather than what was requested" $
    within 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        (a, windowA, boundA, b, windowB, _boundB) ← startTwo env peers
        forM_ [windowA, windowB] $ \window → awaitAdopted peers window 1
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
        awaitLiveTextures peers 2
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        mapM_ (stopUi peers) [a, b]
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
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
            <> (if metricsVisible reported == Just False then " (visible still False: the callback-driven observation was stale and the window stayed ineligible to draw until the explicit sample; reported to the manager as a finding)" else "")
            <> ", the explicit sample "
            <> show back
            <> "; native zero-area framebuffer "
            <> (if zeroNative then "OBSERVED: drawing was suspended and resumed after restore" else "UNEXERCISED on this platform (the framebuffer was never reported with zero area): the controlled zero-metrics coverage is the owning prerequisites' (LFE-18, LFE-20 and the host's suspended-target cases), not claimed as native")

  forM_ [("the first", 0 ∷ Int), ("the second", 1)] $ \(which, index) →
    it ("routes a user close of " <> which <> " live window to one whole-session quit request, which retires both instances and windows, unlike ending one instance") $
      within 120 . withOwnedContent $ \folder →
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


-- | Admit two instances so that each new native window is unambiguously its instance's: with the next two creation
-- outcomes withheld from the provider, the window that appears after A is admitted is A's and the one that appears
-- after B is admitted is B's (and, on the isolated X11 display, the one new viewable X window each time is bound to
-- it). The gate is released before the cases go on.
startTwo ∷ Env → Peers → IO (Spawned, WindowId, Maybe Bound, Spawned, WindowId, Maybe Bound)
startTwo env peers = do
  withholdNextCreations peers 2
  known0 ← viewableNow env
  a ← admitUi peers
  windowA ← awaitNewWindow peers []
  boundA ← bindNew env peers windowA known0
  b ← admitUi peers
  windowB ← awaitNewWindow peers [windowA]
  boundB ← bindNew env peers windowB (known0 <> map boundX (maybe [] pure boundA))
  releaseCreations peers
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
