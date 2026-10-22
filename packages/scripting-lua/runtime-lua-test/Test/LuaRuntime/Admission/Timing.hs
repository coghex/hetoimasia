-- | The timing an opt-in request is admitted with (D-67): on an owner on logical time, a position
-- fixed once at admission from the tick the instance is at (0 in @init@), a validated offset and the
-- request's own number as the sequence, checked against the numeric ceiling before anything is
-- accepted; held and invisible until its position; holding the tick when it is late; and
-- first-settlement on an owner on arrival, which takes no offset.
module Test.LuaRuntime.Admission.Timing (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Control.Monad (replicateM_, void)
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (grantOne)
import Test.LuaRuntime.Request.Support
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, expectFatal, requiredPolicy, withBoundary)

-- | An owner of admitters on logical time.
logical ∷ AFix → LuaRuntime → Text → IO ScheduledOwner
logical fixture runtime label =
  startAdmitting fixture runtime label [admitter, initAdmitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy

-- | An owner of admitters on elapsed time.
arrival ∷ AFix → LuaRuntime → Text → IO ScheduledOwner
arrival fixture runtime label =
  startAdmitting fixture runtime label [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy

-- | Grant one logical step without waiting for the tick to complete.
step ∷ ScheduledOwner → IO ()
step owner = void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))

-- | What the provider was told of the nth request's place and policy.
infoOf ∷ AFix → Int → IO RequestInfo
infoOf fixture index = sbInfo <$> submissionAt (afFake fixture) index

spec ∷ Spec
spec = describe "timing" $ do
  describe "on logical time" $ do
    it "places a request made in init at tick 0 with the default offset at tick 1, records its policy, and holds its early result" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polSource = "the init request"})
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "init origin"
        admitAdmitter fixture owner "i" "initadmitter"
        awaitNote fixture "init started"
        info ← infoOf fixture 0
        (infoDue info, infoOffset info, infoNecessity info, infoSource info, infoNumber info) `shouldBe` (Just (DueSlot 1 1), Nothing, Just RequiredRequest, Just "the init request", 1)
        -- The early result is held: readiness answers from logical state.
        answerResult (afFake fixture) 0 7 >>= (`shouldBe` ReplyHeld)
        acommand fixture owner "i" "ready" "a"
        awaitNote fixture "cmd ready a false"
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=pending}"
        grantOne control owner
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=success,value={v=7}}"

    it "places a request at the tick it is made plus one by default, and at the tick plus the offset when one is given" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "offsets"
        admitAdmitter fixture owner "i" "admitter"
        replicateM_ 10 (grantOne control owner)
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        acommandWith fixture owner "i" "start" "b" Nothing (Just 1) (Just 30)
        awaitStarts fixture 2
        first ← infoOf fixture 0
        second ← infoOf fixture 1
        (infoDue first, infoOffset first) `shouldBe` (Just (DueSlot 11 1), Nothing)
        -- Tick 10 plus an offset of 30 is tick 40, fixed with the sequence it was given.
        (infoDue second, infoOffset second) `shouldBe` (Just (DueSlot 40 2), Just 30)
        -- Both are answered, so neither holds its tick when it comes.
        answerResult (afFake fixture) 0 8 >>= (`shouldBe` ReplyHeld)
        answerResult (afFake fixture) 1 9 >>= (`shouldBe` ReplyHeld)
        replicateM_ 29 (grantOne control owner)
        acommand fixture owner "i" "ready" "b"
        awaitNote fixture "cmd ready b false"
        grantOne control owner
        acommand fixture owner "i" "ready" "b"
        awaitNote fixture "cmd ready b true"

    it "settles requests due at the same tick in the order of their sequences, whatever order the replies came in" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "sequence"
        admitAdmitter fixture owner "i" "admitter"
        admitAdmitter fixture owner "j" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitStarts fixture 1
        acommand fixture owner "j" "start" "b"
        awaitStarts fixture 2
        acommand fixture owner "i" "wait" "a"
        awaitNote fixture "waiting a"
        acommand fixture owner "j" "wait" "b"
        awaitNote fixture "waiting b"
        -- The later request's reply first.
        answerResult (afFake fixture) 1 2 >>= (`shouldBe` ReplyHeld)
        answerResult (afFake fixture) 0 1 >>= (`shouldBe` ReplyHeld)
        grantOne control owner
        awaitNote fixture "cmd wait b woke"
        awaitNote fixture "cmd wait a woke"
        seen ← history fixture
        let position wanted = length (takeWhile (/= wanted) seen)
        (position "cmd wait a woke" < position "cmd wait b woke") `shouldBe` True

    it "does not let a tick begin until a late provider has completed, and keeps serving other work meanwhile" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "late"
        admitAdmitter fixture owner "i" "admitter"
        admitAdmitter fixture owner "j" "admitter"
        acommand fixture owner "i" "start" "a"
        awaitNote fixture "cmd start a started"
        step owner
        acommand fixture owner "j" "noop" "n"
        awaitNote fixture "cmd noop n noop"
        tickReached owner >>= (`shouldBe` 0)
        atomically (ticksOutstanding (scheduledEndpoint owner)) >>= (`shouldBe` 1)
        answerResult (afFake fixture) 0 3 >>= (`shouldBe` ReplyHeld)
        _ ← awaitTicksComplete control owner
        tickReached owner >>= (`shouldBe` 1)

    it "lets a cancel before the position win whatever the provider already delivered, and releases the tick's hold" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "cancel wins"
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "start" "a" Nothing (Just 1) (Just 2)
        awaitNote fixture "cmd start a started"
        answerExpected fixture 0 "not_found" >>= (`shouldBe` ReplyHeld)
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a cancelled"
        -- Cancelled, not failed: the held failure never became a settlement, so it latched nothing.
        grantOne control owner
        grantOne control owner
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=cancelled}"
        d ← diagnostics owner
        (rdLatched d, rdCancelledBeforeTick d, rdHeldNow d) `shouldBe` (0, 1, 0)

  describe "on elapsed time" $ do
    it "takes no tick offset: it is an ordinary Lua error before any work" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "arrival offset"
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "pstart" "a" Nothing (Just 1) (Just 3)
        awaitNote fixture "cmd pstart a error ad.start: request refused: this request settles on arrival and takes no tick offset"
        submissions (afFake fixture) >>= (`shouldBe` 0)
        d ← diagnostics owner
        (rdAdmitted d, rdBusy d) `shouldBe` (0, 0)
        -- The invocation went on: the error was caught.
        acommand fixture owner "i" "start" "b"
        awaitNote fixture "cmd start b started"

    it "settles with whichever of the reply and the cancel is first" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← arrival fixture runtime "first wins"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        acommand fixture owner "i" "start" "b"
        awaitStarts fixture 2
        answerResult (afFake fixture) 0 5 >>= (`shouldBe` ReplySettled)
        acommand fixture owner "i" "cancel" "a"
        awaitNote fixture "cmd cancel a already_settled"
        acommand fixture owner "i" "cancel" "b"
        awaitNote fixture "cmd cancel b cancelled"
        -- A reply after the cancel changes nothing.
        answerResult (afFake fixture) 1 6 >>= (`shouldBe` ReplyLate)
        acommand fixture owner "i" "take" "a"
        awaitNote fixture "cmd take a {status=success,value={v=5}}"
        acommand fixture owner "i" "take" "b"
        awaitNote fixture "cmd take b {status=cancelled}"

  describe "the numeric ceiling" $ do
    it "refuses a tick and offset that pass it as an ordinary Lua error, and accepts the sum that reaches it" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polCeiling = 40})
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "ceiling"
        admitAdmitter fixture owner "i" "admitter"
        replicateM_ 10 (grantOne control owner)
        acommandWith fixture owner "i" "pstart" "a" Nothing (Just 1) (Just 31)
        awaitNote fixture "cmd pstart a error ad.start: request refused: the tick and offset pass the ceiling of 40"
        submissions (afFake fixture) >>= (`shouldBe` 0)
        acommandWith fixture owner "i" "pstart" "b" Nothing (Just 1) (Just 30)
        awaitNote fixture "cmd pstart b started"
        infoOf fixture 0 >>= \info → infoDue info `shouldBe` Just (DueSlot 40 1)

    it "refuses an offset that is zero or negative as an ordinary Lua error" $ bounded $ do
      fixture ← newAFix 4
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← logical fixture runtime "offset sign"
        admitAdmitter fixture owner "i" "admitter"
        acommandWith fixture owner "i" "pstart" "a" Nothing (Just 1) (Just 0)
        awaitNote fixture "cmd pstart a error ad.start: request refused: the tick offset is not a positive integer"
        acommandWith fixture owner "i" "pstart" "b" Nothing (Just 1) (Just (-4))
        awaitNote fixture "cmd pstart b error ad.start: request refused: the tick offset is not a positive integer"
        submissions (afFake fixture) >>= (`shouldBe` 0)

    it "refuses a request when every number up to the ceiling has been issued, before any work, and never reissues one" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polCeiling = 2})
      withBoundary $ \_ runtime → settleAll fixture $ do
        owner ← logical fixture runtime "numbers"
        admitAdmitter fixture owner "i" "admitter"
        acommand fixture owner "i" "start" "a"
        acommand fixture owner "i" "start" "b"
        awaitStarts fixture 2
        acommand fixture owner "i" "pstart" "c"
        awaitNote fixture "cmd pstart c error ad.start: request refused: every request number up to 2 has been issued"
        submissions (afFake fixture) >>= (`shouldBe` 2)
        d ← diagnostics owner
        rdAdmitted d `shouldBe` 2

    it "is an engine failure, never a refusal or busy, when the counter itself has nowhere to go after a valid admission" $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polCeiling = maxBound})
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
        owner ← logical fixture runtime "counter"
        admitAdmitter fixture owner "i" "admitter"
        skipRequestNumbers (scheduledEndpoint owner) maxBound >>= (`shouldBe` Just maxBound)
        acommand fixture owner "i" "start" "a"
        awaitScheduledTerminal control owner
      (fromException failure :: Maybe AdmissionDefect) `shouldSatisfy` (/= Nothing)
      submissions (afFake fixture) >>= (`shouldBe` 0)
