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

import Control.Concurrent.STM (atomically, readTVar, readTVarIO)
import Control.Monad (forM_)
import qualified Data.ByteString as ByteString
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
        withheldCreations peers
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

withOwnedContent ∷ (FilePath → IO a) → IO a
withOwnedContent use = withSystemTempDirectory "hetoimasia-native-milestone" $ \folder → do
  copyTree shippedContent folder
  unchanged ← ByteString.readFile (shippedContent <> "/lua/main.lua")
  copied ← ByteString.readFile (folder <> "/lua/main.lua")
  unchanged `shouldBe` copied
  use folder
