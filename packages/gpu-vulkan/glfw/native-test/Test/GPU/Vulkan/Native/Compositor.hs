-- | A compositor of a private-roots child's own, for a case that ends it.
--
-- The connection-loss case must end the compositor its session is rendering
-- to, and the compositor the run's consent names serves every other case, so
-- the child starts one of its own ('withPrivateCompositor'): packaged Weston,
-- headless, on a socket of its own in a runtime directory created for it with
-- mode 0700, with no configuration file, and with @WAYLAND_DISPLAY@,
-- @WAYLAND_SOCKET@ and @DISPLAY@ removed from its environment. Readiness is a
-- connection — @wayland-info@ connecting to that socket, bounded — never an
-- elapsed time. 'enterPrivate' then points the child's own sessions at it
-- alone, through @WAYLAND_DISPLAY@ set to the socket's absolute path. Ending it
-- ('endCompositor') is @SIGTERM@ and a bounded wait for its exit, so its
-- socket is closed before the next event processing. It is ended on every
-- exit path and its directory removed, and it runs in the child's process
-- group, so the parent's deadline ends it too if the child hangs.
--
-- This is the GLFW native suite's private compositor for WL-3's connection
-- loss children ("Test.GLFW.Native.WaylandScenarios"), kept here because
-- AGENTS.md forbids importing a helper from another component's spec.
module Test.GPU.Vulkan.Native.Compositor
  ( Compositor
  , compositorVersion
  , withPrivateCompositor
  , enterPrivate
  , endCompositor
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically, check, newTVarIO, orElse, readTVar, registerDelay, retry, writeTVar)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM_)
import System.Directory (getTemporaryDirectory, removeDirectoryRecursive)
import System.Environment (getEnvironment, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), openFile)
import System.Posix.Process (getProcessID)
import System.Posix.Temp (mkdtemp)
import System.Process
  ( CreateProcess (env, std_err, std_in, std_out)
  , ProcessHandle
  , StdStream (NoStream, UseHandle)
  , createProcess
  , getProcessExitCode
  , proc
  , terminateProcess
  , waitForProcess
  )

import Test.GPU.Vulkan.Native.Child (ChildEnd (..), Launched (..), launchCommandIn)

-- | A compositor this child started and owns.
data Compositor = Compositor
  { compositorDirectory ∷ !FilePath
    -- ^ Its private runtime directory, mode 0700.
  , compositorSocket ∷ !String
    -- ^ The socket's name inside that directory.
  , compositorProcess ∷ !ProcessHandle
  , compositorVersion ∷ !String
    -- ^ What @weston --version@ answered.
  }

-- | Start packaged Weston headless on a socket of this child's own, wait until
-- that socket is served, lend it to the body, and end it and remove its
-- directory on every exit path. A compositor that is missing, exits, or never
-- serves its socket fails the case.
withPrivateCompositor ∷ (Compositor → IO a) → IO a
withPrivateCompositor body =
  withPrivateDirectory "hetoimasia-vulkan-wayland." $ \directory → do
    pid ← getProcessID
    let socket = "hetoimasia-vulkan-" <> show pid
    environment ← compositorEnvironment directory
    version ←
      launchCommandIn (Just environment) readinessDeadline "weston" ["--version"] >>= \case
        Launched (ChildExited ExitSuccess) out _ _ → pure (takeWhile (/= '\n') out)
        Launched end _ err _ → failCase ("weston --version ended " <> show end <> ": " <> err)
    bracket
      ( do
          out ← openFile (directory </> "compositor.out") WriteMode
          err ← openFile (directory </> "compositor.err") WriteMode
          (_, _, _, handle) ←
            createProcess
              ( proc
                  "weston"
                  ["--backend=headless", "--socket=" <> socket, "--width=1280", "--height=1024", "--no-config", "--idle-time=0"]
              )
                { env = Just environment
                , std_in = NoStream
                , std_out = UseHandle out
                , std_err = UseHandle err
                }
          pure handle
      )
      (\handle → getProcessExitCode handle >>= maybe (() <$ stopProcess handle) (\_ → pure ()))
      ( \handle → do
          let compositor = Compositor directory socket handle version
          awaitServed compositor environment readinessAttempts
          body compositor
      )
  where
    awaitServed compositor environment remaining = do
      exited ← getProcessExitCode (compositorProcess compositor)
      forM_ exited $ \code → do
        logged ← compositorLog compositor
        failCase ("the private compositor exited " <> show code <> " before serving its socket: " <> logged)
      served ←
        launchCommandIn
          (Just (("WAYLAND_DISPLAY", compositorSocket compositor) : environment))
          readinessDeadline
          "wayland-info"
          []
      case launchedEnd served of
        ChildExited ExitSuccess → pure ()
        _
          | remaining <= (0 ∷ Int) → do
              logged ← compositorLog compositor
              failCase ("the private compositor never served " <> compositorSocket compositor <> ": " <> logged)
          | otherwise → threadDelay 100000 >> awaitServed compositor environment (remaining - 1)

-- | The compositor's environment: this process's, with the runtime directory
-- its own, no configuration root to read, and nothing naming another display.
compositorEnvironment ∷ FilePath → IO [(String, String)]
compositorEnvironment directory = do
  inherited ← getEnvironment
  let removed = ["WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DISPLAY", "WESTON_CONFIG_FILE", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_SESSION_TYPE"]
  pure
    ( [(name, value) | (name, value) ← inherited, name `notElem` removed]
        <> [ ("XDG_RUNTIME_DIR", directory)
           , ("XDG_CONFIG_HOME", directory </> "config")
           , ("XDG_SESSION_TYPE", "wayland")
           ]
    )

-- | Point this child's own sessions at the private compositor, and nothing
-- else: the socket by absolute path, and the runtime directory with it.
enterPrivate ∷ Compositor → IO ()
enterPrivate compositor = do
  unsetEnv "WAYLAND_SOCKET"
  unsetEnv "DISPLAY"
  setEnv "XDG_RUNTIME_DIR" (compositorDirectory compositor)
  setEnv "WAYLAND_DISPLAY" (compositorDirectory compositor </> compositorSocket compositor)

-- | End the compositor: @SIGTERM@, then its exit, within a bound.
endCompositor ∷ Compositor → IO ExitCode
endCompositor = stopProcess . compositorProcess

-- | Terminate a process this child started and wait for its exit, failing the
-- case if it does not exit within 'readinessDeadline'.
stopProcess ∷ ProcessHandle → IO ExitCode
stopProcess handle = do
  terminateProcess handle
  exited ← newTVarIO Nothing
  _ ← forkIO (waitForProcess handle >>= atomically . writeTVar exited . Just)
  timer ← registerDelay (round (readinessDeadline * 1000000))
  atomically ((Just <$> (readTVar exited >>= maybe retry pure)) `orElse` (Nothing <$ (readTVar timer >>= check)))
    >>= maybe (failCase "the private compositor did not exit after SIGTERM") pure

compositorLog ∷ Compositor → IO String
compositorLog compositor = do
  logged ←
    mapM
      (\name → either (\(_ ∷ SomeException) → "") id <$> try (readFile (compositorDirectory compositor </> name)))
      ["compositor.out", "compositor.err"]
  pure (unwords (lines (concat logged)))

-- | How long one readiness probe, the version query, or the compositor's exit
-- may take.
readinessDeadline ∷ Double
readinessDeadline = 10

-- | How many readiness probes may fail before the compositor is judged never
-- to serve its socket; with the pause between them, about ten seconds.
readinessAttempts ∷ Int
readinessAttempts = 100

-- | A fresh directory of this child's own, mode 0700, removed on every exit.
withPrivateDirectory ∷ String → (FilePath → IO a) → IO a
withPrivateDirectory prefix = bracket create removeDirectoryRecursive
  where
    create = do
      base ← getTemporaryDirectory
      mkdtemp (base </> prefix)

failCase ∷ String → IO a
failCase = ioError . userError
