-- | The bounded interaction trace, and where an owner turn offers it records.
--
-- The storage examples drive "Hetoimasia.GLFW.Internal.Trace" directly over a
-- scripted clock: what a stopped trace records, that a running one keeps its
-- records in one time domain and in order, that it keeps the first records
-- under its bound and counts the rest lost while still numbering them all,
-- that a take continues the sequence, and that a recording whose clock fails
-- is counted as a fault rather than raised.
--
-- The owner-turn examples run the production loop over the test seam and
-- assert the order the interaction probe reads: a turn begins, the pump is
-- entered, every callback the seam delivers from inside that pump is recorded
-- between the pump's entry and its exit, and the update hook follows the exit.
-- Nothing here initializes GLFW, needs a display, or depends on an observed
-- platform stall: the interaction the probe measures is modelled by events the
-- seam delivers from inside the pump, which is where GLFW delivers them.
module Test.GLFW.Trace (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (throwIO)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time (Instant, MonotonicSource, monotonicSource, scriptedSource)
import Hetoimasia.GLFW.Internal.Seam
  ( WindowEvent (..)
  , asProcessMainThread
  , defaultScript
  , newSeam
  , seamQueueEvents
  )
import Hetoimasia.GLFW.Internal.Session (sessionTrace)
import Hetoimasia.GLFW.Internal.Trace
  ( PumpMode (..)
  , TraceEvent (..)
  , TraceEvidence (..)
  , TraceRecord (..)
  , defaultTraceCapacity
  , evidenceComplete
  , newTrace
  , noEvidence
  , recordTrace
  , startTrace
  , stopTrace
  , takeTrace
  , traceRunning
  )
import Hetoimasia.Runtime.GLFW
  ( LoopHooks (..)
  , Turn (..)
  , TurnStep (..)
  , allocWindowHostIn
  , hostWindowIdentities
  , noApplicationEvents
  , runOwnerLoop
  , runWindowApplication
  , withHostWindow
  )
import Hetoimasia.GLFW.Window (WindowResult (..))
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Numeric.Natural (Natural)
import Test.GLFW.Support
  ( at
  , boundedExample
  , entered
  , quietLogger
  , scriptedClock
  , settings
  , unexpected
  , windowNamed
  )
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW interaction trace" $ do
  describe "bounded measurement storage" $ do
    it "records nothing at all while it is stopped" testStopped
    it "keeps every record in order, in the clock domain it was started with" testOrdered
    it "keeps the first records under its bound and counts the rest lost, numbering them all" testBounded
    it "continues the sequence across a take, which clears the buffer and both counts" testTakeContinues
    it "counts a recording whose clock fails as a fault instead of raising it" testClockFault

  describe "what an owner turn offers it" $ do
    it "orders the turn, its pump, the callbacks delivered inside that pump, and its update hook" $
      boundedExample testOwnerTurnOrder
    it "identifies a poll and a finite wait by the seconds the turn asked for" $
      boundedExample testPumpModes

-- ---------------------------------------------------------------------------
-- Bounded measurement storage

testStopped ∷ Expectation
testStopped = do
  trace ← newTrace
  traceRunning trace `shouldReturn` False
  recordTrace trace (Marked "ignored")
  takeTrace trace `shouldReturn` noEvidence
  stopTrace trace `shouldReturn` noEvidence
  traceRunning trace `shouldReturn` False

testOrdered ∷ Expectation
testOrdered = do
  (clock, unread) ← scriptedClock [10, 20, 30]
  trace ← newTrace
  startTrace trace clock defaultTraceCapacity
  traceRunning trace `shouldReturn` True
  mapM_ (recordTrace trace) [TurnBegan 1, PumpEntered PolledEvents, PumpLeft PolledEvents]
  evidence ← stopTrace trace
  map (\record → (recordSequence record, recordInstant record, recordEvent record)) (evidenceRecords evidence)
    `shouldBe` [ (1, at 10, TurnBegan 1)
               , (2, at 20, PumpEntered PolledEvents)
               , (3, at 30, PumpLeft PolledEvents)
               ]
  evidenceComplete evidence `shouldBe` True
  unread `shouldReturn` 0
  traceRunning trace `shouldReturn` False

testBounded ∷ Expectation
testBounded = do
  (clock, _) ← scriptedClock [10, 20, 30, 40, 50]
  trace ← newTrace
  startTrace trace clock 2
  mapM_ (recordTrace trace . Marked . Text.pack . show) [1 ∷ Int .. 5]
  evidence ← stopTrace trace
  map recordSequence (evidenceRecords evidence) `shouldBe` [1, 2]
  map recordEvent (evidenceRecords evidence) `shouldBe` [Marked "1", Marked "2"]
  evidenceLost evidence `shouldBe` 3
  evidenceFaults evidence `shouldBe` 0
  evidenceComplete evidence `shouldBe` False

testTakeContinues ∷ Expectation
testTakeContinues = do
  (clock, _) ← scriptedClock [10, 20, 30, 40]
  trace ← newTrace
  startTrace trace clock 1
  recordTrace trace (Marked "first")
  recordTrace trace (Marked "lost")
  taken ← takeTrace trace
  map recordSequence (evidenceRecords taken) `shouldBe` [1]
  evidenceLost taken `shouldBe` 1
  recordTrace trace (Marked "second")
  recordTrace trace (Marked "lost again")
  rest ← stopTrace trace
  map (\record → (recordSequence record, recordEvent record)) (evidenceRecords rest)
    `shouldBe` [(3, Marked "second")]
  evidenceLost rest `shouldBe` 1

testClockFault ∷ Expectation
testClockFault = do
  trace ← newTrace
  startTrace trace failingClock defaultTraceCapacity
  recordTrace trace (Marked "never stored")
  recordTrace trace (Marked "never stored either")
  evidence ← stopTrace trace
  evidenceRecords evidence `shouldBe` []
  evidenceFaults evidence `shouldBe` 2
  evidenceLost evidence `shouldBe` 0
  evidenceComplete evidence `shouldBe` False

failingClock ∷ MonotonicSource
failingClock = scriptedSource (throwIO (userError "this clock does not read") ∷ IO Instant)

-- ---------------------------------------------------------------------------
-- What an owner turn offers it

-- | Two turns over the seam: the first polls with a burst of window events
-- delivered from inside that poll, the second is idle and makes a finite wait.
testOwnerTurnOrder ∷ Expectation
testOwnerTurnOrder = do
  evidence ← measuredTurns 2 [MovedTo 120 80, ResizedTo 200 150, RefreshRequested]
  let events = map recordEvent (evidenceRecords evidence)
  evidenceComplete evidence `shouldBe` True
  nondecreasing (map recordInstant (evidenceRecords evidence)) `shouldBe` True
  shape events
    `shouldBe` [ "TurnBegan 1"
               , "PumpEntered poll"
               , "CallbackDelivered window position"
               , "CallbackDelivered window size"
               , "CallbackDelivered window refresh"
               , "PumpLeft poll"
               , "UpdateHookEntered 1"
               , "UpdateHookLeft 1"
               , "TurnBegan 2"
               , "PumpEntered wait"
               , "PumpLeft wait"
               , "UpdateHookEntered 2"
               , "UpdateHookLeft 2"
               ]
  -- Every callback is recorded between a pump's entry and its exit, which is
  -- the property a platform stall is read from.
  insidePump events `shouldSatisfy` (== 3)

testPumpModes ∷ Expectation
testPumpModes = do
  evidence ← measuredTurns 2 []
  [mode | PumpEntered mode ← map recordEvent (evidenceRecords evidence)]
    `shouldBe` [PolledEvents, WaitedForEvents 0.25]

-- | Run the production owner loop over a seam host for that many turns, with
-- the trace started before the first turn, delivering the given events from
-- inside the first turn's pump.
measuredTurns ∷ Natural → [WindowEvent] → IO TraceEvidence
measuredTurns turns events = do
  seam ← newSeam defaultScript
  asProcessMainThread seam . entered seam $ \session → do
    let trace = sessionTrace session
    runWindowApplication
      (withLoggingLifetime quietLogger)
      "trace-example"
      (allocWindowHostIn (pure session) (settings [windowNamed "traced"] monotonicSource))
      id
      (\host _ → pure host)
      ( \host control → do
          atomically (hostWindowIdentities host) >>= \case
            [identity] →
              withHostWindow host identity (\window → seamQueueEvents seam window events) >>= \case
                WindowAvailable () → pure ()
                WindowEnded _ → unexpected "the host's only window has ended"
            identities → unexpected ("expected one window, found " <> show (length identities))
          startTrace trace monotonicSource defaultTraceCapacity
          runOwnerLoop host control $
            LoopHooks
              { loopLogger = quietLogger
              , loopEvent = noApplicationEvents
              , loopUpdate = \turn → do
                  recordTrace trace (UpdateHookEntered (turnNumber turn))
                  recordTrace trace (UpdateHookLeft (turnNumber turn))
                  pure (if turnNumber turn >= turns then Finish () else Continue)
              }
          stopTrace trace
      )

-- | Each event as a short, stable name, so the order is asserted without
-- restating every payload.
shape ∷ [TraceEvent] → [String]
shape = map $ \case
  TurnBegan number → "TurnBegan " <> show number
  PumpEntered PolledEvents → "PumpEntered poll"
  PumpEntered (WaitedForEvents _) → "PumpEntered wait"
  PumpLeft PolledEvents → "PumpLeft poll"
  PumpLeft (WaitedForEvents _) → "PumpLeft wait"
  CallbackDelivered _ name → "CallbackDelivered " <> Text.unpack name
  UpdateHookEntered number → "UpdateHookEntered " <> show number
  UpdateHookLeft number → "UpdateHookLeft " <> show number
  Marked name → "Marked " <> Text.unpack name

-- | How many callbacks were recorded while a pump was open.
insidePump ∷ [TraceEvent] → Int
insidePump = go False 0
  where
    go _ total [] = total
    go _ total (PumpEntered _ : rest) = go True total rest
    go _ total (PumpLeft _ : rest) = go False total rest
    go open total (CallbackDelivered _ _ : rest) = go open (if open then total + 1 else total) rest
    go open total (_ : rest) = go open total rest

nondecreasing ∷ Ord a ⇒ [a] → Bool
nondecreasing values = and (zipWith (<=) values (drop 1 values))
