-- | Settlement at an assigned tick (D-36, D-39): on an owner driven by logical time a
-- request's settlement reaches Lua at the tick the application assigned, in the order of
-- (tick, sequence); a reply that arrives earlier is a held completion and no settlement; the
-- tick does not begin until the request is complete; a cancel before the tick always wins; and
-- the same inputs give the same settlements and effects however the provider's replies arrive.
module Test.LuaRuntime.Request.Logical (spec) where

import Control.Monad (forM_, replicateM_, void)
import Data.IORef (newIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Runtime.Supervision (WorkerStatus (WorkerStopped))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Data.Word (Word64)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Control.Concurrent.STM (atomically)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfDelay), awaitScheduledTerminal)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

-- | An owner of askers that settles at assigned ticks, placing requests by this assignment.
logicalOwner ∷ IFixture → Fake → LuaRuntime → Text → Maybe AssignRequest → IO ScheduledOwner
logicalOwner fixture fake runtime label assign =
  startRequester fixture runtime label [asker, echoer] cmdConfig (logicalGrant fake 8 assign) requiredPolicy

-- | Grant one logical step without waiting for the tick to complete.
step ∷ ScheduledOwner → IO ()
step owner = void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))

-- | How many grants have been accepted and not completed.
outstanding ∷ ScheduledOwner → IO Int
outstanding owner = atomically (ticksOutstanding (scheduledEndpoint owner))

-- | What the scripts recorded, without what the application's own disposal of a dependency did: that
-- follows when the provider finished, which is not logical time, and no script can see it.
scriptLines ∷ IFixture → IO [Text]
scriptLines fixture = filter (not . Text.isPrefixOf "disposed") <$> linesOf fixture

-- | What the cancel-wins scenario observed: the lines the scripts recorded, and the counts the
-- service kept.
data Observed = Observed
  { seenLines ∷ [Text]
  , seenCancelledBefore ∷ Int
  , seenHeldNow ∷ Int
  , seenTick ∷ Word
  , seenStalled ∷ Int
  }
  deriving (Eq, Show)

-- | Admit at tick 0 a request due at tick 2; the script cancels it at tick 1's boundary, before it
-- is due, either after the provider's reply or before it. Everything else is the same.
cancelWins ∷ Bool → IO Observed
cancelWins replyFirst = do
  fixture ← newIFixture
  fake ← newFake
  plan ← newIORef [Just (DueSlot 2 0)]
  withBoundary $ \control runtime → providersFinish fake $ do
    owner ← logicalOwner fixture fake runtime "cancel wins" (Just (planned plan))
    admitAsker fixture owner "i" "asker"
    command fixture owner "i" "start" "a"
    awaitLine fixture "cmd start a started"
    grantOne control owner
    if replyFirst then void (answerResult fake 0 7) else pure ()
    command fixture owner "i" "cancel" "a"
    awaitLine fixture "cmd cancel a cancelled"
    if replyFirst then pure () else void (answerResult fake 0 7)
    -- Settled before the tick it was due at, as far as the script can tell.
    command fixture owner "i" "ready" "a"
    awaitLine fixture "cmd ready a true"
    command fixture owner "i" "take" "a"
    awaitLine fixture "cmd take a {reason=owner,status=cancelled}"
    -- The due tick's hold is released: tick 2 begins without the provider.
    grantOne control owner
    awaitDiagnostic owner ((== 0) . rdWorkPending)
    recorded ← scriptLines fixture
    d ← diagnostics owner
    reached ← tickReached owner
    stalled ← outstanding owner
    pure (Observed recorded (rdCancelledBeforeTick d) (rdHeldNow d) (fromIntegral reached) stalled)

spec ∷ Spec
spec = describe "logical time" $ do
  describe "a request's settlement" $ do
    it "is due at the next tick by default, and a reply that arrives earlier is held, not a settlement" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "default" Nothing
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 7 >>= (`shouldBe` ReplyHeld)
        -- Readiness answers from logical state: pending before the due tick.
        command fixture owner "i" "ready" "a"
        awaitLine fixture "cmd ready a false"
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=pending}"
        rdHeldNow <$> diagnostics owner >>= (`shouldBe` 1)
        grantOne control owner
        -- Settled from the due tick on.
        command fixture owner "i" "ready" "a"
        awaitLine fixture "cmd ready a true"
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=7}"
        d <- diagnostics owner
        (rdSettledAtTick d, rdHeldNow d) `shouldBe` (1, 0)

    it "does not let its tick begin until the provider has completed, and a later grant waits behind it" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "held tick" Nothing
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "s" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        step owner
        step owner
        -- The owner serves other work all the same, and the tick has not begun.
        sync fixture owner "s" 1
        tickReached owner >>= (`shouldBe` 0)
        outstanding owner >>= (`shouldBe` 2)
        answerResult fake 0 3 >>= (`shouldBe` ReplyHeld)
        _ ← awaitTicksComplete control owner
        tickReached owner >>= (`shouldBe` 2)

    it "reaches a waiting script at its tick and never earlier" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "waiter" Nothing
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "s" "asker"
        command fixture owner "i" "start_wait_take" "a"
        awaitLine fixture "waiting a"
        answerResult fake 0 9 >>= (`shouldBe` ReplyHeld)
        sync fixture owner "s" 1
        lineIn fixture "cmd start_wait_take" >>= (`shouldBe` Nothing)
        grantOne control owner
        awaitLine fixture "cmd start_wait_take a {status=result,value=9}"
        tickReached owner >>= (`shouldBe` 1)

    it "retains the settlement at its tick for an instance that is paused, without resuming it, until it is resumed" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "paused" Nothing
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "s" "asker"
        command fixture owner "i" "start_wait_take" "a"
        awaitLine fixture "waiting a"
        settleControl fixture owner "i" InstancePause >>= (`shouldBe` ControlApplied)
        answerResult fake 0 6 >>= (`shouldBe` ReplyHeld)
        grantOne control owner
        sync fixture owner "s" 1
        -- The tick has begun and the request has settled; the paused script has not been resumed.
        tickReached owner >>= (`shouldBe` 1)
        lineIn fixture "cmd start_wait_take" >>= (`shouldBe` Nothing)
        settleControl fixture owner "i" InstanceResume >>= (`shouldBe` ControlApplied)
        awaitLine fixture "cmd start_wait_take a {status=result,value=6}"

    it "stalls the owner only at its own tick, and a provider that never settles stalls it there until stop" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      plan ← newIORef [Just (DueSlot 3 0)]
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "stall" (Just (planned plan))
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "s" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        -- The ticks before it complete, whatever the provider has done.
        grantOne control owner
        grantOne control owner
        tickReached owner >>= (`shouldBe` 2)
        step owner
        sync fixture owner "s" 1
        tickReached owner >>= (`shouldBe` 2)
        outstanding owner >>= (`shouldBe` 1)
        retireScheduled owner
        awaitCancelled fake 1
        finishWork fake 0
        awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)

  describe "an owner that hosts no instances" $ do
    it "serves a task's request at its tick all the same: the grant that reaches the tick is held, served and let go" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \_ runtime → providersFinish fake $ do
        let spec' = (requestSpec fixture "tasks" [] cmdConfig (logicalGrant fake 8 Nothing) requiredPolicy) {scheduledInstances = Nothing}
        owner ← startRequesterWith fixture runtime spec'
        ticket ← taskOf owner "ask" [VText "path", VInteger 3]
        awaitLine fixture "task started 3"
        answerResult fake 0 30 >>= (`shouldBe` ReplyHeld)
        lineIn fixture "task took" >>= (`shouldBe` Nothing)
        step owner
        _ ← waitTask ticket
        awaitLine fixture "task took 3 result 30"
        tickReached owner >>= (`shouldBe` 1)

  describe "placing a request" $ do
    it "refuses a request the application declined to place, and one placed at a tick that has begun, and one placed where another is" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      plan ← newIORef [Nothing, Just (DueSlot 0 0), Just (DueSlot 2 0), Just (DueSlot 2 0)]
      withBoundary $ \_ runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "placing" (Just (planned plan))
        forM_ ["declined", "begun", "first", "second"] $ \name → admitAsker fixture owner name "asker"
        command fixture owner "declined" "start" "a"
        refusalOf fixture "declined" >>= (`shouldBe` Just "request refused: the application assigned it no place")
        command fixture owner "begun" "start" "a"
        refusalOf fixture "begun" >>= (`shouldBe` Just "request refused: the tick assigned to it has begun")
        command fixture owner "first" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "second" "start" "b"
        refusalOf fixture "second" >>= (`shouldBe` Just "request refused: the place assigned to it is taken")
        submissions fake >>= (`shouldBe` 1)

  describe "a cancel before the due tick" $ do
    it "wins whatever the provider has done: the same cancel gives the same effects whether the reply arrived before it or after" $ bounded $ do
      before ← cancelWins True
      after ← cancelWins False
      seenLines before `shouldBe` seenLines after
      before `shouldBe` after
      seenCancelledBefore before `shouldBe` 1
      seenHeldNow before `shouldBe` 0
      seenTick before `shouldBe` 2
      seenStalled before `shouldBe` 0
      seenLines before `shouldBe` ["cmd start a started", "cmd cancel a cancelled", "cmd ready a true", "cmd take a {reason=owner,status=cancelled}"]

    it "discards the held value, releases the due tick's hold and retires the provider's work" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      plan ← newIORef [Just (DueSlot 2 0)]
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "discard" (Just (planned plan))
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 7 >>= (`shouldBe` ReplyHeld)
        command fixture owner "i" "cancel" "a"
        awaitLine fixture "cmd cancel a cancelled"
        -- The provider had finished, so it is not asked to stop, and its work is over.
        awaitDiagnostic owner ((== 0) . rdWorkPending)
        cancelledOrder fake >>= (`shouldBe` [])
        d ← diagnostics owner
        (rdHeldNow d, rdCancelledBeforeTick d) `shouldBe` (0, 1)
        replicateM_ 2 (grantOne control owner)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {reason=owner,status=cancelled}"
        lineIn fixture "cmd take a {status=result" >>= (`shouldBe` Nothing)

    it "keeps only the first of several completions before the tick, and never lets a later one resurrect a value a cancel discarded" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "duplicates" Nothing
        admitAsker fixture owner "i" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 1 >>= (`shouldBe` ReplyHeld)
        answerResult fake 0 2 >>= (`shouldBe` ReplyLate)
        rdDuplicateHeld <$> diagnostics owner >>= (`shouldBe` 1)
        grantOne control owner
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=1}"
        command fixture owner "i" "start" "b"
        awaitLine fixture "cmd start b started"
        answerResult fake 1 5 >>= (`shouldBe` ReplyHeld)
        command fixture owner "i" "cancel" "b"
        awaitLine fixture "cmd cancel b cancelled"
        answerResult fake 1 6 >>= (`shouldBe` ReplyLate)
        grantOne control owner
        command fixture owner "i" "take" "b"
        awaitLine fixture "cmd take b {reason=owner,status=cancelled}"

  describe "a failure is a completion too" $ do
    it "holds an oversized reply as a failure that settles at the tick, never retaining its value" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        let grant = RequestGrant [fakeEndpoint fake "path", fakeEndpointOf fake "text" SText] 4 (SettleAtAssignedTick Nothing)
        owner ← startRequesterWith fixture runtime (smallLimits (requestSpec fixture "oversize" [asker] cmdConfig grant requiredPolicy))
        admitAsker fixture owner "i" "asker"
        commandFrom fixture owner "i" "start" "a" (Just "text") (Just 1)
        awaitLine fixture "cmd start a started"
        answerWith fake 0 (ProviderResult (VText (Text.replicate 2000 "x"))) >>= (`shouldBe` ReplyRefusedValue)
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=pending}"
        grantOne control owner
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {reason=the provider's result exceeded the payload cap,status=failure}"
        rdOversize <$> diagnostics owner >>= (`shouldBe` 1)

  describe "holds on a tick" $ do
    it "keeps the tick for the other request when only one of two that share it is cancelled" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "shared tick" Nothing
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "s" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        command fixture owner "i" "start" "b"
        awaitLine fixture "cmd start b started"
        step owner
        answerResult fake 0 1 >>= (`shouldBe` ReplyHeld)
        -- b is still to complete, so the tick has not begun.
        sync fixture owner "s" 1
        tickReached owner >>= (`shouldBe` 0)
        command fixture owner "i" "cancel" "a"
        awaitLine fixture "cmd cancel a cancelled"
        -- Releasing a's hold left b's: the tick is still held.
        sync fixture owner "s" 2
        tickReached owner >>= (`shouldBe` 0)
        answerResult fake 1 2 >>= (`shouldBe` ReplyHeld)
        _ ← awaitTicksComplete control owner
        tickReached owner >>= (`shouldBe` 1)
        command fixture owner "i" "take" "b"
        awaitLine fixture "cmd take b {status=result,value=2}"

    it "lets a tick begin when the last request that held it is cancelled" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "last" Nothing
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "s" "asker"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        step owner
        sync fixture owner "s" 1
        tickReached owner >>= (`shouldBe` 0)
        command fixture owner "i" "cancel" "a"
        _ ← awaitTicksComplete control owner
        tickReached owner >>= (`shouldBe` 1)

    it "keeps ordinary work for the due tick from beginning while a required completion is pending, cadence work included" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "cadence" Nothing
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "s" "asker"
        _ ← admitWith fixture owner "k" (InstanceRequest (moduleNamed "echoer") (Periodic (LogicalTicks 1)) (Just "k") OrdinaryClass ["tick"])
        awaitPhase fixture owner "k" Active
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        step owner
        sync fixture owner "s" 1
        -- The update due at tick 1 has not begun: the tick has not.
        logCount fixture "update" >>= (`shouldBe` 0)
        tickReached owner >>= (`shouldBe` 0)
        answerResult fake 0 5 >>= (`shouldBe` ReplyHeld)
        _ ← awaitTicksComplete control owner
        awaitLine fixture "update"

    it "serves requests in the order of their places, whatever order their replies and their waits arrived in" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      plan ← newIORef [Just (DueSlot 2 1), Just (DueSlot 2 0)]
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ← logicalOwner fixture fake runtime "order" (Just (planned plan))
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "j" "asker"
        command fixture owner "i" "start_wait_take" "a"
        awaitLine fixture "waiting a"
        command fixture owner "j" "start_wait_take" "b"
        awaitLine fixture "waiting b"
        -- b's place comes before a's, though a was admitted and waited for first and answered last.
        answerResult fake 1 20 >>= (`shouldBe` ReplyHeld)
        answerResult fake 0 10 >>= (`shouldBe` ReplyHeld)
        grantOne control owner
        grantOne control owner
        awaitLine fixture "cmd start_wait_take a {status=result,value=10}"
        recorded ← linesOf fixture
        let position wanted = length (takeWhile (/= wanted) recorded)
        position "cmd start_wait_take b {status=result,value=20}" `shouldSatisfy` (< position "cmd start_wait_take a {status=result,value=10}")

  describe "the one watch on a tick, shared with lifecycle controls" $ do
    it "serves a request due later after a control due earlier is served" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      plan ← newIORef [Just (DueSlot 3 0)]
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ←
          startRequester fixture runtime "control then request" [asker, echoer] cmdConfig {instanceControlAdmission = AdmitLogically} (logicalGrant fake 8 (Just (planned plan))) requiredPolicy
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "t" "asker"
        identity ← idOf fixture "t"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 8 >>= (`shouldBe` ReplyHeld)
        receipt ← requestInstanceControlAt (scheduledEndpoint owner) identity InstanceStop (ControlSlot 1 0) >>= \case
          InstanceControlAccepted accepted → pure accepted
          other → fail ("expected the control accepted, found " <> show other)
        grantOne control owner
        waitInstanceControl receipt >>= (`shouldBe` ControlApplied)
        replicateM_ 2 (grantOne control owner)
        -- The request's tick was still watched after the control's was served.
        command fixture owner "i" "ready" "a"
        awaitLine fixture "cmd ready a true"
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=8}"

    it "applies a control due later after a request due earlier is served" $ bounded $ do
      fixture ← newIFixture
      fake ← newFake
      withBoundary $ \control runtime → providersFinish fake $ do
        owner ←
          startRequester fixture runtime "request then control" [asker, echoer] cmdConfig {instanceControlAdmission = AdmitLogically} (logicalGrant fake 8 Nothing) requiredPolicy
        admitAsker fixture owner "i" "asker"
        admitAsker fixture owner "t" "asker"
        identity ← idOf fixture "t"
        command fixture owner "i" "start" "a"
        awaitLine fixture "cmd start a started"
        answerResult fake 0 8 >>= (`shouldBe` ReplyHeld)
        receipt ← requestInstanceControlAt (scheduledEndpoint owner) identity InstanceStop (ControlSlot 3 0) >>= \case
          InstanceControlAccepted accepted → pure accepted
          other → fail ("expected the control accepted, found " <> show other)
        grantOne control owner
        command fixture owner "i" "take" "a"
        awaitLine fixture "cmd take a {status=result,value=8}"
        replicateM_ 2 (grantOne control owner)
        -- The control's tick was still watched after the request's was served.
        waitInstanceControl receipt >>= (`shouldBe` ControlApplied)

  describe "determinism" $ do
    it "gives identical settlements and effects whether the replies arrive before the grants or while the tick is held, in either order, however the service budget cuts the turns" $ bounded $ do
      let run ∷ Int → (Word64, Maybe Word64) → IO [Text]
          run variant (cost, budget) = do
            fixture ← newIFixture
            fake ← newFake
            writeIORef (sfDelay (sf fixture)) cost
            withBoundary $ \control runtime → providersFinish fake $ do
              let base = requestSpec fixture "determinism" [asker, echoer] cmdConfig (logicalGrant fake 8 Nothing) requiredPolicy
                  spec' = base {scheduledBounds = (scheduledBounds base) {boundServiceBudget = nanoseconds <$> budget}}
              owner ← startRequesterWith fixture runtime spec'
              admitAsker fixture owner "i" "asker"
              admitAsker fixture owner "j" "asker"
              admitAsker fixture owner "s" "asker"
              command fixture owner "i" "start_wait_take" "a"
              awaitLine fixture "waiting a"
              command fixture owner "j" "start_wait_take" "b"
              awaitLine fixture "waiting b"
              case variant of
                0 → do
                  void (answerResult fake 0 1)
                  void (answerResult fake 1 2)
                  grantOne control owner
                1 → do
                  void (answerResult fake 1 2)
                  void (answerResult fake 0 1)
                  grantOne control owner
                _ → do
                  -- The grant is made first and the tick is held; the replies arrive after.
                  step owner
                  sync fixture owner "s" 1
                  void (answerResult fake 1 2)
                  void (answerResult fake 0 1)
                  void (awaitTicksComplete control owner)
              awaitLine fixture "cmd start_wait_take b {status=result,value=2}"
              awaitLine fixture "cmd start_wait_take a {status=result,value=1}"
              filter (not . Text.isPrefixOf "cmd noop") <$> scriptLines fixture
          cuts = [(0, Nothing), (5, Just 1), (1000, Just 1500), (1000, Just 2500)]
      results ← sequence [run variant cut | variant ← [0, 1, 2], cut ← cuts]
      case results of
        first : rest → forM_ rest (`shouldBe` first)
        [] → fail "no runs"
