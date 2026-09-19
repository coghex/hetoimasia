-- | D-8's isolation: equal local numbers in different mods, domains, sessions,
-- or generations name different records and cannot reach one another.
--
-- The protection has to survive observation and reclamation too, because that
-- is when a local number is most likely to be reused while a reply to the old
-- one is still in flight.
module Test.Lua.Protocol.Isolation (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , Generation (Generation)
  , RequestName (RequestName)
  , SessionKey
  , SubscriptionName (SubscriptionName)
  , firstGeneration
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request
  ( Reply (ReplyResult)
  , RequestRecord (requestSettlement)
  , Settlement (SettledResult)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Session (sessionRequests, sessionSubscriptions, sessionTasks)
  , SessionRejection (UnknownRequest, UnknownSubscription, UnknownTask)
  , acceptRequest
  , applyReplyIn
  , cancelTaskIn
  , deliverEvent
  , observeRequestIn
  , registerSubscription
  , startSegment
  , unsubscribeIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription
  ( OverloadPolicy (OrderedEvents)
  , subscriptionBacklog
  )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Protocol.Support
  ( gameplay
  , interfaceSide
  , message
  , ok
  , openSessionAt
  , otherMod
  , otherSession
  , rejected
  , runningTask
  , sampleLimits
  )

endpoint ∷ EndpointId
endpoint = EndpointId "provider.sample"

-- | The three scopes that share every local number with 'gameplay'.
neighbours ∷ [(String, SessionKey)]
neighbours =
  [ ("another domain", interfaceSide)
  , ("another mod", otherMod)
  , ("another session", otherSession)
  ]

spec ∷ Spec
spec = describe "isolation" $ do
  it "gives equal local task numbers different identities in every neighbouring scope" $
    sequence_
      [ do
          ours ← openSessionAt gameplay sampleLimits
          theirs ← openSessionAt scope sampleLimits
          (_, mine) ← runningTask 1 ours
          (yours, yoursId) ← runningTask 1 theirs
          (label, mine == yoursId) `shouldBe` (label, False)
          (_, refusal) ← rejected (startSegment mine yours)
          (label, refusal) `shouldBe` (label, UnknownTask mine)
      | (label, scope) ← neighbours
      ]

  it "will not settle a neighbour's request with an equal local number" $
    sequence_
      [ do
          ours ← openSessionAt gameplay sampleLimits
          theirs ← openSessionAt scope sampleLimits
          (a, mine) ← runningTask 1 ours
          (_, myRequest) ← ok (acceptRequest mine (RequestName 1) firstGeneration endpoint a)
          (b, yoursTask) ← runningTask 1 theirs
          (c, _) ← ok (acceptRequest yoursTask (RequestName 1) firstGeneration endpoint b)
          (d, refusal) ← rejected (applyReplyIn myRequest (ReplyResult (message 1 "mine")) c)
          (label, refusal) `shouldBe` (label, UnknownRequest myRequest)
          (label, fmap requestSettlement (onlyRequest d)) `shouldBe` (label, Just Nothing)
      | (label, scope) ← neighbours
      ]

  it "will not deliver to a neighbour's subscription with an equal local number" $
    sequence_
      [ do
          ours ← openSessionAt gameplay sampleLimits
          theirs ← openSessionAt scope sampleLimits
          (a, mine) ← runningTask 1 ours
          (_, mySubscription) ← ok (registerSubscription mine (SubscriptionName 1) firstGeneration endpoint OrderedEvents a)
          (b, yoursTask) ← runningTask 1 theirs
          (c, _) ← ok (registerSubscription yoursTask (SubscriptionName 1) firstGeneration endpoint OrderedEvents b)
          (_, refusal) ← rejected (deliverEvent mySubscription (message 1 "mine") c)
          (label, refusal) `shouldBe` (label, UnknownSubscription mySubscription)
      | (label, scope) ← neighbours
      ]

  it "will not invalidate a neighbour's records by cancelling an equal local task" $
    sequence_
      [ do
          ours ← openSessionAt gameplay sampleLimits
          theirs ← openSessionAt scope sampleLimits
          (_, mine) ← runningTask 1 ours
          (a, yoursTask) ← runningTask 1 theirs
          (b, _) ← ok (registerSubscription yoursTask (SubscriptionName 1) firstGeneration endpoint OrderedEvents a)
          (_, refusal) ← rejected (cancelTaskIn mine b)
          (label, refusal) `shouldBe` (label, UnknownTask mine)
          (label, Map.size (sessionSubscriptions b)) `shouldBe` (label, 1)
          (label, Map.size (sessionTasks b)) `shouldBe` (label, 1)
      | (label, scope) ← neighbours
      ]

  it "keeps a reused local number safe from a reply to the identity it replaced" $ do
    session ← openSessionAt gameplay sampleLimits
    (a, owner) ← runningTask 1 session
    (b, older) ← ok (acceptRequest owner (RequestName 1) firstGeneration endpoint a)
    (c, ()) ← ok (applyReplyIn older (ReplyResult (message 1 "first")) b)
    (d, settled) ← ok (observeRequestIn older c)
    settled `shouldBe` SettledResult (message 1 "first")
    Map.member older (sessionRequests d) `shouldBe` False
    (e, newer) ← ok (acceptRequest owner (RequestName 1) (Generation 1) endpoint d)
    (older == newer) `shouldBe` False
    (f, refusal) ← rejected (applyReplyIn older (ReplyResult (message 1 "delayed")) e)
    refusal `shouldBe` UnknownRequest older
    fmap requestSettlement (Map.lookup newer (sessionRequests f)) `shouldBe` Just Nothing

  it "keeps a reused subscription number safe from a delivery to the one it replaced" $ do
    session ← openSessionAt gameplay sampleLimits
    (a, owner) ← runningTask 1 session
    (b, older) ← ok (registerSubscription owner (SubscriptionName 1) firstGeneration endpoint OrderedEvents a)
    (c, _) ← ok (unsubscribeIn older b)
    (d, newer) ← ok (registerSubscription owner (SubscriptionName 1) (Generation 1) endpoint OrderedEvents c)
    (older == newer) `shouldBe` False
    (e, refusal) ← rejected (deliverEvent older (message 1 "late") d)
    refusal `shouldBe` UnknownSubscription older
    fmap subscriptionBacklog (Map.lookup newer (sessionSubscriptions e)) `shouldBe` Just 0
  where
    onlyRequest ∷ Session Text → Maybe (RequestRecord Text)
    onlyRequest session = case Map.elems (sessionRequests session) of
      [record] → Just record
      _ → Nothing
