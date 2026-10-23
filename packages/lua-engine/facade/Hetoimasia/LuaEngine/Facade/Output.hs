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
--   the failed sink.
-- * The scope that makes the output ('withOutput') is the owner of the in-flight calls: it closes the
--   output to new calls when its body ends and waits for the calls already in the sink to return, so
--   the sinks it borrowed are never released under a hook that is still writing. A hook that runs during
--   an owner's shutdown still finds its sink: the scope outlives every owner that writes to it.
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
  , SomeAsyncException
  , SomeException
  , fromException
  , mask
  , toException
  , throwIO
  , try
  )
import Control.Monad (unless, when)
import Data.Maybe (isJust)
import Data.Text (Text)
import Hetoimasia.LuaEngine.Facade.Types
  ( FacadeDefect (FacadeDefect)
  , Output (..)
  , OutputSink (..)
  , OutputState (..)
  , Stream (..)
  )

-- | An authored write the output could not make: the stream, and what the sink raised. It is a failure
-- of the host.
data OutputFailure = OutputFailure !Stream !SomeException
  deriving (Show)

instance Exception OutputFailure

-- | Make the session's authored output over these sinks, run the body, then close the output and wait
-- for the calls in flight to return. The sinks belong to the caller, who releases them after this
-- scope; this scope sees to it that no authored call is still using them.
withOutput ∷ OutputSink → OutputSink → (Output → IO a) → IO a
withOutput out err body = mask $ \restore → do
  lock ← newMVar ()
  state ← newTVarIO (OutputState True 0 Nothing)
  let output = Output out err lock state
  outcome ← try (restore (body output))
  interrupted ← closeAndDrain output
  case (outcome, interrupted) of
    (Left failure, _) → throwIO (failure ∷ SomeException)
    (Right _, Just cancellation) → throwIO cancellation
    (Right value, Nothing) → pure value

-- | Close the output to new calls and wait for the calls in flight, whatever interrupts the wait: an
-- interruption is remembered, the wait goes on until the output is idle, and the first is answered.
closeAndDrain ∷ Output → IO (Maybe SomeException)
closeAndDrain output = do
  atomically (readTVar (outState output) >>= \st → writeTVar (outState output) st {stateOpen = False})
  go Nothing
  where
    go remembered = do
      waited ← try (atomically (idle output))
      case waited of
        Right () → pure remembered
        Left interruption → go (maybe (Just interruption) Just remembered)
    idle o = do
      st ← readTVar (outState o)
      when (stateInFlight st > 0) retry

-- | Write one complete authored call: its lines, then the flush, under the output's lock. A sink that
-- raises is recorded once as the output's failure and raised as an 'OutputFailure'; an output that has
-- already failed raises that failure without touching a sink; a closed output is an engine defect
-- (a hook ran after the scope that owns the sinks ended).
writeAuthored ∷ Output → Stream → [Text] → IO ()
writeAuthored output stream ls = mask $ \restore → do
  atomically (enter output)
  written ← try (restore (withMVar (outLock output) (\_ → mapM_ (sinkLine sink) ls >> sinkFlush sink)))
  atomically (leave output stream written)
  case written of
    Right () → pure ()
    Left failure
      | isJust (fromException failure ∷ Maybe SomeAsyncException) → throwIO failure
      | otherwise → throwIO (OutputFailure stream failure)
  where
    sink = case stream of
      Stdout → outStdout output
      Stderr → outStderr output

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

-- | A call ends: no longer counted, and a synchronous failure of the sink remembered if it is the first.
leave ∷ Output → Stream → Either SomeException () → STM ()
leave output stream written = do
  st ← readTVar (outState output)
  let failed = case written of
        Left failure | not (isAsync failure) → Just (toException (OutputFailure stream failure))
        _ → Nothing
  writeTVar
    (outState output)
    st
      { stateInFlight = stateInFlight st - 1
      , stateFailure = maybe failed Just (stateFailure st)
      }
  where
    isAsync failure = isJust (fromException failure ∷ Maybe SomeAsyncException)

-- | How many authored calls are inside a sink now.
outputInFlight ∷ Output → STM Int
outputInFlight output = stateInFlight <$> readTVar (outState output)

-- | Block until no authored call is inside a sink.
awaitOutputIdle ∷ Output → STM ()
awaitOutputIdle output = outputInFlight output >>= \n → when (n > 0) retry

-- | The first failure of a sink, if one has failed.
outputFailure ∷ Output → STM (Maybe SomeException)
outputFailure output = stateFailure <$> readTVar (outState output)
