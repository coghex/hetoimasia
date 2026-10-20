-- | Logical admission (D-23): a target that admits the controls made through a grant by the
-- tick and sequence the application assigned each, applies them at that tick's boundary
-- before its other work, in that order whatever order they arrived in, and refuses what
-- cannot be placed.
module Test.LuaRuntime.Lifecycle.Logical (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_, replicateM, replicateM_, void)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (permutations, sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lifecycle
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Lifecycle.Support
import Test.LuaRuntime.Scheduled.Support (awaitEffect, awaitScheduledTerminal)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (Gated (..), bounded, withBoundary, withBoundaryOpening)

takenAs ∷ Int → Text
takenAs number = "{accepted=true,receipt=" <> Text.pack (show number) <> "}"

refusedAs ∷ Text → Text
refusedAs why = "{accepted=false,refusal=" <> why <> "}"

-- | An assignment that places each request at the next slot of a plan, in the order the
-- engine asks, and notes what it was told of the request.
planned ∷ IORef [Maybe ControlSlot] → IORef [ControlRequestInfo] → AssignControl
planned plan seen info = do
  modifyIORef' seen (<> [info])
  atomicModifyIORef' plan (\case [] → ([], Nothing); next : rest → (rest, next))

-- | A grant over this owner that places its requests by a plan.
planning ∷ ScheduledOwner → IORef [Maybe ControlSlot] → IORef [ControlRequestInfo] → LifecycleGrant
planning owner plan seen = lifecycleGrant [GrantTarget (GrantedEndpoint (scheduledEndpoint owner)) bothPermits (Just (planned plan seen))]

-- | More places for the plan to give.
plan' ∷ IORef [Maybe ControlSlot] → [Maybe ControlSlot] → IO ()
plan' plan more = atomicModifyIORef' plan (\held → (held <> more, ()))

slot ∷ Word → Word → Maybe ControlSlot
slot tick order = Just (ControlSlot (fromIntegral tick) (fromIntegral order))

-- | The operation's name, as the script calls it.
opName ∷ InstanceControl → Text
opName = \case
  InstancePause → "pause"
  InstanceResume → "resume"
  InstanceStop → "stop"

-- | The scenario: an instance whose callback waits a tick, and a pause and a resume assigned to
-- that tick and a stop assigned to the third, told to the commander in this order. What the
-- target recorded, and what each request came to, by operation.
scenario ∷ [InstanceControl] → IO ([Text], [(Text, Text)])
scenario arrival = do
  targetFx ← newIFixture
  callerFx ← newIFixture
  withBoundary $ \control runtime → do
    owner ← startTarget targetFx runtime "target" [slow] logicalConfig
    _ ← admit targetFx owner "s" (moduleNamed "slow")
    awaitPhase targetFx owner "s" Active
    tid ← tidValue targetFx "s"
    expectDelivered targetFx owner "s" 1
    awaitDiagnosticsWaiting owner
    let places = \case
          InstancePause → slot 1 0
          InstanceResume → slot 1 1
          InstanceStop → slot 3 0
    plan ← newIORef (map places arrival)
    seen ← newIORef []
    caller ← startCaller callerFx runtime "caller" (Just (planning owner plan seen))
    admitCommander callerFx caller "cmdr"
    answers ← forM arrival $ \op → ask callerFx caller "cmdr" (opName op) (Just tid) Nothing
    answers `shouldBe` map takenAs [0 .. 2]
    replicateM_ 3 (grantOne control owner)
    _ ← awaitSettled targetFx "s"
    results ← forM (zip [0 ..] arrival) $ \(number, op) → (,) (opName op) <$> receiptResult callerFx caller "cmdr" number
    trace ← logged targetFx
    pure (trace, sort results)

spec ∷ Spec
spec = describe "logical admission" $ do
  it "applies controls in the order of (tick, sequence) whatever order they arrived in, each at its own tick's boundary" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] logicalConfig
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      -- Arriving as resume, stop, pause: assigned to ticks 2, 4 and 1.
      plan ← newIORef [slot 2 0, slot 4 0, slot 1 0]
      seen ← newIORef []
      caller ← startCaller callerFx runtime "caller" (Just (planning owner plan seen))
      admitCommander callerFx caller "cmdr"
      answers ← forM ["resume", "stop", "pause"] $ \op → ask callerFx caller "cmdr" op (Just tid) Nothing
      answers `shouldBe` map takenAs [0, 1, 2]
      forM_ [0, 1, 2] $ \n → ask callerFx caller "cmdr" "result" Nothing (Just n) >>= (`shouldBe` "pending")
      phaseOf targetFx owner "a" >>= (`shouldBe` Just Active)
      -- Nothing is applied before its tick, however long it has been accepted.
      grantOne control owner
      awaitPhase targetFx owner "a" Paused
      receiptResult callerFx caller "cmdr" 2 >>= (`shouldBe` "applied")
      forM_ [0, 1] $ \n → ask callerFx caller "cmdr" "result" Nothing (Just n) >>= (`shouldBe` "pending")
      -- The resume that arrived first is applied after the pause that arrived last, so it finds
      -- the instance paused and applies: arrival order would have found it active.
      grantOne control owner
      awaitPhase targetFx owner "a" Active
      receiptResult callerFx caller "cmdr" 0 >>= (`shouldBe` "applied")
      grantOne control owner
      phaseOf targetFx owner "a" >>= (`shouldBe` Just Active)
      ask callerFx caller "cmdr" "result" Nothing (Just 1) >>= (`shouldBe` "pending")
      grantOne control owner
      awaitPhase targetFx owner "a" Stopped
      receiptResult callerFx caller "cmdr" 1 >>= (`shouldBe` "applied")

  it "refuses what cannot be placed explicitly and takes nothing for it: a tick that has begun, a place that is taken, a place not given" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] logicalConfig
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      plan ← newIORef [slot 0 0]
      seen ← newIORef []
      caller ← startCaller callerFx runtime "caller" (Just (planning owner plan seen))
      admitCommander callerFx caller "cmdr"
      -- Tick zero is the tick the owner is at.
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` refusedAs "late")
      grantOne control owner
      plan' plan [slot 1 5, slot 2 1, slot 2 1, Nothing, slot 2 2]
      answers ← replicateM' 5 (ask callerFx caller "cmdr" "pause" (Just tid) Nothing)
      answers `shouldBe` [refusedAs "late", takenAs 0, refusedAs "duplicate", refusedAs "unassigned", takenAs 1]
      -- None of the refusals held a reservation: the other six of the eight are all there is.
      plan' plan [slot 3 n | n ← [0 .. 5]]
      more ← replicateM' 6 (ask callerFx caller "cmdr" "pause" (Just tid) Nothing)
      more `shouldBe` map takenAs [2 .. 7]
      plan' plan [slot 3 6]
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` refusedAs "full")

  it "tells the assignment who asked and of what from what the engine knows, never from what the script passed" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] logicalConfig
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      plan ← newIORef [slot 1 0, slot 1 1]
      seen ← newIORef []
      caller ← startCaller callerFx runtime "caller" (Just (planning owner plan seen))
      admitCommander callerFx caller "cmdr"
      _ ← ask callerFx caller "cmdr" "pause" (Just tid) Nothing
      void (taskLine callerFx caller "pause" [tid])
      commanderId ← idOf callerFx "cmdr"
      targetId ← idOf targetFx "a"
      told ← readIORef seen
      told
        `shouldBe` [ ControlRequestInfo (scheduledIdentity caller) (Just commanderId) targetId InstancePause
                   , ControlRequestInfo (scheduledIdentity caller) Nothing targetId InstancePause
                   ]

  it "applies a stop before the ordinary work of the tick it is assigned: the callback that tick wakes is closed, not resumed" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [closing] logicalConfig
      _ ← admit targetFx owner "c" (moduleNamed "closing")
      awaitPhase targetFx owner "c" Active
      tid ← tidValue targetFx "c"
      expectDelivered targetFx owner "c" 1
      awaitDiagnosticsWaiting owner
      plan ← newIORef [slot 1 0]
      seen ← newIORef []
      caller ← startCaller callerFx runtime "caller" (Just (planning owner plan seen))
      admitCommander callerFx caller "cmdr"
      ask callerFx caller "cmdr" "stop" (Just tid) Nothing >>= (`shouldBe` takenAs 0)
      logged targetFx >>= (`shouldBe` ["begin 1 1"])
      grantOne control owner
      awaitEffect (sf targetFx) "shutdown 1 stopped"
      -- The wait the tick ended was never resumed: no @end@.
      logged targetFx >>= (`shouldBe` ["begin 1 1", "closed 1", "shutdown 1 stopped"])
      receiptResult callerFx caller "cmdr" 0 >>= (`shouldBe` "applied")

  it "applies a pause before the ordinary work of the tick it is assigned: the callback that tick wakes stays frozen until resumed" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [slow] logicalConfig
      _ ← admit targetFx owner "s" (moduleNamed "slow")
      awaitPhase targetFx owner "s" Active
      tid ← tidValue targetFx "s"
      expectDelivered targetFx owner "s" 1
      awaitDiagnosticsWaiting owner
      plan ← newIORef [slot 1 0]
      seen ← newIORef []
      caller ← startCaller callerFx runtime "caller" (Just (planning owner plan seen))
      admitCommander callerFx caller "cmdr"
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` takenAs 0)
      grantOne control owner
      awaitPhase targetFx owner "s" Paused
      logged targetFx >>= (`shouldBe` ["begin 1 1"])
      -- The application's own request is admitted on arrival whatever the owner admits.
      settleControl targetFx owner "s" InstanceResume >>= (`shouldBe` ControlApplied)
      awaitEffect (sf targetFx) "end 1 1"

  it "gives the same trace and the same results for every order the same assigned requests arrive in" $ bounded $ do
    runs ← forM (permutations [InstancePause, InstanceResume, InstanceStop]) scenario
    -- The pause and the resume share a tick: pause first, so the callback is resumed within the
    -- tick its wait ended in. Applied in arrival order, a resume that arrived first would find
    -- it running, and the pause would freeze it until the stop.
    let expected = (["begin 1 1", "end 1 1", "shutdown 1 stopped"], [("pause", "applied"), ("resume", "applied"), ("stop", "applied")])
    runs `shouldBe` replicate 6 expected

  it "settles what was assigned to a tick the owner never reached as no longer applicable when it exits" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] logicalConfig
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      plan ← newIORef [slot 5 0]
      seen ← newIORef []
      caller ← startCaller callerFx runtime "caller" (Just (planning owner plan seen))
      admitCommander callerFx caller "cmdr"
      ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` takenAs 0)
      retireScheduled owner
      _ ← awaitScheduledTerminal control owner
      receiptResult callerFx caller "cmdr" 0 >>= (`shouldBe` "no_longer_applicable")

  it "gives the Haskell API the same places: late, duplicate, and refused by an owner that admits on arrival, while a request without one is applied on arrival" $ bounded $ do
    targetFx ← newIFixture
    arrivalFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] logicalConfig
      plainOwner ← startTarget arrivalFx runtime "arrival" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      _ ← admit arrivalFx plainOwner "p" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      awaitPhase arrivalFx plainOwner "p" Active
      a ← idOf targetFx "a"
      p ← idOf arrivalFx "p"
      let at tick order = requestInstanceControlAt (scheduledEndpoint owner) a InstancePause (ControlSlot tick order)
      (answerKind <$> at 0 0) >>= (`shouldBe` "late")
      first ← at 1 0
      answerKind first `shouldBe` "accepted"
      (answerKind <$> at 1 0) >>= (`shouldBe` "duplicate")
      (answerKind <$> at 1 1) >>= (`shouldBe` "accepted")
      (answerKind <$> requestInstanceControlAt (scheduledEndpoint plainOwner) p InstancePause (ControlSlot 1 0)) >>= (`shouldBe` "not logical")
      -- A request without a place is admitted as it always was, though the owner admits logically.
      settleControl targetFx owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      -- The ones waiting for their ticks are settled as the instance ends: nothing is left to
      -- apply them to, and no tick need come.
      case first of
        InstanceControlAccepted receipt → waitInstanceControl receipt >>= (`shouldBe` ControlNoLongerApplicable)
        _ → fail "not accepted"

  it "never loses a request racing the grant that begins its tick: each is accepted and then settles, or is refused as late" $ bounded $ do
    targetFx ← newIFixture
    withBoundary $ \control runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (logicalConfig {instanceBounds = InstanceBounds 8 16 8 32})
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      a ← idOf targetFx "a"
      done ← newEmptyMVar
      forM_ [0 .. 7] $ \order → forkIO $ do
        answer ← requestInstanceControlAt (scheduledEndpoint owner) a InstancePause (ControlSlot 1 order)
        putMVar done answer
      grantOne control owner
      answers ← forM [0 .. 7 ∷ Int] (const (takeMVar done))
      forM_ answers $ \case
        InstanceControlAccepted receipt → waitInstanceControl receipt >>= (`shouldSatisfy` \result → result `elem` [ControlApplied, ControlAlreadyInState])
        InstanceControlLate → pure ()
        other → fail ("expected accepted or late, found " <> show other)
      -- Accepted before the tick was reached, it is applied; after, it is refused: the tick 1 pause
      -- was applied if any was accepted.
      let acceptedCount = length [() | InstanceControlAccepted _ ← answers]
      phaseOf targetFx owner "a" >>= (`shouldBe` (if acceptedCount > 0 then Just Paused else Just Active))
      tick ← atomically (scheduledTick (scheduledEndpoint owner))
      tick `shouldBe` 1

  describe "a tick and the controls assigned to it" $ do
    it "holds the tick until its controls are applied, so grants queued together act as grants served one by one" $ bounded $ do
      -- A paused periodic instance and a resume assigned to tick 1: whether the grants for ticks 1 and 2
      -- were applied together or one after the other, the resume finds the owner at tick 1, so the first
      -- update newly due, one interval after it, is at tick 2.
      updates ← forM [True, False] $ \batched → do
        targetFx ← newIFixture
        withBoundaryOpening [openAllGates targetFx] $ \control runtime → do
          owner ← startTarget targetFx runtime "target" [echoer, holder] logicalConfig
          _ ← admitWith targetFx owner "p" (InstanceRequest (moduleNamed "echoer") (Periodic (LogicalTicks 1)) (Just "p") OrdinaryClass ["tick"])
          awaitPhase targetFx owner "p" Active
          settleControl targetFx owner "p" InstancePause >>= (`shouldBe` ControlApplied)
          p ← idOf targetFx "p"
          answer ← requestInstanceControlAt (scheduledEndpoint owner) p InstanceResume (ControlSlot 1 0)
          answerKind answer `shouldBe` "accepted"
          if batched
            then do
              holdOwner targetFx owner
              replicateM_ 2 (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))
              releaseOwner targetFx
              void (awaitTicksComplete control owner)
            else replicateM_ 2 (grantOne control owner)
          awaitPhase targetFx owner "p" Active
          logCount targetFx "update"
      updates `shouldBe` [1, 1]

    it "drops a cadence point a pause and a resume assigned to its tick invalidate: the next update is a full interval after the resume" $ bounded $ do
      targetFx ← newIFixture
      withBoundary $ \control runtime → do
        owner ← startTarget targetFx runtime "target" [echoer] logicalConfig
        _ ← admitWith targetFx owner "p" (InstanceRequest (moduleNamed "echoer") (Periodic (LogicalTicks 1)) (Just "p") OrdinaryClass ["tick"])
        awaitPhase targetFx owner "p" Active
        p ← idOf targetFx "p"
        forM_ [(InstancePause, 0), (InstanceResume, 1)] $ \(op, order) →
          requestInstanceControlAt (scheduledEndpoint owner) p op (ControlSlot 1 order) >>= (`shouldSatisfy` ((== "accepted") . answerKind))
        -- The point the tick reached is the pause's to drop: no update at tick 1.
        grantOne control owner
        logCount targetFx "update" >>= (`shouldBe` 0)
        grantOne control owner
        awaitEffect (sf targetFx) "update"
        logCount targetFx "update" >>= (`shouldBe` 1)

    it "keeps a place taken until its tick begins, whatever became of the request that took it, within the bound on what is queued" $ bounded $ do
      targetFx ← newIFixture
      withBoundary $ \_ runtime → do
        owner ← startTarget targetFx runtime "target" [echoer] (logicalConfig {instanceBounds = InstanceBounds 16 32 8 8})
        forM_ [0 .. 8 ∷ Int] $ \n → admit targetFx owner (Text.pack (show n)) (moduleNamed "echoer")
        forM_ [0 .. 8 ∷ Int] $ \n → awaitPhase targetFx owner (Text.pack (show n)) Active
        ids ← forM [0 .. 8 ∷ Int] (idOf targetFx . Text.pack . show)
        let at identity order = requestInstanceControlAt (scheduledEndpoint owner) identity InstancePause (ControlSlot 5 order)
        first ← at (ids !! 0) 0
        answerKind first `shouldBe` "accepted"
        -- Its instance ends before the tick: its request settles, and its place stays taken.
        settleControl targetFx owner "0" InstanceStop >>= (`shouldBe` ControlApplied)
        _ ← awaitSettled targetFx "0"
        case first of
          InstanceControlAccepted receipt → waitInstanceControl receipt >>= (`shouldBe` ControlNoLongerApplicable)
          _ → fail "not accepted"
        (answerKind <$> at (ids !! 1) 0) >>= (`shouldBe` "duplicate")
        -- Seven more places, each given up by an instance that ended: eight are queued and none is reserved.
        forM_ [1 .. 7] $ \n → do
          answer ← at (ids !! n) (fromIntegral n + 100)
          answerKind answer `shouldBe` "accepted"
          settleControl targetFx owner (Text.pack (show n)) InstanceStop >>= (`shouldBe` ControlApplied)
          _ ← awaitSettled targetFx (Text.pack (show n))
          case answer of
            InstanceControlAccepted receipt → waitInstanceControl receipt >>= (`shouldBe` ControlNoLongerApplicable)
            _ → fail "not accepted"
        (answerKind <$> at (ids !! 8) 200) >>= (`shouldBe` "full")

  describe "a closing handler" $
    it "is the caller its instance is: it asks as the instance and reads who it is, and what it asked is abandoned when the instance ends" $ bounded $ do
      targetFx ← newIFixture
      callerFx ← newIFixture
      withBoundary $ \_ runtime → do
        owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
        _ ← admit targetFx owner "a" (moduleNamed "echoer")
        awaitPhase targetFx owner "a" Active
        tid ← tidValue targetFx "a"
        caller ← startCaller callerFx runtime "caller" (Just (target owner))
        _ ← admitWith callerFx caller "closer" (InstanceRequest (moduleNamed "closingcommander") EventOnly (Just "closer") OrdinaryClass ["cmd"])
        awaitPhase callerFx caller "closer" Active
        tell callerFx caller "closer" "wait" (Just tid) Nothing
        awaitDiagnosticsWaiting caller
        mine ← tidValue callerFx "closer"
        -- Stopping it closes the suspended callback, which runs its closing handler.
        settleControl callerFx caller "closer" InstanceStop >>= (`shouldBe` ControlApplied)
        _ ← awaitSettled callerFx "closer"
        logged callerFx >>= (`shouldBe` ["closed self " <> renderTid mine, "closed pause " <> takenAs 0])
        -- Nothing is left holding a reservation of the target's: the instance's end abandoned it.
        awaitPhase targetFx owner "a" Paused
        reservationsAllFree' targetFx owner "a"

  describe "an instance's control of itself" $
    it "applies a request for its own pause at the assigned tick, before the tick's work: the wait the tick ends is not resumed" $ bounded $ do
      fixture ← newIFixture
      withBoundary $ \control runtime → do
        plan ← newIORef [slot 1 0]
        seen ← newIORef []
        let assign = planned plan seen
        owner ← startCallerIn fixture runtime "self" logicalCommanders (Just (lifecycleGrant [GrantTarget GrantedSelf bothPermits (Just assign)]))
        admitCommander fixture owner "cmdr"
        tell fixture owner "cmdr" "pause_self_wait" Nothing Nothing
        awaitCmd fixture 1
        cmdLines fixture >>= (`shouldBe` ["cmd pause_self_wait " <> takenAs 0])
        awaitDiagnosticsWaiting owner
        phaseOf fixture owner "cmdr" >>= (`shouldBe` Just Active)
        grantOne control owner
        awaitPhase fixture owner "cmdr" Paused
        -- The wait the tick ended was not resumed: the pause came first.
        lineCount fixture "post woke" >>= (`shouldBe` 0)
        _ ← settleControl fixture owner "cmdr" InstanceResume
        awaitEffect (sf fixture) "post woke"
        receiptResult fixture owner "cmdr" 0 >>= (`shouldBe` "applied")

  describe "a target that admits logically" $
    it "needs no assignment for a grant that only inspects it" $ bounded $ do
      targetFx ← newIFixture
      callerFx ← newIFixture
      withBoundary $ \_ runtime → do
        owner ← startTarget targetFx runtime "target" [echoer] logicalConfig
        _ ← admit targetFx owner "a" (moduleNamed "echoer")
        awaitPhase targetFx owner "a" Active
        tid ← tidValue targetFx "a"
        caller ← startCaller callerFx runtime "caller" (Just (lifecycleGrant [grantOver owner [PermitInspect]]))
        admitCommander callerFx caller "cmdr"
        ask callerFx caller "cmdr" "inspect" (Just tid) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=active")
        ask callerFx caller "cmdr" "pause" (Just tid) Nothing >>= (`shouldBe` refusedAs "unauthorized")

-- | Whether the target's owner holds a reservation for every control it may: it takes this many
-- requests, whose receipts nobody reads, and refuses the next.
reservationsAllFree' ∷ IFixture → ScheduledOwner → Text → IO ()
reservationsAllFree' fixture owner name = do
  receipts ← replicateM 8 (askUntilTaken fixture owner name InstancePause)
  forM_ receipts $ \answer → answer `shouldSatisfy` \case InstanceControlAccepted _ → True; _ → False
  askControl fixture owner name InstancePause >>= (`shouldSatisfy` \case InstanceControlFull → True; _ → False)

-- | Do this many times, in order.
replicateM' ∷ Int → IO a → IO [a]
replicateM' n action = forM [1 .. n] (const action)

-- | What requesting control answered, in a word.
answerKind ∷ InstanceControlAnswer → Text
answerKind = \case
  InstanceControlAccepted _ → "accepted"
  InstanceControlLate → "late"
  InstanceControlDuplicate → "duplicate"
  InstanceControlNotLogical → "not logical"
  InstanceControlFull → "full"
  InstanceControlClosed → "closed"
  InstanceControlUnknown → "unknown"
