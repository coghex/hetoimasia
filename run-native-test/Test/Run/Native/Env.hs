-- | What the native examples are given: the way to run an action on the process main thread, which owns GLFW and
-- serves the owner loop, and the lines the run's evidence record is made of.
module Test.Run.Native.Env
  ( Env (..)
  , envMain
  , evidence
  ) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar')
import Control.Monad (join)
import Data.Text (Text)
import Test.Run.Native.X11 (X11)

data Env = Env
  { envStart ∷ ∀ a. IO a → IO (IO a)
  -- ^ Hand an action to the process main thread and answer, at once and without being able to be interrupted
  -- half way, the way to wait for what it returned or raised. Once this has returned the action will run: so a
  -- caller that is cancelled afterwards knows there is something to wait for, and one cancelled before it knows
  -- there is not. The examples run on a thread of their own so that one that blocks cannot starve the main thread;
  -- GLFW, the owner loop and every native window operation are the main thread's.
  , envEvidence ∷ !(TVar [Text])
  -- ^ Lines for the run's evidence record, newest first.
  , envX11 ∷ !(Maybe X11)
  -- ^ The external X11 evidence helper, present exactly when the run carries the isolated-X11 consent. Absent
  -- elsewhere: on macOS there is no OS capture, by the issue, and the owner's confirmations are what stands.
  , envCaptureDir ∷ !FilePath
  -- ^ Where this run's captures and machine-readable records are written: the validation runner's evidence
  -- directory when it names one, a scratch directory removed at the end of the run otherwise.
  }

-- | Run an action on the process main thread and answer what it returned or raised.
envMain ∷ Env → IO a → IO a
envMain env action = join (envStart env action)

-- | Record a line of evidence.
evidence ∷ Env → Text → IO ()
evidence env line = atomically (modifyTVar' (envEvidence env) (line :))
