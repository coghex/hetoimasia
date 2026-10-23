{-# LANGUAGE OverloadedStrings #-}

-- | The session's authored output: where a script's @print@ and @warn@ are written (D-71).
--
-- = The contract
--
-- * @print@ writes plain authored text to the stdout sink, no prefix; @warn@ writes to the stderr sink,
--   each line marked with an engine-made prefix naming the role, the content and the instance whose
--   hook called it, or the module being evaluated. The bound, the escaping and the line splitting are
--   the runner's ("Hetoimasia.Scripting.Lua.Output"): one call writes at most the profile's
--   'PrintWarnBytes' of UTF-8, prefixes, escapes, line ends and a visible truncation marker included.
-- * One whole call is written under the output's lock and flushed before the lock is released, so a
--   call is never interleaved with another, from this VM or another sharing the output, and what a
--   call wrote is out of the engine's hands when it returns. Calls of one owner are in the order it made
--   them; calls of two owners are in the order they were executed. There is no queue, no drop, no retry
--   and no rate limit, and a slow sink blocks the writer that waits for it. Returning does not promise
--   the bytes are durable. A call that an asynchronous exception (the owner's cancellation) interrupts
--   inside a sink may have written only some of its lines: the write is not masked, so that a stuck sink
--   cannot make its writer uninterruptible, and the interruption is not a sink failure and is not
--   remembered as one.
-- * A sink that raises is a failure of the host: the call raises it from the binding, so it ends the
--   owner whatever Lua did with the stand-in error, and the output remembers the first failure so that
--   no later call is written or retried through a sink that has failed. Nothing is ever reported through
--   the failed sink. The failure is checked and recorded /under the output's lock/: a writer that was
--   waiting for the lock behind the one whose sink failed finds the failure when it gets it and touches
--   neither sink, so a failed output has exactly one failed write and no write after it.
-- * The scope that makes the output ('withOutput') is the owner of the in-flight calls: it closes the
--   output to new calls when its body ends and waits for the calls already in the sink to return, so
--   the sinks it borrowed are never released under a hook that is still writing. A hook that runs during
--   an owner's shutdown still finds its sink: the scope outlives every owner that writes to it.
-- * The scope is a 'withResourceLabelled' scope, so its body's failure is primary and keeps every cleanup
--   failure the owners and the coordinator inside it retained; the close and drain is its release, and
--   what it raises is retained beside the body's failure and not instead of it. Nothing here catches an
--   exception and throws it again plainly: a failure is rethrown with the context it was caught with
--   ('rethrowIO'), and a sink's failure is kept whole, context and all, inside the 'OutputFailure' that
--   reports it.
module Hetoimasia.LuaEngine.Facade.Output
  ( withOutput
  , writeAuthored
  , outputInFlight
  , awaitOutputIdle
  , outputFailure
  , OutputFailure (..)
  ) where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Concurrent.STM (STM, atomically, newTVarIO, readTVar, retry, throwSTM, writeTVar)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , rethrowIO
  , throwIO
  , toException
  , tryWithContext
  )
import Control.Monad (unless, when)
import Data.Maybe (isJust)
import Data.Text (Text)
import Hetoimasia.Foundation.Resource (withResourceLabelled)
import Hetoimasia.LuaEngine.Facade.Types
  ( FacadeDefect (FacadeDefect)
  , Output (..)
  , OutputSink (..)
  , OutputState (..)
  , Stream (..)
  )

-- | An authored write the output could not make: the stream, and what the sink raised, with the context it
-- was raised with. It is a failure of the host.
data OutputFailure = OutputFailure !Stream !(ExceptionWithContext SomeException)
  deriving (Show)

instance Exception OutputFailure

-- | Make the session's authored output over these sinks, run the body, then close the output and wait
-- for the calls in flight to return. The sinks belong to the caller, who releases them after this
-- scope; this scope sees to it that no authored call is still using them.
withOutput ∷ OutputSink → OutputSink → (Output → IO a) → IO a
withOutput out err = withResourceLabelled "lua authored output scope" acquire closeAndDrain
  where
    acquire = do
      lock ← newMVar ()
      state ← newTVarIO (OutputState True 0 Nothing)
      pure (Output out err lock state)

-- | The release: close the output to new calls, then wait until no call is inside a sink. It runs
-- uninterruptibly, as every release of a resource scope does, and so waits as long as a sink holds a
-- writer.
closeAndDrain ∷ Output → IO ()
closeAndDrain output = do
  atomically (readTVar (outState output) >>= \st → writeTVar (outState output) st {stateOpen = False})
  atomically (outputInFlight output >>= \n → when (n > 0) retry)

-- | Write one complete authored call: its lines, then the flush, under the output's lock. A sink that
-- raises is recorded once as the output's failure, before the lock is released, and raised as an
-- 'OutputFailure'; an output that has already failed raises that failure, checked again once the lock
-- is held, without touching a sink; a closed output is an engine defect (a hook ran after the scope
-- that owns the sinks ended). An asynchronous exception is not a failure of the sink: it is raised as
-- it was, with its context, and the output goes on.
writeAuthored ∷ Output → Stream → [Text] → IO ()
writeAuthored output stream ls = mask $ \restore → do
  atomically (enter output)
  written ← tryWithContext @SomeException (restore (withMVar (outLock output) (\_ → locked)))
  atomically (leave output)
  either rethrowIO pure written
  where
    sink = case stream of
      Stdout → outStdout output
      Stderr → outStderr output
    -- With the lock held. The failure is looked for again, here, because the writer ahead may have failed
    -- while this one waited; and it is recorded here, masked, before the lock goes to the next writer.
    locked = mask $ \restoreSink → do
      atomically (refuseIfFailed output)
      attempted ← tryWithContext @SomeException (restoreSink (mapM_ (sinkLine sink) ls >> sinkFlush sink))
      case attempted of
        Right () → pure ()
        Left failure@(ExceptionWithContext _ raised)
          | isJust (fromException raised ∷ Maybe SomeAsyncException) → rethrowIO failure
          | otherwise → do
              let reported = toException (OutputFailure stream failure)
              atomically (remember output reported)
              throwIO reported

-- | A call begins: counted if the output takes calls, otherwise refused with the failure it holds or as
-- a defect.
enter ∷ Output → STM ()
enter output = do
  st ← readTVar (outState output)
  case stateFailure st of
    Just failure → throwSTM failure
    Nothing → do
      unless (stateOpen st) $ throwSTM (FacadeDefect "an authored call was made after the output's scope ended")
      writeTVar (outState output) st {stateInFlight = stateInFlight st + 1}

-- | The output's failure, if it has one: raised by a writer that holds the lock before it touches a sink.
refuseIfFailed ∷ Output → STM ()
refuseIfFailed output = readTVar (outState output) >>= maybe (pure ()) throwSTM . stateFailure

-- | Remember the first failure of a sink.
remember ∷ Output → SomeException → STM ()
remember output failure = do
  st ← readTVar (outState output)
  writeTVar (outState output) st {stateFailure = maybe (Just failure) Just (stateFailure st)}

-- | A call ends: no longer counted.
leave ∷ Output → STM ()
leave output = do
  st ← readTVar (outState output)
  writeTVar (outState output) st {stateInFlight = stateInFlight st - 1}

-- | How many authored calls are inside a sink now.
outputInFlight ∷ Output → STM Int
outputInFlight output = stateInFlight <$> readTVar (outState output)

-- | Block until no authored call is inside a sink.
awaitOutputIdle ∷ Output → STM ()
awaitOutputIdle output = outputInFlight output >>= \n → when (n > 0) retry

-- | The first failure of a sink, if one has failed.
outputFailure ∷ Output → STM (Maybe SomeException)
outputFailure output = stateFailure <$> readTVar (outState output)
