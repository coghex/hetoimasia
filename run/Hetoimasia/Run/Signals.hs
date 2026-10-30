-- | The signal rule of @hetoimasia run@: one scoped installation of SIGINT and SIGTERM handlers sharing one
-- coordinator (D-42, P-71).
--
-- The rule is "Hetoimasia.Console.Lua.Signals"' and is reused rather than copied: a first delivery, of either
-- signal, requests an orderly whole-session stop and returns without waiting for it; a second delivery while
-- the run is stopping calls the force action, exactly once, and a later one changes nothing. The two signals
-- share the one count and the one authority. In production the force action leaves the process at once with
-- status 130 ('forceExit'): no handler, finalizer or flush runs, no script and no cleanup, even when a failure
-- was already recorded.
--
-- The handlers are installed after the arguments are valid and before any boot work, and the handlers that
-- were in force are put back on every way out of the scope, ordinary return or failure alike. (The @lua@
-- command installs its handlers for the life of the process and does not restore them; this scope does.)
--
-- Ownership: the coordinator belongs to the scope; a handler runs on a thread the runtime makes for the
-- delivery, touches only the coordinator's one variable and the force action, and never enters Lua.
module Hetoimasia.Run.Signals
  ( withRunSignals
  , forceExit
  ) where

import Control.Exception (bracket, onException)
import Control.Monad (void)
import Hetoimasia.Console.Exit (cancellationExitCode)
import Hetoimasia.Console.Lua.Signals (Coordinator, deliver, newCoordinator)
import System.Posix.Process (exitImmediately)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

-- | The production force action: leave the process now with status 130. It is not a catchable exception and it
-- unwinds nothing.
forceExit ∷ IO ()
forceExit = exitImmediately cancellationExitCode

-- | Run a body with SIGINT and SIGTERM sharing one coordinator whose force action is this, and restore the
-- previous handlers when the body leaves.
withRunSignals ∷ IO () → (Coordinator → IO a) → IO a
withRunSignals force body = do
  coordinator ← newCoordinator force
  let handler = Catch (void (deliver coordinator))
  bracket
    ( do
        interrupt ← installHandler sigINT handler Nothing
        -- A failed second installation puts the first back: the scope never leaves one handler of the two.
        terminate ← installHandler sigTERM handler Nothing `onException` installHandler sigINT interrupt Nothing
        pure (interrupt, terminate)
    )
    ( \(interrupt, terminate) → do
        _ ← installHandler sigINT interrupt Nothing
        void (installHandler sigTERM terminate Nothing)
    )
    (\_ → body coordinator)
