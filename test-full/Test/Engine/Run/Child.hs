-- | The suite's binary as a child process: the @run@ command's real composition (its real signal handlers, its
-- real boot, its real session, its real exit mapping) over a game folder, without a native session, so the
-- signal examples can send real signals to a real process and read its real status.
--
-- The suite launches itself with one variable, 'childVariable', naming the mode, and one, 'gameVariable',
-- naming the folder. Without them this does nothing and Hspec runs. The variables belong to the suite alone; the
-- command reads neither, and its production values are not reachable from here.
--
-- * @orderly@: the real session over the folder, stdout the real stdout, the force action the real immediate
--   exit with status 130. A script prints @ui ready@; a signal stops it in order.
-- * @stuck@: the launch announces @ready@, announces @stopping@ when it first sees the stop, and then never
--   finishes: a cleanup that does not come back. It exists to show that a second signal leaves the process at once
--   with status 130, whatever the cleanup was doing, and that nothing after the stuck step runs.
module Test.Engine.Run.Child
  ( childEntry
  , childVariable
  , gameVariable
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically, check)
import Control.Exception (finally)
import Control.Monad (forever)
import Hetoimasia.Foundation.Log (LogFilter (..), defaultLogFilter)
import Hetoimasia.Run (Setup (..), production, runGame)
import Hetoimasia.Run.Session (productionEnvironment)
import System.Environment (lookupEnv)
import System.Exit (exitWith)
import System.IO (hFlush, stdout)
import Test.Engine.Run.Support (launchWithout)

-- | The variable that makes this binary a child, with the mode as its value.
childVariable ∷ String
childVariable = "HETOIMASIA_TEST_RUN_CHILD"

-- | The variable that names the game folder.
gameVariable ∷ String
gameVariable = "HETOIMASIA_TEST_RUN_GAME"

-- | Run as the child when launched as one, and answer whether this process was.
childEntry ∷ IO Bool
childEntry =
  lookupEnv childVariable >>= \case
    Nothing → pure False
    Just mode → do
      game ← lookupEnv gameVariable >>= maybe (fail "no game folder was named") pure
      let configuration = defaultLogFilter {filterEnabled = True}
          setup = case mode of
            "orderly" → production {setupLaunch = launchWithout productionEnvironment}
            "stuck" → production {setupLaunch = \_ stop _ _ → stuck stop}
            other → error ("an unknown child mode: " <> other)
      status ← runGame setup configuration game
      exitWith status
      pure True
  where
    stuck stop = do
      say "ready"
      atomically (stop >>= check)
      say "stopping"
      -- A cleanup that never returns; only the force action can end the process now.
      forever (threadDelay 100000000) `finally` say "cleaned up"
    say line = putStrLn line >> hFlush stdout
