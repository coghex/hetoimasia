-- | The hazard runner: an example that cannot be bounded inside a test
-- process, run in a process of its own.
--
-- Cancelling a Haskell thread that is inside Lua does not interrupt Lua.
-- @lua_pcall@ is a @safe@ foreign call, and an asynchronous exception is not
-- delivered to a thread that is inside one; a chunk that never returns
-- therefore never yields its thread back, and nothing in the process can take
-- it. A suite that ran that in its own process would leave a thread and an
-- interpreter running for the rest of the run, and would have no way to report
-- what it observed.
--
-- So it runs here. This program reports what it observed on stdout and then
-- waits; the suite that started it reads the report, ends the process, and
-- keeps the exit status as the example's evidence.
--
-- The observation is @throwTo@'s own: it blocks until the exception is
-- delivered, so a @throwTo@ that has not returned is a cancellation that has
-- not been delivered. There is one window in which it can be delivered -- the
-- instant the chunk spends inside the handshake callback, which is Haskell --
-- and landing in it is reported and retried rather than assumed away.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, SomeException, try)
import Control.Monad (forever, void)
import Hetoimasia.Scripting.Lua.Bridge (chunkName, evalChunk, newVm)
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (NoResult)
  , installCallback
  )
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import System.Timeout (timeout)

-- | The cancellation this program tries to deliver.
data Hazard = Hazard
  deriving (Show)

instance Exception Hazard

-- | Long enough that a deliverable cancellation would have arrived, short
-- enough to stay a test. Nothing this program concludes depends on the length:
-- it reports which of the two observations it made.
boundMicroseconds ∷ Int
boundMicroseconds = 5000000

-- | How many times the handshake window may swallow the cancellation before
-- this program gives up and says so.
attemptLimit ∷ Int
attemptLimit = 5

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments ← getArgs
  case arguments of
    ["uninterruptible-lua"] → uninterruptibleLua 1
    _ → do
      hPutStrLn stderr "usage: lua-hazard uninterruptible-lua"
      exitWith (ExitFailure 2)

-- | Run a chunk that never returns, cancel the thread running it, and report
-- whether the cancellation was delivered.
uninterruptibleLua ∷ Int → IO ()
uninterruptibleLua attempt
  | attempt > attemptLimit = do
      putStrLn ("HAZARD delivered-every-attempt attempts=" <> show attemptLimit)
      exitWith (ExitFailure 3)
  | otherwise = do
      entered ← newEmptyMVar
      delivered ← newEmptyMVar
      -- No standard library: the loop is language syntax, and a VM with
      -- nothing open is still a VM.
      vm ← newVm []
      installCallback vm "ready" (putMVar entered () >> pure NoResult) (pure ())
      runner ←
        forkIO . void . try @SomeException $
          evalChunk vm (chunkName "hazard") "ready() while true do end"
      takeMVar entered
      _ ← forkIO (throwTo runner Hazard >> putMVar delivered ())
      landed ← timeout boundMicroseconds (takeMVar delivered)
      case landed of
        -- The cancellation reached the thread while it was still inside the
        -- handshake callback rather than inside Lua. That is the window this
        -- program exists to exclude, so it tries again.
        Just () → uninterruptibleLua (attempt + 1)
        Nothing → do
          putStrLn ("HAZARD uninterrupted attempts=" <> show attempt)
          -- The interpreter is still running Lua and no longer reachable: this
          -- process cannot end itself cleanly, which is the whole reason the
          -- example lives here. The suite ends it.
          forever (threadDelay maxBound)
