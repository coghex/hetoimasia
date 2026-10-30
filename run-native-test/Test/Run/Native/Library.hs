-- | The command's production composition on a real device, with real windows, observed through the host's own
-- public lifecycle: the shipped content (an unchanged copy), the accepted common-entry quad example as ordinary
-- Lua in the roles of a real session, a real verified PNG read and decoded by the pipeline, a GPU-ready texture, a
-- ready native window and the scene publication.
--
-- /No pixel is captured or read back, and none is claimed/ (offscreen pixel proof is LFE-24's, visible output
-- qualification LFE-25's). The evidence is the host's frame events and scene state (the revision published, the
-- revision adopted), the adapter's reading of the texture's stage and the ledger's holds: it shows that the
-- accepted scene is adopted; that its texture stays held and is recorded again after Lua's immediate release; and
-- that everything is retired once the window closes. The composition is the command's own
-- ('Hetoimasia.Run.runGame' over 'Hetoimasia.Run.Graphics.runNativeWith'): the only addition is an observation
-- that reads and never writes, and no provider is substituted.
--
-- A genuine native close is delivered through the platform by the test-only driver of
-- @hetoimasia-glfw:native-check@, on the main thread (a real @WM_DELETE_WINDOW@ on X11), so the window's own
-- callback latches it and the session stops in order: exit 0.
module Test.Run.Native.Library (spec, shippedContent, copyTree) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newEmptyTMVarIO
  , newTVarIO
  , putTMVar
  , readTMVar
  , readTVar
  , readTVarIO
  , retry
  , swapTVar
  )
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Foundation.Log (LogFilter (..), defaultLogFilter)
import Hetoimasia.GLFW.NativeCheck (NativeCloseAnswer (..), requestNativeClose)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand (immediateDemand, publishDemand)
import Hetoimasia.GLFW.Window (WindowId)
import Hetoimasia.GPU.Vulkan.GLFW
  ( FrameEvent (..)
  , VulkanHost (..)
  , VulkanSceneState (..)
  , WindowSceneStanding (..)
  , readVulkanSceneState
  )
import Hetoimasia.LuaEngine.Facade (OutputSink (..))
import Hetoimasia.LuaEngine.Graphics.Scene (GraphicsScene)
import Hetoimasia.LuaEngine.Graphics.Texture (BackendReading (..), TextureGraphics (..))
import Hetoimasia.Run (Setup (..), runGame)
import Hetoimasia.Run.Boot (noBootHooks)
import Hetoimasia.Run.Graphics (Observation (..), runNativeWith)
import Hetoimasia.Run.Session (Environment (..), productionEnvironment)
import Hetoimasia.Runtime.GLFW (attachmentWindow, hostWindowClient, hostWindowIdentities)
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe)
import Test.Run.Native.Env (Env (..), evidence)

-- | The shipped content's folder, from the repository root the runner starts the suite in.
shippedContent ∷ FilePath
shippedContent = "samples/lua-quad/content"

-- | Copy a folder's files, byte for byte, into another.
copyTree ∷ FilePath → FilePath → IO ()
copyTree from to = do
  createDirectoryIfMissing True to
  names ← listDirectory from
  forM_ names $ \name → do
    isDirectory ← doesDirectoryExist (from </> name)
    if isDirectory then copyTree (from </> name) (to </> name) else ByteString.readFile (from </> name) >>= ByteString.writeFile (to </> name)

-- | What a scenario may observe of one run.
data Watch = Watch
  { watchFrames ∷ !(TVar (Int, [FrameEvent]))
  , watchJobs ∷ !(TVar [IO ()])
  }

-- | A run's result: its status, what the scripts printed, and the host and adapter to read afterwards.
data Ran = Ran
  { ranStatus ∷ ExitCode
  , ranOut ∷ [Text]
  , ranHost ∷ VulkanHost GraphicsScene
  , ranGraphics ∷ TextureGraphics
  }

spec ∷ Env → Spec
spec env = describe "the command's production composition" $ do
  it "shows the shipped content's accepted scene adopted, its texture held and recorded again after Lua's immediate release, and exits 0 when the platform delivers a genuine close, with everything retired" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        ran ← runWith env folder $ \watch host graphics → do
          window ← awaitWindow host
          mark ← frameMark watch
          step "the adoption of the example's scene" (awaitAdopted host window 1)
          step "a frame recorded with it" (awaitFrame watch window 1 mark)
          step "the released texture held by the adopted scene" (awaitHeld graphics)
          expectHeld graphics
          -- Recording needs no further publication: another frame of what the window holds, with the same revision.
          later ← frameMark watch
          demandFrame host window
          step "a frame recorded after the release" (awaitFrame watch window 1 later)
          published host window >>= (`shouldBe` Just 1)
          expectHeld graphics
          answer ← onMainTurn watch (requestNativeClose (vulkanWindowHost host) window)
          answer `shouldBe` NativeCloseDelivered
        ranStatus ran `shouldBe` ExitSuccess
        ranOut ran `shouldBe` []
        retired ran
        evidence env "shipped content: the example's scene (revision 1) was adopted, recorded again after the immediate Lua release with its texture held by the ledger, a genuine native close was delivered on the main thread, the session exited 0, the window was destroyed and the texture proved retired; no pixel was captured"

  it "exits 0 when the script quits after publishing, with the window destroyed and the texture retired" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        quitting folder (\script → Text.replace "api.texture.release(self.image.texture)" "api.texture.release(self.image.texture)\n        api.session.quit()" script)
        ran ← runWith env folder (\_ _ _ → pure ())
        ranStatus ran `shouldBe` ExitSuccess
        retired ran
        evidence env "quit: a script that quits right after publishing and releasing ended the session with exit 0; the window was destroyed and the texture proved retired"

  it "answers busy, nonfatally and with no host capacity fault, when the reachable request and texture reservations are full while the window slot is free, accepts the explicit retry after reclamation, and keeps a second own-window request an ordinary error" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        ByteString.writeFile (folder </> "lua" </> "main.lua") (Text.encodeUtf8 capacityScript)
        ran ← runWith env folder (\_ _ _ → pure ())
        ranStatus ran `shouldBe` ExitSuccess
        ranOut ran
          `shouldBe` [ "textures accepted 8"
                     , "data accepted 8"
                     , "window while full: busy"
                     , "window after reclaim: accepted"
                     , "second window: error"
                     ]
        retired ran
        evidence env "capacity: through the production facade, 8 texture requests (the instance's 128 MiB nominal bytes) and 8 data requests filled the instance's 16 request records; the window request with its own slot free answered busy, a nonfatal data answer with no host fault; after the results were taken and the textures released an explicit retry was accepted; a second window request was the ordinary error; the session exited 0 and everything retired"

  it "exits 1 when a required texture cannot be read, cleaning up the window it had and every resource" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        quitting folder (Text.replace "images/quad.png" "images/missing.png")
        ran ← runWith env folder (\_ _ _ → pure ())
        ranStatus ran `shouldBe` ExitFailure 1
        retired ran
        evidence env "setup failure: a missing required texture ended the session with exit 1; the window it had been given was destroyed and nothing was left live"
  where
    quitting folder change = do
      let path = folder </> "lua" </> "main.lua"
      text ← ByteString.readFile path
      let changed = change (decode text)
      changed `shouldNotBe` decode text
      ByteString.writeFile path (Text.encodeUtf8 changed)
    decode = Text.decodeUtf8

-- | Run a folder through the command's real composition with the production native graphics and these watches. The
-- scenario runs on a thread of its own once the adapter is composed; its failure is raised after the command has
-- returned and unwound.
runWith ∷ Env → FilePath → (Watch → VulkanHost GraphicsScene → TextureGraphics → IO ()) → IO Ran
runWith env folder scenario = do
  composed ← newEmptyTMVarIO
  frames ← newTVarIO (0, [])
  jobs ← newTVarIO []
  out ← newTVarIO []
  let watch = Watch frames jobs
      record ref = OutputSink {sinkLine = \line → atomically (modifyTVar' ref (<> [line])), sinkFlush = pure ()}
  err ← newTVarIO []
  let environment = productionEnvironment {envStdout = record out, envStderr = record err}
      observation =
        Observation
          { observeFrame = \event → atomically (modifyTVar' frames (\(count, events) → (count + 1, take 4096 (event : events))))
          , observeComposed = \host graphics → do
              atomically (putTMVar composed (host, graphics))
              pure (atomically (swapTVar jobs []) >>= sequence_)
          }
      setup = Setup {setupForce = pure (), setupReady = \_ → pure (), setupBoot = noBootHooks, setupLaunch = runNativeWith observation environment}
  finished ← newEmptyMVar ∷ IO (MVar (Either SomeException ()))
  _ ← forkIO $ try (do (host, graphics) ← atomically (readTMVar composed); scenario watch host graphics) >>= putMVar finished
  status ← envMain env (runGame setup defaultLogFilter {filterEnabled = False} folder)
  -- A scenario still waiting is bounded by its own waits.
  readMVar finished >>= either throwIO pure
  (host, graphics) ← atomically (readTMVar composed)
  Ran status <$> readTVarIO out <*> pure host <*> pure graphics

-- | Nothing the run made is left: no native window, no live texture, no hold.
retired ∷ Ran → IO ()
retired ran = do
  windows ← atomically (hostWindowIdentities (vulkanWindowHost (ranHost ran)))
  windows `shouldBe` []
  reading ← atomically (graphicsReading (ranGraphics ran))
  readingLiveTextures reading `shouldBe` 0

-- | Run an action on the main thread's next turn of the owner loop and answer what it returned.
onMainTurn ∷ Watch → IO a → IO a
onMainTurn watch action = do
  answer ← newEmptyMVar
  atomically (modifyTVar' (watchJobs watch) (<> [try action >>= putMVar answer]))
  takeMVar answer >>= either (\e → throwIO (e ∷ SomeException)) pure

-- | The identity of the one native window the example opens.
awaitWindow ∷ VulkanHost GraphicsScene → IO WindowId
awaitWindow host = step "the example's window" . atomically $ do
  windows ← hostWindowIdentities (vulkanWindowHost host)
  case windows of
    [window] → pure window
    _ → retry

-- | Block until the owner adopted at least this revision of the window's scene.
awaitAdopted ∷ VulkanHost GraphicsScene → WindowId → Natural → IO ()
awaitAdopted host window revision = atomically $ do
  state ← readVulkanSceneState host
  case Map.lookup window (sceneWindows state) >>= windowAdopted of
    Just adopted | adopted >= revision → pure ()
    _ → retry

-- | The latest revision published for the window.
published ∷ VulkanHost GraphicsScene → WindowId → IO (Maybe Natural)
published host window = do
  state ← atomically (readVulkanSceneState host)
  pure (Map.lookup window (sceneWindows state) >>= windowPublished)

frameMark ∷ Watch → IO Int
frameMark watch = fst <$> readTVarIO (watchFrames watch)

-- | Block until a frame was asked to be presented for the window with this revision after the first @mark@ events.
awaitFrame ∷ Watch → WindowId → Natural → Int → IO ()
awaitFrame watch window revision mark = atomically $ do
  (count, events) ← readTVar (watchFrames watch)
  let fresh = take (max 0 (count - mark)) events
  unless (or [attachmentWindow attachment == window && rendered == revision | FramePresentRequested attachment _ _ rendered ← fresh]) retry

-- | Ask the window's target for another frame of what it holds.
demandFrame ∷ VulkanHost GraphicsScene → WindowId → IO ()
demandFrame host window =
  atomically (hostWindowClient (vulkanWindowHost host) window) >>= \case
    Nothing → expectationFailure "the window has no client to publish demand to"
    Just client → () <$ publishDemand (clientDemandPublisher client) immediateDemand

-- | Wait until the released texture's release has been asked and refused for the hold (its stage is @held@). The wait
-- fails early when every texture has already retired: the owner let it go while its scene was adopted.
awaitHeld ∷ TextureGraphics → IO ()
awaitHeld graphics = do
  settled ← atomically $ do
    reading ← graphicsReading graphics
    case readingTextureStages reading of
      ["held"] → pure False
      [] → pure True
      _ → retry
  unless (not settled) (expectationFailure "the texture retired while its scene was adopted")

-- | The backend holds exactly one texture back from retirement, by the ledger: its stage is @held@.
expectHeld ∷ TextureGraphics → IO ()
expectHeld graphics = do
  reading ← atomically (graphicsReading graphics)
  readingTextureStages reading `shouldBe` ["held"]

-- | A wait that names itself when it does not end.
step ∷ String → IO a → IO a
step label action =
  timeout (40 * 1000000) action >>= \case
    Just value → pure value
    Nothing → expectationFailure ("no " <> label <> " within 40 seconds") >> error "unreachable"

within ∷ Int → IO a → IO a
within seconds action =
  timeout (seconds * 1000000) action >>= \case
    Just value → pure value
    Nothing → expectationFailure ("the example did not finish within " <> show seconds <> " seconds") >> error "unreachable"

-- | A presentation role that fills the instance's reachable reservations, asks for its window while they are full,
-- reclaims them and retries, and then asks for a second window. Textures fill the nominal-bytes and read-queue banks
-- (eight of them); optional data requests for a file the folder does not hold are accepted and fail without a worker,
-- so they fill the remaining request records without touching the read queue and latch no failure.
capacityScript ∷ Text
capacityScript =
  Text.unlines
    [ "local function fill(api, kind, path, held)"
    , "  local accepted = 0"
    , "  while accepted < 64 do"
    , "    local request, refusal"
    , "    if kind == 'texture' then request, refusal = api.content.texture(path)"
    , "    else request, refusal = api.content.data(path, {optional = true}) end"
    , "    if not request then assert(refusal.code == 'busy', refusal.code) return accepted end"
    , "    held[#held + 1] = {kind = kind, request = request}"
    , "    accepted = accepted + 1"
    , "  end"
    , "  error('never busy')"
    , "end"
    , ""
    , "return {"
    , "  gameplay = {every_ticks = 1, update = function(self, dt) end},"
    , "  presentation = {"
    , "    every_seconds = 0.02,"
    , "    init = function(self, api)"
    , "      self.held = {}"
    , "      print('textures accepted ' .. fill(api, 'texture', 'images/quad.png', self.held))"
    , "      print('data accepted ' .. fill(api, 'data', 'missing.bin', self.held))"
    , "      local window, refusal = api.window.open({title = 'capacity', width = 64, height = 64})"
    , "      print('window while full: ' .. (window and 'accepted' or refusal.code))"
    , "      self.phase = 'reclaim'"
    , "    end,"
    , "    update = function(self, dt)"
    , "      local api = self.api"
    , "      if self.phase == 'reclaim' then"
    , "        for i = #self.held, 1, -1 do"
    , "          local entry = self.held[i]"
    , "          if api.request.ready(entry.request) then"
    , "            local result = api.request.take(entry.request)"
    , "            if entry.kind == 'texture' and result.status == 'success' then api.texture.release(result.value.texture) end"
    , "            table.remove(self.held, i)"
    , "          end"
    , "        end"
    , "        if #self.held == 0 then self.phase = 'retry' end"
    , "      elseif self.phase == 'retry' then"
    , "        local window, refusal = api.window.open({title = 'capacity', width = 64, height = 64})"
    , "        if window then"
    , "          print('window after reclaim: accepted')"
    , "          local ok = pcall(api.window.open, {title = 'again', width = 64, height = 64})"
    , "          print('second window: ' .. (ok and 'accepted' or 'error'))"
    , "          api.session.quit()"
    , "          self.phase = 'done'"
    , "        else assert(refusal.code == 'busy', refusal.code) end"
    , "      end"
    , "    end"
    , "  }"
    , "}"
    ]
