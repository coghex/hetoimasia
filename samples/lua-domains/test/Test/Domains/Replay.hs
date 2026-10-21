-- | A replay through the sample's own admission seam (#500 requirement 4): the driver releases each record of an input log to
-- the seam the UI's path uses, with its recorded tick and place, only when the tick it is for is the next unstarted one, and
-- the sample's rules apply unchanged. A log that cannot be replayed is refused before anything starts, with the reason; what
-- only an execution can decide is not predicted, and keeps the failure behavior the sample delivers.
module Test.Domains.Replay (spec) where

import Control.Concurrent.STM (atomically, readTVarIO)
import Control.Exception (try)
import Control.Monad (forM, forM_, void, when)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import qualified Data.Text as Text
import qualified Data.ByteString.Lazy as Lazy
import Data.Word (Word64)
import Hetoimasia.Sample.LuaDomains
  ( Bounds (boundDelta, boundEntities, boundPendingControls, boundPlaces, boundQueue)
  , Domains (domainsControl, domainsGameplay, domainsShared)
  , DomainsConfig (..)
  , DomainsDefect (BoundsRefused, ReplayNotAdmitted, ReplayRefused)
  , ReplayOutcome (..)
  , SessionReport (reportControls, reportCounts, reportReplay, reportRecorded, reportStatus, reportTicks)
  , Started (startedTicket)
  , renderReport
  , requestStop
  , runSession
  , GameSnapshot (..)
  , SessionStatus (Failed, Paused, Running, Stopped)
  , TickPoint (BeforeGrant)
  , defaultBounds
  , defaultConfig
  , stepTick
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.InputLog
import Hetoimasia.Sample.LuaDomains.Intention (Answer (Declined), Dispositions (..), Intention (..), Placement (..), Refusal (RefusedDelta, RefusedEntity), Stale (..), StaleReason (StaleSession, StaleVersion))
import Hetoimasia.Sample.LuaDomains.Queue (AdmitAt (AdmittedAt), nextUnstarted, reserved)
import Hetoimasia.Sample.LuaDomains.Scenario (Scenario (Normal, Stop), scenarioStopAfter)
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedControls, sharedCounts, sharedQueue, sharedRecorder), admitLogged, failSession)
import Hetoimasia.Sample.LuaDomains.Snapshot (SessionFailure (SessionFailure))
import Hetoimasia.Scripting.Lua.Instance (awaitInstance)
import Hetoimasia.Sample.LuaDomains.Tally (ControlCounts (..), Counts (..))
import qualified Data.Map.Strict as Map
import Test.Domains.FixedLog
import Test.Domains.Support
import Test.Hspec

-- | An intention record, acting in the session, as the examples offer one.
intent ∷ Word64 → Word64 → Int → Word64 → Integer → Integer → Record
intent tick place entity version dx dy = RecordIntention (Placement tick (fromIntegral place)) ActsCurrent (tick - 1) entity version (fromInteger dx) (fromInteger dy)

control ∷ Word64 → Word64 → ControlOp → Record
control tick place = RecordControl tick place TargetGameplay

-- | The problems a log has in a session of this many ticks (at the scenario's stop, if it has one), with these bounds.
problemsOf ∷ Bounds → Maybe Word64 → Maybe Word64 → [Record] → [ReplayProblem]
problemsOf bounds final stopAfter = checkReplayable bounds final stopAfter . logOf

spec ∷ Spec
spec = describe "a replay through the admission seam" $ do
  describe "a log that cannot be replayed" $ do
    let refused label bounds final stopAfter records problems =
          it ("is refused, from the log, the tick limit and the scenario alone: " <> label) $
            problemsOf bounds final stopAfter records `shouldBe` problems
    refused "a record for a tick after the session's last" defaultBounds (Just 5) Nothing [intent 6 0 0 0 1 0] [ReplayBeyondTicks 6 5]
    refused "a record for a tick after the one the scenario stops the session at" defaultBounds (Just 20) (Just 8) [intent 9 0 0 0 1 0] [ReplayBeyondStop 9 8]
    refused
      "more intentions for one tick than the queue takes"
      defaultBounds {boundQueue = 3}
      (Just 5)
      Nothing
      [intent 2 place 0 0 1 0 | place ← [0 .. 3]]
      [ReplayTooManyIntentions 2 4 3]
    refused
      "more intentions for one tick than it has places"
      defaultBounds
      (Just 5)
      Nothing
      [intent 2 place 0 0 1 0 | place ← [0 .. 8]]
      [ReplayTooManyIntentions 2 9 8, ReplayPlaceBeyondBound 2 8 8]
    refused "a place that is not one of the tick's" defaultBounds {boundPlaces = 2} (Just 5) Nothing [intent 2 3 0 0 1 0] [ReplayPlaceBeyondBound 2 3 2]
    refused "more controls for one tick than the engine reserves" defaultBounds (Just 5) Nothing [control 2 place OpPause | place ← [0 .. 4]] [ReplayTooManyControls 2 5 4]
    refused "an intention the live path would have refused: an entity the configured world does not have" defaultBounds {boundEntities = 4} (Just 5) Nothing [intent 2 0 4 0 1 0] [ReplayOutsideBounds 2 0 RefusedEntity]
    refused "an intention the live path would have refused: a delta over the configured bound" defaultBounds {boundDelta = 2} (Just 5) Nothing [intent 2 0 0 0 3 0] [ReplayOutsideBounds 2 0 RefusedDelta]
    refused "two records for one place" defaultBounds (Just 5) Nothing [intent 2 1 0 0 1 0, intent 2 1 1 0 1 0] [ReplayDuplicate 2]
    refused "two controls for one place" defaultBounds (Just 5) Nothing [control 2 0 OpPause, control 2 0 OpResume] [ReplayDuplicate 2]
    refused "every problem, the first few of them" defaultBounds (Just 1) Nothing [intent tick 0 0 0 1 0 | tick ← [2 .. 20]] (take maxProblemsListed [ReplayBeyondTicks tick 1 | tick ← [2 .. 20]])

    it "is accepted when it is within every bound, and a session of no tick limit holds no log to a last tick" $ do
      problemsOf defaultBounds (Just 5) Nothing [control 2 0 OpPause, intent 2 0 0 0 1 0, intent 5 7 7 0 (-8) 8] `shouldBe` []
      problemsOf defaultBounds Nothing Nothing [intent 99999 0 0 0 1 0] `shouldBe` []
      -- An intention's place and a control's sequence are two spaces: one tick may hold both at zero.
      problemsOf defaultBounds (Just 5) Nothing [control 2 0 OpPause, intent 2 0 0 0 1 0] `shouldBe` []
      problemsOf defaultBounds (Just 20) (scenarioStopAfter Stop) [intent 8 0 0 0 1 0] `shouldBe` []

    it "is refused before anything starts: the session raises the reason and runs nothing" $ do
      ran ← newIORef False
      outcome ←
        withBoundary $ \control' →
          try @DomainsDefect $
            withDomains
              control'
              (fixedConfig (logOf [intent 6 0 0 0 1 0]) 5 1 Normal defaultConfig)
              (\_ → writeIORef ran True)
      outcome `shouldBe` Left (ReplayRefused [ReplayBeyondTicks 6 5])
      readIORef ran `shouldReturn` False

  describe "a session that could accept more records than a log holds" $
    it "is refused when it is made, so that the log's bound is the bound of every valid bounded session" $ do
      ran ← newIORef False
      let session ticks bounds = withBoundary $ \control' → try @DomainsDefect (withDomains control' (sampleConfig' ticks bounds) (\_ → writeIORef ran True))
          sampleConfig' ticks bounds = defaultConfig {configTicks = Just ticks, configBounds = bounds}
      outcome ← session 20000 defaultBounds {boundPlaces = 64}
      outcome `shouldSatisfy` \case
        Left (BoundsRefused [reason]) → "1360000 records" `isInfixOf` reason
        _ → False
      readIORef ran `shouldReturn` False
      -- A configuration that could accept a place or a control no log can name, or a session longer than a trace holds, is
      -- refused as well, whatever its records would come to.
      places ← session 10 defaultBounds {boundPlaces = 257}
      places `shouldSatisfy` \case
        Left (BoundsRefused [reason]) → "TooManyPlaces 257" `isInfixOf` reason
        _ → False
      controls ← session 10 defaultBounds {boundPendingControls = 257}
      controls `shouldSatisfy` \case
        Left (BoundsRefused [reason]) → "TooManyPendingControls 257" `isInfixOf` reason
        _ → False
      longer ← session 100001 defaultBounds {boundPlaces = 1, boundPendingControls = 1}
      longer `shouldSatisfy` \case
        Left (BoundsRefused [reason]) → "100001 ticks is longer" `isInfixOf` reason
        _ → False
      readIORef ran `shouldReturn` False
      -- The most a session may be asked for, at the default bounds, is exactly what a log holds: it is made.
      accepted ← session 100000 defaultBounds
      accepted `shouldSatisfy` either (const False) (const True)
      readIORef ran `shouldReturn` True

  describe "a stop or a failure recorded while a replay releases its records" $ do
    -- Admission has ended for the tick that was about to begin: nothing is released after it, whichever it is, and a record
    -- that was released before it is accounted for as any accepted input is. The session ends as it would for any other, with
    -- #499's report, and the replay says it is incomplete; it is never a defect of the replay.
    let stopping holder = do
          known ← readIORef holder
          forM_ known $ \domains → do
            requestStop domains
            -- The gameplay instance has settled, so what asks it for anything is refused as unknown.
            void (awaitInstance (domainsControl domains) (startedTicket (domainsGameplay domains)))
        failing holder = do
          known ← readIORef holder
          forM_ known $ \domains →
            atomically (failSession (domainsShared domains) (SessionFailure "injected" "active" "update" 1 "script error" "injected"))
        -- Run a replay of these records to its end, the hook run before each record is released: it is given the holder of
        -- the session and how many records have been released before.
        racing records act = do
          holder ← newIORef Nothing
          releases ← newIORef (0 ∷ Int)
          let hook = do
                released ← readIORef releases
                modifyIORef' releases (+ 1)
                act holder released
          withSample (\config → (fixedConfig (logOf records) 3 1 Normal config) {configReleaseHook = hook}) $ \_ _ domains → do
            writeIORef holder (Just domains)
            generous (runSession domains)
        settledControls report =
          let controls = reportControls report
           in controlApplied controls + controlAlready controls + controlNoLonger controls + controlAbandoned controls
        stopsAt n holder released = when (released == n) (stopping holder)
        failsAt n holder released = when (released == n) (failing holder)

    it "stops quietly before a control is released: no defect, a stopped session's report, an incomplete replay, nothing recorded" $ do
      report ← racing [control 1 0 OpPause] (stopsAt 0)
      (reportTicks report, reportStatus report) `shouldBe` (0, Stopped)
      reportReplay report `shouldBe` Just (ReplayOutcome 1 0)
      reportRecorded report `shouldBe` Right emptyLog
      (controlOffered (reportControls report), controlAccepted (reportControls report)) `shouldBe` (1, 0)

    it "stops quietly before an intention is released, the same" $ do
      report ← racing [intent 1 0 0 0 1 0] (stopsAt 0)
      (reportTicks report, reportStatus report) `shouldBe` (0, Stopped)
      reportReplay report `shouldBe` Just (ReplayOutcome 1 0)
      reportRecorded report `shouldBe` Right emptyLog
      countAccepted (reportCounts report) `shouldBe` 0

    it "stops between the records of one tick: what was released is accounted for, the rest is not released" $ do
      let records = [control 1 0 OpPause, intent 1 0 0 0 1 0, intent 1 1 1 0 1 0]
      report ← racing records (stopsAt 1)
      reportStatus report `shouldBe` Stopped
      reportReplay report `shouldBe` Just (ReplayOutcome 3 1)
      -- The control the engine took is recorded and settles as no longer applicable; the intentions were never released.
      reportRecorded report `shouldBe` Right (logOf [control 1 0 OpPause])
      (controlAccepted (reportControls report), settledControls report) `shouldBe` (1, 1)
      countAccepted (reportCounts report) `shouldBe` 0

    it "stops between two intentions of one tick: the one released is discarded exactly once, with the ledger balanced" $ do
      let records = [intent 1 0 0 0 1 0, intent 1 1 1 0 1 0]
      report ← racing records (stopsAt 1)
      reportStatus report `shouldBe` Stopped
      reportReplay report `shouldBe` Just (ReplayOutcome 2 1)
      -- The one released is discarded by the stop, exactly once: the session's own law holds ('runSession' checks it).
      (countAccepted (reportCounts report), countDiscarded (reportCounts report)) `shouldBe` (1, 1)
      reportRecorded report `shouldBe` Right (logOf [intent 1 0 0 0 1 0])

    it "fails the session quietly when a failure is recorded before an intention is released: #499's failure, an incomplete replay" $ do
      report ← racing [intent 1 0 0 0 1 0] (failsAt 0)
      reportTicks report `shouldBe` 0
      reportStatus report `shouldSatisfy` \case Failed _ → True; _ → False
      reportReplay report `shouldBe` Just (ReplayOutcome 1 0)
      reportRecorded report `shouldBe` Right emptyLog
      filter ("replay: " `isPrefixOf`) (map Text.unpack (renderReport report)) `shouldSatisfy` \case
        [line] → "incomplete (session failed at tick 1)" `isSuffixOf` line
        _ → False

    it "fails the session when a failure is recorded before a control is released: the engine still takes it, and it settles as no longer applicable" $ do
      report ← racing [control 1 0 OpPause] (failsAt 0)
      reportStatus report `shouldSatisfy` \case Failed _ → True; _ → False
      reportReplay report `shouldBe` Just (ReplayOutcome 1 1)
      reportRecorded report `shouldBe` Right (logOf [control 1 0 OpPause])
      (controlAccepted (reportControls report), settledControls report) `shouldBe` (1, 1)

    it "fails the session when a failure is recorded between the records of a tick: the intentions released before it are invalidated" $ do
      let records = [intent 1 0 0 0 1 0, intent 1 1 1 0 1 0]
      report ← racing records (failsAt 1)
      reportStatus report `shouldSatisfy` \case Failed _ → True; _ → False
      reportReplay report `shouldBe` Just (ReplayOutcome 2 1)
      (countAccepted (reportCounts report), countInvalidated (reportCounts report)) `shouldBe` (1, 1)
      reportRecorded report `shouldBe` Right (logOf [intent 1 0 0 0 1 0])

  describe "a log that can" $ do
    it "is released to the seam one tick at a time: each tick's records only once it is the next unstarted tick, none before it" $ do
      let records = [intent 1 0 0 0 1 0, intent 1 1 1 0 1 0, intent 2 0 2 0 1 0, intent 3 0 3 0 1 0, intent 3 1 4 0 1 0, intent 3 2 5 0 1 0]
      seen ← newIORef []
      holder ← newIORef Nothing
      let hook point = case point of
            BeforeGrant → do
              known ← readIORef holder
              forM_ known $ \domains → do
                (next, held) ← atomically ((,) <$> nextUnstarted (sharedQueue (domainsShared domains)) <*> reserved (sharedQueue (domainsShared domains)))
                modifyIORef' seen (<> [(next, held)])
            _ → pure ()
      withSample (\config → (fixedConfig (logOf records) 3 1 Normal config) {configTickHook = hook}) $ \_ _ domains → do
        writeIORef holder (Just domains)
        -- Nothing is released before the first tick is the next one, and the first is the next from the start: nothing yet.
        atomically (reserved (sharedQueue (domainsShared domains))) `shouldReturn` 0
        mapM_ (const (stepCommitted domains)) [1 .. 3 ∷ Int]
        -- Each tick that began held exactly its own records (the tick after it is the next unstarted one by then), and each
        -- commit settled them.
        readIORef seen `shouldReturn` [(2, 2), (3, 1), (4, 3)]
        atomically (reserved (sharedQueue (domainsShared domains))) `shouldReturn` 0

    it "applies the sample's rules unchanged: revalidation in place order, the dispositions, the staging and the commit" $ do
      let records =
            [ intent 1 0 2 0 1 0
            , intent 1 1 2 0 0 1
            , RecordIntention (Placement 1 2) ActsCurrent 0 3 5 0 1
            , RecordIntention (Placement 1 3) ActsForeign 0 4 0 1 0
            ]
      withSample (fixedConfig (logOf records) 3 1 Normal) $ \_ _ domains → do
        snapshot ← stepCommitted domains
        let dispositions = snapDispositions snapshot
        -- The first applies; the second finds the entity moved and the third carries a version the entity never had; the
        -- fourth acted in another session.
        dispApplied dispositions `shouldBe` [Placement 1 0]
        [(stalePlace stale, staleReason stale) | stale ← dispStale dispositions] `shouldBe` [(Placement 1 1, StaleVersion), (Placement 1 2, StaleVersion), (Placement 1 3, StaleSession)]
        balanced domains

    it "reads a log back from its text and replays it as it replays the log itself" $ do
      log' ← generateLog 3 12 True
      let reread = either (error . show) id (parseLog (Lazy.toStrict (renderLog log')))
      reread `shouldBe` log'
      direct ← runFixed undisturbed log' 12 3 Normal
      viaText ← runFixed undisturbed reread 12 3 Normal
      traceOf viaText `shouldBe` traceOf direct

    it "applies a control the log holds at its recorded tick, with no UI behavior originating it" $ do
      let records = [control 2 0 OpPause, control 4 0 OpResume]
      withSample (fixedConfig (logOf records) 5 1 Normal) $ \_ _ domains → do
        statuses ← forM [1 .. 5 ∷ Int] (const (snapStatus <$> stepCommitted domains))
        statuses `shouldBe` [Running, Paused, Paused, Running, Running]
        -- The UI behavior was never made due: nothing in this session asked for either control but the log.
        updatesNow domains `shouldReturn` 0
        controls ← readTVarIO (sharedControls (domainsShared domains))
        (controlOffered controls, controlAccepted controls) `shouldBe` (2, 2)

    it "refuses the UI's request for a control before it takes a place, and declines the UI's offers, in a session that takes both from a log" $ do
      let records = [control 3 0 OpPause, intent 1 0 0 0 1 0]
          ui =
            luaLines
              [ "function update(self, dt)"
              , "  control.settle()"
              , "  control.pause()"
              , "  ui.updated()"
              , "end"
              ]
      withSample (\config → (fixedConfig (logOf records) 4 1 Normal config) {configUiSource = ui}) $ \_ fakeUi domains → do
        forM_ [1 .. 3 ∷ Int] $ \_ → offer domains 1 `shouldReturn` Declined
        offer domains 2 `shouldReturn` Declined
        uiStep domains fakeUi
        uiStep domains fakeUi
        statuses ← forM [1 .. 4 ∷ Int] (const (snapStatus <$> stepCommitted domains))
        -- Only the log's own pause was applied, at its own tick: the UI's two requests took nothing.
        statuses `shouldBe` [Running, Running, Paused, Paused]
        controls ← readTVarIO (sharedControls (domainsShared domains))
        (controlAccepted controls, Map.lookup "unassigned" (controlRefused controls)) `shouldBe` (1, Just 2)
        counts ← readTVarIO (sharedCounts (domainsShared domains))
        (countAccepted counts, countDeclined counts) `shouldBe` (1, 4)
        balanced domains

    it "never skips a record the seam would not take: a place already held when its tick is released is a defect, not a silent loss" $ do
      let records = [intent 1 0 0 0 1 0]
      withSample (fixedConfig (logOf records) 3 1 Normal) $ \_ _ domains → do
        -- Something other than the log took the place, which no session that takes its intentions from a log alone does.
        taken ← atomically (admitLogged (domainsShared domains) (Placement 1 0) (Intention 1 0 5 0 1 0))
        taken `shouldBe` AdmittedAt (Placement 1 0)
        outcome ← try @DomainsDefect (stepTick domains)
        outcome `shouldSatisfy` \found → case found of
          Left (ReplayNotAdmitted 1 _) → True
          _ → False
        recorder ← readTVarIO (sharedRecorder (domainsShared domains))
        either (const 0) (length . logRecords) (recorderLog recorder) `shouldBe` 1
