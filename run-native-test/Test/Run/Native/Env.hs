-- | What the native examples are given: the way to run an action on the process main thread, which owns GLFW and
-- serves the owner loop, and the lines the run's evidence record is made of.
module Test.Run.Native.Env
  ( Env (..)
  , evidence
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar')
import Data.Text (Text)

data Env = Env
  { envMain ∷ ∀ a. IO a → IO a
  -- ^ Run an action on the process main thread and answer what it returned or raised. The examples run on a thread
  -- of their own so that one that blocks cannot starve the main thread; GLFW, the owner loop and every native
  -- window operation are the main thread's.
  , envEvidence ∷ !(TVar [Text])
  -- ^ Lines for the run's evidence record, newest first.
  }

-- | Record a line of evidence.
evidence ∷ Env → Text → IO ()
evidence env line = atomically (modifyTVar' (envEvidence env) (line :))
