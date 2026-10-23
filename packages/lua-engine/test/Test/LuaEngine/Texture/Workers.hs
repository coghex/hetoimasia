{-# LANGUAGE OverloadedStrings #-}

-- | The pipeline's workers, lanes and queues seen from Lua: two read workers shared with everyone,
-- two lanes, one decode worker, accepted work waiting in the pipeline's own bounded queue, execution
-- slots freed at the handoff while the backend still holds the work, the shared pool's priority for a
-- dependency read, and completion that needs none of the normal banks to have room.
module Test.LuaEngine.Texture.Workers (spec) where

import Control.Concurrent.MVar (readMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, replicateM_)
import qualified Data.Text as Text
import Hetoimasia.Content.ReadPool
  ( PoolStatus (..)
  , ReadPriority (..)
  , releaseSlot
  )
import Hetoimasia.LuaEngine.Profile (ByteLimit (..), CountLimit (..))
import Test.Hspec
import Test.LuaEngine.Request.Profiles (smaller)
import Test.LuaEngine.Texture.Contract (layout, loadAs, small, started)
import Test.LuaEngine.Texture.Support

spec ∷ Spec
spec = describe "workers, lanes and queues" $ do
  lanes
  slots
  priority
  saturation

lanes ∷ Spec
lanes = describe "the lanes" $ do
  it "starts two reads and keeps the third as accepted work in the pipeline's own queue, with the pool's queue empty; a lane freed by a finished upload starts it" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "lanes" OnArrival
      admitDriver session vm "i"
      closeGate (ssProbe session) "a.png"
      forM_ ["k0", "k1", "k2"] $ \key → started session vm "i" key "a.png"
      awaitStarted (ssProbe session) 2
      awaitPipeline session (\reading → readingReading reading == 2 && readingPending reading == 1)
      pool ← poolReading session
      (statusActive pool, statusQueued pool) `shouldBe` (2, 0)
      readsStarted (ssProbe session) `shouldReturn` 2
      openGate (ssProbe session) "a.png"
      awaitUploads (ssFake session) 2
      -- Both lanes hold their uploads: the third stays accepted and waits, with no read started.
      awaitPipeline session (\reading → readingUploading reading == 2 && readingPending reading == 1)
      readsStarted (ssProbe session) `shouldReturn` 2
      first ← uploadN (ssFake session) 0
      _ ← finishUpload (ssFake session) first
      awaitUploads (ssFake session) 3
      readsStarted (ssProbe session) `shouldReturn` 3
      maxActive (ssProbe session) >>= (`shouldSatisfy` (<= 2))

  it "has exactly two read workers, two lanes and one decode worker" $
    withSession (config small layout) $ \session _ _ → do
      awaitPipeline session ((== 1) . readingDecodeWorkers)
      reading ← pipelineNow session
      (length (readingLanes reading), readingDecodeWorkers reading) `shouldBe` (2, 1)
      statusWorkers <$> poolReading session `shouldReturn` 2

slots ∷ Spec
slots = describe "execution slots" $
  it "frees the read workers and the decode worker at the handoff while the backend still holds the work, so a read of another consumer completes" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "slots" OnArrival
      admitDriver session vm "i"
      forM_ ["k0", "k1", "k2"] $ \key → started session vm "i" key "a.png"
      awaitUploads (ssFake session) 2
      awaitPipeline session (\reading → readingUploading reading == 2 && readingDecoding reading == 0 && readingPending reading == 1)
      awaitPool session (\pool → statusActive pool == 0 && statusLive pool == 0)
      -- Every execution slot is free while two uploads are held and a third job waits for a lane.
      done ← directRead session OrdinaryRead "d.png"
      readMVar done `shouldReturn` True
      awaitPool session (\pool → statusLive pool == 0)
      atomically (releaseSlot (ssPool session))

priority ∷ Spec
priority = describe "the shared pool's priority" $
  it "serves a dependency read ahead of a texture read queued behind it, and leaves the module chain's own progress to the pool" $
    withSession (config small layout) $ \session _ runtime → do
      vm ← startVm session runtime "priority" OnArrival
      admitDriver session vm "i"
      let probe = ssProbe session
      mapM_ (closeGate probe) ["c.png", "d.png", "b.png"]
      first ← directRead session OrdinaryRead "c.png"
      second ← directRead session OrdinaryRead "d.png"
      awaitStarted probe 2
      -- Both workers are busy: the texture's read waits in the pool's queue, then a dependency read
      -- is queued behind it. The dependency is served first when one worker frees.
      started session vm "i" "k0" "a.png"
      awaitPool session (\pool → statusQueued pool == 1)
      dependency ← directRead session DependencyProgress "b.png"
      awaitPool session (\pool → statusQueued pool == 2)
      openGate probe "c.png"
      awaitStarted probe 3
      startedPaths probe >>= \paths → drop 2 paths `shouldBe` ["b.png"]
      openGate probe "d.png"
      awaitStarted probe 4
      startedPaths probe >>= (`shouldBe` ["c.png", "d.png", "b.png", "a.png"])
      openGate probe "b.png"
      readMVar dependency `shouldReturn` True
      mapM_ readMVar [first, second]
      awaitPool session (\pool → statusLive pool == 0)
      -- The consumer's own slots go back when its reads have retired.
      replicateM_ 3 (atomically (releaseSlot (ssPool session)))

saturation ∷ Spec
saturation = describe "with the normal banks full" $
  it "still completes and retires what was accepted: results settle with every request place held, and the next request is busy until one is taken" $
    withSession (config (smaller [(RequestsPerInstance, 2), (PngPixels, 1024), (PngAxisMaximum, 32)] bytes) layout) $ \session _ runtime → do
      vm ← startVm session runtime "full" OnArrival
      admitDriver session vm "i"
      started session vm "i" "k0" "a.png"
      started session vm "i" "k1" "b.png"
      loadAs session vm "i" "z" "c.png" >>= (`shouldBe` "i start z busy:busy:request capacity is not available: the instance holds all 2 of its request places")
      awaitUploads (ssFake session) 2
      forM_ [0, 1] $ \index → uploadN (ssFake session) index >>= finishUpload (ssFake session)
      forM_ ["k0", "k1"] $ \key → do
        command session vm "i" "wait_take" key
        line ← lineStarting session ("i wait_take " <> key <> " ")
        line `shouldSatisfy` Text.isInfixOf "status=success"
      -- Taking both and the work retiring gives the request places back; the textures stay charged.
      started session vm "i" "k2" "c.png"
      ownerNow vm "i" >>= \reading → ownerSlotsHeld reading `shouldBe` 3
  where
    bytes =
      [ (PngEncodedBytes, 65536)
      , (PngInflatedScanlineBytes, 65536)
      , (PngPipelineWorkspaceBytes, 1048576)
      , (TextureBytesPerUiInstance, 16384)
      , (TextureBytesPerSession, 32768)
      ]
