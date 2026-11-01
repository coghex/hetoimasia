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
import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import Control.Concurrent.STM (newTVarIO)
import Control.Exception (AsyncException (UserInterrupt), ExceptionWithContext (..), SomeException, finally, fromException, onException, tryWithContext, uninterruptibleMask_)
import Data.List (isInfixOf)
import Data.Maybe (isJust)
import Test.HUnit.Lang (HUnitFailure (..))
import Control.Monad (forM, forM_, unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.Set as Set
import System.Directory (doesDirectoryExist)
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
import Test.Run.Native.Capture (Bound (..), bindNew, ownPid, snap, snapAs, viewableNow)
import Test.Run.Native.Json (Json (..))
import Test.Run.Native.Landmarks (blackLandmarks)
import Test.Run.Native.Lifecycle (Disposal (..), awaitDisposal, disposalFollowedObligations, disposalRecord, disposalsSoFar, heldTextures, writeLifecycle)
import qualified Test.Run.Native.X11 as X11
import Test.Run.Native.Checkpoint (checkpoint)
import Test.Run.Native.Observe
import Test.Run.Native.Owned (withOwnedThread)
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
  it "loads the same PNG for two instances independently, ends one while its accepted scene still holds its released texture, and keeps the other updating with the same texture and window" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        -- A's window is created first and B's second: with creation outcomes withheld from the provider, each new
        -- native window is the only one that appeared since the instance was admitted, so it is that instance's.
        heldAlone ← newIORef Set.empty
        (a, windowA, _boundA, b, windowB, boundB) ← startTwo env peers $ \_ bound → do
          snap env peers "two-instances--a-quad" bound
          heldTextures peers >>= writeIORef heldAlone
        spIdentity a `shouldNotBe` spIdentity b
        spInstance a `shouldNotBe` spInstance b
        windowA `shouldNotBe` windowB
        awaitAdopted peers windowB 1
        snap env peers "two-instances--b-quad" boundB
        checkpoint env "two-instances-quads" "the owner confirms the textured quad is visible in both windows, the same picture in each" =<< factsFor peers [("A", windowA), ("B", windowB)]
        -- Two textures were allocated, uploaded and registered: the same path was never coalesced. The ledger names them.
        awaitLiveTextures peers 2
        idsA ← readIORef heldAlone
        both ← heldTextures peers
        Set.size idsA `shouldBe` 1
        Set.size both `shouldBe` 2
        (idsA `Set.isSubsetOf` both) `shouldBe` True
        let idsB = both `Set.difference` idsA
        -- The independent logical owner is alive and ticking on its own clock beside both.
        ticksBefore ← logicalAdvances peers
        -- Ending A through its public lifecycle control closes only its window, and is never a user close.
        beforeA ← disposalsSoFar peers
        stopUi peers a
        awaitWindowCount peers 1
        remaining ← windowsNow peers
        remaining `shouldBe` [windowB]
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        awaitLiveTextures peers 1
        -- A's disposal followed what A asked of the GPU: at every native disposal call that ended A's graphics, in the order
        -- the host made them among its frame events, every submission A's frames had made had completed and every
        -- presentation had retired. Read from the order recorded as the calls happened, not from what finished after.
        disposalA ← awaitDisposal peers windowA beforeA
        disposalFollowedObligations disposalA `shouldBe` True
        dsSurfaceDestroyed disposalA `shouldBe` True
        afterEnd ← heldTextures peers
        afterEnd `shouldBe` idsB
        -- B continues: another frame of what it holds, with the same revision, and nothing reloaded: the identity it
        -- holds is the one it held with A beside it.
        mark ← frameMark peers
        demandFrame peers windowB
        awaitFrame peers windowB 1 mark
        publishedRevisionOf peers windowB >>= (`shouldBe` Just 1)
        afterFrame ← heldTextures peers
        afterFrame `shouldBe` idsB
        -- B's quad is still right on the display.
        snap env peers "two-instances--b-after-a-ended" boundB
        checkpoint env "peer-survival" "the owner confirms A's window is gone and B's window still shows the correct quad, never reloaded" =<< factsFor peers [("B", windowB)]
        beforeB ← disposalsSoFar peers
        stopUi peers b
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        disposalB ← awaitDisposal peers windowB beforeB
        disposalFollowedObligations disposalB `shouldBe` True
        dsSurfaceDestroyed disposalB `shouldBe` True
        heldEnd ← heldTextures peers
        Set.null heldEnd `shouldBe` True
        ticksAfter ← logicalAdvances peers
        (ticksAfter > ticksBefore) `shouldBe` True
        -- Every cleanup close has happened by now: none of them was a user close.
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        reading ← atomically (graphicsReading (peGraphics peers))
        readingLiveTextures reading `shouldBe` 0
        writeLifecycle env "two-instances"
          [ ("instances", JArray [JString (spIdentity a), JString (spIdentity b)])
          , ("windows", JArray [JString (Text.pack (show windowA)), JString (Text.pack (show windowB))])
          , ("texture_identity_a", JArray (map (JNumber . fromIntegral) (Set.toList idsA)))
          , ("texture_identity_b", JArray (map (JNumber . fromIntegral) (Set.toList idsB)))
          , ("texture_identities_held_after_a_ended", JArray (map (JNumber . fromIntegral) (Set.toList afterEnd)))
          , ("texture_identities_held_after_b_frame", JArray (map (JNumber . fromIntegral) (Set.toList afterFrame)))
          , ("a_disposal", disposalRecord "A" disposalA)
          , ("b_disposal", disposalRecord "B" disposalB)
          , ("logical_owner_tick_while_both_live", JNumber (fromIntegral ticksBefore))
          , ("logical_owner_tick_at_end", JNumber (fromIntegral ticksAfter))
          , ("user_close_requests", JNumber 0)
          ]
        evidence env (Text.pack ("two instances: instances " <> show (spIdentity a, spIdentity b) <> ", windows " <> show (windowA, windowB) <> ", texture identities " <> show (Set.toList idsA, Set.toList idsB) <> "; ended A with B live: A's submissions and presentations had completed and retired at its disposal, B held the same identity throughout (nothing reloaded), the logical owner ticked from " <> show ticksBefore <> " to " <> show ticksAfter <> " and retired in order; no user close; validation layer and synchronization validation enabled on this host"))

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
        -- B's texture is the only identity any scene holds: A's read is still held, so A has no texture yet.
        idsB0 ← heldTextures peers
        Set.size idsB0 `shouldBe` 1
        -- A is ended with its read borrowed by a worker: it cannot settle until the read returns.
        beforeA ← disposalsSoFar peers
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
        -- A's late result was discarded, never delivered to its ended Lua and never adopted: no new identity appeared, B's
        -- is the one still held, and everything A asked of the GPU has finished.
        disposalAPending ← awaitDisposal peers windowA beforeA
        disposalFollowedObligations disposalAPending `shouldBe` True
        heldAfterRelease ← heldTextures peers
        heldAfterRelease `shouldBe` idsB0
        writeLifecycle env "pending-read"
          [ ("ended_instance", JString (spIdentity a))
          , ("peer_instance", JString (spIdentity b))
          , ("peer_texture_identity", JArray (map (JNumber . fromIntegral) (Set.toList idsB0)))
          , ("texture_identities_held_after_the_late_result", JArray (map (JNumber . fromIntegral) (Set.toList heldAfterRelease)))
          , ("ended_window_disposal", disposalRecord "A" disposalAPending)
          ]
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
        idsBeforeEnd ← heldTextures peers
        atomically (creationsWithheld peers) >>= (`shouldBe` 1)
        beforeA ← disposalsSoFar peers
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
        disposalAWithheld ← awaitDisposal peers windowA beforeA
        disposalFollowedObligations disposalAWithheld `shouldBe` True
        heldAfterWindowRetired ← heldTextures peers
        heldAfterWindowRetired `shouldBe` idsBeforeEnd
        writeLifecycle env "pending-window"
          [ ("ended_instance", JString (spIdentity a))
          , ("peer_instance", JString (spIdentity b))
          , ("texture_identities_before", JArray (map (JNumber . fromIntegral) (Set.toList idsBeforeEnd)))
          , ("texture_identities_after_the_withheld_outcome_was_released", JArray (map (JNumber . fromIntegral) (Set.toList heldAfterWindowRetired)))
          , ("ended_window_disposal", disposalRecord "A" disposalAWithheld)
          ]
        awaitLiveTextures peers 1
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        stopUi peers b
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        -- Every cleanup close has happened by now: none of them was a user close.
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        evidence env (Text.pack ("pending window: A=" <> show (spIdentity a) <> " ended while its creation outcome (window " <> show windowA <> ") was withheld; it stayed tracked until the outcome was released and then retired, B=" <> show (spIdentity b) <> " (window " <> show windowB <> ") unaffected, no user close"))


  it "shows the initial empty window while its texture read is held, then the textured quad in the same window once the gate is released, with the instance never ended" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        known0 ← viewableNow env
        holdNextReads peers quadPath 1
        withholdNextCreations peers 1
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        boundA ← bindNew env peers windowA known0
        releaseCreations peers
        readsEntered peers quadPath 1
        -- Initial output: the window is ready and the owner adopted its initial empty scene (revision 0) while the
        -- instance's texture read is borrowed and held: nothing is published and no texture identity is held.
        awaitAdopted peers windowA 0
        atomically (readsHeld peers quadPath) >>= (`shouldBe` 1)
        publishedRevisionOf peers windowA >>= (`shouldSatisfy` maybe True (< 1))
        mark ← frameMark peers
        demandFrame peers windowA
        awaitFrame peers windowA 0 mark
        initialHeld ← heldTextures peers
        Set.null initialHeld `shouldBe` True
        awaitLiveTextures peers 0
        snapAs env peers "initial-empty--a-black" blackLandmarks boundA
        -- The gate is released and the instance goes on: the same window is adopted with the textured scene.
        releaseReadsOf peers quadPath
        awaitAdopted peers windowA 1
        windowsNow peers >>= (`shouldBe` [windowA])
        atomically (instancePhaseOf peers a) >>= (`shouldBe` Just Active)
        awaitLiveTextures peers 1
        loadedHeld ← heldTextures peers
        Set.size loadedHeld `shouldBe` 1
        snap env peers "initial-empty--a-quad" boundA
        beforeA ← disposalsSoFar peers
        stopUi peers a
        awaitWindowCount peers 0
        awaitLiveTextures peers 0
        disposalA ← awaitDisposal peers windowA beforeA
        disposalFollowedObligations disposalA `shouldBe` True
        dsSurfaceDestroyed disposalA `shouldBe` True
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        writeLifecycle env "initial-empty"
          [ ("instance", JString (spIdentity a))
          , ("window", JString (Text.pack (show windowA)))
          , ("adopted_revision_while_the_read_was_held", JNumber 0)
          , ("texture_identities_held_while_the_read_was_held", JArray [])
          , ("texture_identity_after_release", JArray (map (JNumber . fromIntegral) (Set.toList loadedHeld)))
          , ("window_disposal", disposalRecord "A" disposalA)
          ]
        evidence env (Text.pack ("initial empty window: instance " <> show (spIdentity a) <> " window " <> show windowA <> " showed its initial empty scene (revision 0, no texture identity held) while its texture read was held at the pool's reader, then the same window adopted the textured scene (revision 1, texture identity " <> show (Set.toList loadedHeld) <> ") once the gate was released; the instance was never ended in between"))

  it "keeps an unchanged published scene while the window is made smaller, larger, minimized and restored, and records what the platform reported rather than what was requested" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        known0 ← viewableNow env
        withholdNextCreations peers 1
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        boundA ← bindNew env peers windowA known0
        releaseCreations peers
        awaitAdopted peers windowA 1
        -- The subject is the only window until, if ever, a peer is needed to pace a native zero-area framebuffer.
        pacemaker ← newIORef Nothing
        _ ← logicalAdvances peers
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
              -- What the window reported before this step: a new reading is one the step itself produced, either the
              -- size that was asked for or a different one published after it.
              before ← windowMetrics peers windowA
              disposition ← requestSize peers windowA (width, height)
              (label, attempted disposition) `shouldBe` (label, True)
              reached ← awaitMetrics peers windowA (label <> " to be reported") (\m → metricsLogical m == Just (width, height) || (metricsLogical m /= metricsLogical before && metricsRevision m > metricsRevision before))
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
            -- A native zero-area framebuffer: drawing is suspended for this window while a peer, admitted now to pace it
            -- and keeping its size, is still presented and its presentations still retire; no frame of this window's
            -- is requested.
            peer ← admitUi peers
            windowB ← awaitNewWindow peers [windowA]
            awaitAdopted peers windowB 1
            writeIORef pacemaker (Just peer)
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
        -- What the platform's own callbacks reported once the restore took effect. A restored window could once stay
        -- ineligible to draw until something sampled it again (#581); that is fixed, so nothing here samples it: it must
        -- report itself drawable by itself, and that is the regression check.
        reported ← awaitMetrics peers windowA "the restore to be reported" (\m → metricsIconified m == Just False)
        back ← awaitMetrics peers windowA "the restored window to report itself drawable without a further sample" (\m → metricsIconified m == Just False && metricsVisible m /= Just False && maybe True (\(w, h) → w * h > 0) (metricsFramebuffer m))
        renders "restored"
        snap env peers "view--restored" boundA
        checkpoint env "restore" "the owner confirms the restored window shows the quad again" =<< factsFor peers [("subject", windowA)]
        paced ← readIORef pacemaker
        awaitLiveTextures peers (maybe 1 (const 2) paced)
        readTVarIO (peFatals peers) >>= (`shouldBe` [])
        atomically (readTVar (peStops peers)) >>= (`shouldBe` 0)
        mapM_ (stopUi peers) (a : maybe [] pure paced)
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
            <> (if metricsVisible reported == Just False then " (visible still False at that moment: the stale reading #581 fixed, and the window recovered by itself)" else " (drawable at once)")
            <> ", then, with no further sample, "
            <> show back
            <> "; native zero-area framebuffer "
            <> (if zeroNative then "OBSERVED: drawing was suspended and resumed after restore" else "UNEXERCISED on this platform (the framebuffer was never reported with zero area): the controlled zero-metrics coverage is the owning prerequisites' (LFE-18, LFE-20 and the host's suspended-target cases), not claimed as native")


  it "unwinds by itself, and raises its own failure with a clean teardown attached, when the scenario fails with a read held, a creation withheld and a window live" $
    withinCase env 120 . withOwnedContent $ \folder → do
      -- Only the scenario's own assertion failure is expected, matched by its type and its words, and its context is kept: the
      -- capture's verdict must be attached and clean and no scope may have retained a cleanup failure beside it. Any other
      -- exception, a hang in the unwinding (a gate left closed) or a failed teardown fails this example.
      outcome ← tryWithContext @HUnitFailure . withPeers (envStart env) folder $ \peers → do
        holdNextReads peers quadPath 1
        withholdNextCreations peers 1
        _ ← admitUi peers
        _ ← awaitNewWindow peers []
        readsEntered peers quadPath 1
        expectationFailure "the scenario failed on purpose"
      case outcome of
        Left failure@(ExceptionWithContext _ (HUnitFailure _ reason)) → do
          show reason `shouldSatisfy` isInfixOf "the scenario failed on purpose"
          teardownProblems failure `shouldBe` []
        Right () → expectationFailure "the scenario's failure was swallowed"
      evidence env "unwinding control: a scenario that failed while a read was held at the pool's reader, a window creation was withheld and a native window was live raised its own failure after the gates were released and the instance, window and texture were retired within the bound, with the capture's diagnostic verdict attached and clean and no cleanup failure retained"

  it "stops its scenario, releases its gates and waits for the retirement before it returns, when its caller is cancelled with a read held and a creation withheld" $
    withinCase env 120 . withOwnedContent $ \folder → do
      unwound ← newIORef False
      held ← newEmptyMVar
      never ← newTVarIO False
      caller ← myThreadId
      -- The cancellation is delivered once the gates are really held: an event, not a delay. The thread that delivers it is
      -- owned: stopped and joined however the example ends, so it cannot outlive this scope waiting for an event.
      outcome ← withOwnedThread (takeMVar held >> throwTo caller UserInterrupt) $ \_ _ → tryWithContext @SomeException . withPeers (envStart env) folder $ \peers → do
        holdNextReads peers quadPath 1
        withholdNextCreations peers 1
        _ ← admitUi peers
        _ ← awaitNewWindow peers []
        readsEntered peers quadPath 1
        -- The finalizer is installed before the cancellation can be requested: it protects the readiness publication and
        -- the wait, so a cancellation that lands the moment the sender is released still finds it.
        ( do
            putMVar held ()
            -- Nothing ends this wait but the cancellation; the scenario's own scopes must release and retire on the way out.
            atomically (readTVar never >>= \set → unless set retry)
          )
          `finally` writeIORef unwound True
      -- The call returned only after the application ended: the scenario's cleanup ran first, and the folder it borrowed is still here.
      -- What it raises is the caller's own cancellation, with the application's end retained beside it: the scenario's
      -- cancellation, a clean diagnostic verdict attached to it and no cleanup failure of its own.
      case outcome of
        Left failure@(ExceptionWithContext _ cancelled) → do
          (fromException cancelled ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
          cancellationProblems failure `shouldBe` []
        Right () → expectationFailure "the cancelled call returned normally"
      readIORef unwound >>= (`shouldBe` True)
      doesDirectoryExist folder >>= (`shouldBe` True)
      readTVarIO never >>= (`shouldBe` False)
      evidence env "cancellation control: a caller cancelled while its scenario held a read at the pool's reader and a window creation outcome had the scenario stopped, its gates released and its instance, window and texture retired before the call returned, and the folder it borrowed was still there"

  it "keeps stopping its scenario and retains the interruption, when its caller is cancelled a second time while the stop is being delivered to a scenario that cannot receive it yet" $
    withinCase env 120 . withOwnedContent $ \folder → do
      unwound ← newIORef False
      inRegion ← newEmptyMVar
      stopStarted ← newEmptyMVar
      release ← newEmptyMVar
      never ← newTVarIO False
      caller ← myThreadId
      -- The scenario cannot receive the stop (it is in an uninterruptible region), so its delivery blocks; the caller is
      -- cancelled again at that point. Each step waits for the event before it: the scenario being in the region, the stop
      -- being started; the scenario is released however the chain ends, so a failure here fails the example and does not hang it.
      -- The delivering thread is owned (stopped and joined however the example ends).
      outcome ←
       withOwnedThread
        ( ( takeMVar inRegion
              >> throwTo caller UserInterrupt
              >> takeMVar stopStarted
              >> throwTo caller UserInterrupt
          )
            `finally` tryPutMVar release ()
        )
        $ \_ _ → tryWithContext @SomeException . withPeersUsing noPeersHooks {hookStopping = () <$ tryPutMVar stopStarted ()} (envStart env) folder $ \peers → do
        holdNextReads peers quadPath 1
        withholdNextCreations peers 1
        _ ← admitUi peers
        _ ← awaitNewWindow peers []
        readsEntered peers quadPath 1
        ( do
            putMVar inRegion ()
            uninterruptibleMask_ (takeMVar release)
            atomically (readTVar never >>= \set → unless set retry)
          )
          `finally` writeIORef unwound True
      case outcome of
        Left failure@(ExceptionWithContext _ cancelled) → do
          (fromException cancelled ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
          cancellationProblems failure `shouldBe` []
          -- The second cancellation is kept beside the first, not lost.
          retainedLabels failure `shouldSatisfy` elem "a further interruption while the scenario was being stopped"
        Right () → expectationFailure "the cancelled call returned normally"
      readIORef unwound >>= (`shouldBe` True)
      doesDirectoryExist folder >>= (`shouldBe` True)
      evidence env "cancellation control, second cancellation: a caller cancelled again while the stop was being delivered to a scenario in an uninterruptible region kept stopping it, joined the application, retained the further interruption beside the first and the application's end (the scenario's cancellation, a clean attached verdict, no cleanup failure), and the folder it borrowed was still there"

  it "retains the application's terminal failure and its clean diagnostic verdict when its caller is cancelled as the application ends, before the result is published" $
    withinCase env 120 . withOwnedContent $ \folder → do
      caller ← myThreadId
      -- The cancellation is delivered from the main thread after the application has ended and before its result reaches the caller.
      outcome ← tryWithContext @SomeException . withPeersUsing noPeersHooks {hookBeforeResult = throwTo caller UserInterrupt} (envStart env) folder $ \_ →
        expectationFailure "the scenario failed on purpose"
      case outcome of
        Left failure@(ExceptionWithContext _ cancelled) → do
          (fromException cancelled ∷ Maybe AsyncException) `shouldBe` Just UserInterrupt
          case applicationEnds failure of
            [end@(ExceptionWithContext _ ended)] → do
              teardownProblems end `shouldBe` []
              (fromException ended ∷ Maybe HUnitFailure) `shouldSatisfy` isJust
            other → expectationFailure ("the application's end was retained " <> show (length other) <> " times, not once")
        Right () → expectationFailure "the cancelled call returned normally"
      evidence env "cancellation control, completion race: a caller cancelled after the application had ended and before its result was published still collected the application's terminal failure with its clean diagnostic verdict, retained beside the cancellation"

  it "answers an INJECTED clean refusal of one window's standing as that instance's required window failure, retires the window the host really made and the instance's texture, and leaves the live peer unaffected" $
    withinCase env 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        -- The peer is fully live first, so what happens to the refused instance can only be seen not to reach it.
        b ← admitUi peers
        windowB ← awaitNewWindow peers []
        awaitAdopted peers windowB 1
        -- A's creation outcome is withheld before A is admitted, so the real window it is given is observed and recorded
        -- while it is held, and only then released to meet the refusal: the refusal cannot destroy it first.
        withholdNextCreations peers 1
        refuseNextStandings peers 1
        a ← admitUi peers
        windowA ← awaitNewWindow peers [windowB]
        windowsNow peers >>= (`shouldBe` [windowB, windowA])
        releaseCreations peers
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
          (a, windowA, _boundA, b, windowB, boundB) ← startTwo env peers (\_ bound → snap env peers (Text.pack ("user-close-" <> show index <> "--a-quad")) bound)
          awaitAdopted peers windowB 1
          snap env peers (Text.pack ("user-close-" <> show index <> "--b-quad")) boundB
          _ ← logicalAdvances peers
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

-- | Admit two instances, one after the other, so that each new native window is unambiguously its instance's: with the
-- next creation outcome withheld from the provider, the window that appears after an instance is admitted is that
-- instance's (and, on the isolated X11 display, the one new viewable X window is bound to it). The gate is released
-- before the cases go on. The first instance is looked at /alone/: @whileAlone@ runs once its scene is adopted and
-- before the second instance exists, because an X server without a compositor answers a capture with whatever window is
-- on top, and the window created last is. Both are then placed side by side where an owner can see them.
startTwo ∷ Env → Peers → (WindowId → Maybe Bound → IO ()) → IO (Spawned, WindowId, Maybe Bound, Spawned, WindowId, Maybe Bound)
startTwo env peers whileAlone = do
  note "startTwo: admitting A"
  known0 ← viewableNow env
  withholdNextCreations peers 1
  a ← admitUi peers
  windowA ← awaitNewWindow peers []
  note ("startTwo: host window for A: " <> show windowA)
  boundA ← bindNew env peers windowA known0
  releaseCreations peers
  awaitAdopted peers windowA 1
  whileAlone windowA boundA
  note "startTwo: admitting B"
  withholdNextCreations peers 1
  b ← admitUi peers
  windowB ← awaitNewWindow peers [windowA]
  note ("startTwo: host window for B: " <> show windowB)
  boundB ← bindNew env peers windowB (known0 <> map boundX (maybe [] pure boundA))
  releaseCreations peers
  placeWindow env peers windowA 0
  placeWindow env peers windowB 1
  note "startTwo: both windows are up"
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
