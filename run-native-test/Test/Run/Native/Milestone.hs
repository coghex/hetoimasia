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
import Control.Monad (forM_, unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Hetoimasia.GLFW.NativeCheck (NativeCloseAnswer (..), requestNativeClose)
import Hetoimasia.GPU.Vulkan.GLFW (VulkanHost (..))
import Hetoimasia.Scripting.Lua.Instance (InstancePhase (..))
import qualified Data.Text as Text
import Hetoimasia.LuaEngine.Graphics.Texture (BackendReading (..), TextureGraphics (..))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.Run.Native.Env (Env (..), evidence)
import Test.Run.Native.Library (copyTree, shippedContent)
import Test.Run.Native.Observe
import Test.Run.Native.Peers

spec ∷ Env → Spec
spec env = describe "Lua native milestone" $ do
  it "loads the same PNG for two instances independently, ends one while its accepted scene still holds its released texture, and keeps the other updating with its texture and window" $
    within 120 . withOwnedContent $ \folder →
      withPeers (envStart env) folder $ \peers → do
        -- A's window is created first and B's second: with creation outcomes withheld from the provider, each new
        -- native window is the only one that appeared since the instance was admitted, so it is that instance's.
        withholdNextCreations peers 2
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        b ← admitUi peers
        windowB ← awaitNewWindow peers [windowA]
        releaseCreations peers
        spIdentity a `shouldNotBe` spIdentity b
        spInstance a `shouldNotBe` spInstance b
        windowA `shouldNotBe` windowB
        forM_ [windowA, windowB] $ \window → awaitAdopted peers window 1
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
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        readsEntered peers quadPath 1
        b ← admitUi peers
        windowB ← awaitNewWindow peers [windowA]
        awaitAdopted peers windowB 1
        atomically (readsHeld peers quadPath) >>= (`shouldBe` 1)
        -- A is ended with its read borrowed by a worker: it cannot settle until the read returns.
        stopUi peers a
        step "A's phase to become Stopping" . atomically $ instancePhaseOf peers a >>= \phase → unless (phase == Just Stopping) retry
        mark ← frameMark peers
        demandFrame peers windowB
        awaitFrame peers windowB 1 mark
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
        a ← admitUi peers
        windowA ← awaitNewWindow peers []
        b ← admitUi peers
        windowB ← awaitNewWindow peers [windowA]
        awaitAdopted peers windowB 1
        atomically (creationsWithheld peers) >>= (`shouldBe` 1)
        stopUi peers a
        -- A's accepted window work is still pending: its native window is tracked until the provider collects the
        -- outcome and retires it, and the peer neither notices nor stops.
        mark ← frameMark peers
        demandFrame peers windowB
        awaitFrame peers windowB 1 mark
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

  forM_ [("the first", 0 ∷ Int), ("the second", 1)] $ \(which, index) →
    it ("routes a user close of " <> which <> " live window to one whole-session quit request, which retires both instances and windows, unlike ending one instance") $
      within 120 . withOwnedContent $ \folder →
        withPeers (envStart env) folder $ \peers → do
          withholdNextCreations peers 2
          a ← admitUi peers
          windowA ← awaitNewWindow peers []
          b ← admitUi peers
          windowB ← awaitNewWindow peers [windowA]
          releaseCreations peers
          forM_ [windowA, windowB] $ \window → awaitAdopted peers window 1
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


quadPath ∷ ByteString
quadPath = "images/quad.png"

withOwnedContent ∷ (FilePath → IO a) → IO a
withOwnedContent use = withSystemTempDirectory "hetoimasia-native-milestone" $ \folder → do
  copyTree shippedContent folder
  unchanged ← ByteString.readFile (shippedContent <> "/lua/main.lua")
  copied ← ByteString.readFile (folder <> "/lua/main.lua")
  unchanged `shouldBe` copied
  use folder
