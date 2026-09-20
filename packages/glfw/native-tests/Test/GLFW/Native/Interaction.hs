-- | The owner-loop interaction probe: what an owner turn does while a person
-- moves, resizes, and uses the menu bar against an ordinary engine window.
--
-- GLFW documents that on some platforms those interactions run a platform
-- modal loop inside @glfwPollEvents@ or @glfwWaitEventsTimeout@. An owner turn
-- reconciles callbacks, dispatches commands, and offers the update hook only
-- after that call returns, so if such a loop exists here, nothing the
-- application owns progresses while the person is interacting. This probe
-- measures that instead of assuming it: it runs the production owner loop over
-- an ordinary window in the shared session, with the session's bounded
-- interaction trace ("Hetoimasia.GLFW.Internal.Trace") started, and reports the
-- pump entries and exits, the callbacks delivered between them, the owner
-- turns, and the update opportunities, all stamped from one monotonic clock.
--
-- = It is not part of any routine run
--
-- Two separate things gate it. The suite's consent gate refuses it, like every
-- other example that touches the session, before its body runs when the run
-- carries no @HETOIMASIA_NATIVE_SESSION@ consent. On top of that it is
-- /inactive/ unless @HETOIMASIA_INTERACTION_PROBE_SECONDS@ asks for it, so the
-- mandatory @test.glfw-native@ group — which runs the whole suite on an
-- isolated X11 display, with consent — reports it pending and opens no window.
-- No validation group names it and no CI runs it: it exists to be invoked
-- deliberately, once, by a person who has agreed to the disruption and will
-- perform the interactions.
--
-- = What a person does
--
-- The run works through 'probePhases' in order, each lasting the seconds the
-- variable asked for. Before each phase it prints what to do and marks the
-- phase's beginning in the trace; when that phase's time is up it marks the end
-- and takes the phase's records. Every line it prints is between measurement
-- intervals, never inside one, so an interval contains only the loop and the
-- recording, and recording is one clock reading and one non-blocking update.
-- The first phase is an idle baseline, so an interaction's numbers are read
-- against ordinary waiting rather than against nothing.
--
-- = What it asserts
--
-- That each phase measured something — at least one owner turn and one
-- complete pump — and that no phase lost records or faulted, because a verdict
-- must not be written from truncated evidence. It asserts nothing about
-- whether a stall happened: that is the question, and either answer is a
-- result. The report is printed before any assertion, so a failing run still
-- retains everything it measured.
module Test.GLFW.Native.Interaction
  ( spec

    -- * Activation
  , probeVariable
  , probeOutputVariable
  , ProbeInactive (..)
  , probeActivation
  , inactiveMessage

    -- * The interactions asked for
  , Phase (..)
  , probePhases
  ) where

import Control.Monad (forM_, unless, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, sortOn)
import qualified Data.Map.Strict as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (RequirePositive)
  , Instant
  , MonotonicSource
  , addDuration
  , convertedDuration
  , deadlineReached
  , durationFromSeconds
  , durationNanoseconds
  , elapsedBetween
  , monotonicSource
  , readInstant
  )
import Hetoimasia.GLFW.Internal.Session (sessionTrace)
import Hetoimasia.GLFW.Internal.Trace
  ( PumpMode (..)
  , Trace
  , TraceEvent (..)
  , TraceEvidence (..)
  , TraceRecord (..)
  , defaultTraceCapacity
  , evidenceComplete
  , recordTrace
  , startTrace
  , stopTrace
  , takeTrace
  )
import Hetoimasia.GLFW.Session (Session, sessionBackend)
import Hetoimasia.GLFW.Window (defaultWindowConfig)
import Hetoimasia.Runtime.GLFW
  ( HostConfig (..)
  , LoopHooks (..)
  , Turn (..)
  , TurnStep (..)
  , allocWindowHostIn
  , defaultHostConfig
  , noApplicationEvents
  , runOwnerLoop
  , runWindowApplication
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Numeric (showFFloat)
import Numeric.Natural (Natural)
import System.Environment (getEnvironment)
import System.IO (hFlush, stdout)
import System.Info (os)
import Test.GLFW.Native.Support (Shared, failed, owned)
import Test.Hspec (Spec, describe, it, pendingWith)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Activation

-- | The variable that activates the probe, holding the seconds each phase
-- lasts. Unset, the probe is pending and opens no window.
probeVariable ∷ String
probeVariable = "HETOIMASIA_INTERACTION_PROBE_SECONDS"

-- | An optional file the run writes every record to, so the timestamped
-- evidence can be retained beside a verdict. Unset, only the summary is
-- printed.
probeOutputVariable ∷ String
probeOutputVariable = "HETOIMASIA_INTERACTION_PROBE_OUTPUT"

-- | Why an environment does not activate the probe.
data ProbeInactive
  = ProbeNotRequested
    -- ^ The variable is unset or empty.
  | ProbeNotSeconds String
    -- ^ It holds something that is not a positive, finite number of seconds.
  deriving (Eq, Show)

-- | The seconds each phase lasts, or why this environment does not activate
-- the probe. Pure, so what activates it is decided and tested without an
-- environment, a display, or a session.
probeActivation ∷ [(String, String)] → Either ProbeInactive Double
probeActivation environment = case lookup probeVariable environment of
  Nothing → Left ProbeNotRequested
  Just "" → Left ProbeNotRequested
  Just value → case readMaybe value of
    Just seconds
      | seconds > 0 && not (isInfinite seconds) && not (isNaN seconds) → Right seconds
    _ → Left (ProbeNotSeconds value)

-- | What a pending run says: why it is pending, what activating it does to the
-- desktop, and which variable activates it.
inactiveMessage ∷ ProbeInactive → String
inactiveMessage inactive =
  reason
    <> "; this probe opens an ordinary window on the desktop the run is on and asks a person to move it,"
    <> " resize it, and use the menu bar while it measures owner-turn progress, so no routine or CI run"
    <> " performs it. Set "
    <> probeVariable
    <> " to the seconds each interaction should last, on an approved desktop command, to exercise it"
  where
    reason = case inactive of
      ProbeNotRequested → "unexercised on " <> os <> ": " <> probeVariable <> " is not set"
      ProbeNotSeconds value → probeVariable <> "=" <> show value <> " is not a positive number of seconds"

-- ---------------------------------------------------------------------------
-- The interactions asked for

-- | One measured interval and what the person is asked to do during it.
data Phase = Phase
  { phaseName ∷ !Text
  , phaseInstruction ∷ !String
  }
  deriving (Eq, Show)

-- | The idle baseline first, then the three interactions RR-4 asks about, in
-- order. A phase a person does not actually perform is still measured and
-- still reported; the verdict says which ones were performed.
probePhases ∷ [Phase]
probePhases =
  [ Phase "idle baseline" "do not touch the window, the mouse, or the keyboard"
  , Phase "window move" "press and hold on the window's title bar and keep dragging it, without letting go"
  , Phase "window resize" "press and hold on an edge or a corner of the window and keep dragging it, without letting go"
  , Phase "menu-bar interaction" "open a menu in the menu bar, keep it open, and move through its entries"
  ]

-- ---------------------------------------------------------------------------
-- The example

spec ∷ Shared → Spec
spec shared = describe "owner-loop progress during window interactions" $
  it "records the native pump, the callbacks delivered inside it, and owner-turn progress while a person moves, resizes, and uses the menu bar" $
    probeActivation <$> getEnvironment >>= \case
      Left inactive → pendingWith (inactiveMessage inactive)
      Right seconds → runProbe shared seconds

-- | What one phase produced.
data PhaseResult = PhaseResult
  { resultPhase ∷ !Phase
  , resultEvidence ∷ !TraceEvidence
  }

runProbe ∷ Shared → Double → IO ()
runProbe shared seconds = do
  output ← lookup probeOutputVariable <$> getEnvironment
  duration ← case durationFromSeconds RequirePositive seconds of
    Right converted → pure (convertedDuration converted)
    Left rejected → failed (probeVariable <> " is not a duration: " <> show rejected)
  (backend, results) ← owned shared $ \session →
    (,) (show (sessionBackend session)) <$> measure probeHostConfig duration session
  putStr (report backend seconds probeHostConfig results)
  hFlush stdout
  forM_ output $ \path → do
    writeFile path (dump results)
    putStrLn ("glfw-native-tests interaction probe: every record written to " <> path)
    hFlush stdout
  mapM_ checkPhase results

checkPhase ∷ PhaseResult → IO ()
checkPhase result = do
  when (null [() | TurnBegan _ ← events]) $
    failed ("the " <> name <> " phase recorded no owner turn at all")
  when (null (pumpIntervals (evidenceRecords evidence))) $
    failed ("the " <> name <> " phase recorded no complete native pump")
  unless (evidenceComplete evidence) . failed $
    "the "
      <> name
      <> " phase lost "
      <> show (evidenceLost evidence)
      <> " record(s) and faulted "
      <> show (evidenceFaults evidence)
      <> " time(s), so its evidence is incomplete; shorten the phase or raise the trace capacity and run it again"
  where
    evidence = resultEvidence result
    events = map recordEvent (evidenceRecords evidence)
    name = Text.unpack (phaseName (resultPhase result))

-- | An ordinary engine window and the ordinary loop settings, so what is
-- measured is a configuration an application would actually run.
probeHostConfig ∷ HostConfig
probeHostConfig =
  defaultHostConfig [defaultWindowConfig "Hetoimasia owner-loop interaction probe" 640 480]

-- ---------------------------------------------------------------------------
-- Measuring

-- | Run the production owner loop through every phase, on the owner thread.
measure ∷ HostConfig → Duration → Session → IO [PhaseResult]
measure config duration session = do
  collected ← newIORef []
  runWindowApplication
    (withLoggingLifetime quietLogger)
    "interaction-probe"
    (allocWindowHostIn (pure session) config)
    id
    (\host _ → pure host)
    ( \host control → case probePhases of
        [] → pure ()
        first : rest → do
          pending ← newIORef rest
          current ← newIORef first
          announce first
          deadline ← newIORef =<< after clock duration
          startTrace trace clock defaultTraceCapacity
          mark trace first "begins"
          runOwnerLoop host control $
            LoopHooks
              { loopLogger = quietLogger
              , loopEvent = noApplicationEvents
              , loopUpdate = \turn → do
                  recordTrace trace (UpdateHookEntered (turnNumber turn))
                  now ← readInstant clock
                  reached ← deadlineReached now <$> readIORef deadline
                  recordTrace trace (UpdateHookLeft (turnNumber turn))
                  if reached
                    then advance trace duration collected pending current deadline
                    else pure Continue
              }
    )
  readIORef collected
  where
    trace = sessionTrace session
    clock = monotonicSource

-- | Close the phase that just ended, keep its records, and either begin the
-- next phase or finish. Everything printed here is between measurement
-- intervals, never inside one.
advance
  ∷ Trace
  → Duration
  → IORef [PhaseResult]
  → IORef [Phase]
  → IORef Phase
  → IORef Instant
  → IO (TurnStep ())
advance trace duration collected pending current deadline = do
  finished ← readIORef current
  mark trace finished "ends"
  evidence ← takeTrace trace
  modifyIORef' collected (<> [PhaseResult finished evidence])
  readIORef pending >>= \case
    [] → Finish () <$ stopTrace trace
    next : rest → do
      writeIORef pending rest
      writeIORef current next
      announce next
      writeIORef deadline =<< after monotonicSource duration
      mark trace next "begins"
      pure Continue

mark ∷ Trace → Phase → Text → IO ()
mark trace phase what = recordTrace trace (Marked (phaseName phase <> " " <> what))

announce ∷ Phase → IO ()
announce phase = do
  putStrLn ""
  putStrLn ("glfw-native-tests interaction probe — " <> Text.unpack (phaseName phase))
  putStrLn ("  from now until this says otherwise: " <> phaseInstruction phase)
  hFlush stdout

after ∷ MonotonicSource → Duration → IO Instant
after clock duration = do
  now ← readInstant clock
  either (\overflow → failed ("the phase deadline overflowed: " <> show overflow)) pure (addDuration now duration)

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

-- ---------------------------------------------------------------------------
-- Reading the records

-- | One entry into the native event call and its matching exit.
data PumpInterval = PumpInterval
  { intervalMode ∷ !PumpMode
  , intervalStart ∷ !Instant
  , intervalEnd ∷ !Instant
  , intervalCallbacks ∷ ![Text]
    -- ^ The callbacks delivered between the two, in order.
  }

-- | Every complete pump interval, in order. A pump still open at the end of
-- the records is not an interval: its exit was not recorded.
pumpIntervals ∷ [TraceRecord] → [PumpInterval]
pumpIntervals = go Nothing
  where
    go _ [] = []
    go open (record : rest) = case (recordEvent record, open) of
      (PumpEntered mode, _) → go (Just (mode, recordInstant record, [])) rest
      (PumpLeft mode, Just (_, start, inside)) →
        PumpInterval mode start (recordInstant record) (reverse inside) : go Nothing rest
      (CallbackDelivered _ name, Just (mode, start, inside)) → go (Just (mode, start, name : inside)) rest
      _ → go open rest

intervalDuration ∷ PumpInterval → Duration
intervalDuration interval = elapsedBetween (intervalStart interval) (intervalEnd interval)

-- | How much longer the call took than the turn asked it to.
--
-- A finite wait asked for its seconds, so anything beyond them is overrun; a
-- poll asked to return at once, so its whole duration is.
intervalOverrun ∷ PumpInterval → Double
intervalOverrun interval = case intervalMode interval of
  PolledEvents → taken
  WaitedForEvents requested → max 0 (taken - requested)
  where
    taken = secondsOf (intervalDuration interval)

-- | The longest stretch with no update opportunity: from one update hook's
-- return to the next one's entry.
updateGaps ∷ [TraceRecord] → [(Instant, Instant)]
updateGaps records = go Nothing records
  where
    go _ [] = []
    go left (record : rest) = case (recordEvent record, left) of
      (UpdateHookLeft _, _) → go (Just (recordInstant record)) rest
      (UpdateHookEntered _, Just from) → (from, recordInstant record) : go Nothing rest
      _ → go left rest

-- ---------------------------------------------------------------------------
-- The report

report ∷ String → Double → HostConfig → [PhaseResult] → String
report backend seconds config results =
  unlines $
    [ ""
    , "glfw-native-tests owner-loop interaction probe"
    , "  platform " <> os <> "; session backend " <> backend
    , "  seconds per phase " <> showSeconds seconds <> "; trace capacity " <> show defaultTraceCapacity <> " records"
    , "  host idle wait "
        <> showSeconds (hostIdleWait config)
        <> " s; command budget "
        <> show (hostCommandBudget config)
        <> "; event budget "
        <> show (hostEventBudget config)
        <> "; window limit "
        <> show (hostWindowLimit config)
    , "  every instant below is an offset from the first record of its own phase, on one monotonic clock"
    ]
      <> concatMap phaseReport results

phaseReport ∷ PhaseResult → [String]
phaseReport result =
  [ ""
  , "phase " <> show (Text.unpack (phaseName (resultPhase result)))
  , "  asked for: " <> phaseInstruction (resultPhase result)
  ]
    <> case evidenceRecords evidence of
      [] → ["  nothing was recorded"]
      first : _ →
        let origin = recordInstant first
            intervals = pumpIntervals (evidenceRecords evidence)
            waits = [interval | interval ← intervals, WaitedForEvents _ ← [intervalMode interval]]
            polls = [interval | interval ← intervals, PolledEvents ← [intervalMode interval]]
            gaps = updateGaps (evidenceRecords evidence)
            callbacks = [name | CallbackDelivered _ name ← map recordEvent (evidenceRecords evidence)]
            inside = concatMap intervalCallbacks intervals
         in [ "  span "
                <> showDuration (elapsedBetween origin (recordInstant (lastRecord first (evidenceRecords evidence))))
                <> "; owner turns "
                <> show (length [() | TurnBegan _ ← map recordEvent (evidenceRecords evidence)])
                <> "; update opportunities "
                <> show (length [() | UpdateHookEntered _ ← map recordEvent (evidenceRecords evidence)])
            , "  pumps " <> show (length intervals) <> " (" <> show (length polls) <> " poll, " <> show (length waits) <> " wait)"
            , "  longest stretch with no update opportunity: "
                <> maybe "none recorded" (\(from, to) → showDuration (elapsedBetween from to) <> " at +" <> showDuration (elapsedBetween origin from)) (longestGap gaps)
            , "  callbacks delivered " <> show (length callbacks) <> ", of which " <> show (length inside) <> " from inside a pump"
            , "  callbacks by name: " <> tally callbacks
            , "  evidence "
                <> (if evidenceComplete evidence then "complete" else "INCOMPLETE")
                <> " ("
                <> show (evidenceLost evidence)
                <> " lost, "
                <> show (evidenceFaults evidence)
                <> " faults)"
            ]
              <> ["  the longest pump intervals:"]
              <> map (("    " <>) . describeInterval origin) (take 5 (sortOn (Down . intervalOverrun) intervals))
  where
    evidence = resultEvidence result

-- | The last record, with the first as the fallback an empty tail cannot
-- reach: the caller already matched at least one record.
lastRecord ∷ TraceRecord → [TraceRecord] → TraceRecord
lastRecord fallback = foldl' (\_ record → record) fallback

longestGap ∷ [(Instant, Instant)] → Maybe (Instant, Instant)
longestGap gaps = case sortOn (\(from, to) → Down (elapsedBetween from to)) gaps of
  longest : _ → Just longest
  [] → Nothing

describeInterval ∷ Instant → PumpInterval → String
describeInterval origin interval =
  mode
    <> " took "
    <> showDuration (intervalDuration interval)
    <> " at +"
    <> showDuration (elapsedBetween origin (intervalStart interval))
    <> ", over by "
    <> showSeconds (intervalOverrun interval * 1000)
    <> " ms, with "
    <> show (length (intervalCallbacks interval))
    <> " callback(s) inside: "
    <> tally (intervalCallbacks interval)
  where
    mode = case intervalMode interval of
      PolledEvents → "poll"
      WaitedForEvents requested → "wait of " <> showSeconds (requested * 1000) <> " ms"

tally ∷ [Text] → String
tally [] = "none"
tally names =
  intercalate ", " [Text.unpack name <> " " <> show count | (name, count) ← Map.toAscList counted]
  where
    counted = Map.fromListWith (+) [(name, 1 ∷ Int) | name ← names]

secondsOf ∷ Duration → Double
secondsOf duration = fromIntegral (durationNanoseconds duration) / 1e9

showDuration ∷ Duration → String
showDuration duration = showSeconds (secondsOf duration * 1000) <> " ms"

showSeconds ∷ Double → String
showSeconds value = showFFloat (Just 3) value ""

-- ---------------------------------------------------------------------------
-- The retained dump

-- | Every record of every phase, one per line: its sequence number, its offset
-- from the first record of its phase, and the event.
dump ∷ [PhaseResult] → String
dump results = unlines (concatMap phaseDump results)
  where
    phaseDump result =
      [ "# phase " <> Text.unpack (phaseName (resultPhase result))
      , "# asked for: " <> phaseInstruction (resultPhase result)
      , "# lost " <> show (evidenceLost evidence) <> "; faults " <> show (evidenceFaults evidence)
      , "# sequence\toffset_ms\tevent"
      ]
        <> case evidenceRecords evidence of
          [] → ["# no records"]
          first : _ → map (line (recordInstant first)) (evidenceRecords evidence)
      where
        evidence = resultEvidence result
    line origin record =
      show (recordSequence record)
        <> "\t"
        <> showSeconds (secondsOf (elapsedBetween origin (recordInstant record)) * 1000)
        <> "\t"
        <> describeEvent (recordEvent record)

describeEvent ∷ TraceEvent → String
describeEvent = \case
  TurnBegan number → "turn " <> show (number ∷ Natural) <> " began"
  PumpEntered PolledEvents → "pump entered (poll)"
  PumpEntered (WaitedForEvents requested) → "pump entered (wait " <> showSeconds (requested * 1000) <> " ms)"
  PumpLeft PolledEvents → "pump left (poll)"
  PumpLeft (WaitedForEvents requested) → "pump left (wait " <> showSeconds (requested * 1000) <> " ms)"
  CallbackDelivered window name → "callback " <> Text.unpack name <> " on window " <> Text.unpack window
  UpdateHookEntered number → "update hook entered (turn " <> show number <> ")"
  UpdateHookLeft number → "update hook left (turn " <> show number <> ")"
  Marked what → "mark: " <> Text.unpack what
