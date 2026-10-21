-- | What the replay and qualification examples share: a deterministic input log, a session that takes its intentions and
-- controls from it alone, and the ways its execution is disturbed without changing what it is given (#500 requirements 4
-- and 5).
--
-- = The log
--
-- 'generateLog' makes a log by driving a session by hand: between ticks the example offers intentions through the UI's own
-- path, each carrying the version the latest snapshot shows, and asks the fake UI owner to do an update that pauses or
-- resumes gameplay. Nothing waits for time and nothing depends on it, so the same call makes the same log; the examples
-- use the log as a value and replay it. It holds, at its ticks, a single intention, two intentions on one entity at one
-- version (the second is stale once the first is applied), intentions on several entities, and one carrying a version
-- that is not the entity's.
--
-- = The disturbances
--
-- Delays and UI activity are produced by gates a binding holds a segment on, the amount of busy work a binding does, the
-- UI owner's updates each made due by hand and awaited by its own completion signal, and the driver's grants issued back to
-- back or with a gap that is itself UI updates. None of them waits for a duration to pass.
module Test.Domains.FixedLog
  ( -- * The log
    generateLog
  , gameplayWith
  , heavyUi
  , pausingUi
    -- * A session over a log
  , fixedConfig
  , Disturbance (..)
  , undisturbed
  , gateOf
  , gatedOn
  , gated
  , spun
  , uiHeavyOn
  , uiHeavy
  , gapped
  , runFixed
  , runFixedReal
  , runLive
  , Run (..)
  , traceOf
  , repeats
    -- * Reading a log
  , recordsAt
  , moveRecord
  , exchangePlaces
  ) where

import Control.Concurrent.STM (readTVarIO)
import Control.Monad (forM_, replicateM_, when)
import Data.ByteString (ByteString)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word (Word32, Word64)
import Hetoimasia.Sample.LuaDomains
  ( Domains (domainsShared)
  , DomainsConfig (..)
  , GameSnapshot (snapWorld)
  , SessionReport (reportTrace)
  , runSession
  , scenarioGameplay
  , scenarioStopAfter
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Canonical (Digest)
import Hetoimasia.Sample.LuaDomains.InputLog (InputLog, RecordProblem, Record (..), logOf, logRecords, recorderLog)
import Hetoimasia.Sample.LuaDomains.Intention (Placement (..), Submitted (Submitted))
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario, scenarioName, scriptedInputs)
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedRecorder), submit)
import Hetoimasia.Sample.LuaDomains.Snapshot (GameSnapshot (snapTick))
import Hetoimasia.Sample.LuaDomains.World (Entity (entityVersion), World (worldEntities))
import qualified Data.Sequence as Seq
import Test.Domains.Support

-- | How many times an example repeats a run: enough to be convincing that a disturbance changes nothing, and few enough for
-- a routine suite. The optional probe repeats them far more.
repeats ∷ Int
repeats = 5

-- | The UI behavior that pauses gameplay in its first update and resumes it in its second.
pausingUi ∷ ByteString
pausingUi =
  luaLines
    [ "local n = 0"
    , "function update(self, dt)"
    , "  n = n + 1"
    , "  control.settle()"
    , "  if n == 1 then control.pause() end"
    , "  if n == 2 then control.resume() end"
    , "  ui.updated()"
    , "end"
    ]

-- | A UI behavior with a great deal to do in each update, none of it part of any log: it reads the view over and over,
-- draws from its own random stream, offers intentions of its own (which a session that takes its intentions from a log
-- declines) and asks to pause gameplay (which such a session refuses). It says which status it sees, as the production
-- behavior does, because a session that ends in a failure waits for the UI to have seen it.
heavyUi ∷ ByteString
heavyUi =
  luaLines
    [ "local n = 0"
    , "local last_status"
    , "function update(self, dt)"
    , "  n = n + 1"
    , "  local status = view.status()"
    , "  if status ~= last_status then"
    , "    ui.saw(status)"
    , "    last_status = status"
    , "  end"
    , "  for i = 1, 20 do"
    , "    local present, _, _, version = view.entity(i % 8)"
    , "    local seen = view.tick() + view.count() + #view.status()"
    , "    intent.submit(view.session(), view.tick(), i % 8, version, 1, 1)"
    , "    local draw = math.random(1, 1000) + math.random()"
    , "  end"
    , "  if n % 3 == 0 then control.pause() end"
    , "  control.settle()"
    , "  ui.updated()"
    , "end"
    ]

-- | The production gameplay behavior with these lines run first in every update: what the examples do to a segment without
-- changing what it stages, draws or commits.
gameplayWith ∷ [Text] → ByteString
gameplayWith before =
  luaLines $
    [ "function init(self, api)"
    , "  self.workspace = workspace.open()"
    , "end"
    , "function update(self, dt)"
    ]
      <> before
      <> [ "  local count = world.count()"
         , "  local who = rand.below(count)"
         , "  local dx = rand.below(3) - 1"
         , "  local dy = rand.below(3) - 1"
         , "  staging.move(who, dx, dy)"
         , "  workspace.note(self.workspace, world.tick())"
         , "  staging.finish()"
         , "end"
         ]

-- | Make a log of this many ticks by driving a session by hand, as the module header describes; with the controls, gameplay
-- is paused for tick five and resumed for tick ten.
generateLog ∷ Word64 → Word64 → Bool → IO InputLog
generateLog seed ticks withControls =
  withSample (\config → config {configSeed = seed, configTicks = Just ticks, configInput = [], configUiSource = pausingUi}) $ \_ ui domains → do
    forM_ [1 .. ticks] $ \tick → do
      when (withControls && tick `elem` [5, 10]) (uiStep domains ui)
      (snapshot, _) ← snapshotNow domains
      let entities = worldEntities (snapWorld snapshot)
          versionOf index = maybe 0 (fromIntegral . entityVersion) (Seq.lookup index entities)
          offerAt index version dx dy = submit (domainsShared domains) (Submitted 1 (fromIntegral (snapTick snapshot)) (fromIntegral index) version dx dy)
          entity = fromIntegral ((tick * 3) `mod` 8)
          other = fromIntegral ((tick * 5 + 1) `mod` 8)
      _ ← offerAt entity (versionOf entity) 1 (-1)
      -- Two intentions on one entity at one version: the first applies and the second is stale.
      when (tick `mod` 4 == 2) (offerAt entity (versionOf entity) 0 1 >> pure ())
      when (tick `mod` 5 == 0) (offerAt other (versionOf other) (-2) 0 >> pure ())
      -- One that carries a version the entity does not have.
      when (tick `mod` 6 == 3) (offerAt other (versionOf other + 99) 2 2 >> pure ())
      _ ← stepCommitted domains
      pure ()
    recorder ← readTVarIO (sharedRecorder (domainsShared domains))
    either (\problem → fail ("the generated log was refused: " <> show problem)) pure (recorderLog recorder)

-- | A configuration that takes its intentions and controls from this log and from nothing else, for this many ticks at this
-- seed, in this scenario's gameplay.
fixedConfig ∷ InputLog → Word64 → Word64 → Scenario → DomainsConfig → DomainsConfig
fixedConfig log' ticks seed scenario config =
  config
    { configReplay = Just log'
    , configTicks = Just ticks
    , configSeed = seed
    , configScenario = scenarioName scenario
    , configGameplaySource = scenarioGameplay scenario
    , configStopAfter = scenarioStopAfter scenario
    , configInput = []
    , configUiScenario = Just "normal"
    }

-- | How a run's execution is disturbed. Each field is a way of changing when things happen and never what the session is
-- given.
data Disturbance = Disturbance
  { disturbanceName ∷ String
  , disturbanceAdjust ∷ Word64 → DomainsConfig → DomainsConfig
    -- ^ The configuration, given the number of ticks: a different gameplay behavior that holds or spins, or a UI with a good
    -- deal to do.
  , disturbanceGates ∷ Word64 → [Text]
    -- ^ The gates the gameplay behavior holds its ticks on, so that the run is released from them whatever happens.
  , disturbanceSide ∷ Word64 → Fx → FakeUi → Domains → IO ()
    -- ^ What an example does on a thread beside the driver while the session runs: it releases the gates, with UI updates
    -- between.
  , disturbancePace ∷ Domains → FakeUi → Word64 → IO ()
    -- ^ What the driver does after each committed tick: nothing, or a gap that is UI updates.
  }

-- | Nothing disturbed: the production behaviors, no UI update at all, the driver's grants back to back.
undisturbed ∷ Disturbance
undisturbed = Disturbance "undisturbed" (const id) (const []) (\_ _ _ _ → pure ()) (\_ _ _ → pure ())

-- | The gate a tick of the gated runs is held on.
gateOf ∷ Word64 → Text
gateOf tick = "t" <> Text.pack (show tick)

holdEveryTick ∷ ByteString
holdEveryTick = gameplayWith ["  fx.hold('t' .. world.tick())"]

-- | Gameplay's ticks held on gates, each released after a number of UI updates that depends on the tick, none at all for some:
-- the points at which segments are held and released differ from tick to tick. Only the ticks the predicate names are held:
-- a tick in which the behavior is paused runs no update, so nothing in it reaches a gate.
gatedOn ∷ (Word64 → Bool) → Disturbance
gatedOn runs =
  undisturbed
    { disturbanceName = "gameplay segments held and released at differing points"
    , disturbanceAdjust = \_ config → config {configGameplaySource = holdEveryTick}
    , disturbanceGates = map gateOf . held
    , disturbanceSide = \total fx ui domains →
        forM_ (held total) $ \tick → do
          awaitEntered fx (gateOf tick)
          replicateM_ (fromIntegral (tick `mod` 4)) (uiStep domains ui)
          releaseGate fx (gateOf tick)
    }
  where
    held total = filter runs [1 .. total]

gated ∷ Disturbance
gated = gatedOn (const True)

-- | Gameplay's segments doing differing amounts of busy work, in a binding that has no clock: the amount is a function of the
-- tick that a run changes with its salt.
spun ∷ Word64 → Disturbance
spun salt =
  undisturbed
    { disturbanceName = "differing amounts of spin work in segments"
    , disturbanceAdjust = \_ config → config {configGameplaySource = gameplayWith ["  fx.spin(((world.tick() * 7919 + " <> Text.pack (show salt) <> ") % 41) * 20000)"]}
    }

-- | The UI doing far more than the log: each tick the predicate names is held until the UI has done six updates, each reading
-- the view over and over, drawing from its own random stream, offering intentions of its own and asking to pause gameplay.
uiHeavyOn ∷ (Word64 → Bool) → Disturbance
uiHeavyOn runs =
  (gatedOn runs)
    { disturbanceName = "the UI doing many more updates, reads, draws and offers of its own"
    , disturbanceAdjust = \_ config → config {configGameplaySource = holdEveryTick, configUiSource = heavyUi, configInput = scriptedInputs}
    , disturbanceSide = \total fx ui domains →
        forM_ (filter runs [1 .. total]) $ \tick → do
          awaitEntered fx (gateOf tick)
          replicateM_ 6 (uiStep domains ui)
          releaseGate fx (gateOf tick)
    }

uiHeavy ∷ Disturbance
uiHeavy = uiHeavyOn (const True)

-- | The driver's grants with a gap between them, which is UI updates: the heavy UI runs between ticks, never in them.
gapped ∷ Disturbance
gapped =
  undisturbed
    { disturbanceName = "the driver's grants with gaps between them"
    , disturbanceAdjust = \_ config → config {configUiSource = heavyUi, configInput = scriptedInputs}
    , disturbancePace = \domains ui _ → replicateM_ 3 (uiStep domains ui)
    }

-- | One run of a session over a fixed log, read when it has ended.
data Run = Run
  { runReport ∷ SessionReport
  }

traceOf ∷ Run → [Digest]
traceOf = reportTrace . runReport

-- | Run a session that takes its intentions and controls from this log alone, with the UI owner on its fake clock, disturbed
-- as asked.
runFixed ∷ Disturbance → InputLog → Word64 → Word64 → Scenario → IO Run
runFixed disturbance log' ticks seed scenario = do
  holder ← newIORef Nothing
  let adjust _ ui config =
        (disturbanceAdjust disturbance ticks (fixedConfig log' ticks seed scenario config))
          { configPace = \tick → do
              known ← readIORef holder
              forM_ known (\domains → disturbancePace disturbance domains ui tick)
          }
      gates = disturbanceGates disturbance ticks
  withFixed adjust $ \fx ui domains → do
    writeIORef holder (Just domains)
    report ← withReleased fx gates (alongside (disturbanceSide disturbance ticks fx ui domains) (generous (runSession domains)))
    pure (Run report)

-- | Run a session over a fixed log with the UI owner on the real clock and timer, as the executable runs it, with the
-- scripted input to offer and the heavy UI behavior: what it offers is declined and what it asks of gameplay refused. With
-- the first tick held, the UI has done a few updates before gameplay begins, so that there is activity to refuse (the
-- examples never wait for the clock: they wait for the UI's own completion signal); without it, the run is the scenario's
-- own gameplay behavior and nothing is held.
runFixedReal ∷ Bool → InputLog → Word64 → Word64 → Scenario → IO Run
runFixedReal hold log' ticks seed scenario =
  withRealSample
    ( \config →
        let fixed = (fixedConfig log' ticks seed scenario config) {configInput = scriptedInputs, configUiSource = heavyUi}
         in if hold then fixed {configGameplaySource = gameplayWith ["  if world.tick() == 1 then fx.hold('first') end"]} else fixed
    )
    $ \fx domains → withReleased fx ["first"] $ do
      let session = generous (runSession domains)
      report ←
        if hold
          then alongside (awaitEntered fx "first" >> awaitUpdates domains 3 >> releaseGate fx "first") session
          else session
      pure (Run report)

-- | Run a live session, whose intentions come from the UI owner on the real clock and timer offering the scripted input:
-- gameplay holds its first tick until the UI has completed a few updates, so that there is something to record, and the run
-- is otherwise as the executable's. It answers the run, with the log the session accepted.
runLive ∷ Word64 → Word64 → IO (Run, Either RecordProblem InputLog)
runLive ticks seed =
  withRealSample
    (\config → config {configTicks = Just ticks, configSeed = seed, configGameplaySource = gameplayWith ["  if world.tick() == 1 then fx.hold('first') end"]})
    $ \fx domains → withReleased fx ["first"] $ do
      report ←
        alongside
          (awaitEntered fx "first" >> awaitUpdates domains 3 >> releaseGate fx "first")
          (generous (runSession domains))
      recorder ← readTVarIO (sharedRecorder (domainsShared domains))
      pure (Run report, recorderLog recorder)

-- | A session over a configuration the example adjusts, with the UI owner on the fake clock and timer, built from the fake and
-- the fixture the adjustment is given.
withFixed ∷ (Fx → FakeUi → DomainsConfig → DomainsConfig) → (Fx → FakeUi → Domains → IO a) → IO a
withFixed adjust body = do
  fx ← newFx
  ui ← newFakeUi
  withBoundary $ \control → withDomains control (adjust fx ui (sampleConfig fx ui)) (body fx ui)

-- The log, read ----------------------------------------------------------------------

-- | The records of this tick.
recordsAt ∷ Word64 → InputLog → [Record]
recordsAt tick = filter (\record → recordTickOf record == tick) . logRecords

recordTickOf ∷ Record → Word64
recordTickOf = \case
  RecordIntention place _ _ _ _ _ _ → placeTick place
  RecordControl tick _ _ _ → tick

-- | The log with its first intention at this tick moved to this other tick, at a place that tick does not hold.
moveRecord ∷ Word64 → Word64 → InputLog → InputLog
moveRecord from to log' = logOf (moved <> kept)
  where
    intentionsAt tick = [record | record@(RecordIntention {}) ← recordsAt tick log']
    chosen = case intentionsAt from of
      record : _ → record
      [] → error "no intention at the tick to move from"
    kept = [record | record ← logRecords log', record /= chosen]
    free = fromIntegral (length (intentionsAt to)) ∷ Word32
    moved = case chosen of
      RecordIntention _ acting view entity version dx dy → [RecordIntention (Placement to free) acting view entity version dx dy]
      other → [other]

-- | The log with the places of the first two intentions of this tick exchanged, the records being the same.
exchangePlaces ∷ Word64 → InputLog → InputLog
exchangePlaces tick log' = case [record | record@(RecordIntention {}) ← recordsAt tick log'] of
  first@(RecordIntention (Placement _ p1) a1 v1 e1 n1 x1 y1) : second@(RecordIntention (Placement _ p2) a2 v2 e2 n2 x2 y2) : _ →
    logOf
      ( [record | record ← logRecords log', record /= first, record /= second]
          <> [RecordIntention (Placement tick p2) a1 v1 e1 n1 x1 y1, RecordIntention (Placement tick p1) a2 v2 e2 n2 x2 y2]
      )
  _ → error "fewer than two intentions at the tick"
