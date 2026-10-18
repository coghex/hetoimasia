-- | Failure handling (subscriptions): provider code raising when the engine calls it (handing it a
-- subscription, telling it interest was withdrawn) is a failure of application code, a failure of
-- the host under the owner's policy, unconverted; a failure in a provider's retirement is a
-- cleanup failure, fatal under every policy; simultaneous failures keep the first as primary and
-- the others whole as evidence; a delivery that is unfit, or whose value throws when it is
-- inspected, is refused and counted and never reaches the owner; a grant that does not make sense
-- is refused before anything starts, naming every reason; and the phases of an instance's life
-- decide whether it may subscribe at all.
module Test.LuaRuntime.Subscription.Failures (spec) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, throwIO, toException, tryWithContext)
import Control.Monad (forM_, void)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerPolicy, WorkerStatus (WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Request.Support (awaitLine, linesOf, refusalOf)
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Subscription.Support
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, optionalPolicy, requiredPolicy, withBoundary)

-- | Whether a retained failure is the application's own, of this name.
brokenAmong ∷ Text → ExceptionWithContext SomeException → Bool
brokenAmong name (ExceptionWithContext _ failure) = brokenIs name failure

subscribeTo' ∷ IFixture → ScheduledOwner → Text → Text → Text → IO ()
subscribeTo' fixture owner name key endpoint = do
  commandWith fixture owner name "subscribe" key (Just endpoint) Nothing
  awaitLine fixture ("cmd subscribe " <> key <> " ok")

ownerWith ∷ IFixture → FakeEvents → LuaRuntime → Text → [ModuleSource] → WorkerPolicy → IO ScheduledOwner
ownerWith fixture fake runtime label modules policy =
  startSubscriber fixture runtime label modules subConfig SettleOnArrival (subGrant fake 4 16) policy

spec ∷ Spec
spec = describe "failures" $ do
  describe "a provider that raises when handed a subscription" $ do
    it "is a failure of the host, unconverted, under a required policy, and the subscription is taken back" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      onSubscribe fake (\_ → throwIO (Broken "subscribe"))
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "required" [subscriber] requiredPolicy
        admitSubscriber fixture owner "i" "subscriber"
        commandWith fixture owner "i" "subscribe" "a" (Just "ticks") Nothing
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "subscribe"

    it "ends only an optional owner whose classifier recognizes it, as unavailable with its own type, and holds nothing" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      onSubscribe fake (\_ → throwIO (Broken "subscribe"))
      withBoundary $ \control runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "optional" [subscriber] (optionalPolicy (brokenIs "subscribe"))
        admitSubscriber fixture owner "i" "subscriber"
        commandWith fixture owner "i" "subscribe" "a" (Just "ticks") Nothing
        awaitScheduledTerminal control owner >>= \case
          WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "subscribe"
          other → fail ("expected an unavailable owner, found " <> show other)
        subscribedCount fake >>= (`shouldBe` 0)
        d ← subDiagnostics owner
        -- Admitted, and taken back: nothing is held for a subscription that never reached its provider.
        (sdLive d, sdCharged d, sdRefusedSubscribe d) `shouldBe` (0, 0, 1)

  describe "a provider that raises when told interest was withdrawn" $ do
    it "is a failure of the host when the script's unsubscribe told it, and it is told once" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      onCancelSub fake (\_ → throwIO (Broken "cancel"))
      ExceptionWithContext _ failure ← expectFatal $ \control runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "cancel" [subscriber] requiredPolicy
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks"
        commandWith fixture owner "i" "unsubscribe" "a" Nothing Nothing
        awaitCancelledSubs fake 1
        finishSubscription fake 0
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "cancel"
      cancelledSubs fake >>= (`shouldBe` [0])

    it "keeps the first as the owner's failure and the rest whole as cleanup evidence when several raise together" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      onCancelSub fake (\index → throwIO (Broken ("cancel " <> Text.pack (show index))))
      ExceptionWithContext context failure ← expectFatal $ \control runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "together" [subscriber] (optionalPolicy (const True))
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks"
        subscribeTo' fixture owner "i" "b" "state"
        _ ← expectControl fixture owner "i" InstanceStop
        awaitCancelledSubs fake 2
        finishSubscription fake 0
        finishSubscription fake 1
        awaitScheduledTerminal control owner
      failure `shouldSatisfy` brokenIs "cancel 0"
      let evidence = [(cleanupFailureLabel found, cleanupFailureException found) | found ← cleanupFailuresInContext context]
      map fst evidence `shouldSatisfy` elem "lua request cancel"
      [exception | ("lua request cancel", exception) ← evidence] `shouldSatisfy` any (brokenAmong "cancel 1")
      -- Both were told, whatever the first raised.
      cancelledSubs fake >>= (`shouldBe` [0, 1])

  describe "a provider's retirement that fails" $ do
    it "is retained as cleanup evidence, fatal under a required and under an optional policy alike" $ bounded $ do
      forM_ [("required", requiredPolicy), ("optional", optionalPolicy (const True))] $ \(label, policy) → do
        fixture ← newIFixture
        fake ← newFakeEvents
        ExceptionWithContext context _ ← expectFatal $ \control runtime → eventsFinish fake $ do
          owner ← ownerWith fixture fake runtime ("retirement " <> label) [subscriber] policy
          admitSubscriber fixture owner "i" "subscriber"
          subscribeTo' fixture owner "i" "a" "ticks"
          commandWith fixture owner "i" "unsubscribe" "a" Nothing Nothing
          awaitCancelledSubs fake 1
          failRetirement fake 0 (ProviderFailed (toException (Broken "retirement")))
          awaitScheduledTerminal control owner
        let evidence = [(cleanupFailureLabel found, cleanupFailureException found) | found ← cleanupFailuresInContext context]
        map fst evidence `shouldSatisfy` any (Text.isInfixOf "subscription")
        map snd evidence `shouldSatisfy` any (brokenAmong "retirement")

  describe "a delivery" $ do
    it "that is not what the endpoint declares, is over the limits, or throws when it is inspected is refused and counted, and never reaches Lua" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "unfit" [subscriber] requiredPolicy
        admitSubscriber fixture owner "i" "subscriber"
        subscribeTo' fixture owner "i" "a" "ticks"
        deliverRaw fake 0 Nothing (VText "not a record") >>= (`shouldBe` EventRefusedValue)
        deliverRaw fake 0 Nothing (VRecord [("n", VText "five")]) >>= (`shouldBe` EventRefusedValue)
        deliverRaw fake 0 Nothing (VRecord [("n", VInteger (error "a value that throws when it is first looked at"))]) >>= (`shouldBe` EventRefusedValue)
        d ← subDiagnostics owner
        sdRefusedValue d `shouldBe` 3
        -- The subscription is alive, and a fit delivery is admitted.
        deliverTo fake 0 Nothing 4 >>= (`shouldBe` EventAdmitted)
        awaitLine fixture "got a n=4 seq=1 t=0"

    it "that is larger than the owner's limits are is refused, whatever the endpoint says" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        let wordy = (fakeEventEndpoint fake "text" OrderedEvents) {eventPayload = SText}
        owner ←
          startWith fixture runtime . withLimits (either (error . show) id (valueLimits 512 8 64)) $
            subscriptionSpec fixture "limits" [subscriber] subConfig SettleOnArrival (SubscriptionGrant [wordy] 4 16) requiredPolicy
        _ ← admitWith fixture owner "i" (InstanceRequest (moduleNamed "subscriber") EventOnly (Just "i") OrdinaryClass ["cmd", "text"])
        awaitPhase fixture owner "i" Active
        subscribeTo' fixture owner "i" "a" "text"
        deliverRaw fake 0 Nothing (VText (Text.replicate 2000 "x")) >>= (`shouldBe` EventRefusedValue)
        (sdRefusedValue <$> subDiagnostics owner) >>= (`shouldBe` 1)

  describe "the life of an instance" $ do
    it "may subscribe in init, and has the subscription revoked when init then fails" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "init fails" [failingInitSubscriber] requiredPolicy
        _ ← admitWith fixture owner "i" (subscriberRequest "i" "failinginitsubscriber")
        awaitSubscribed fake 1
        awaitCancelledSubs fake 1
        finishSubscription fake 0
        settled ← awaitSettled fixture "i"
        resultPhase settled `shouldBe` Failed
        deliverTo fake 0 Nothing 1 >>= (`shouldBe` EventEnded)

    it "is refused a subscription in its shutdown hook, which is past taking them, and the provider is asked nothing" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "shutdown" [shutdownSubscriber] requiredPolicy
        admitSubscriber fixture owner "i" "shutdownsubscriber"
        void (settleControl fixture owner "i" InstanceStop)
        awaitLine fixture "shutdown stopped"
        -- The hook raised the engine's refusal, so the instance ends as failed, and the provider was
        -- never asked.
        settled ← awaitSettled fixture "i"
        resultPhase settled `shouldBe` Failed
        refusalOf fixture "i" >>= (`shouldSatisfy` maybe False (Text.isInfixOf "no longer taking subscriptions"))
        linesOf fixture >>= (`shouldSatisfy` notElem "shutdown after")
        subscribedCount fake >>= (`shouldBe` 0)

    it "has a one-shot's subscription revoked when the one-shot completes" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      withBoundary $ \_ runtime → eventsFinish fake $ do
        owner ← ownerWith fixture fake runtime "one-shot" [oneShotSubscriber] requiredPolicy
        _ ← admitWith fixture owner "i" (InstanceRequest (moduleNamed "oneshotsubscriber") RunOnce (Just "i") OrdinaryClass ["ticks"])
        awaitSubscribed fake 1
        awaitCancelledSubs fake 1
        -- It completed; the provider has not said its retirement is over.
        finishSubscription fake 0
        settled ← awaitSettled fixture "i"
        resultPhase settled `shouldBe` Completed

  describe "a subscription grant" $ do
    it "is refused before anything starts when it does not make sense, naming the reasons" $ bounded $ do
      fixture ← newIFixture
      fake ← newFakeEvents
      let refusedWith label change wanted = do
            outcome ← tryWithContext @SomeException $ withBoundary $ \_ runtime → eventsFinish fake $
              startWith fixture runtime (change (subscriptionSpec fixture label [subscriber] subConfig SettleOnArrival (subGrant fake 4 16) requiredPolicy))
            case outcome of
              Left (ExceptionWithContext _ failure) → show failure `shouldSatisfy` Text.isInfixOf wanted . Text.pack
              Right _ → fail ("expected the grant refused: " <> Text.unpack wanted)
      refusedWith "bounds" (\spec' → spec' {scheduledSubscriptions = Just (SubscriptionGrant (allEndpoints fake) 0 0)}) "SubscriptionBoundOutOfRange 0"
      refusedWith "staging" (\spec' → spec' {scheduledSubscriptions = Just (SubscriptionGrant (allEndpoints fake) 4 0)}) "StagingBoundOutOfRange 0"
      refusedWith "none" (\spec' → spec' {scheduledSubscriptions = Just (SubscriptionGrant [] 4 16)}) "NoEventEndpoints"
      refusedWith "twice" (\spec' → spec' {scheduledSubscriptions = Just (SubscriptionGrant [ticksEndpoint fake, ticksEndpoint fake] 4 16)}) "DuplicateEventName \"ticks\""
      refusedWith "name" (\spec' → spec' {scheduledSubscriptions = Just (SubscriptionGrant [fakeEventEndpoint fake "not a name" OrderedEvents] 4 16)}) "InvalidEventName"
      refusedWith "capability" (\spec' → spec' {scheduledSubscriptions = Just (SubscriptionGrant [(ticksEndpoint fake) {eventPayload = SCapability "handle"}] 4 16)}) "EventPayloadCapability"
      refusedWith "no service" (\spec' → spec' {scheduledRequests = Nothing}) "SubscriptionsNeedService"
      refusedWith "no instances" (\spec' → spec' {scheduledInstances = Nothing}) "SubscriptionsNeedInstances"
      refusedWith "too many" (\spec' → spec' {scheduledSubscriptions = Just (SubscriptionGrant [fakeEventEndpoint fake ("e" <> Text.pack (show n)) OrderedEvents | n ← [1 .. 70 ∷ Int]] 4 16)}) "TooManyEventEndpoints"
