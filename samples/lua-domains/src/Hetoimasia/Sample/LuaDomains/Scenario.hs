-- | The executable's scenarios (#499 requirement 13): each is a fixed scripted fake input, a gameplay
-- behavior and, for two of them, a tick at which the session does something. They are the same session as
-- #498's with one thing changed, so the report and the exit status show what that one thing does.
--
-- +-----------+------------------------------------------------------------------------------------+
-- | Scenario  | What it does                                                                       |
-- +===========+====================================================================================+
-- | @normal@  | #498's session: the fixed input, nothing else. The default.                        |
-- +-----------+------------------------------------------------------------------------------------+
-- | @pause@   | The UI asks to pause gameplay's behavior once the view shows tick 4 and to resume  |
-- |           | it once the view shows tick 9. Ticks go on being granted and committed throughout. |
-- +-----------+------------------------------------------------------------------------------------+
-- | @failure@ | Gameplay's behavior raises at tick 6. The session fails there: the last good world |
-- |           | is tick 5's, and the session ends in status @failed@, exit status 1.               |
-- +-----------+------------------------------------------------------------------------------------+
-- | @flood@   | The UI offers two hundred intentions, sixteen an update, more than the queue holds,|
-- |           | so many are answered @full@ and offered again a bounded number of times.           |
-- +-----------+------------------------------------------------------------------------------------+
-- | @stop@    | The driver stops the session after tick 8 is committed: status @stopped@.          |
-- +-----------+------------------------------------------------------------------------------------+
--
-- The ticks are those of the session's own numbering. A scenario's UI behavior reads them from its view, so
-- on elapsed time the tick it acts at can be a little later than the one named; the failure and the stop are
-- the driver's and the script's, and happen at exactly theirs.
module Hetoimasia.Sample.LuaDomains.Scenario
  ( Scenario (..)
  , allScenarios
  , scenarioName
  , parseScenario
  , scenarioInputs
  , scenarioGameplay
  , scenarioStopAfter
  , scenarioMinimumTicks
  , scriptedInputs
  ) where

import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains.Scripts (gameplayFailureSource, gameplaySource)
import Hetoimasia.Sample.LuaDomains.Shared (ScriptedInput (..))

-- | One of the executable's scenarios.
data Scenario
  = Normal
  | Pause
  | Failure
  | Flood
  | Stop
  deriving (Eq, Show, Enum, Bounded)

allScenarios ∷ [Scenario]
allScenarios = [minBound .. maxBound]

scenarioName ∷ Scenario → Text
scenarioName = \case
  Normal → "normal"
  Pause → "pause"
  Failure → "failure"
  Flood → "flood"
  Stop → "stop"

-- | The scenario of this name, if there is one.
parseScenario ∷ String → Maybe Scenario
parseScenario name = lookup name [(Text.unpack (scenarioName scenario), scenario) | scenario ← allScenarios]

-- | The fake input source's list, the same on every run: forty entries cycling through the first
-- eight entities, with deltas from two short tables.
scriptedInputs ∷ [ScriptedInput]
scriptedInputs =
  [ ScriptedInput (fromIntegral ((index * 3) `mod` 8)) (dxs !! (index `mod` 8)) (dys !! ((index + 3) `mod` 8))
  | index ← [0 .. 39 ∷ Int]
  ]
  where
    dxs = [1, -1, 2, 0, -2, 1, 0, 3]
    dys = [0, 1, -1, 2, 0, -2, 1, -1]

-- | The input a scenario offers: the fixed forty, or for @flood@ two hundred of the same kind.
scenarioInputs ∷ Scenario → [ScriptedInput]
scenarioInputs = \case
  Flood →
    [ ScriptedInput (fromIntegral ((index * 3) `mod` 8)) (dxs !! (index `mod` 8)) (dys !! ((index + 3) `mod` 8))
    | index ← [0 .. 199 ∷ Int]
    ]
  _ → scriptedInputs
  where
    dxs = [1, -1, 2, 0, -2, 1, 0, 3]
    dys = [0, 1, -1, 2, 0, -2, 1, -1]

-- | The gameplay behavior a scenario runs: the normal one, or for @failure@ the one that raises at tick six.
scenarioGameplay ∷ Scenario → ByteString
scenarioGameplay = \case
  Failure → gameplayFailureSource
  _ → gameplaySource

-- | The tick after which the driver stops the session, for the scenario that stops it.
scenarioStopAfter ∷ Scenario → Maybe Word64
scenarioStopAfter = \case
  Stop → Just 8
  _ → Nothing

-- | The fewest ticks a scenario's point can fall within: asking for fewer ends the session before it.
scenarioMinimumTicks ∷ Scenario → Word64
scenarioMinimumTicks = \case
  Normal → 1
  Pause → 12
  Failure → 7
  Flood → 4
  Stop → 9
