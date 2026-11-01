{-# LANGUAGE OverloadedStrings #-}

-- | What the milestone cases observe of the host and its windows, and the public controls they drive them with.
--
-- Everything here reads the host's own public facts (window identities, the scene state the owner adopted, the frame
-- events, a window's latest observation) or submits the public window commands of "Hetoimasia.GLFW.Command" (resize,
-- minimize, restore) and waits for their disposition. Every wait is on a fact in STM, bounded and naming itself when
-- it does not end; none is a sleep standing in for evidence. A control's disposition says the native call was made, not
-- that the window reached the state: what it reached is what the next observation reports, and only that is recorded.
module Test.Run.Native.Observe
  ( Metrics (..)
  , windowMetrics
  , awaitMetrics
  , controlWindow
  , requestSize
  , requestMinimize
  , requestRestore
  , awaitWindowCount
  , awaitNewWindow
  , windowsNow
  , awaitAdopted
  , adoptedRevision
  , publishedRevisionOf
  , frameMark
  , awaitFrame
  , freshEvents
  , attempted
  , demandFrame
  , awaitLiveTextures
  , step
  , within
  ) where

import Control.Concurrent.STM (STM, atomically, readTVar, retry)
import Control.Monad (unless)
import qualified Data.Map.Strict as Map
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.GLFW.Command
  ( Disposition (..)
  , SubmitResult (..)
  , WindowClient
  , awaitCompletion
  , clientCommandPort
  , clientDemandPublisher
  , clientObservations
  , minimizeWindowCommand
  , restoreWindowCommand
  , setWindowSizeCommand
  , submitWindowCommand
  , WindowCommand
  )
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Window
  ( Attribute (..)
  , ContentScale (..)
  , Extent (..)
  , WindowId
  , observedContentScale
  , observedFramebufferExtent
  , observedIconified
  , observedLogicalExtent
  , observedRevision
  , observedVisible
  )
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , SceneTargetKey (..)
  , VulkanHost (..)
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , readVulkanSceneState
  )
import Hetoimasia.LuaEngine.Graphics.Texture (BackendReading (..), TextureGraphics (..))
import Hetoimasia.Runtime.GLFW (attachmentWindow, hostWindowClient, hostWindowIdentities)
import Numeric.Natural (Natural)
import System.Timeout (timeout)
import Test.Hspec (expectationFailure)
import Test.Run.Native.Peers (Peers (..))

-- | What a window's latest observation reported, as the platform reported it ('Nothing': unavailable).
data Metrics = Metrics
  { metricsRevision ∷ !Natural
  , metricsLogical ∷ !(Maybe (Int, Int))
  , metricsFramebuffer ∷ !(Maybe (Int, Int))
  , metricsScale ∷ !(Maybe (Float, Float))
  , metricsIconified ∷ !(Maybe Bool)
  , metricsVisible ∷ !(Maybe Bool)
  }
  deriving (Eq, Show)

attribute ∷ Attribute a → Maybe a
attribute = \case
  Observed value → Just value
  Unavailable → Nothing

clientOf ∷ Peers → WindowId → IO WindowClient
clientOf peers window =
  atomically (hostWindowClient (vulkanWindowHost (peHost peers)) window) >>= \case
    Nothing → expectationFailure ("window " <> show window <> " has no client") >> error "unreachable"
    Just client → pure client

-- | The window's latest published observation.
windowMetrics ∷ Peers → WindowId → IO Metrics
windowMetrics peers window = clientOf peers window >>= \client → atomically (metricsOf client)

metricsOf ∷ WindowClient → STM Metrics
metricsOf client = do
  observation ← readSnapshot (clientObservations client)
  let seen = preparedValue (observedValue observation)
      extent (Extent width height) = (width, height)
  pure
    Metrics
      { metricsRevision = observedRevision seen
      , metricsLogical = extent <$> attribute (observedLogicalExtent seen)
      , metricsFramebuffer = extent <$> attribute (observedFramebufferExtent seen)
      , metricsScale = (\(ContentScale x y) → (x, y)) <$> attribute (observedContentScale seen)
      , metricsIconified = attribute (observedIconified seen)
      , metricsVisible = attribute (observedVisible seen)
      }

-- | Block until the window's observation satisfies this, and answer it. The wait is on the observation's own changes.
awaitMetrics ∷ Peers → WindowId → String → (Metrics → Bool) → IO Metrics
awaitMetrics peers window label wanted = do
  client ← clientOf peers window
  step label . atomically $ do
    now ← metricsOf client
    if wanted now then pure now else retry

-- | Submit a public window command and wait for its disposition.
controlWindow ∷ Peers → WindowId → WindowCommand → IO Disposition
controlWindow peers window command = do
  client ← clientOf peers window
  submitWindowCommand (clientCommandPort client) [("client", "native-milestone")] command >>= \case
    SubmitAccepted ticket → step "the command's disposition" (awaitCompletion ticket)
    SubmitFull → expectationFailure "the window's command port was full" >> error "unreachable"
    SubmitClosed → expectationFailure "the window's command port was closed" >> error "unreachable"

requestSize ∷ Peers → WindowId → (Int, Int) → IO Disposition
requestSize peers window (width, height) = controlWindow peers window (setWindowSizeCommand window (Extent width height))

requestMinimize, requestRestore ∷ Peers → WindowId → IO Disposition
requestMinimize peers window = controlWindow peers window (minimizeWindowCommand window)
requestRestore peers window = controlWindow peers window (restoreWindowCommand window)

windowsNow ∷ Peers → IO [WindowId]
windowsNow peers = atomically (hostWindowIdentities (vulkanWindowHost (peHost peers)))

-- | Block until exactly this many windows exist.
awaitWindowCount ∷ Peers → Int → IO ()
awaitWindowCount peers wanted =
  step ("exactly " <> show wanted <> " windows") . atomically $ do
    windows ← hostWindowIdentities (vulkanWindowHost (peHost peers))
    unless (length windows == wanted) retry

-- | Block until exactly one window not in this list exists, and answer it.
awaitNewWindow ∷ Peers → [WindowId] → IO WindowId
awaitNewWindow peers earlier = step "a new window" . atomically $ do
  windows ← hostWindowIdentities (vulkanWindowHost (peHost peers))
  case filter (`notElem` earlier) windows of
    [window] → pure window
    _ → retry

-- | Block until the owner adopted at least this revision of the window's scene.
awaitAdopted ∷ Peers → WindowId → Natural → IO ()
awaitAdopted peers window revision = step ("the adoption of revision " <> show revision <> " of window " <> show window) . atomically $ do
  state ← readVulkanSceneState (peHost peers)
  case Map.lookup (KeyWindow window) (sceneWindows state) >>= windowAdopted of
    Just adopted | adopted >= revision → pure ()
    _ → retry

adoptedRevision ∷ Peers → WindowId → IO (Maybe Natural)
adoptedRevision peers window = do
  state ← atomically (readVulkanSceneState (peHost peers))
  pure (Map.lookup (KeyWindow window) (sceneWindows state) >>= windowAdopted)

publishedRevisionOf ∷ Peers → WindowId → IO (Maybe Natural)
publishedRevisionOf peers window = do
  state ← atomically (readVulkanSceneState (peHost peers))
  pure (Map.lookup (KeyWindow window) (sceneWindows state) >>= windowPublished)

-- | The number of frame events seen so far.
frameMark ∷ Peers → IO Int
frameMark peers = fst <$> atomically (readTVar (peFrames peers))

-- | Block until a frame was asked to be presented for the window with this revision after the first @mark@ events.
awaitFrame ∷ Peers → WindowId → Natural → Int → IO ()
awaitFrame peers window revision mark = step ("a frame of revision " <> show revision <> " of window " <> show window) . atomically $ do
  (count, events) ← readTVar (peFrames peers)
  let fresh = take (max 0 (count - mark)) events
  unless (or [attachmentWindow attachment == window && rendered == revision | FramePresentRequested attachment _ _ rendered ← fresh]) retry

-- | The frame events seen after the first @mark@ events, oldest first.
freshEvents ∷ Peers → Int → IO [FrameEvent]
freshEvents peers mark = do
  (count, events) ← atomically (readTVar (peFrames peers))
  pure (reverse (take (max 0 (count - mark)) events))

-- | Whether a window control's native calls were made (and so what the window reached is for the next observation).
attempted ∷ Disposition → Bool
attempted = \case
  Attempted _ → True
  _ → False

-- | Ask the window's target for another frame of what it holds.
demandFrame ∷ Peers → WindowId → IO ()
demandFrame peers window = do
  client ← clientOf peers window
  () <$ publishDemand (clientDemandPublisher client) immediateDemand

-- | Block until the adapter's table holds exactly this many live textures (not yet proved retired).
awaitLiveTextures ∷ Peers → Int → IO ()
awaitLiveTextures peers wanted = step (show wanted <> " live textures") . atomically $ do
  reading ← graphicsReading (peGraphics peers)
  unless (readingLiveTextures reading == wanted) retry

-- | A wait that names itself when it does not end.
step ∷ String → IO a → IO a
step label action =
  timeout (40 * 1000000) action >>= \case
    Just value → pure value
    Nothing → expectationFailure ("no " <> label <> " within 40 seconds") >> error "unreachable"

-- | Bound a whole case.
within ∷ Int → IO a → IO a
within seconds action =
  timeout (seconds * 1000000) action >>= \case
    Just value → pure value
    Nothing → expectationFailure ("the example did not finish within " <> show seconds <> " seconds") >> error "unreachable"
