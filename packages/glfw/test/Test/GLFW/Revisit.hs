-- | Examples for the follow-up of a window's visible attribute after an
-- iconify transition: the quick re-reads, the slow re-check, and every state in
-- which a window is never re-read.
--
-- Every loop example runs a production owner loop over a one-window host on the
-- seam, with an injected clock, so the owner turn's own ordering decides what
-- each example sees: the mode reconciliation boundary runs before
-- 'reconcileWindowEvents' and can consume the iconify capture, and the follow-up
-- runs after both. Each example runs under 'runOwnerLoop', which reads no clock
-- of its own, and under 'runScheduledOwnerLoop', which reads it twice a turn.
--
-- The scripted platform answers visible, iconified, and the framebuffer extent
-- from cells the example moves between turns. Events are queued from the
-- update opportunity and delivered by the next turn's native step, as GLFW
-- delivers them. The clock is a cell too, advanced only by the example, so
-- nothing here sleeps, measures wall-clock time, or reads one: every instant
-- is scripted, and an example asserts the native visible queries the seam
-- recorded and the clock readings its source was asked for.
--
-- Nothing initializes GLFW, opens a window, or needs a display.
module Test.GLFW.Revisit (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_, when)
import Data.Maybe (listToMaybe)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Time (scriptedSource)
import Hetoimasia.GLFW.Demand (CapturedDemand (..), immediateDemand)
import Hetoimasia.GLFW.Internal.Control (ControlResult (..), WindowControl (..), ControlOutcome (..))
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
  , Seam
  , SeamScript (..)
  , WindowAttribute (..)
  , WindowEvent (..)
  , asProcessMainThread
  , defaultScript
  , featureUnavailableCode
  , newSeam
  , reportError
  , seamCalls
  , seamQueueEvents
  )
import Hetoimasia.GLFW.Internal.Session (NativeFailure)
import Hetoimasia.GLFW.Internal.Window
  ( EventProcessing (..)
  , beginWindowClosing
  , controlWindow
  , processWindowEvents
  , reconcileWindowEvents
  , revisitVisible
  )
import Hetoimasia.GLFW.Internal.Window.Revisit (visibleQuickReads)
import Hetoimasia.GLFW.Window
  ( Attribute (..)
  , Extent (..)
  , Window
  , WindowObservation
  , WindowResult (..)
  , observedFramebufferExtent
  , observedIconified
  , observedRevision
  , observedVisible
  , observedWindow
  , synchronizeWindow
  , windowIdentity
  , withWindow
  )
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.UpdatePolicy (Demand (..))
import Numeric.Natural (Natural)
import Test.GLFW.Support
  ( at
  , caughtAs
  , current
  , durationOf
  , entered
  , hosted
  , millis
  , quietLogger
  , settings
  , stashed
  , unexpected
  , windowNamed
  )
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldSatisfy)

spec ∷ Spec
spec = describe "GLFW visible follow-up" $ do
  forM_ [Unscheduled, Scheduled] $ \kind →
    describe (show kind) $ do
      it "recovers a window whose restore command sampled a transient not-visible, with no sample command"
        (testRestoreCommand kind)
      it "re-reads on later turns for a user restore, and stops as soon as visible reads true"
        (testUserRestore kind)
      it "spends exactly the quick bound when visible never reads true, and reads the clock only once it enters the slow phase"
        (testQuickBound kind)
      it "recovers on the slow re-check after the quick bound is spent, never more often than once per idle wait"
        (testSlowRecovery kind)
      it "keeps a window that is really hidden after a restore not visible and suspended, publishing no revision"
        (testHiddenStays kind)
      it "re-reads a window that is really hidden at the slow pace, once per idle wait"
        (testHiddenPace kind)
      it "stops the re-reads when a hide control settles during the slow phase"
        (testHideStops kind)
      it "stops the re-reads when the window begins closing, and when it is iconified again, and restarts the quick phase on the next restore"
        (testClosingAndIconifyAgain kind)
      it "never re-reads a window that is visible, hidden by a command, or minimized, however many turns and clock advances pass"
        (testNoOtherStateReads kind)
      it "leaves a visible that is unavailable unavailable, and decides from the other fields"
        (testUnavailable kind)
      it "keeps a visible that stops being reported unavailable, and stops re-reading"
        (testBecomesUnavailable kind)
      it "keeps a restore that leaves a zero framebuffer extent suspended"
        (testZeroFramebuffer kind)
  describe "the re-read itself" $ do
    it "fails with the native failure of a broken report, publishes nothing, and leaves the owed re-reads owed"
      testBrokenReport
    it "stops without a native call for a window that has ended"
      testEndedWindow

-- ---------------------------------------------------------------------------
-- The owner loops

-- | Which production owner loop an example runs.
data LoopKind = Unscheduled | Scheduled
  deriving (Eq, Show)

-- | What the scripted platform answers for visible.
data Report
  = Reports Bool
  | Missing
    -- ^ An unavailable-feature error: the attribute is 'Unavailable'.
  | Broken
    -- ^ Any other error, which fails the query.

-- | The cells the scripted platform answers from.
data Platform = Platform
  { platformVisible ∷ IORef Report
  , platformIconified ∷ IORef Bool
  , platformFramebuffer ∷ IORef (Int, Int)
  }

-- | A platform showing a restored, visible window with a drawable extent.
newPlatform ∷ IO Platform
newPlatform = Platform <$> newIORef (Reports True) <*> newIORef False <*> newIORef (640, 480)

platformScript ∷ Platform → SeamScript
platformScript platform =
  defaultScript
    { scriptFramebufferSize = \_ → readIORef (platformFramebuffer platform)
    , scriptWindowAttribute = \attribute reporter → case attribute of
        VisibleAttribute →
          readIORef (platformVisible platform) >>= \case
            Reports visible → pure visible
            Missing → reportError reporter featureUnavailableCode "the platform provides no window visibility" >> pure False
            Broken → reportError reporter 0x00010008 "window visibility failed" >> pure False
        IconifiedAttribute → readIORef (platformIconified platform)
        _ → pure False
    }

-- | What an update opportunity may do to the running example.
data Rig = Rig
  { rigSeam ∷ Seam
  , rigPlatform ∷ Platform
  , rigClock ∷ IORef Integer
  , rigWindow ∷ Window
  , rigNotes ∷ IORef [(String, WindowObservation)]
  }

-- | What one turn left behind, recorded before the example's script for that
-- turn runs.
data Turned = Turned
  { turnedNumber ∷ Natural
  , turnedReads ∷ Int
    -- ^ Native visible queries the seam has recorded so far, construction's included.
  , turnedClockReads ∷ Int
    -- ^ Readings the host's clock source was asked for beyond the two a scheduled turn takes itself.
  , turnedNow ∷ Integer
    -- ^ The clock cell while the turn ran, in nanoseconds.
  , turnedObservation ∷ WindowObservation
  }

-- | Run one owner loop for @turns@ turns over a one-window host on the scripted
-- platform. After each turn's work, that turn is recorded and then
-- @script@ runs for it; whatever it queues or moves is seen by the next turn.
play ∷ LoopKind → Platform → Natural → (Natural → Rig → IO ()) → IO ([Turned], [(String, WindowObservation)])
play kind platform turns script = do
  seam ← newSeam (platformScript platform)
  now ← newIORef 0
  taken ← newIORef (0 ∷ Int)
  notes ← newIORef []
  records ← newIORef []
  let clock = scriptedSource (modifyIORef' taken (+ 1) >> (at <$> readIORef now))
  hosted seam (settings [windowNamed "followed"] clock) (\host _ → pure host) $ \host control → do
    window ← onlyWindow host
    let rig = Rig seam platform now window notes
        turn number = do
          queries ← visibleReads seam
          clockReads ← readIORef taken
          nowNanos ← readIORef now
          observation ← current window
          modifyIORef' records (<> [Turned number queries (clockReads - ownReads number) nowNanos observation])
          script number rig
          pure (number >= turns)
        ownReads number = if kind == Scheduled then 2 * fromIntegral number else 0
    case kind of
      Unscheduled →
        runOwnerLoop host control $
          LoopHooks
            { loopLogger = quietLogger
            , loopEvent = noApplicationEvents
            , loopUpdate = \summary → (\done → if done then Finish () else Continue) <$> turn (turnNumber summary)
            }
      Scheduled →
        runScheduledOwnerLoop host control $
          defaultScheduledHooks quietLogger $ \scheduled →
            (\done → if done then FinishWith () else ContinueWith NoUpdateDemand) <$> turn (turnNumber (scheduledTurn scheduled))
  (,) <$> readIORef records <*> readIORef notes

onlyWindow ∷ WindowHost → IO Window
onlyWindow host =
  atomically (hostWindowIdentities host) >>= \case
    [identity] →
      withHostWindow host identity pure >>= \case
        WindowAvailable window → pure window
        WindowEnded _ → unexpected "the host's only window has ended"
    windows → unexpected ("expected one window, found " <> show (length windows))

-- | How many native visible queries the seam has recorded.
visibleReads ∷ Seam → IO Int
visibleReads seam = length . filter (== QueryWindowAttribute VisibleAttribute) <$> seamCalls seam

-- ---------------------------------------------------------------------------
-- Moving the scripted platform

-- | The platform reports the window minimized, and the callback follows on the
-- next turn.
minimize ∷ Rig → IO ()
minimize rig = do
  writeIORef (platformIconified (rigPlatform rig)) True
  seamQueueEvents (rigSeam rig) (rigWindow rig) [IconifyChanged True]

-- | The platform reports the window not minimized, and the callback follows on
-- the next turn. Visible is whatever the platform says at each re-read.
unminimize ∷ Rig → IO ()
unminimize rig = do
  writeIORef (platformIconified (rigPlatform rig)) False
  seamQueueEvents (rigSeam rig) (rigWindow rig) [IconifyChanged False]

sayVisible ∷ Rig → Report → IO ()
sayVisible rig = writeIORef (platformVisible (rigPlatform rig))

-- | A sample catches the platform's transient answer while the window is still
-- minimized: the title control's post-call sample reads whatever the platform
-- says now, here visible @report@ and iconified true. This is the stale
-- reading a restore command's own sample leaves behind, set up without the
-- restore so the user-restore examples can start from it.
catchTransient ∷ Rig → Report → IO ()
catchTransient rig report = sayVisible rig report >> perform rig (TitleControl "sampled")

-- | Advance the injected clock.
advance ∷ Rig → Integer → IO ()
advance rig nanoseconds = modifyIORef' (rigClock rig) (+ nanoseconds)

-- | Run one ordinary control through the window, which samples it afterwards.
perform ∷ Rig → WindowControl → IO ()
perform rig wanted =
  controlWindow (rigWindow rig) wanted >>= \case
    WindowAvailable (ControlAttempted ControlReturned _) → pure ()
    other → unexpected ("the control did not settle: " <> show other)

note ∷ Rig → String → IO ()
note rig label = current (rigWindow rig) >>= \observation → modifyIORef' (rigNotes rig) (<> [(label, observation)])

-- ---------------------------------------------------------------------------
-- What an observation says

-- | Iconified and visible as the observation holds them.
fields ∷ WindowObservation → (Attribute Bool, Attribute Bool)
fields observation = (observedIconified observation, observedVisible observation)

-- | Whether a frame demand yields an opportunity for the window.
offersFrame ∷ WindowObservation → Bool
offersFrame observation = map offeredWindow (renderOffers result) == [observedWindow observation]
  where
    (result, _) = renderTurn budget (RenderTurn (at 0) NoDemand [WindowRender observation (Just (CapturedDemand 1 immediateDemand)) Nothing]) noRenderDemand
    budget = either (\rejected → error ("the budget was rejected: " <> show rejected)) id (renderBudget 2)

eligibility ∷ Turned → RenderEligibility
eligibility = windowRenderEligibility . turnedObservation

-- | The turns at which a slow re-check is due when the clock reads as recorded
-- and the previous re-read was at @stamp@: the first turn at least one idle
-- wait after it, and then after each of those.
slowTurns ∷ Integer → [Turned] → [Natural]
slowTurns stamp turned = case dropWhile ((< stamp + idleWait) . turnedNow) turned of
  [] → []
  due : rest → turnedNumber due : slowTurns (turnedNow due) rest

-- | The idle wait 'settings' configures: a quarter of a second.
idleWait ∷ Integer
idleWait = millis 250

quickBound ∷ Int
quickBound = fromIntegral visibleQuickReads

-- | The turns at which the seam recorded one more visible query than the turn
-- before.
readTurns ∷ [Turned] → [Natural]
readTurns turned = [number | (before, Turned number queries _ _ _) ← zip turned (drop 1 turned), queries > turnedReads before]

-- | The minimize and user restore every slow-phase example starts from: the
-- window is minimized by turn 2 and restored by the user, with no command, so
-- that turn 3 folds the callback. The clock advances a tenth of a second a turn.
minimizeAndRestore ∷ Report → Natural → Rig → IO ()
minimizeAndRestore afterwards number rig = do
  advance rig (millis 100)
  case number of
    1 → minimize rig
    2 → catchTransient rig afterwards >> unminimize rig
    _ → pure ()

-- ---------------------------------------------------------------------------
-- Recovery

-- | A restore command whose post-call sample reads iconified true and visible
-- false; the callback that reports the restore arrives on a later turn, by
-- which time the platform reports the window visible. Nothing samples again.
testRestoreCommand ∷ LoopKind → Expectation
testRestoreCommand kind = do
  platform ← newPlatform
  (turned, notes) ← play kind platform 6 $ \number rig → case number of
    1 → minimize rig
    2 → do
      -- Cocoa's restore completes asynchronously.
      writeIORef (platformIconified platform) True
      sayVisible rig (Reports False)
      perform rig RestoreControl
      note rig "immediately after the restore control"
      sayVisible rig (Reports True)
      unminimize rig
    _ → pure ()
  map (fmap fields) notes `shouldBe` [("immediately after the restore control", (Observed True, Observed False))]
  map (windowRenderEligibility . snd) notes `shouldBe` [RenderSuspended]
  map (fields . turnedObservation) turned
    `shouldBe` [ (Observed False, Observed True)
               , (Observed True, Observed True)
               ]
      <> replicate 4 (Observed False, Observed True)
  drop 2 (map eligibility turned) `shouldBe` replicate 4 RenderEligible
  offersFrame (turnedObservation (turned !! 2)) `shouldBe` True

-- | The user restores the window: no restore command exists. Visible still
-- reads false on the first quick re-read, and true on the next; the re-reads
-- stop there.
testUserRestore ∷ LoopKind → Expectation
testUserRestore kind = do
  platform ← newPlatform
  (turned, _) ← play kind platform 8 $ \number rig → case number of
    1 → minimize rig
    2 → catchTransient rig (Reports False) >> unminimize rig
    3 → sayVisible rig (Reports True)
    _ → pure ()
  -- Turn 2's record precedes the title control, whose own sample read once.
  let base = turnedReads (turned !! 1) + 1
  -- Turn 3 folded the callback and made the first re-read, which still read
  -- false; the platform then turned visible, turn 4 read true, and nothing is
  -- read after that.
  map (subtract base . turnedReads) (drop 2 turned) `shouldBe` [1, 2, 2, 2, 2, 2]
  map (observedVisible . turnedObservation) (drop 2 turned)
    `shouldBe` Observed False : replicate 5 (Observed True)
  map eligibility (drop 2 turned) `shouldBe` RenderSuspended : replicate 5 RenderEligible
  offersFrame (turnedObservation (turned !! 3)) `shouldBe` True
  -- The stop is a stop: no clock reading was needed at all.
  map turnedClockReads turned `shouldBe` replicate 8 0

-- | Visible never reads true: the quick phase ends at exactly the bound, and
-- with the clock standing still no slow re-check falls due. The clock is first
-- read by the turn that spends the bound, and by every slow turn after it.
testQuickBound ∷ LoopKind → Expectation
testQuickBound kind = do
  platform ← newPlatform
  (turned, _) ← play kind platform 24 $ \number rig → case number of
    1 → minimize rig
    2 → catchTransient rig (Reports False) >> unminimize rig
    _ → pure ()
  -- Turn 2's record precedes the title control, whose own sample read once.
  let base = turnedReads (turned !! 1) + 1
      spentAt = 2 + fromIntegral quickBound ∷ Int
  map (subtract base . turnedReads) (drop 2 turned)
    `shouldBe` [min quickBound (turn - 2) | turn ← [3 .. 24]]
  readTurns turned `shouldBe` map fromIntegral [3 .. spentAt]
  -- Entering the slow phase takes one reading; each slow turn takes one more.
  map turnedClockReads turned
    `shouldBe` [if kind == Unscheduled then max 0 (turn - spentAt + 1) else 0 | turn ← [1 .. 24]]

-- | The bound is spent with visible reading false; the platform later reports
-- visible, and the next slow re-check, which falls due one idle wait after the
-- last re-read, recovers the window. No re-read happens before then.
testSlowRecovery ∷ LoopKind → Expectation
testSlowRecovery kind = do
  platform ← newPlatform
  (turned, _) ← play kind platform 24 $ \number rig → do
    minimizeAndRestore (Reports False) number rig
    when (number == 11) (sayVisible rig (Reports True))
  let spentAt = 2 + fromIntegral quickBound ∷ Natural
      stamp = turnedNow (turned !! (fromIntegral spentAt - 1))
      due = take 1 (slowTurns stamp (drop (fromIntegral spentAt) turned))
  due `shouldSatisfy` (not . null)
  recoveredAt ← case due of
    [only] → pure only
    other → unexpected ("expected one due slow re-check, found " <> show other)
  recoveredAt `shouldSatisfy` (> 11)
  -- Reads: the quick bound, then exactly the one slow re-check, and no more.
  readTurns turned `shouldBe` [3 .. spentAt] <> [recoveredAt]
  map eligibility turned
    `shouldBe` [if turnedNumber record >= recoveredAt then RenderEligible else eligibilityBefore record | record ← turned]
  offersFrame (turnedObservation (turned !! (fromIntegral recoveredAt - 1))) `shouldBe` True
  where
    -- Turn 1 is shown; turn 2 is minimized; from turn 3 visible reads false.
    eligibilityBefore record
      | turnedNumber record < 2 = RenderEligible
      | otherwise = RenderSuspended

-- | A window that is genuinely hidden after the restore stays not visible and
-- suspended however long it is followed, and publishes no revision beyond the
-- one that folded the callback. Nothing here depends on the follow-up existing.
testHiddenStays ∷ LoopKind → Expectation
testHiddenStays kind = do
  platform ← newPlatform
  (turned, _) ← play kind platform 40 (minimizeAndRestore (Reports False))
  let afterRestore = drop 2 turned
  map (observedVisible . turnedObservation) afterRestore `shouldBe` replicate (length afterRestore) (Observed False)
  map eligibility afterRestore `shouldBe` replicate (length afterRestore) RenderSuspended
  -- The one revision is the one that folded the callback.
  map (observedRevision . turnedObservation) afterRestore
    `shouldBe` replicate (length afterRestore) (observedRevision (turnedObservation (turned !! 2)))

-- | A window that is genuinely hidden after the restore is re-read exactly when
-- each idle wait has passed once the quick bound is spent: no oftener, and on
-- the first turn the clock allows.
testHiddenPace ∷ LoopKind → Expectation
testHiddenPace kind = do
  platform ← newPlatform
  (turned, _) ← play kind platform 40 (minimizeAndRestore (Reports False))
  let spentAt = 2 + fromIntegral quickBound ∷ Natural
      stamp = turnedNow (turned !! (fromIntegral spentAt - 1))
      slow = slowTurns stamp (drop (fromIntegral spentAt) turned)
  length slow `shouldSatisfy` (>= 3)
  readTurns turned `shouldBe` [3 .. spentAt] <> slow
  -- With the clock a tenth of a second a turn and an idle wait of a quarter,
  -- a re-read is due every third turn.
  all id [b - a == 3 | (a, b) ← zip slow (drop 1 slow)] `shouldBe` True

-- ---------------------------------------------------------------------------
-- Stops

-- | A hide control that settles during the slow phase stops the re-reads: the
-- native visible queries stay where the hide's own sample left them, and the
-- clock is not read again, over many turns and clock advances.
testHideStops ∷ LoopKind → Expectation
testHideStops kind = do
  platform ← newPlatform
  (turned, _) ← play kind platform 40 $ \number rig → do
    minimizeAndRestore (Reports False) number rig
    when (number == 14) (perform rig HideControl)
    when (number > 14) (advance rig (millis 300))
  -- The hide ran after turn 14's record, and its own post-call sample is the
  -- one read that turn 15 shows beyond turn 14's.
  let settled = turned !! 14
      after = drop 14 turned
  turnedReads settled `shouldBe` turnedReads (turned !! 13) + 1
  map turnedReads after `shouldBe` replicate (length after) (turnedReads settled)
  map turnedClockReads after `shouldBe` replicate (length after) (turnedClockReads (turned !! 13))
  map (observedVisible . turnedObservation) after `shouldBe` replicate (length after) (Observed False)
  map eligibility after `shouldBe` replicate (length after) RenderSuspended

-- | The window begins closing during the slow phase, and later runs show the
-- re-reads stopped; a second window shape iconifies again, which stops them,
-- and the next restore starts the quick phase afresh.
testClosingAndIconifyAgain ∷ LoopKind → Expectation
testClosingAndIconifyAgain kind = do
  closing ← do
    platform ← newPlatform
    fst <$> play kind platform 30 (\number rig → do
      minimizeAndRestore (Reports False) number rig
      when (number == 14) $
        beginWindowClosing (pure ()) (pure True) (rigWindow rig) >>= \case
          WindowAvailable True → pure ()
          other → unexpected ("closing did not begin: " <> show other)
      when (number > 14) (advance rig (millis 300)))
  let afterClosing = drop 14 closing
  map turnedReads afterClosing `shouldBe` replicate (length afterClosing) (turnedReads (closing !! 13))
  map turnedClockReads afterClosing `shouldBe` replicate (length afterClosing) (turnedClockReads (closing !! 13))

  platform ← newPlatform
  (again, _) ← play kind platform 40 $ \number rig → do
    -- The clock stops after turn 17, so the restarted quick phase is told apart
    -- from a slow re-check, which no standing clock can make due.
    when (number <= 17) (minimizeAndRestore (Reports False) number rig)
    -- Iconified again during the slow phase; later the user restores it again.
    when (number == 14) (minimize rig)
    when (number == 18) (unminimize rig)
    when (number > 14 && number < 18) (advance rig (millis 300))
  let baseline = turnedReads (again !! 13)
      stopped = take 4 (drop 14 again)
      restarted = drop 18 again
  -- The callback of turn 15 stops the re-reads: none through turn 18.
  map turnedReads stopped `shouldBe` replicate 4 baseline
  map turnedClockReads stopped `shouldBe` replicate 4 (turnedClockReads (again !! 13))
  -- The restore of turn 19 folds, and the quick phase runs from the top again.
  map (subtract baseline . turnedReads) restarted
    `shouldBe` [min quickBound (turn - 18) | turn ← [19 .. 40]]

-- | A window that is visible, one hidden by a command, and one that is
-- minimized are never re-read, and the unscheduled loop never reads its clock
-- for them.
testNoOtherStateReads ∷ LoopKind → Expectation
testNoOtherStateReads kind = do
  visible ← newPlatform
  (shown, _) ← play kind visible 20 (\_ rig → advance rig (millis 300))
  steady shown

  hidden ← newPlatform
  (hiding, _) ← play kind hidden 20 $ \number rig → do
    when (number == 1) (sayVisible rig (Reports False) >> perform rig HideControl)
    advance rig (millis 300)
  -- The hide's own post-call sample, taken by turn 2's record, is the last read.
  steady (drop 1 hiding)
  map (observedVisible . turnedObservation) hiding `shouldBe` Observed True : replicate 19 (Observed False)

  minimized ← newPlatform
  (minimizing, _) ← play kind minimized 20 $ \number rig → do
    when (number == 1) (minimize rig)
    advance rig (millis 300)
  steady (drop 1 minimizing)
  map (observedIconified . turnedObservation) (drop 1 minimizing) `shouldBe` replicate 19 (Observed True)
  where
    steady records = do
      map turnedReads records `shouldBe` replicate (length records) (maybe 0 turnedReads (listToMaybe records))
      map turnedClockReads records `shouldBe` replicate (length records) 0

-- ---------------------------------------------------------------------------
-- What the platform may report

-- | A platform with no visible attribute: the transition arms the follow-up,
-- which finds nothing to follow and makes no native call, and the other fields
-- decide eligibility.
testUnavailable ∷ LoopKind → Expectation
testUnavailable kind = do
  silent ← newPlatform
  writeIORef (platformVisible silent) Missing
  (quiet, _) ← play kind silent 10 $ \number rig → do
    when (number == 1) (minimize rig)
    when (number == 2) (unminimize rig)
    advance rig (millis 300)
  map (observedVisible . turnedObservation) quiet `shouldBe` replicate 10 Unavailable
  map eligibility (drop 2 quiet) `shouldBe` replicate 8 RenderEligible
  map turnedReads quiet `shouldBe` replicate 10 (maybe 0 turnedReads (listToMaybe quiet))

-- | A visible observed false whose re-read reports the feature unavailable
-- becomes unavailable and is never fabricated; the re-reads stop there.
testBecomesUnavailable ∷ LoopKind → Expectation
testBecomesUnavailable kind = do
  vanishing ← newPlatform
  (lost, _) ← play kind vanishing 10 $ \number rig → do
    when (number == 1) (minimize rig)
    when (number == 2) (catchTransient rig (Reports False) >> unminimize rig)
    when (number == 3) (sayVisible rig Missing)
    advance rig (millis 300)
  -- Turn 2's record precedes the title control, whose own sample read once.
  let base = turnedReads (lost !! 1) + 1
  map (observedVisible . turnedObservation) (drop 2 lost) `shouldBe` Observed False : replicate 7 Unavailable
  map (subtract base . turnedReads) (drop 2 lost) `shouldBe` 1 : replicate 7 2
  map eligibility (drop 3 lost) `shouldBe` replicate 7 RenderEligible

-- | The restore leaves a zero framebuffer extent: visible turns true on the
-- re-read, and the window stays suspended on its extent.
testZeroFramebuffer ∷ LoopKind → Expectation
testZeroFramebuffer kind = do
  platform ← newPlatform
  (turned, notes) ← play kind platform 8 $ \number rig → case number of
    1 → minimize rig
    2 → do
      sayVisible rig (Reports False)
      writeIORef (platformFramebuffer platform) (0, 0)
      perform rig RestoreControl
      note rig "restored"
      sayVisible rig (Reports True)
      unminimize rig
    _ → pure ()
  map (observedFramebufferExtent . snd) notes `shouldBe` [Observed (Extent 0 0)]
  -- Whatever visible reads, the extent keeps the window suspended.
  map eligibility (drop 2 turned) `shouldBe` replicate 6 RenderSuspended

-- ---------------------------------------------------------------------------
-- The re-read itself

-- | A broken report during a re-read fails with the native failure and neither
-- publishes nor advances anything: once the platform answers again, the
-- re-read that was owed still happens, and no clock reading was taken.
testBrokenReport ∷ Expectation
testBrokenReport = do
  platform ← newPlatform
  seam ← newSeam (platformScript platform)
  clockReads ← newIORef (0 ∷ Int)
  let clock = modifyIORef' clockReads (+ 1) >> pure (at 0)
  (before, after, recovered) ← asProcessMainThread seam $ entered seam $ \session →
    withWindow session (windowNamed "broken") $ \window → do
      -- The restore command's own sample caught the transient not-visible.
      writeIORef (platformIconified platform) True
      writeIORef (platformVisible platform) (Reports False)
      _ ← synchronizeWindow window
      writeIORef (platformIconified platform) False
      seamQueueEvents seam window [IconifyChanged False]
      processWindowEvents session ProcessPending
      _ ← reconcileWindowEvents window
      armed ← current window
      writeIORef (platformVisible platform) Broken
      (_ ∷ NativeFailure, _) ← caughtAs (revisitVisible (durationOf idleWait) clock window)
      afterFailure ← current window
      writeIORef (platformVisible platform) (Reports True)
      _ ← revisitVisible (durationOf idleWait) clock window
      healed ← current window
      pure (armed, afterFailure, healed)
  fields before `shouldBe` (Observed False, Observed False)
  -- The failed re-read published nothing, and the next one still read.
  observedRevision after `shouldBe` observedRevision before
  fields after `shouldBe` fields before
  fields recovered `shouldBe` (Observed False, Observed True)
  readIORef clockReads >>= (`shouldBe` 0)

-- | A window that has ended answers 'WindowEnded' to a follow-up it was owed,
-- and makes no native query.
testEndedWindow ∷ Expectation
testEndedWindow = do
  platform ← newPlatform
  seam ← newSeam (platformScript platform)
  stash ← newIORef Nothing
  asProcessMainThread seam $ entered seam $ \session →
    withWindow session (windowNamed "ended") $ \window → do
      writeIORef (platformIconified platform) True
      writeIORef (platformVisible platform) (Reports False)
      _ ← synchronizeWindow window
      writeIORef (platformIconified platform) False
      seamQueueEvents seam window [IconifyChanged False]
      processWindowEvents session ProcessPending
      _ ← reconcileWindowEvents window
      writeIORef stash (Just window)
  window ← stashed stash
  before ← visibleReads seam
  result ← revisitVisible (durationOf idleWait) (pure (at 0)) window
  result `shouldBe` WindowEnded (windowIdentity window)
  visibleReads seam >>= (`shouldBe` before)
