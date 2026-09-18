-- | Examples for the render demand helper and for the composition that runs it
-- beside the scheduled owner loop and a fixed-step simulation policy.
--
-- The helper itself is a pure value, so most examples here are ordinary
-- applications of 'renderTurn' to observations and captures. The observations
-- are real ones: each is published by a window of a seam session whose scripted
-- platform reports exactly the framebuffer extent, visibility, and minimize
-- state the example wants, including the unavailable errors that make a field
-- 'Unavailable'. Nothing here builds an observation by hand, initializes GLFW,
-- opens a window, or needs a display.
--
-- The two composition examples run the production scheduled loop over the same
-- seam and a scripted clock, exactly as "Test.GLFW.Scheduled" does, and share
-- its scaffolding. Nothing sleeps or measures wall-clock time: every instant is
-- scripted, and every wait asserted is the seconds the loop passed to the seam.
module Test.GLFW.Render (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (void, when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Time (ElapsedBaseline, Instant, addDuration, advanceBaseline, noBaseline)
import Hetoimasia.GLFW.Command (clientDemandPublisher)
import Hetoimasia.GLFW.Demand
  ( CapturedDemand (..)
  , DemandPublisher
  , DemandRequest
  , deadlineDemand
  , immediateDemand
  , publishDemand
  )
import Hetoimasia.GLFW.Internal.Seam
  ( NativeCall (..)
  , SeamScript (..)
  , WindowAttribute (..)
  , asProcessMainThread
  , defaultScript
  , featureUnavailableCode
  , newSeam
  , reportError
  )
import Hetoimasia.GLFW.Internal.Window (beginWindowClosing)
import Hetoimasia.GLFW.Window
  ( Attribute (..)
  , Extent (..)
  , Window
  , WindowId
  , WindowObservation
  , WindowPhase (..)
  , WindowResult (..)
  , observedPhase
  , observedWindow
  , synchronizeWindow
  , windowIdentity
  , windowLocalIdentity
  , withWindow
  )
import Hetoimasia.Runtime.GLFW
import Hetoimasia.Runtime.UpdatePolicy
  ( Demand (..)
  , FixedStepConfig
  , FixedStepPolicy
  , FixedStepTurn (..)
  , advanceFixedStep
  , fixedStepConfig
  , fixedStepPolicy
  )
import Numeric.Natural (Natural)
import Test.GLFW.Scheduled
  ( at
  , durationOf
  , hosted
  , millis
  , pumps
  , quietLogger
  , scriptedClock
  , settings
  , windowNamed
  )
import Test.GLFW.Window (current, entered, stashed, unexpected)
import Test.Hspec (Expectation, Spec, describe, it, shouldBe, shouldReturn)

spec ∷ Spec
spec = describe "GLFW render demand" $ do
  describe "eligibility" $ do
    it "reads every combination of the framebuffer extent, visibility, and minimize state exactly as observed"
      testEligibilityMatrix
    it "excludes a closing window and every terminal phase from normal render demand"
      testEligibilityPhases

  describe "the opportunity budget" $
    it "refuses a budget that would offer nothing and keeps a positive one"
      testBudget

  describe "suspension and resume" $ do
    it "keeps a suspended window's dirtiness and published deadline while excluding its expired deadline from the wait"
      testSuspensionRetainsWithoutSpinning
    it "requests exactly one current frame on resume, rebased at the resume instant, and replays nothing missed"
      testResumeRequestsOneFrame
    it "keeps the owed resume frame across an intervening deferred observation"
      testResumeThroughDeferred
    it "retains a deferred window's captured demand, excludes its deadlines, and offers it once a usable extent arrives"
      testDeferredRetainsDemand

  describe "simulation demand" $ do
    it "reports the simulation's own deadline with every window suspended"
      testSimulationSurvivesSuspension
    it "reports no deadline at all with no simulation demand and no eligible window work"
      testNoDemandMeansWaiting
    it "never marks a window dirty by itself, and a served opportunity never implies simulation demand"
      testSimulationIsIndependent

  describe "frame deadlines" $
    it "serves a frame once, recreates nothing from an unchanged request, and takes its cadence only from a new one"
      testFrameConsumption

  describe "fairness" $ do
    it "offers an occasionally dirty window within a bounded number of turns beside an always dirty one"
      testFairnessAgainstAlwaysDirty
    it "offers every one of a stable eligible set within the turns its budget allows, and keeps unserved due work immediate"
      testFairnessBound

  describe "acknowledgement" $ do
    it "leaves a request published after the acknowledged revision pending, and offers it again"
      testOlderRevisionLeavesNewerPending
    it "coalesces continuous dirtiness into one opportunity per turn and grows no backlog"
      testCoalescing

  describe "state removal" $
    it "deletes a window's state when its slot closes with it, when its phase is terminal, and on request"
      testRemoval

  describe "the reported schedule" $
    it "reports no deadline for work this turn's own offer already covers, and keeps one it does not"
      testOfferedDeadlineIsNotReported

  describe "the scheduled composition" $ do
    it "runs the scheduled loop, a fixed-step policy, and two windows with independent deadlines and dirtiness"
      testComposition
    it "waits its whole fallback bound after capturing a suspended window's demand"
      testSuspendedCaptureStillWaits

-- ---------------------------------------------------------------------------
-- Eligibility

-- | Every combination of the three observed fields the eligibility rules read,
-- over one window resampled under each scripted platform in turn. The expected
-- classifications are written out per visibility and minimize pair, one entry
-- per framebuffer extent in the order the extents are listed.
testEligibilityMatrix ∷ Expectation
testEligibilityMatrix = do
  classified ← withScripted 1 $ \reports windows → do
    window ← only windows
    mapM
      (\(labels, scripted) → (,) labels . windowRenderEligibility <$> observationAt reports scripted window)
      [ ((visibility, minimized), Scripted extent visible iconified)
      | (visibility, visible) ← visibilities
      , (minimized, iconified) ← minimizations
      , (_, extent) ← extents
      ]
  map fst extents `shouldBe` ["drawable", "zero width", "zero height", "unknown extent"]
  grouped classified
    `shouldBe` [ (("visible", "restored"), [RenderEligible, RenderSuspended, RenderSuspended, RenderDeferred])
               , (("visible", "minimized"), replicate 4 RenderSuspended)
               , (("visible", "unknown minimize"), [RenderEligible, RenderSuspended, RenderSuspended, RenderDeferred])
               , (("hidden", "restored"), replicate 4 RenderSuspended)
               , (("hidden", "minimized"), replicate 4 RenderSuspended)
               , (("hidden", "unknown minimize"), replicate 4 RenderSuspended)
               , (("unknown visibility", "restored"), [RenderEligible, RenderSuspended, RenderSuspended, RenderDeferred])
               , (("unknown visibility", "minimized"), replicate 4 RenderSuspended)
               , (("unknown visibility", "unknown minimize"), [RenderEligible, RenderSuspended, RenderSuspended, RenderDeferred])
               ]
  where
    visibilities, minimizations ∷ [(String, Attribute Bool)]
    visibilities = [("visible", Observed True), ("hidden", Observed False), ("unknown visibility", Unavailable)]
    minimizations = [("restored", Observed False), ("minimized", Observed True), ("unknown minimize", Unavailable)]
    extents ∷ [(String, Attribute Extent)]
    extents =
      [ ("drawable", Observed (Extent 1600 1200))
      , ("zero width", Observed (Extent 0 1200))
      , ("zero height", Observed (Extent 1600 0))
      , ("unknown extent", Unavailable)
      ]
    grouped entries = case splitAt (length extents) entries of
      ([], _) → []
      (row@((labels, _) : _), rest) → (labels, map snd row) : grouped rest

-- | A window that is closing, and each of the three terminal phases, has no
-- normal render demand however drawable its other fields look.
testEligibilityPhases ∷ Expectation
testEligibilityPhases = do
  open ← withScripted 1 (\reports windows → only windows >>= observationAt reports drawable)
  closing ← closingObservation
  released ← endedObservation (scriptOf (pure drawable))
  disposalFailed ←
    endedObservation
      (scriptOf (pure drawable))
        {scriptDetachWindowCallbacks = \reporter → reportError reporter 0x00010008 "detach reported"}
  uncertain ←
    endedObservation
      (scriptOf (pure drawable)) {scriptDetachWindowCallbacks = \_ → throwIO (userError "release raised")}
  let observations = [open, closing, released, disposalFailed, uncertain]
  map observedPhase observations
    `shouldBe` [WindowOpen, WindowClosing, WindowReleased, WindowDisposalFailed, WindowReleaseUncertain]
  map windowRenderEligibility observations `shouldBe` RenderEligible : replicate 4 RenderExcluded

-- ---------------------------------------------------------------------------
-- The opportunity budget

testBudget ∷ Expectation
testBudget = do
  map renderBudget [0, -1] `shouldBe` replicate 2 (Left OpportunityBudgetNotPositive)
  fmap renderBudgetSize (renderBudget 3) `shouldBe` Right 3

-- ---------------------------------------------------------------------------
-- Suspension and resume

-- | A window dirty and holding a deadline that has since expired, then hidden.
-- Its demand is kept, and none of it reaches the wait: an expired deadline of a
-- suspended window would otherwise shorten every wait to nothing.
testSuspensionRetainsWithoutSpinning ∷ Expectation
testSuspensionRetainsWithoutSpinning = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  hidden ← observationAt reports drawable {scriptedVisible = Observed False} window
  let request = captured 1 (immediateDemand <> deadlineDemand (at (millis 10)))
      (first, afterFirst) = turn (at 0) NoDemand [WindowRender visible request Nothing] noRenderDemand
      (second, afterSecond) = turn (at (millis 20)) NoDemand [plain hidden] afterFirst
  map offeredWindow (renderOffers first) `shouldBe` [windowIdentity window]
  -- The offer covers the whole captured request, deadline included, so the
  -- schedule reports nothing the caller was just handed.
  renderSchedule first `shouldBe` NoUpdateDemand
  -- Nothing was acknowledged, so the demand is still owed; suspended, it is
  -- owed silently.
  renderOffers second `shouldBe` []
  renderSchedule second `shouldBe` NoUpdateDemand
  renderDeadline second `shouldBe` Nothing
  fmap retained (windowRenderState (windowIdentity window) afterSecond)
    `shouldBe` Just (True, Just (at (millis 10)), True)
  where
    retained state = (windowRedrawPending state, windowDeadlinePending state, windowSuspended state)

-- | Leaving suspension rebases the frame schedule at the resume instant and
-- owes exactly one current frame. Nothing missed while suspended is replayed,
-- and once that frame is acknowledged the next turn's wait is the simulation's
-- alone.
testResumeRequestsOneFrame ∷ Expectation
testResumeRequestsOneFrame = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  hidden ← observationAt reports drawable {scriptedVisible = Observed False} window
  let target = windowIdentity window
      frame = Just (at (millis 10))
      -- A frame deadline set while the window was drawable, then a suspension
      -- across nine of its periods.
      (_, started) = turn (at 0) NoDemand [WindowRender visible Nothing frame] noRenderDemand
      (asleep, suspended) = turn (at (millis 5)) NoDemand [WindowRender hidden Nothing frame] started
      (resumed, afterResume) = turn (at (millis 100)) NoDemand [WindowRender visible Nothing frame] suspended
      acknowledged = foldr acknowledgeRender afterResume (renderOffers resumed)
      (settled, _) =
        turn (at (millis 110)) (DeadlineDemand (at (millis 200))) [WindowRender visible Nothing frame] acknowledged
  renderOffers asleep `shouldBe` []
  -- Exactly one opportunity, carrying a frame obligation rebased at the resume
  -- instant rather than the nine periods that elapsed.
  renderOffers resumed `shouldBe` [RenderOffer target 0 (Just (at (millis 100)))]
  fmap windowFrameDue (windowRenderState target acknowledged) `shouldBe` Just Nothing
  -- The unchanged frame request recreates nothing, so the next wait is the
  -- simulation's own.
  renderOffers settled `shouldBe` []
  renderSchedule settled `shouldBe` UpdateBy (at (millis 200))

-- | A window that becomes drawable only after an observation whose framebuffer
-- extent is unknown still owes the frame its resume created.
testResumeThroughDeferred ∷ Expectation
testResumeThroughDeferred = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  hidden ← observationAt reports drawable {scriptedVisible = Observed False} window
  unknown ← observationAt reports drawable {scriptedFramebuffer = Unavailable} window
  let target = windowIdentity window
      (_, opened) = turn (at 0) NoDemand [plain visible] noRenderDemand
      (_, slept) = turn (at (millis 10)) NoDemand [plain hidden] opened
      (deferred, waiting) = turn (at (millis 20)) NoDemand [plain unknown] slept
      (drawn, _) = turn (at (millis 30)) NoDemand [plain visible] waiting
  -- The resume happened at the deferred observation, which is offered nothing
  -- and reports no deadline of its own.
  renderOffers deferred `shouldBe` []
  renderSchedule deferred `shouldBe` NoUpdateDemand
  fmap windowFrameDue (windowRenderState target waiting) `shouldBe` Just (Just (at (millis 20)))
  -- Becoming drawable offers exactly that owed frame.
  renderOffers drawn `shouldBe` [RenderOffer target 0 (Just (at (millis 20)))]

-- | A deferred window keeps what was captured for it, contributes nothing to
-- the wait, and is offered as soon as a usable extent is known.
testDeferredRetainsDemand ∷ Expectation
testDeferredRetainsDemand = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  unknown ← observationAt reports drawable {scriptedFramebuffer = Unavailable} window
  let target = windowIdentity window
      request = captured 1 (immediateDemand <> deadlineDemand (at (millis 5)))
      (held, waiting) = turn (at 0) NoDemand [WindowRender unknown request Nothing] noRenderDemand
      (drawn, _) = turn (at (millis 10)) NoDemand [plain visible] waiting
  renderOffers held `shouldBe` []
  renderSchedule held `shouldBe` NoUpdateDemand
  fmap windowRedrawPending (windowRenderState target waiting) `shouldBe` Just True
  -- The retained work becomes eligible without a second publication, and
  -- nothing missed is replayed: one opportunity, not one per deferred turn. Its
  -- published deadline is what made it due; it owed no frame of its own, and
  -- deferral is not suspension, so no resume frame was created either.
  renderOffers drawn `shouldBe` [RenderOffer target 1 Nothing]

-- ---------------------------------------------------------------------------
-- Simulation demand

-- | Two suspended windows, both owing work. The deadline reported is the
-- simulation's, which no window's state touches.
testSimulationSurvivesSuspension ∷ Expectation
testSimulationSurvivesSuspension = withScripted 2 $ \reports windows → do
  hidden ← mapM (observationAt reports drawable {scriptedVisible = Observed False}) windows
  let live = [WindowRender observation (captured 1 immediateDemand) (Just (at (millis 1))) | observation ← hidden]
      (result, _) = turn (at (millis 20)) (DeadlineDemand (at (millis 50))) live noRenderDemand
  renderOffers result `shouldBe` []
  renderSchedule result `shouldBe` UpdateBy (at (millis 50))
  renderDeadline result `shouldBe` Just (at (millis 50))

-- | Nothing demanded anywhere is no deadline at all, which leaves the loop its
-- fallback bound.
testNoDemandMeansWaiting ∷ Expectation
testNoDemandMeansWaiting = withScripted 1 $ \reports windows → do
  visible ← only windows >>= observationAt reports drawable
  let (result, _) = turn (at 0) NoDemand [plain visible] noRenderDemand
  renderOffers result `shouldBe` []
  renderSchedule result `shouldBe` NoUpdateDemand
  renderDeadline result `shouldBe` Nothing

-- | Simulation demand is carried beside the windows and never becomes one:
-- immediate simulation demand offers no window an opportunity, and finishing
-- one leaves the simulation exactly where it was.
testSimulationIsIndependent ∷ Expectation
testSimulationIsIndependent = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  let (busy, afterBusy) = turn (at 0) ImmediateDemand [plain visible] noRenderDemand
      (served, afterServed) =
        turn (at (millis 10)) NoDemand [WindowRender visible (captured 1 immediateDemand) Nothing] afterBusy
      acknowledged = foldr acknowledgeRender afterServed (renderOffers served)
      (quiet, _) = turn (at (millis 20)) NoDemand [plain visible] acknowledged
  -- The simulation wants a turn; the window does not, and is offered nothing.
  renderOffers busy `shouldBe` []
  renderSchedule busy `shouldBe` UpdateImmediately
  map offeredWindow (renderOffers served) `shouldBe` [windowIdentity window]
  -- Finishing that opportunity implies no further demand of either kind.
  renderOffers quiet `shouldBe` []
  renderSchedule quiet `shouldBe` NoUpdateDemand

-- ---------------------------------------------------------------------------
-- Frame deadlines

-- | An absolute frame deadline is one obligation, not a period. It is offered
-- when it is reached, served once, and never recreated while the caller keeps
-- asking for the same instant; a new instant is a new obligation, and none at
-- all removes the demand.
testFrameConsumption ∷ Expectation
testFrameConsumption = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  let target = windowIdentity window
      first = Just (at (millis 10))
      next = Just (at (millis 40))
      (pending, afterPending) = turn (at 0) NoDemand [WindowRender visible Nothing first] noRenderDemand
      (due, afterDue) = turn (at (millis 10)) NoDemand [WindowRender visible Nothing first] afterPending
      acknowledged = foldr acknowledgeRender afterDue (renderOffers due)
      (unchanged, afterUnchanged) = turn (at (millis 20)) NoDemand [WindowRender visible Nothing first] acknowledged
      (replaced, afterReplaced) = turn (at (millis 30)) NoDemand [WindowRender visible Nothing next] afterUnchanged
      (withdrawn, _) = turn (at (millis 35)) NoDemand [WindowRender visible Nothing Nothing] afterReplaced
  renderOffers pending `shouldBe` []
  renderSchedule pending `shouldBe` UpdateBy (at (millis 10))
  renderOffers due `shouldBe` [RenderOffer target 0 (Just (at (millis 10)))]
  -- The same request repeated is the same obligation, already served.
  renderOffers unchanged `shouldBe` []
  renderSchedule unchanged `shouldBe` NoUpdateDemand
  -- Cadence comes only from the caller's next deadline.
  renderSchedule replaced `shouldBe` UpdateBy (at (millis 40))
  renderSchedule withdrawn `shouldBe` NoUpdateDemand

-- ---------------------------------------------------------------------------
-- Fairness

-- | One window dirty on every turn and one dirty once, against a budget of one
-- opportunity. The always dirty window cannot keep the other from its turn.
testFairnessAgainstAlwaysDirty ∷ Expectation
testFairnessAgainstAlwaysDirty = withScripted 2 $ \reports windows → do
  observations ← mapM (observationAt reports drawable) windows
  (busy, occasional) ← case map windowIdentity windows of
    [first, second] → pure (first, second)
    other → unexpected ("expected two windows, found " <> show (length other))
  let live revision both =
        [ WindowRender observation (if index == (0 ∷ Int) || both then captured revision immediateDemand else Nothing) Nothing
        | (index, observation) ← zip [0 ..] observations
        ]
      run instant revision both state =
        case renderTurn (budgetOf 1) (RenderTurn (at instant) NoDemand (live revision both)) state of
          (result, next) → (result, foldr acknowledgeRender next (renderOffers result))
      (first', afterFirst) = run 0 1 True noRenderDemand
      (second', afterSecond) = run (millis 10) 2 False afterFirst
      (third, _) = run (millis 20) 3 False afterSecond
  map (map offeredWindow . renderOffers) [first', second', third]
    `shouldBe` [[busy], [occasional], [busy]]
  -- The turn that could not serve the second window kept the next schedule
  -- immediate rather than waiting on work it already owed.
  renderSchedule first' `shouldBe` UpdateImmediately
  renderSchedule second' `shouldBe` UpdateImmediately

-- | Three continuously eligible windows against a budget of two: every one of
-- them is offered within the two turns @ceiling (3 \/ 2)@ allows, and the
-- rotation advances on the offers themselves.
testFairnessBound ∷ Expectation
testFairnessBound = withScripted 3 $ \reports windows → do
  observations ← mapM (observationAt reports drawable) windows
  let live revision = [WindowRender observation (captured revision immediateDemand) Nothing | observation ← observations]
      run instant revision state =
        case renderTurn (budgetOf 2) (RenderTurn (at instant) NoDemand (live revision)) state of
          (result, next) → (result, foldr acknowledgeRender next (renderOffers result))
      (first, afterFirst) = run 0 1 noRenderDemand
      (second, _) = run (millis 10) 2 afterFirst
      served result = map (windowLocalIdentity . offeredWindow) (renderOffers result)
  map (windowLocalIdentity . windowIdentity) windows `shouldBe` [1, 2, 3]
  served first `shouldBe` [1, 2]
  served second `shouldBe` [3, 1]
  -- Due work beyond the budget is what keeps the schedule immediate.
  renderSchedule first `shouldBe` UpdateImmediately

-- ---------------------------------------------------------------------------
-- Acknowledgement

-- | Capturing a publication and acknowledging an opportunity are different
-- things. An acknowledgement of a revision older than what has since been
-- captured clears nothing, and the newer request is offered again.
testOlderRevisionLeavesNewerPending ∷ Expectation
testOlderRevisionLeavesNewerPending = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  let target = windowIdentity window
      (first, afterFirst) =
        turn (at 0) NoDemand [WindowRender visible (captured 1 immediateDemand) Nothing] noRenderDemand
      (second, afterSecond) =
        turn (at (millis 10)) NoDemand [WindowRender visible (captured 2 immediateDemand) Nothing] afterFirst
      stale = foldr acknowledgeRender afterSecond (renderOffers first)
      (third, afterThird) = turn (at (millis 20)) NoDemand [plain visible] stale
      settled = foldr acknowledgeRender afterThird (renderOffers second)
      (fourth, _) = turn (at (millis 30)) NoDemand [plain visible] settled
  renderOffers first `shouldBe` [RenderOffer target 1 Nothing]
  renderOffers second `shouldBe` [RenderOffer target 2 Nothing]
  -- The stale acknowledgement recorded its revision and erased nothing.
  fmap windowRedrawPending (windowRenderState target stale) `shouldBe` Just True
  fmap windowRevisionServed (windowRenderState target stale) `shouldBe` Just 1
  renderOffers third `shouldBe` [RenderOffer target 2 Nothing]
  -- Acknowledging the revision actually captured clears it.
  renderOffers fourth `shouldBe` []
  fmap windowRevisionServed (windowRenderState target settled) `shouldBe` Just 2

-- | Republished dirtiness between two opportunities is one opportunity, and the
-- state a window holds is the same size however many publications it coalesced.
testCoalescing ∷ Expectation
testCoalescing = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  let target = windowIdentity window
      dirty revision = [WindowRender visible (captured revision immediateDemand) Nothing]
      run (seen, state) revision =
        case turn (at (millis (toInteger revision * 10))) NoDemand (dirty revision) state of
          (result, next) → (seen <> [renderOffers result], next)
      (offers, saturated) = foldl run ([], noRenderDemand) [1 .. 4 ∷ Natural]
      acknowledged = foldr acknowledgeRender saturated (concat (drop 3 offers))
      (quiet, _) = turn (at (millis 50)) NoDemand [plain visible] acknowledged
  -- Four publications, one opportunity each turn: no backlog of obsolete
  -- frames, and the last offer carries the newest revision.
  offers
    `shouldBe` [ [RenderOffer target 1 Nothing]
               , [RenderOffer target 2 Nothing]
               , [RenderOffer target 3 Nothing]
               , [RenderOffer target 4 Nothing]
               ]
  windowRenderState target saturated
    `shouldBe` Just
      WindowRenderState
        { windowRedrawPending = True
        , windowDeadlinePending = Nothing
        , windowRevisionPending = 4
        , windowRevisionServed = 0
        , windowFrameDue = Nothing
        , windowFrameRequested = Nothing
        , windowSuspended = False
        }
  renderOffers quiet `shouldBe` []

-- ---------------------------------------------------------------------------
-- State removal

-- | A window the caller stops listing, one whose phase is terminal, and one
-- forgotten outright all leave the state holding nothing for them. A closing
-- window keeps its entry and is offered nothing.
testRemoval ∷ Expectation
testRemoval = do
  closing ← closingObservation
  released ← endedObservation (scriptOf (pure drawable))
  withScripted 2 $ \reports windows → do
    observations ← mapM (observationAt reports drawable) windows
    (kept, gone) ← case map windowIdentity windows of
      [first, second] → pure (first, second)
      other → unexpected ("expected two windows, found " <> show (length other))
    let dirty observation = WindowRender observation (captured 1 immediateDemand) Nothing
        (_, both) = turn (at 0) NoDemand (map dirty observations) noRenderDemand
        (dropped, afterDropped) =
          turn (at (millis 10)) NoDemand [dirty observation | observation ← observations, observedWindow observation == kept] both
        -- The closing and released windows are a different session's, so they
        -- start from no state of their own and are removed on sight.
        (_, afterClosingSeen) = turn (at (millis 15)) NoDemand [dirty closing] afterDropped
        (ending, afterEnding) = turn (at (millis 20)) NoDemand [plain closing] afterClosingSeen
        (_, afterTerminal) = turn (at (millis 30)) NoDemand [plain released] afterEnding
    renderDemandWindows both `shouldBe` [kept, gone]
    -- The window the host no longer holds took its slot and its state with it.
    renderDemandWindows afterDropped `shouldBe` [kept]
    map offeredWindow (renderOffers dropped) `shouldBe` [kept]
    -- A closing window's demand slot closed with it, so its state goes at the
    -- first closing observation rather than lingering until release, and it is
    -- never offered even with a capture beside it.
    renderDemandWindows afterClosingSeen `shouldBe` []
    renderDemandWindows afterEnding `shouldBe` []
    renderOffers ending `shouldBe` []
    renderSchedule ending `shouldBe` NoUpdateDemand
    -- A terminal phase removes it too, as does forgetting one outright.
    renderDemandWindows afterTerminal `shouldBe` []
    renderDemandWindows (forgetRenderWindow kept both) `shouldBe` [gone]
    renderDemandWindows (forgetRenderWindow kept noRenderDemand) `shouldBe` []

-- ---------------------------------------------------------------------------
-- The reported schedule

-- | A capture carrying immediate demand and a deadline that is not yet due is
-- offered now, and acknowledging that offer clears both. The schedule that turn
-- reports must not name the deadline it just handed out, or the loop would wake
-- for work already done; a frame deadline the offer did not serve is still
-- owed, and is still reported.
testOfferedDeadlineIsNotReported ∷ Expectation
testOfferedDeadlineIsNotReported = withScripted 1 $ \reports windows → do
  window ← only windows
  visible ← observationAt reports drawable window
  let target = windowIdentity window
      request = captured 1 (immediateDemand <> deadlineDemand (at (millis 50)))
      (served, afterServed) =
        turn (at 0) NoDemand [WindowRender visible request (Just (at (millis 80)))] noRenderDemand
      acknowledged = foldr acknowledgeRender afterServed (renderOffers served)
      (after, _) = turn (at (millis 10)) NoDemand [WindowRender visible Nothing (Just (at (millis 80)))] acknowledged
  renderOffers served `shouldBe` [RenderOffer target 1 Nothing]
  -- The published deadline is the offer's; the frame deadline is not, so it is
  -- the only one reported.
  renderSchedule served `shouldBe` UpdateBy (at (millis 80))
  -- Acknowledging left no trace of the deadline the offer covered.
  fmap windowDeadlinePending (windowRenderState target acknowledged) `shouldBe` Just Nothing
  renderOffers after `shouldBe` []
  renderSchedule after `shouldBe` UpdateBy (at (millis 80))

-- ---------------------------------------------------------------------------
-- The scheduled composition

-- | The reference composition: the scheduled owner loop, a fixed-step
-- simulation policy, and two windows with their own frame cadences and their
-- own dirtiness, over the seam and a scripted clock.
--
-- Each turn's update samples nothing of its own. It takes the instant the loop
-- gives it, advances the simulation from that instant, captures each window's
-- demand slot, and hands the helper the observations, the captures, and the
-- frame deadlines the application owns. The schedule the helper answers is what
-- the loop continues with, and rebasing a served window's next frame is the
-- caller's, because an absolute deadline names no period.
testComposition ∷ Expectation
testComposition = do
  seam ← newSeam (scriptOf (pure drawable))
  (clock, unread) ←
    scriptedClock
      [ 0
      , 0
      , millis 2
      , millis 10
      , millis 12
      , millis 20
      , millis 22
      , millis 30
      , millis 32
      , millis 40
      , millis 42
      , millis 50
      ]
  steps ← newIORef []
  offered ← newIORef []
  schedules ← newIORef []
  pacings ← newIORef []
  hosted seam (settings [windowNamed "left", windowNamed "right"] clock) (\host _ → pure host) $ \host control → do
    (left, right) ←
      atomically (hostWindowIdentities host) >>= \case
        [first, second] → pure (first, second)
        other → unexpected ("expected two windows, found " <> show (length other))
    -- Each window's own cadence, which the application owns: the helper is
    -- given an absolute instant and never infers the period behind it.
    let periods = [(left, millis 20), (right, millis 50)]
    frames ← newIORef [(left, at (millis 20)), (right, at (millis 50))]
    simulation ← newIORef (fixedStepPolicy (policyOf (millis 10) (millis 100) 5), noBaseline)
    demand ← newIORef noRenderDemand
    publisher ← publisherFor host right
    let record = Recording {recordedSteps = steps, recordedOffers = offered, recordedSchedules = schedules, recordedPacings = pacings}
    runScheduledOwnerLoop host control $
      (defaultScheduledHooks quietLogger (composed host [left, right] periods frames simulation demand record publisher))
        {scheduledStart = UpdateImmediately}
  readIORef pacings `shouldReturn` (PolledForWork : replicate 5 (WaitedForDeadline (durationOf (millis 8))))
  pumps seam `shouldReturn` (PollEvents : replicate 5 (WaitEvents 0.008))
  readIORef steps `shouldReturn` [0, 1, 1, 1, 1, 1]
  -- The window served, by its own number: nothing until the left window's first
  -- frame is due, then both once the right window is dirty and its own frame
  -- follows, with each turn's rotation starting after the window served last.
  readIORef offered `shouldReturn` [[], [], [1], [], [2, 1], [2]]
  readIORef schedules `shouldReturn` map (UpdateBy . at . millis) [10, 20, 30, 40, 50, 60]
  unread `shouldReturn` 0

-- | Where the composition records what each of its turns did.
data Recording = Recording
  { recordedSteps ∷ IORef [Int]
  , recordedOffers ∷ IORef [[Natural]]
  , recordedSchedules ∷ IORef [UpdateSchedule]
  , recordedPacings ∷ IORef [TurnPacing]
  }

-- | One update opportunity of the composition.
composed
  ∷ WindowHost
  → [WindowId]
  → [(WindowId, Integer)]
  → IORef [(WindowId, Instant)]
  → IORef (FixedStepPolicy, ElapsedBaseline)
  → IORef RenderDemand
  → Recording
  → DemandPublisher
  → ScheduledTurn
  → IO (ScheduledStep ())
composed host windows periods frames simulation demand record publisher turned = do
  modifyIORef' (recordedPacings record) (<> [scheduledPacing turned])
  -- The simulation advances from the instant the loop gave this turn, and its
  -- next step is its own demand, independent of every window.
  (policy, baseline) ← readIORef simulation
  let (elapsed, advanced) = advanceBaseline now baseline
      (ran, stepped) = advanceFixedStep now elapsed policy
  writeIORef simulation (stepped, advanced)
  modifyIORef' (recordedSteps record) (<> [stepsToRun ran])
  due ← either (\overflow → unexpected ("the next step overflowed: " <> show overflow)) pure (nextStepDue ran)
  live ← mapM (observed host frames) windows
  state ← readIORef demand
  let (result, turnedState) = renderTurn (budgetOf 2) (RenderTurn now (DeadlineDemand due) live) state
  modifyIORef' (recordedOffers record) (<> [map (windowLocalIdentity . offeredWindow) (renderOffers result)])
  modifyIORef' (recordedSchedules record) (<> [renderSchedule result])
  -- Rendering is the caller's, acknowledging what it served is too, and so is
  -- the next deadline of every window whose frame this turn consumed.
  writeIORef demand (foldr acknowledgeRender turnedState (renderOffers result))
  mapM_ rebase [offer | offer ← renderOffers result, Just _ ← [offeredFrame offer]]
  -- The right window is made dirty once, after this turn's captures, so the
  -- next turn's capture is what sees it.
  when (turnNumber (scheduledTurn turned) == 4) (void (publishDemand publisher immediateDemand))
  pure (if turnNumber (scheduledTurn turned) == 6 then FinishWith () else ContinueWith (renderSchedule result))
  where
    now = scheduledNow turned
    rebase offer = do
      let target = offeredWindow offer
          period = maybe 0 id (lookup target periods)
      shifted ←
        either (\overflow → unexpected ("the frame deadline overflowed: " <> show overflow)) pure (addDuration now (durationOf period))
      modifyIORef' frames (map (\(window, instant) → (window, if window == target then shifted else instant)))

-- | One window's inputs for the turn: its latest observation, what its slot had
-- pending, and the frame deadline the application currently wants for it.
observed ∷ WindowHost → IORef [(WindowId, Instant)] → WindowId → IO WindowRender
observed host frames target = do
  observation ←
    withHostWindow host target current >>= \case
      WindowAvailable observation → pure observation
      WindowEnded _ → unexpected "the composition's window ended"
  capture ← captureWindowDemand host target
  frame ← lookup target <$> readIORef frames
  pure (WindowRender observation capture frame)

-- | A suspended window whose demand the owner captures still leaves the loop a
-- whole fallback bound to wait: the capture moved the work into bounded
-- scheduling state rather than leaving permanent immediate demand behind.
testSuspendedCaptureStillWaits ∷ Expectation
testSuspendedCaptureStillWaits = do
  seam ← newSeam (scriptOf (pure drawable {scriptedVisible = Observed False}))
  (clock, unread) ← scriptedClock [0, 0, millis 1, millis 2]
  offered ← newIORef []
  pacings ← newIORef []
  pending ← newIORef Nothing
  hosted seam (settings [windowNamed "hidden"] clock) (\host _ → pure host) $ \host control → do
    target ←
      atomically (hostWindowIdentities host) >>= \case
        [single] → pure single
        other → unexpected ("expected one window, found " <> show (length other))
    publisher ← publisherFor host target
    _ ← publishDemand publisher immediateDemand
    frames ← newIORef []
    demand ← newIORef noRenderDemand
    runScheduledOwnerLoop host control $
      (defaultScheduledHooks quietLogger $ \turned → do
          modifyIORef' pacings (<> [scheduledPacing turned])
          live ← observed host frames target
          state ← readIORef demand
          let (result, next) = renderTurn (budgetOf 2) (RenderTurn (scheduledNow turned) NoDemand [live]) state
          writeIORef demand next
          modifyIORef' offered (<> [renderOffers result])
          writeIORef pending (windowRenderState target next)
          pure (if turnNumber (scheduledTurn turned) == 2 then FinishWith () else ContinueWith (renderSchedule result)))
        {scheduledStart = UpdateImmediately}
  readIORef pacings `shouldReturn` [PolledForWork, WaitedForFallback (durationOf (millis 250))]
  pumps seam `shouldReturn` [PollEvents, WaitEvents 0.25]
  readIORef offered `shouldReturn` [[], []]
  -- The publication was captured and is still owed, and it never shortened a
  -- wait while the window could not be drawn.
  (fmap windowRedrawPending <$> readIORef pending) `shouldReturn` Just True
  unread `shouldReturn` 0

publisherFor ∷ WindowHost → WindowId → IO DemandPublisher
publisherFor host target =
  atomically (hostWindowClient host target) >>= \case
    Just client → pure (clientDemandPublisher client)
    Nothing → unexpected "the host does not hold the window it just created"

policyOf ∷ Integer → Integer → Int → FixedStepConfig
policyOf step cap budget = case fixedStepConfig (durationOf step) (durationOf cap) budget of
  Right config → config
  Left rejected → error ("the example's fixed-step configuration was rejected: " <> show rejected)

-- ---------------------------------------------------------------------------
-- Scripted observations

-- | What one scripted platform reports for the three fields the eligibility
-- rules read. Every other field keeps the default script's answer.
data Scripted = Scripted
  { scriptedFramebuffer ∷ Attribute Extent
  , scriptedVisible ∷ Attribute Bool
  , scriptedIconified ∷ Attribute Bool
  }

-- | A window the platform reports as shown, restored, and drawable.
drawable ∷ Scripted
drawable = Scripted (Observed (Extent 1600 1200)) (Observed True) (Observed False)

-- | A seam script answering whatever the current 'Scripted' says. A field it
-- reports as 'Unavailable' is one the platform answers with an unavailable
-- error rather than a fabricated value.
scriptOf ∷ IO Scripted → SeamScript
scriptOf reports =
  defaultScript
    { scriptFramebufferSize = \reporter →
        reports >>= \scripted → case scriptedFramebuffer scripted of
          Observed extent → pure (extentWidth extent, extentHeight extent)
          Unavailable → refuse reporter "framebuffer size" >> pure (0, 0)
    , scriptWindowAttribute = \attribute reporter →
        reports >>= \scripted → case attribute of
          VisibleAttribute → answer reporter "window visibility" (scriptedVisible scripted)
          IconifiedAttribute → answer reporter "window iconify" (scriptedIconified scripted)
          _ → pure False
    }
  where
    answer reporter what = \case
      Observed value → pure value
      Unavailable → refuse reporter what >> pure False
    refuse reporter what = reportError reporter featureUnavailableCode ("the platform provides no " <> what)

-- | Run an action over a session holding @count@ windows and the report the
-- whole session samples through, so an example can resample any of them under a
-- different scripted platform.
withScripted ∷ Int → (IORef Scripted → [Window] → IO r) → IO r
withScripted count use = do
  reports ← newIORef drawable
  seam ← newSeam (scriptOf (readIORef reports))
  let nest session remaining held
        | remaining <= (0 ∷ Int) = use reports (reverse held)
        | otherwise =
            withWindow session (windowNamed (Text.pack ("render-" <> show remaining))) $ \window →
              nest session (remaining - 1) (window : held)
  asProcessMainThread seam (entered seam (\session → nest session count []))

-- | Resample one window under a scripted platform and answer what it published.
observationAt ∷ IORef Scripted → Scripted → Window → IO WindowObservation
observationAt reports scripted window = do
  writeIORef reports scripted
  synchronizeWindow window >>= \case
    WindowAvailable observation → pure observation
    WindowEnded _ → unexpected "the window ended while the example was scripting it"

-- | A drawable window whose owner has begun its close protocol.
closingObservation ∷ IO WindowObservation
closingObservation = do
  seam ← newSeam (scriptOf (pure drawable))
  asProcessMainThread seam $ entered seam $ \session →
    withWindow session (windowNamed "closing") $ \window → do
      _ ← beginWindowClosing (pure ()) (pure True) window
      current window

-- | The final observation of a window whose scope has ended, however it ended.
-- A release that failed ends the scope with its own failure, which is the
-- fixture's business and not what the example asserts.
endedObservation ∷ SeamScript → IO WindowObservation
endedObservation script = do
  seam ← newSeam script
  stash ← newIORef Nothing
  ended ←
    try (asProcessMainThread seam (entered seam (\session → withWindow session (windowNamed "ended") (writeIORef stash . Just))))
  case ended ∷ Either SomeException () of
    _ → stashed stash >>= current

-- ---------------------------------------------------------------------------
-- Shared scaffolding

-- | One turn at a budget of two opportunities.
turn ∷ Instant → Demand → [WindowRender] → RenderDemand → (RenderResult, RenderDemand)
turn now simulation live = renderTurn (budgetOf 2) (RenderTurn now simulation live)

-- | A window with nothing captured and no frame deadline.
plain ∷ WindowObservation → WindowRender
plain observation = WindowRender observation Nothing Nothing

captured ∷ Natural → DemandRequest → Maybe CapturedDemand
captured revision request = Just (CapturedDemand revision request)

budgetOf ∷ Int → RenderBudget
budgetOf opportunities = case renderBudget opportunities of
  Right accepted → accepted
  Left rejected → error ("the example's budget was rejected: " <> show rejected)

only ∷ [Window] → IO Window
only = \case
  [window] → pure window
  windows → unexpected ("expected one window, found " <> show (length windows))
