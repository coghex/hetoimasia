-- | The rule for signals during a @lua@ run: one coordinator, shared by SIGINT and SIGTERM.
--
-- The first signal, whichever it is, requests the stop: it sets the runner's stop request and returns.
-- It does not wait for the shutdown it asks for. The second, whichever it is, calls the force action,
-- exactly once, and a later one changes nothing. No single signal calls it. The decision is one atomic
-- step on one state, so deliveries that overlap on several threads still request the stop once and
-- force at most once; the actions run after the decision, outside it, and are the caller's: the force
-- action in production leaves the process at once with status 130, waiting for no cleanup and flushing
-- nothing (D-42).
module Hetoimasia.Console.Lua.Signals
  ( Coordinator
  , Delivery (..)
  , newCoordinator
  , stopRequested
  , deliver
  ) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVarIO, readTVar, writeTVar)

-- | Where the rule is: nothing yet, stop requested, forced.
data Phase = Quiet | Stopping | Forced
  deriving (Eq, Show)

-- | What one delivery did.
data Delivery
  = -- | It was the first: the stop was requested.
    Requested
  | -- | It was the second: the force action was called.
    Forcing
  | -- | The stop was already requested and the force already called.
    Ignored
  deriving (Eq, Show)

data Coordinator = Coordinator
  { coordinatorPhase ∷ !(TVar Phase)
  , coordinatorForce ∷ IO ()
  }

-- | A coordinator whose force action is this.
newCoordinator ∷ IO () → IO Coordinator
newCoordinator force = (\phase → Coordinator phase force) <$> newTVarIO Quiet

-- | The runner's stop request: set from the first delivery on.
stopRequested ∷ Coordinator → STM Bool
stopRequested coordinator = (/= Quiet) <$> readTVar (coordinatorPhase coordinator)

-- | One signal arrived. Never blocks, and calls the force action at most once however many arrive,
-- on however many threads.
deliver ∷ Coordinator → IO Delivery
deliver coordinator = do
  delivery ← atomically $ do
    phase ← readTVar (coordinatorPhase coordinator)
    case phase of
      Quiet → writeTVar (coordinatorPhase coordinator) Stopping >> pure Requested
      Stopping → writeTVar (coordinatorPhase coordinator) Forced >> pure Forcing
      Forced → pure Ignored
  case delivery of
    Forcing → coordinatorForce coordinator
    _ → pure ()
  pure delivery
