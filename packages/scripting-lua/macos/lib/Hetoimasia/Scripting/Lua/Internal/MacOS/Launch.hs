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
  , EndpointSeams (..)
  , noEndpointSeams
  , withEndpointSeamed

    -- * Launching
  , LaunchRequest (..)
  , Launched (..)
  , LaunchFailure (..)
  , jetsamAvailable
  , jetsamFlags
  , withLaunch

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

import Control.Concurrent (ThreadId, forkIOWithUnmask, killThread)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
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
import Control.Exception (IOException, bracket, catch, finally, mask, onException, try, uninterruptibleMask_)
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
import GHC.Conc (threadWaitRead)
import System.Exit (ExitCode (..))
import System.IO (hClose, hIsEOF, hSetEncoding, utf8)
import System.Posix.IO (closeFd, createPipe, fdToHandle)
import System.Posix.Process (ProcessStatus (..), getProcessStatus)
import System.Posix.Signals (Signal, nullSignal, signalProcess)
import System.Posix.Types (Fd (..), ProcessID)
import System.Timeout (timeout)

import Hetoimasia.Scripting.Lua.Internal.MacOS.Report (Report (..), parseReport)

-- | A listening Unix-domain socket the parent owns.
--
-- Nothing is ever accepted on it. Its whole job is to be a real endpoint, so
-- that a confined child's refused @connect@ is the sandbox refusing and not a
-- socket that was never there.
newtype Endpoint = Endpoint {endpointPath ∷ FilePath}
  deriving (Eq, Show)

-- | What a regression example observes of an endpoint (#598). The production endpoint passes none ('noEndpointSeams').
data EndpointSeams = EndpointSeams
  { seamReaper ∷ ThreadId → IO ()
  -- ^ Told the backlog thread, in the masked step that starts it.
  , seamBeforeClose ∷ IO ()
  -- ^ Run in the release after the backlog thread has been joined and before the descriptor is closed.
  }

noEndpointSeams ∷ EndpointSeams
noEndpointSeams = EndpointSeams (\_ → pure ()) (pure ())

-- | Bind an endpoint for the duration of an action.
withEndpoint ∷ FilePath → (Endpoint → IO a) → IO a
withEndpoint = withEndpointSeamed noEndpointSeams

-- | 'withEndpoint' with the seams of the regression examples.
--
-- /Ownership (#598)./ The backlog thread is started in the same masked step that registers its stop-and-join, with @base@ alone
-- (this is the probe library, not a test suite, and may not use the test-support facility). However the action ends (a return,
-- an exception, a cancellation), the release ends the thread, waits for its end without being interruptible, and only then
-- shuts the socket down and closes the descriptor: the descriptor is retained until the thread that waits on it has ended.
--
-- The thread waits for a connection through the runtime ('threadWaitRead') on a non-blocking socket, so killing it ends the
-- wait. A thread parked in a blocking @accept@ is in a foreign call that no exception reaches, and that shutting the socket
-- down ends it on this system is not shown by anything here, which is why the wait is not one.
--
-- State owner: the thread owns nothing but its wait; the endpoint owns the descriptor. Thread: one backlog thread per
-- endpoint, started and joined by it. Lifetime: the action's. Disposal: the release.
withEndpointSeamed ∷ EndpointSeams → FilePath → (Endpoint → IO a) → IO a
withEndpointSeamed seams path action =
  bracket acquire (\descriptor → uninterruptibleMask_ (c_shutdown_fd descriptor >> c_close_fd descriptor)) $ \descriptor →
    mask $ \restore → do
      done ← newEmptyMVar
      -- One thread keeps the backlog empty for the endpoint's whole life. Without
      -- it the eighth connection is refused, and a refused connection reads
      -- exactly like a sandbox denial.
      reaper ← forkIOWithUnmask (\unmask → unmask (drainBacklog descriptor) `finally` putMVar done ())
      seamReaper seams reaper `onException` stop reaper done
      restore (action (Endpoint path)) `finally` stop reaper done
 where
  acquire = do
    descriptor ← withCString path c_listen_unix
    when (descriptor < 0) $
      ioError (userError ("cannot listen on " <> path <> ": errno " <> show (negate descriptor)))
    pure descriptor
  -- Not interruptible: ends the thread and waits for its end. The socket is shut down and closed in the bracket's own release,
  -- which runs after this scope has returned.
  stop reaper done = uninterruptibleMask_ $ do
    killThread reaper
    readMVar done
    seamBeforeClose seams
  drainBacklog descriptor = do
    threadWaitRead (Fd descriptor)
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
  -- ^ The helper's output reached end of file. That the stream is finished is not proof that the reader has been joined: the
  -- scope that launched the helper joins it ('withLaunch').
  , launchedReader ∷ ThreadId
  -- ^ The thread that reads the helper's output, owned by the scope of 'withLaunch'.
  }

-- | Is the spawn-time memory-limit mechanism present on this system?
jetsamAvailable ∷ IO Bool
jetsamAvailable = (/= 0) <$> c_jetsam_available

-- | The jetsam flag word a limited launch sets, for the record.
jetsamFlags ∷ IO Int
jetsamFlags = fromIntegral <$> c_jetsam_flags

-- | Spawn a helper for the length of an action, with its memory limit installed before it runs, and own the thread that reads
-- its output (#598).
--
-- A limit that cannot be installed is a refused launch, not an unlimited child; the action is then told so and no thread
-- exists. When the helper is launched, the reader thread is started in the same masked step that registers its stop-and-join
-- (with @base@ alone: this is the probe library, not a test suite), and on every way out of the action (a return, an exception,
-- a cancellation) the thread has ended and been joined, without being interruptible, before this returns. The scope ends the
-- reader when the caller is done with the helper: a caller that wants the complete set of reports waits for 'awaitStreamEnd'
-- before it leaves, as the examples do after reaping the helper. The scope does not end the helper: the caller does, and
-- observes that it ended.
--
-- State owner: the reader owns the pipe end and the reports it appends; the launcher owns the helper process. Thread: one
-- reader per helper, started and joined by this scope. Lifetime: the action's. Disposal: the release.
withLaunch ∷ LaunchRequest → (Either LaunchFailure Launched → IO a) → IO a
withLaunch request body
  | requestMemoryLimitMiB request > 0 = do
      available ← jetsamAvailable
      if available then spawnIt else body (Left MemoryLimitUnavailable)
  | otherwise = spawnIt
 where
  spawnIt = mask $ \restore → do
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
        restore (body (Left (LaunchRejected code)))
      Right pid → do
        handle ← fdToHandle readEnd
        hSetEncoding handle utf8
        reports ← newTVarIO []
        finished ← newTVarIO False
        done ← newEmptyMVar
        -- The stream's cleanup (the finished flag, the handle) is installed before the thread is let go of the mask, so a stop
        -- that reaches the thread at its first unmasked instruction still finishes the stream (review round 1 of #598).
        reader ←
          forkIOWithUnmask
            ( \unmask →
                unmask (drain handle reports)
                  `finally` (atomically (writeTVar finished True) >> void (try @IOException (hClose handle)) >> putMVar done ())
            )
            `onException` hClose handle
        restore (body (Right (Launched pid reports finished reader)))
          `finally` uninterruptibleMask_ (killThread reader >> readMVar done)

  -- One reader thread owns the pipe end for the helper's whole life. It stops
  -- at end of file or at the first read failure; the finally around it (in the
  -- thread's start) marks the stream finished exactly once and closes the handle,
  -- however the thread ends, so a waiter never blocks on a helper that has already gone.
  drain handle reports =
    loop `catch` \(_ ∷ IOException) → pure ()
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
