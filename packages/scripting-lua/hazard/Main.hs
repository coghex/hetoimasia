-- | The examples that need a process of their own, and their report.
--
-- Two of them. One is a hazard: cancelling a Haskell thread that is inside Lua
-- does not interrupt Lua, so a chunk that never returns holds its thread for
-- the life of the process. A suite that ran that in its own process would leave
-- a thread and an interpreter running for the rest of the run and would have no
-- way to report what it observed.
--
-- The other needs an RTS option the suite cannot have: exactly one capability.
-- That is what makes the independent-progress claim falsifiable. Under one
-- capability, a Haskell thread can run during a foreign call only if the call
-- released the capability; if @lua_pcall@ were imported @unsafe@ it would not,
-- and the Haskell work that the chunk's own exit condition depends on could
-- never happen. With two capabilities the same example passes either way and
-- proves nothing.
--
-- Each mode prints one report line on stdout. The suite reads it, ends the
-- process when the mode cannot end itself, and keeps the exit status.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (Exception, SomeException, try)
import Control.Monad (forever, void)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Scripting.Lua.Bridge
  ( Library (LibraryBase)
  , chunkName
  , closeVm
  , evalChunk
  , newVm
  )
import Hetoimasia.Scripting.Lua.Internal.Callback
  ( CallbackResult (BooleanResult, NoResult)
  , installCallback
  )
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (BufferMode (LineBuffering), hPutStrLn, hSetBuffering, stderr, stdout)
import System.Timeout (timeout)

-- | The cancellation the hazard tries to deliver.
data Hazard = Hazard
  deriving (Show)

instance Exception Hazard

-- | Long enough that a deliverable cancellation would have arrived, short
-- enough to stay a test. Nothing either mode concludes depends on the length:
-- each reports which observation it made.
boundMicroseconds ∷ Int
boundMicroseconds = 5000000

-- | How many times the handshake window may swallow the cancellation before
-- the hazard gives up and says so.
attemptLimit ∷ Int
attemptLimit = 5

main ∷ IO ()
main = do
  hSetBuffering stdout LineBuffering
  arguments ← getArgs
  case arguments of
    ["uninterruptible-lua"] → uninterruptibleLua 1
    ["capability-release"] → capabilityRelease
    _ → do
      hPutStrLn stderr "usage: lua-hazard uninterruptible-lua|capability-release"
      exitWith (ExitFailure 2)

-- | Run a chunk that never returns, cancel the thread running it, and report
-- whether the cancellation was delivered.
--
-- The evidence is @throwTo@'s own: it returns when the exception is delivered,
-- so a @throwTo@ that has not returned is a cancellation that has not been
-- delivered. There is one window in which it can be delivered -- the instant
-- the chunk spends inside the handshake callback, which is Haskell -- and
-- landing in it is reported and retried rather than assumed away.
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
        -- mode exists to exclude, so it tries again.
        Just () → uninterruptibleLua (attempt + 1)
        Nothing → do
          putStrLn ("HAZARD uninterrupted attempts=" <> show attempt)
          -- The interpreter is still running Lua and no longer reachable: this
          -- process cannot end itself cleanly, which is the whole reason the
          -- example lives here. The suite ends it.
          forever (threadDelay maxBound)

-- | Show that Haskell runs during a substantial pure-Lua computation, on a
-- runtime with one capability.
--
-- The chunk's exit condition is Haskell work: it loops until @keep_going@
-- answers false, and only the Haskell thread below can make it do that. So the
-- chunk terminating at all means that thread ran. What makes the result mean
-- something is where it ran: the counter is read at the end of the chunk's
-- first block of pure Lua, before any Lua has called back a second time, so
-- what it counts happened while the interpreter was inside @lua_pcall@ and
-- nowhere else.
--
-- With one capability, that is possible only because @lua_pcall@ is imported
-- @safe@ and releases it. An @unsafe@ import would hold the capability for the
-- whole call, and the count taken at the end of the first block would be zero.
capabilityRelease ∷ IO ()
capabilityRelease = do
  vm ← newVm [LibraryBase]
  started ← newEmptyMVar
  finished ← newEmptyMVar
  counter ← newIORef (0 ∷ Int)
  baseline ← newIORef (0 ∷ Int)
  duringFirstBlock ← newIORef (Nothing ∷ Maybe Int)
  stop ← newIORef False
  installCallback
    vm
    "started"
    ( do
        -- The count before the chunk's first block, so what the block is
        -- credited with is growth and not a total.
        readIORef counter >>= writeIORef baseline
        putMVar started ()
        pure NoResult
    )
    (pure ())
  installCallback
    vm
    "keep_going"
    ( do
        recorded ← readIORef duringFirstBlock
        case recorded of
          Just _ → pure ()
          Nothing → readIORef counter >>= writeIORef duringFirstBlock . Just
        halt ← readIORef stop
        pure (BooleanResult (not halt))
    )
    (pure ())
  _ ← forkIO $ do
    outcome ←
      try @SomeException
        ( evalChunk
            vm
            (chunkName "busy")
            ( "started()\n"
                <> "local total = 0\n"
                <> "repeat\n"
                <> "  for index = 1, 4000000 do total = total + index end\n"
                <> "until not keep_going()\n"
            )
        )
    putMVar finished outcome
  takeMVar started
  -- Count until the chunk's first block ends. Every increment here happens
  -- while the interpreter is inside the foreign call.
  let count = do
        recorded ← readIORef duringFirstBlock
        case recorded of
          Just _ → pure ()
          Nothing → atomicModifyIORef' counter (\value → (value + 1, ())) >> count
  ran ← timeout boundMicroseconds count
  writeIORef stop True
  outcome ← timeout boundMicroseconds (takeMVar finished)
  before ← readIORef baseline
  reached ← readIORef duringFirstBlock
  closeVm vm
  case (ran, outcome, reached) of
    (Just (), Just (Right ()), Just during) →
      putStrLn
        ( "HAZARD progressed baseline="
            <> show before
            <> " during-first-block="
            <> show (during - before)
        )
    (Nothing, _, _) → report "the counting thread never saw the first block end"
    (_, Nothing, _) → report "the chunk never returned"
    (_, Just (Left failure), _) → report ("the chunk failed: " <> show failure)
    (_, _, Nothing) → report "the chunk never reached its exit condition"
  where
    report reason = do
      putStrLn ("HAZARD no-progress reason=" <> reason)
      exitWith (ExitFailure 4)
