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

import Control.Concurrent (ThreadId, forkIO, forkIOWithUnmask, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryReadMVar)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newEmptyTMVarIO
  , newTVarIO
  , putTMVar
  , readTMVar
  , tryReadTMVar
  , writeTVar
  , readTVar
  , readTVarIO
  , retry
  , swapTVar
  )
import Control.Exception (AsyncException (UserInterrupt), ExceptionWithContext, catch, SomeException, finally, mask, rethrowIO, throwIO, try, tryWithContext, uninterruptibleMask_)
import Control.Applicative ((<|>))
import Control.Monad (forM_, unless, void, when)
import Data.Foldable (traverse_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (fromMaybe, isJust)
import GHC.Conc (BlockReason (BlockedOnException), ThreadStatus (ThreadBlocked), threadStatus)
import qualified Data.ByteString as ByteString
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Console.Lua.Signals (deliver)
import Hetoimasia.Run.Session (newSessionLink)
import Hetoimasia.Run.Settle (combine, isAsynchronous, rememberingInterruption)
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Foundation.Log (LogFilter (..), Logger, callbackSink, defaultLogFilter, mkLogger)
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
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldNotBe, shouldSatisfy)
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
  , watchFail ∷ !(TVar Bool)
  -- ^ When set, the main thread's next turn raises: the owner loop's own failure, made on demand.
  , watchDrainFail ∷ !(TVar Bool)
  -- ^ When set, every turn of the drain loop raises too: a loop that cannot be served any more.
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

  it "fails the example, and does not pass it, when the command exits 0 before the scenario has made its observations" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        quitting folder (\script → Text.replace "api.texture.release(self.image.texture)" "api.texture.release(self.image.texture)\n        api.session.quit()" script)
        -- An observation that cannot be made once the command is gone: held on a cell nothing will ever set (kept
        -- reachable below, so the runtime does not end the wait itself).
        never ← newTVarIO False
        outcome ← try @SomeException $ runWith env folder $ \_ _ _ → atomically (readTVar never >>= \set → unless set retry)
        readTVarIO never >>= (`shouldBe` False)
        either (\failure → show failure) (const "no failure") outcome `shouldSatisfy` isInfixOf "the command ended successfully before the scenario had finished its observations"
        evidence env "outrun scenario: a command that exited 0 before the scenario's observation could be made failed the example (it was not ended and counted as passed)"

  it "keeps a scenario's own assertion failure when the end of the run races with it, rather than counting the scenario as ended" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        quitting folder (\script → Text.replace "api.texture.release(self.image.texture)" "api.texture.release(self.image.texture)\n        api.session.quit()" script)
        never ← newTVarIO False
        -- Held until the harness ends it, and then failing on its own account: its assertion is not the end's.
        outcome ← try @SomeException $
          runWith env folder $ \_ _ _ →
            atomically (readTVar never >>= \set → unless set retry)
              `catch` \(_ ∷ AsyncException) → expectationFailure "the assertion raised while the run was ending"
        readTVarIO never >>= (`shouldBe` False)
        either (\failure → show failure) (const "no failure") outcome `shouldSatisfy` isInfixOf "the assertion raised while the run was ending"
        evidence env "assertion kept: a scenario assertion that failed while the harness was ending it was raised as the example's failure, not replaced by the end"

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

  it "serves the owner's retirement while it unwinds an owner loop that failed with a window live, and exits 1 with everything retired" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        ran ← runWith env folder $ \watch host _ → do
          window ← awaitWindow host
          step "the adoption of the example's scene" (awaitAdopted host window 1)
          atomically (writeTVar (watchFail watch) True)
        ranStatus ran `shouldBe` ExitFailure 1
        retired ran
        evidence env "owner loop failure: the main thread's loop was made to raise while the shipped content's window was live; the session was asked to stop, the loop was served again until the window was destroyed and the texture proved retired, and the command exited 1"

  it "stops and joins the run by itself when the observing scenario fails, and raises the scenario's failure" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        outcome ← try @SomeException $ runWith env folder $ \_ host _ → do
          _ ← awaitWindow host
          ioError (userError "the observation failed on purpose")
        either (\failure → show failure) (const "no failure") outcome `shouldBe` "user error (the observation failed on purpose)"
        evidence env "failed observation: a scenario that failed with the shipped content's window live stopped the run by the orderly request, the run unwound by itself, and the scenario's failure was raised afterwards"

  it "stops and joins the run by itself when the example is cancelled before the command's stop endpoint exists" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        ended <- newEmptyMVar
        began <- newEmptyMVar
        gate <- newEmptyMVar
        caller <- myThreadId
        -- Cancel the example once the command has begun but before it publishes its endpoint, then let it go on.
        _ <- forkIO (takeMVar began >> throwTo caller UserInterrupt >> putMVar gate ())
        outcome <- try @SomeException (runWithEnding env folder ended (putMVar began () >> takeMVar gate) (\_ _ _ → pure ()))
        either (\failure → show failure) (const "no failure") outcome `shouldBe` "user interrupt"
        -- The command had ended when the example returned: nothing outlives it.
        tryReadMVar ended >>= (`shouldBe` Just ())
        evidence env "early cancellation: an example cancelled before the command published its stop endpoint latched the stop, which was delivered when the endpoint appeared; the main thread finished with the run and the cancellation was raised after it"

  it "stops and joins a live run by itself when the example is cancelled with its window up" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        ended <- newEmptyMVar
        caller <- myThreadId
        outcome <- try @SomeException $ runWithEnding env folder ended (pure ()) $ \_ host _ → do
          window <- awaitWindow host
          step "the adoption of the example's scene" (awaitAdopted host window 1)
          throwTo caller UserInterrupt
        either (\failure → show failure) (const "no failure") outcome `shouldBe` "user interrupt"
        tryReadMVar ended >>= (`shouldBe` Just ())
        evidence env "live cancellation: an example cancelled with the shipped content's window up stopped the run by the orderly request, waited for the main thread without a bound and raised the cancellation afterwards"

  it "settles a run whose owner loop is lost for good with a window live: the application's own exit destroys what the loop could not" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        ran ← runWith env folder $ \watch host _ → do
          window ← awaitWindow host
          step "the adoption of the example's scene" (awaitAdopted host window 1)
          atomically (writeTVar (watchFail watch) True >> writeTVar (watchDrainFail watch) True)
        ranStatus ran `shouldBe` ExitFailure 1
        retired ran
        evidence env "lost owner loop: the main thread's loop and every drain of it were made to raise while the shipped content's window was live; the drain gave up, the application's own protected exit destroyed the window, the session was joined after the application had torn down, and the command exited 1 with nothing live"

  it "keeps the scenario owned until it has finished when the example is cancelled after the command has ended" $
    within 120 $
      withSystemTempDirectory "hetoimasia-run-native" $ \folder → do
        copyTree shippedContent folder
        ended <- newEmptyMVar
        gate <- newEmptyMVar
        order <- newIORef ([] :: [String])
        caller <- myThreadId
        let note line = atomicModifyIORef' order (\l -> (l <> [line], ()))
        -- After the command has ended, and once the caller is blocked sending its end to the held scenario, cancel it.
        _ <- forkIO $ do
          readMVar ended
          blockedSending caller
          throwTo caller UserInterrupt
          putMVar gate ()
        outcome <- try @SomeException $ runWithEnding env folder ended (pure ()) $ \watch host _ -> do
          _ <- awaitWindow host
          atomically (writeTVar (watchFail watch) True)
          -- Held where an end cannot reach it until the example lets it go.
          uninterruptibleMask_ (takeMVar gate) `finally` note "scenario ended"
        note "runWith left"
        either (\failure -> show failure) (const "no failure") outcome `shouldSatisfy` isPrefixOf "user interrupt"
        readIORef order >>= (`shouldBe` ["scenario ended", "runWith left"])
        evidence env "cancelled after the command ended: with the scenario held where an end could not reach it, the example was cancelled while the harness was ending it; the scenario finished first, then the cancellation was raised"

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
  ended ← newEmptyMVar
  runWithEnding env folder ended (pure ()) scenario

-- | 'runWith', telling when the main thread has finished with the run, and running a step before the command's
-- stop endpoint is published (so an example can cancel before it exists).
--
-- The run and the scenario are two activities this function owns until /both/ have actually finished, on every way
-- out: the scenario failing, or the example being cancelled, asks the run to stop by the orderly request the
-- installed handlers make (latched, so a request that comes before the endpoint exists is delivered when it does,
-- once), waits for the main thread without a bound and joins the scenario. A wait that timed out would let the
-- example and its temporary folder go while the command still ran, so there is none.
runWithEnding ∷ Env → FilePath → MVar () → IO () → (Watch → VulkanHost GraphicsScene → TextureGraphics → IO ()) → IO Ran
runWithEnding env folder ended beforePublishing scenario = mask $ \restore → do
  composed ← newEmptyTMVarIO
  frames ← newTVarIO (0, [])
  jobs ← newTVarIO []
  failNow ← newTVarIO False
  drainFailNow ← newTVarIO False
  out ← newTVarIO []
  err ← newTVarIO []
  coordinator ← newEmptyMVar
  wanted ← newTVarIO False
  delivered ← newTVarIO False
  killedByUs ← newIORef False
  let watch = Watch frames jobs failNow drainFailNow
      record ref = OutputSink {sinkLine = \line → atomically (modifyTVar' ref (<> [line])), sinkFlush = pure ()}
      environment = productionEnvironment {envStdout = record out, envStderr = record err}
      observation =
        Observation
          { observeFrame = \event → atomically (modifyTVar' frames (\(count, events) → (count + 1, take 4096 (event : events))))
          , observeComposed = \host graphics → do
              atomically (putTMVar composed (host, graphics))
              pure $ do
                atomically (swapTVar jobs []) >>= sequence_
                readTVarIO failNow >>= \poisoned → when poisoned (ioError (userError "the owner loop was made to fail"))
          , observeDrain = readTVarIO drainFailNow >>= \poisoned → when poisoned (ioError (userError "the drain loop was made to fail too"))
          }
      deliverOnce coord = do
        first ← atomically (readTVar delivered >>= \done → writeTVar delivered True >> pure (not done))
        when first (void (deliver coord))
      -- Latched: asked before the endpoint exists, it is delivered by 'publish' when it does.
      stopRun = do
        atomically (writeTVar wanted True)
        tryReadMVar coordinator >>= mapM_ deliverOnce
      publish coord = do
        beforePublishing
        putMVar coordinator coord
        readTVarIO wanted >>= \asked → when asked (deliverOnce coord)
      setup =
        Setup
          { setupForce = pure ()
          , setupReady = publish
          , setupBoot = noBootHooks
          , setupLifetime = \_ → withLoggingLifetime silentLogger
          , setupLink = newSessionLink
          , setupReport = \_ → pure ()
          , setupLaunch = runNativeWith observation environment
          }
  finished ← newEmptyMVar ∷ IO (MVar (Either (ExceptionWithContext SomeException) ()))
  scenarioThread ← forkIOWithUnmask $ \unmask → do
    result ← tryWithContext (unmask (do (host, graphics) ← atomically (readTMVar composed); scenario watch host graphics))
    either (const stopRun) pure result
    -- A scenario this function ended before it finished is not a scenario that failed (the cancellation it was
    -- ended with is not its failure), but its own failure, an assertion above all, is kept even if the end raced
    -- with it. A scenario that returned is complete: an exception is only delivered while it runs.
    killed ← readIORef killedByUs
    putMVar finished $ case result of
      Left failure | killed, isAsynchronous failure → Right ()
      other → other
  let run = runGame setup defaultLogFilter {filterEnabled = False} folder `finally` putMVar ended ()
      -- Both activities finished: the command (waited for with no bound), and then the scenario.
      --
      -- A command that ended in success has not ended the scenario: the scenario's last steps (an assertion on
      -- what the close answered, a read of what was retired) may still be running. So the scenario is given that
      -- end: it is waited for until it has finished or is blocked, which the runtime reports (nothing serves a
      -- main-thread job, a frame or a host state any more, so a blocked scenario cannot progress). One that is
      -- still unfinished then is a command that outran it, and that is a failure of the example, not a pass. A
      -- command that ended otherwise is not held to this: an unfinished scenario is ended and joined. Every
      -- cancellation meanwhile is remembered, across the whole sequence, and answered.
      settle succeeded = do
        stopRun
        first ← rememberingInterruption (void (readMVar ended))
        when succeeded awaitFinishedOrBlocked
        scenarioDone ← isJust <$> tryReadMVar finished
        unless scenarioDone (writeIORef killedByUs True)
        second ← rememberingInterruption (killThread scenarioThread >> void (readMVar finished))
        pure (first <|> second, succeeded && not scenarioDone)
      awaitFinishedOrBlocked = do
        finishedNow ← isJust <$> tryReadMVar finished
        status ← threadStatus scenarioThread
        unless (finishedNow || blocked status) (yield >> awaitFinishedOrBlocked)
      blocked = \case
        ThreadBlocked _ → True
        _ → False
  waitMain ← envStart env run
  statusOutcome ← tryWithContext @SomeException (restore waitMain)
  (interruption, outrun) ← settle $ case statusOutcome of
    Right ExitSuccess → True
    _ → False
  scenarioOutcome ← readMVar finished
  let scenarioEvidence = [("the scenario", failure) | Left failure ← [scenarioOutcome]]
  case statusOutcome of
    Left failure → rethrowIO =<< combine (fromMaybe failure interruption) ([("the command's run", failure) | isJust interruption] <> scenarioEvidence)
    Right status → do
      traverse_ (\interrupted → rethrowIO =<< combine interrupted scenarioEvidence) interruption
      -- A scenario that failed on its own is the example's failure.
      either rethrowIO pure scenarioOutcome
      -- And so is a command that ended in success while the scenario still had observations to make.
      when outrun $ expectationFailure "the command ended successfully before the scenario had finished its observations"
      atomically (tryReadTMVar composed) >>= \case
        Nothing → expectationFailure "the command ended before the adapter was composed" >> error "unreachable"
        Just (host, graphics) → Ran status <$> readTVarIO out <*> pure host <*> pure graphics

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

-- | Wait until the thread is blocked in a @throwTo@ (an end being sent that has not yet been received).
blockedSending :: ThreadId -> IO ()
blockedSending thread = threadStatus thread >>= \status ->
  if status == ThreadBlocked BlockedOnException then pure () else yield >> blockedSending thread

-- | A logger that writes nothing: the run's diagnostics are not what these examples observe.
silentLogger :: Logger
silentLogger = mkLogger defaultLogFilter {filterEnabled = False} (callbackSink (\_ -> pure ()))
