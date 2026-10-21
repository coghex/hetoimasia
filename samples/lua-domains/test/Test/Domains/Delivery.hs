-- | What the session does with events a provider delivers to a gameplay instance (#499 requirement 7): the sample's
-- application assigns each event the tick whose boundary admits it; an event the store has no place for is refused when it
-- is offered, counted by the engine and failing nothing; and a delivery the instance cannot be handed (ordered
-- events beyond its queue) fails the instance, and so the session, with a delivery failure as the evidence.
--
-- The provider is a test-only fake the examples drive by hand, granted to the gameplay owner through its specification.
module Test.Domains.Delivery (spec) where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry, writeTVar)
import Control.Exception (finally)
import Control.Monad (forM)
import Data.Text (Text)
import Hetoimasia.Sample.LuaDomains
  ( Domains
  , DomainsConfig (configGameplayInstances, configGameplayModules, configGameplaySpec, configInput)
  , GameSnapshot (snapStatus)
  , SessionStatus (Failed, Running)
  , TickOutcome (TickFailed)
  , stepTick
  )
import Hetoimasia.Sample.LuaDomains.Scripts (moduleSource)
import Hetoimasia.Sample.LuaDomains.Snapshot (FailureEvidence (evidencePrimary), SessionFailure (failKind))
import Hetoimasia.Scripting.Lua.Instance (InstanceKind (EventOnly), InstanceRequest (..))
import Hetoimasia.Scripting.Lua.Owner (ModuleRef (ModuleRef))
import Hetoimasia.Scripting.Lua.Provider
  ( DueSlot (DueSlot)
  , EventAnswer (EventStaged, EventStagingFull)
  , EventEndpoint (..)
  , EventFeed (feedDeliver)
  , EventSubscription (subscriptionFeed)
  , OverloadPolicy (OrderedEvents)
  , ProviderWork (..)
  , RequestEndpoint (..)
  , RequestGrant (RequestGrant)
  , RequestTiming (SettleAtAssignedTick)
  , RetirementState (ProviderComplete, ProviderPending)
  , SubscriptionGrant (SubscriptionGrant)
  )
import Hetoimasia.Scripting.Lua.Scheduled (ScheduledSpec (scheduledRequests, scheduledSubscriptions), ServiceClass (OrdinaryClass))
import Hetoimasia.Scripting.Lua.Value (Schema (SInteger, SRecord), Value (VInteger, VRecord))
import Test.Domains.Support
import Test.Hspec

-- | The feeds the provider was handed, and what it was told of their end.
data Fake = Fake
  { fakeFeeds ∷ TVar [EventFeed]
  , fakeRetired ∷ TVar Bool
  }

newFake ∷ IO Fake
newFake = Fake <$> newTVarIO [] <*> newTVarIO False

-- | The endpoint @ticks@, delivering @{n = integer}@ as ordered events.
ticks ∷ Fake → EventEndpoint
ticks fake =
  EventEndpoint
    { eventName = "ticks"
    , eventPayload = SRecord [("n", SInteger)]
    , eventPolicy = OrderedEvents
    , eventSubscribe = \subscription → do
        atomically (modifyTVar' (fakeFeeds fake) (<> [subscriptionFeed subscription]))
        pure
          ProviderWork
            { workCancel = pure ()
            , workRetirement = readTVar (fakeRetired fake) >>= \done → pure (if done then ProviderComplete else ProviderPending)
            }
    }

-- | The owner's specification granted the fake's endpoint, on logical time, with room to hold this many events.
granted ∷ Fake → Int → ScheduledSpec → ScheduledSpec
granted fake staging base =
  base
    { scheduledRequests = Just (RequestGrant [unused] 4 (SettleAtAssignedTick Nothing))
    , scheduledSubscriptions = Just (SubscriptionGrant [ticks fake] 4 staging)
    }
  where
    unused = RequestEndpoint "unused" SInteger (\_ → pure ProviderWork {workCancel = pure (), workRetirement = pure ProviderComplete})

-- | An instance beside the behavior that subscribes to @ticks@ and records what it is handed.
subscriber ∷ (InstanceRequest, Text)
subscriber = (InstanceRequest (ModuleRef "extra" "1") EventOnly (Just "subscriber") OrdinaryClass ["ticks"], "extra")

subscriberLines ∷ [Text]
subscriberLines =
  [ "function init(self, api)"
  , "  api.subscribe('ticks', function(self, ev) fx.record('got ' .. ev.payload.n) end)"
  , "end"
  ]

-- | The nth event of a tick: its place and its value.
deliverAt ∷ Fake → Int → Int → Int → IO EventAnswer
deliverAt fake tick place n = do
  feeds ← readTVarIO (fakeFeeds fake)
  case feeds of
    feed : _ → feedDeliver feed (Just (DueSlot (fromIntegral tick) (fromIntegral place))) (VRecord [("n", VInteger (fromIntegral n))])
    [] → fail "the provider was handed no subscription"

awaitFeed ∷ Fake → IO ()
awaitFeed fake = waitFor (readTVar (fakeFeeds fake) >>= \feeds → if null feeds then retry else pure ())

-- | The provider proves its work over however the body ends, before the session retires its owners: an owner
-- that ends waits for the provider to prove the work it was handed over, and so would wait for ever.
retiring ∷ Fake → IO a → IO a
retiring fake body = body `finally` atomically (writeTVar (fakeRetired fake) True)

-- | A session whose gameplay owner is granted the fake's endpoint, with room to hold this many events, and an
-- instance beside the behavior that subscribes to it.
withEvents ∷ Fake → Int → (Fx → Domains → IO a) → IO a
withEvents fake staging body =
  withSample
    ( \config →
        config
          { configInput = []
          , configGameplaySpec = granted fake staging
          , configGameplayInstances = [fst subscriber]
          , configGameplayModules = [moduleSource (snd subscriber) (luaLines subscriberLines)]
          }
    )
    (\fx _ domains → retiring fake (body fx domains))

spec ∷ Spec
spec = describe "events a provider delivers to a gameplay instance" $ do
  it "refuses an event the store has no place for when it is offered, explicitly, and nothing fails: the held events are delivered at their tick" $ do
    fake ← newFake
    withEvents fake 2 $ \fx domains → do
      awaitFeed fake
      answers ← forM [0, 1, 2] $ \place → deliverAt fake 1 place (10 + place)
      answers `shouldBe` [EventStaged, EventStaged, EventStagingFull]
      snapshot ← stepCommitted domains
      snapStatus snapshot `shouldBe` Running
      fxLines fx `shouldReturn` ["got 10", "got 11"]

  it "fails the session with a delivery failure when ordered events for one tick exceed the instance's queue, and no event is dropped silently" $ do
    fake ← newFake
    withEvents fake 16 $ \_ domains → do
      awaitFeed fake
      answers ← forM (reverse [0 .. 9]) $ \place → deliverAt fake 1 place (100 + place)
      answers `shouldBe` replicate 10 EventStaged
      -- The provider proves its work over, as it does when told interest was withdrawn.
      atomically (writeTVar (fakeRetired fake) True)
      outcome ← stepTick domains
      case outcome of
        TickFailed snapshot → do
          snapStatus snapshot `shouldSatisfy` \case Failed _ → True; _ → False
          fmap (failKind . evidencePrimary) (case snapStatus snapshot of Failed found → Just found; _ → Nothing) `shouldBe` Just "delivery failure"
        other → expectationFailure ("expected the session to fail, found " <> show other)
