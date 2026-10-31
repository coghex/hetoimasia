{-# LANGUAGE OverloadedStrings #-}

-- | What the integrated (LFE-23) examples of the CPU suite share. They compose the facade's world
-- ('Test.LuaEngine.Facade.Support') and the session's ('Test.LuaEngine.Session.Support'); this module adds only the
-- small readings and waits the integrated examples have in common. It owns no fixture state and no registry.
--
-- Every wait is bounded and none sleeps: a wait is on a line a script printed, on a read the pool's probe saw, or on
-- STM, never on time. A failing wait prints what the world had seen, so the first broken invariant is in the log.
module Test.LuaEngine.Integrated.Support
  ( named
  , pumpClock
  , awaitLine
  , dumpOnFailure
  , awaitPhaseOf
  , awaitErrLines
  , awaitStartedPath
  , awaitFinishedPath
  , shareModule
  ) where

import Control.Concurrent (yield)
import Control.Exception (onException)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import System.IO (hPutStrLn, stderr)
import Hetoimasia.Scripting.Lua.Instance (InstancePhase)
import Test.LuaEngine.Facade.Support
import Test.LuaEngine.Modules.Support (Probe, finishedPaths, startedPaths)
import Test.Support.Bounded (bounded)

-- | The lines an example printed that start with this label and a space, without them.
named ∷ Text → [Text] → [Text]
named label seen = [Text.drop (Text.length label + 1) line | line ← seen, (label <> " ") `Text.isPrefixOf` line]

-- | Move the injected clock on one second and fire the armed timers, until the condition holds: each pass makes
-- every presentation instance whose cadence is a second due again. Bounded; nothing waits for time to pass.
pumpClock ∷ World → IO Bool → IO ()
pumpClock world condition = bounded loop
  where
    loop = do
      done ← condition
      unless done (advanceClock world 1000000000 >> fireTimers world >> yield >> loop)

-- | Pump the clock until a script has printed exactly this line.
awaitLine ∷ World → Text → IO ()
awaitLine world wanted = pumpClock world (elem wanted <$> outLines world)

-- | Run an example; if it fails, print what the world had printed and how each instance stood, for the log.
dumpOnFailure ∷ World → [Spawned] → IO a → IO a
dumpOnFailure world instances action = action `onException` dump
  where
    dump = do
      out ← outLines world
      err ← errLines world
      hPutStrLn stderr ("stdout: " <> show out <> "\nstderr: " <> show err)
      mapM_ (\found → phaseOf found >>= \phase → hPutStrLn stderr (show (spId found, phase))) instances

-- | Wait until the pool's reader has started a read of this path.
awaitStartedPath ∷ Probe → ByteString → IO ()
awaitStartedPath probe path = bounded loop
  where
    loop = startedPaths probe >>= \found → unless (path `elem` found) (yield >> loop)

-- | Wait until the pool's reader has finished a read of this path.
awaitFinishedPath ∷ Probe → ByteString → IO ()
awaitFinishedPath probe path = bounded loop
  where
    loop = finishedPaths probe >>= \found → unless (path `elem` found) (yield >> loop)

-- | A module every instance of a VM imports: its table is the VM's one export, shared and mutable.
shareModule ∷ ByteString
shareModule =
  luaMain
    [ "warn('share evaluated')"
    , "return {n = 0, apis = {}, selves = {}, data = {}, saved = {}}"
    ]

-- | Wait until the instance is in this phase (and not past it: a phase it has left is a failed wait).
awaitPhaseOf ∷ Spawned → InstancePhase → IO ()
awaitPhaseOf found wanted = bounded loop
  where
    loop =
      phaseOf found >>= \phase →
        if phase == Just wanted then pure () else yield >> loop

-- | Wait until a script has warned this many times.
awaitErrLines ∷ World → Int → IO ()
awaitErrLines world wanted = bounded (awaitErr world wanted >>= \_ → pure ())
