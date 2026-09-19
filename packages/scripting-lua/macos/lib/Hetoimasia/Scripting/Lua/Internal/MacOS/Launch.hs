-- | The trusted parent side of the macOS probe: launching a confined helper
-- under an enforced memory limit, watching what it says, ending it, and
-- observing that it really ended.
--
-- Two separations in here are the point of the exercise rather than
-- housekeeping. The memory limit is installed by the parent at spawn and is
-- lost by any later @exec@, so the helper is spawned directly and confines
-- itself; an exec-based wrapper would silently drop the limit. And a parent's
-- quota is released by 'releaseObserved' only after 'awaitExit' has returned a
-- real status, never by a successful signal send, because a signal the kernel
-- accepted says nothing about whether the process is gone.
module Hetoimasia.Scripting.Lua.Internal.MacOS.Launch
  ( -- * Endpoints
    Endpoint (..)
  , withEndpoint

    -- * Launching
  , LaunchRequest (..)
  , Launched (..)
  , LaunchFailure (..)
  , jetsamAvailable
  , jetsamFlags
  , launch

    -- * Watching
  , awaitReport
  , collectReports
  , awaitReady

    -- * Ending and observing
  , Exit (..)
  , sendSignal
  , awaitExit
  , awaitExitWithin
  , awaitStreamEnd
  , processGone

    -- * The parent's admission ledger
  , Ledger
  , newLedger
  , admit
  , releaseObserved
  , admitted
  ) where

import Control.Concurrent (forkIO, killThread)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (IOException, bracket, catch, finally, try)
import Control.Monad (void, when)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text.IO as Text
import Data.Word (Word64)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Array (withArray0)
import Foreign.Marshal.Utils (with)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek)
import System.Exit (ExitCode (..))
import System.IO (hClose, hIsEOF, hSetEncoding, utf8)
import System.Posix.IO (closeFd, createPipe, fdToHandle)
import System.Posix.Process (ProcessStatus (..), getProcessStatus)
import System.Posix.Signals (Signal, nullSignal, signalProcess)
import System.Posix.Types (ProcessID)
import System.Timeout (timeout)

import Hetoimasia.Scripting.Lua.Internal.MacOS.Report (Report (..), parseReport)

-- | A listening Unix-domain socket the parent owns.
--
-- Nothing is ever accepted on it. Its whole job is to be a real endpoint, so
-- that a confined child's refused @connect@ is the sandbox refusing and not a
-- socket that was never there.
newtype Endpoint = Endpoint {endpointPath ∷ FilePath}
  deriving (Eq, Show)

-- | Bind an endpoint for the duration of an action.
withEndpoint ∷ FilePath → (Endpoint → IO a) → IO a
withEndpoint path action =
  bracket acquire release (\_ → action (Endpoint path))
 where
  acquire = do
    descriptor ← withCString path c_listen_unix
    when (descriptor < 0) $
      ioError (userError ("cannot listen on " <> path <> ": errno " <> show (negate descriptor)))
    -- One thread keeps the backlog empty for the endpoint's whole life. Without
    -- it the eighth connection is refused, and a refused connection reads
    -- exactly like a sandbox denial.
    reaper ← forkIO (drainBacklog descriptor)
    pure (descriptor, reaper)
  release (descriptor, reaper) = do
    -- Shut the socket down before closing it, so the thread parked in accept
    -- returns instead of outliving the endpoint.
    c_shutdown_fd descriptor
    c_close_fd descriptor
    killThread reaper
  drainBacklog descriptor = do
    taken ← c_accept_and_close descriptor
    when (taken >= 0) (drainBacklog descriptor)

-- | What the parent asks for when it launches a helper.
data LaunchRequest = LaunchRequest
  { requestExecutable ∷ FilePath
  , requestArguments ∷ [String]
  , requestMemoryLimitMiB ∷ Int
  -- ^ Zero launches with no memory limit at all, which only the examples that
  -- are establishing a control ever ask for.
  }
  deriving (Eq, Show)

-- | A launch that did not happen.
data LaunchFailure
  = -- | The spawn-time memory-limit mechanism is not exported by this system.
    MemoryLimitUnavailable
  | -- | The limit or the spawn was rejected, with its errno.
    LaunchRejected Int
  deriving (Eq, Show)

-- | A running helper.
data Launched = Launched
  { launchedPid ∷ ProcessID
  , launchedReports ∷ TVar [Report]
  -- ^ In arrival order. Written by the reader thread, read by the examples.
  , launchedFinished ∷ TVar Bool
  -- ^ The helper's output reached end of file.
  }

-- | Is the spawn-time memory-limit mechanism present on this system?
jetsamAvailable ∷ IO Bool
jetsamAvailable = (/= 0) <$> c_jetsam_available

-- | The jetsam flag word a limited launch sets, for the record.
jetsamFlags ∷ IO Int
jetsamFlags = fromIntegral <$> c_jetsam_flags

-- | Spawn a helper, with its memory limit installed before it runs.
--
-- A limit that cannot be installed is a refused launch, not an unlimited child.
launch ∷ LaunchRequest → IO (Either LaunchFailure Launched)
launch request
  | requestMemoryLimitMiB request > 0 = do
      available ← jetsamAvailable
      if available then spawnIt else pure (Left MemoryLimitUnavailable)
  | otherwise = spawnIt
 where
  spawnIt = do
    (readEnd, writeEnd) ← createPipe
    result ←
      withCString (requestExecutable request) $ \path →
        withCStrings (requestExecutable request : requestArguments request) $ \argv →
          with (0 :: CInt) $ \pidOut → do
            code ←
              c_spawn_limited
                path
                argv
                (fromIntegral (requestMemoryLimitMiB request))
                (fromIntegral writeEnd)
                (fromIntegral readEnd)
                pidOut
            if code < 0
              then pure (Left (negate (fromIntegral code) :: Int))
              else Right . fromIntegral <$> peek pidOut
    closeFd writeEnd
    case result of
      Left code → do
        closeFd readEnd
        pure (Left (LaunchRejected code))
      Right pid → do
        handle ← fdToHandle readEnd
        hSetEncoding handle utf8
        reports ← newTVarIO []
        finished ← newTVarIO False
        void (forkIO (drain handle reports finished))
        pure (Right (Launched pid reports finished))

  -- One reader thread owns the pipe end for the helper's whole life. It stops
  -- at end of file or at the first read failure, and marks the stream finished
  -- exactly once, so a waiter never blocks on a helper that has already gone.
  drain handle reports finished =
    (loop `catch` \(_ ∷ IOException) → pure ())
      `finally` ( do
                    atomically (writeTVar finished True)
                    void (try @IOException (hClose handle))
                )
   where
    loop = do
      done ← hIsEOF handle
      if done
        then pure ()
        else do
          line ← Text.hGetLine handle
          atomically (modifyTVar' reports (<> [parseReport line]))
          loop

-- | Wait for the first report satisfying a predicate.
--
-- 'Nothing' means the helper's output ended first, or the deadlock guard fired.
-- The guard is measured in microseconds and is a guard: every example that uses
-- it also asserts on what it actually saw, so a guard that fires is a failure
-- rather than a way of moving on.
awaitReport ∷ Launched → Int → (Report → Bool) → IO (Maybe Report)
awaitReport launched guardMicros predicate =
  timeoutToNothing
    <$> timeout
      guardMicros
      ( atomically $ do
          reports ← readTVar (launchedReports launched)
          case find predicate reports of
            Just report → pure (Just report)
            Nothing → do
              done ← readTVar (launchedFinished launched)
              if done then pure Nothing else retry
      )
 where
  timeoutToNothing = \case
    Nothing → Nothing
    Just found → found

-- | Wait for the helper to declare itself confined and admitted.
awaitReady ∷ Launched → Int → IO Bool
awaitReady launched guardMicros =
  (== Just Ready) <$> awaitReport launched guardMicros (== Ready)

-- | Everything the helper has said so far.
collectReports ∷ Launched → IO [Report]
collectReports = readTVarIO . launchedReports

-- | How a helper ended.
data Exit
  = ExitedWith Int
  | Signalled Int
  deriving (Eq, Show)

-- | Send a signal. 'False' means the process was already gone.
sendSignal ∷ Launched → Signal → IO Bool
sendSignal launched signal =
  (True <$ signalProcess signal (launchedPid launched))
    `catch` \(_ ∷ IOException) → pure False

-- | Block until the helper's status is reaped.
awaitExit ∷ Launched → IO Exit
awaitExit launched = do
  status ← getProcessStatus True False (launchedPid launched)
  pure $ case status of
    Just (Exited ExitSuccess) → ExitedWith 0
    Just (Exited (ExitFailure code)) → ExitedWith code
    Just (Terminated signal _) → Signalled (fromIntegral signal)
    Just (Stopped signal) → Signalled (fromIntegral signal)
    Nothing → ExitedWith (-1)

-- | Reap within a bound, so a helper that never dies fails an example instead
-- of hanging the suite.
awaitExitWithin ∷ Launched → Int → IO (Maybe Exit)
awaitExitWithin launched guardMicros = timeout guardMicros (awaitExit launched)

-- | Wait for the helper's output to reach end of file.
--
-- Reaping a status and having read everything the helper wrote are two
-- different events, and the second is the one that makes 'collectReports'
-- complete. A caller that reads the reports straight after 'awaitExit' can lose
-- the final refusal, ceiling, or measurement line to a reader thread that has
-- not been scheduled yet -- nondeterministically, which is the worst way for
-- retained evidence to be wrong. 'False' means the stream had still not ended
-- within the bound, which is a failure rather than something to continue past.
awaitStreamEnd ∷ Launched → Int → IO Bool
awaitStreamEnd launched guardMicros =
  maybe False id
    <$> timeout
      guardMicros
      ( atomically $ do
          done ← readTVar (launchedFinished launched)
          if done then pure True else retry
      )

-- | Is the process identity really gone? Asked only after a status was reaped.
processGone ∷ ProcessID → IO Bool
processGone pid =
  (False <$ signalProcess nullSignal pid) `catch` \(_ ∷ IOException) → pure True

-- | The parent's record of which owners hold admitted memory.
newtype Ledger = Ledger (TVar (Map Text Word64))

newLedger ∷ IO Ledger
newLedger = Ledger <$> newTVarIO Map.empty

-- | Reserve an owner's admitted budget.
admit ∷ Ledger → Text → Word64 → IO ()
admit (Ledger ledger) owner budget = atomically (modifyTVar' ledger (Map.insert owner budget))

-- | Release an owner's budget. Call this only with an observed exit in hand.
releaseObserved ∷ Ledger → Text → Exit → IO ()
releaseObserved (Ledger ledger) owner _observed =
  atomically (modifyTVar' ledger (Map.delete owner))

-- | Who still holds a budget.
admitted ∷ Ledger → IO [(Text, Word64)]
admitted (Ledger ledger) = Map.toList <$> readTVarIO ledger

withCStrings ∷ [String] → (Ptr CString → IO a) → IO a
withCStrings values action = go values []
 where
  go [] acc = withArray0 nullPtr (reverse acc) action
  go (value : rest) acc = withCString value (\pointer → go rest (pointer : acc))

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_listen_unix"
  c_listen_unix ∷ CString → IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_accept_and_close"
  c_accept_and_close ∷ CInt → IO CInt

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_shutdown_fd"
  c_shutdown_fd ∷ CInt → IO ()

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_close_fd"
  c_close_fd ∷ CInt → IO ()

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_jetsam_available"
  c_jetsam_available ∷ IO CInt

foreign import ccall unsafe "hetoimasia_macos_probe.h hetoimasia_macos_jetsam_flags"
  c_jetsam_flags ∷ IO CInt

foreign import ccall safe "hetoimasia_macos_probe.h hetoimasia_macos_spawn_limited"
  c_spawn_limited ∷ CString → Ptr CString → CInt → CInt → CInt → Ptr CInt → IO CInt
