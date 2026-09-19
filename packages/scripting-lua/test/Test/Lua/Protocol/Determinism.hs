-- | The model is a function of its inputs.
--
-- The same sequence of admitted inputs and applied outcomes has to produce the
-- same states, the same ordinals, and the same records, with nothing read from
-- a clock, a thread, or the environment. The examples here run one scripted
-- sequence twice and compare the whole session value, which is the strongest
-- form of that claim this model can state about itself.
module Test.Lua.Protocol.Determinism (spec) where

import Data.Text (Text)
import qualified Data.Map.Strict as Map
import Hetoimasia.Scripting.Lua.Internal.Protocol.Identity
  ( EndpointId (EndpointId)
  , Ordinal
  , RequestName (RequestName)
  , SubscriptionName (SubscriptionName)
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Request (Reply (ReplyResult))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Session
  ( Session (sessionNextOrdinal, sessionTasks)
  , acceptRequest
  , applyOutcome
  , applyReplyIn
  , deliverEvent
  , registerSubscription
  , startSegment
  , stopSession
  , wakeTaskIn
  )
import Hetoimasia.Scripting.Lua.Internal.Protocol.Subscription (OverloadPolicy (ReplaceableState))
import Hetoimasia.Scripting.Lua.Internal.Protocol.Task
  ( SegmentOutcome (SegmentWaiting, SegmentYielded)
  , Task (taskOrdinal)
  , WaitCause (WaitingOnRequest)
  )
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Lua.Protocol.Support
  ( admitted
  , message
  , ok
  , openSessionWith
  , roomyLimits
  , runningTask
  )

-- | One scripted run: admissions, segments, a request, an event, and a wake.
scripted ∷ IO (Session Text)
scripted = do
  session ← openSessionWith roomyLimits
  (a, first) ← runningTask 1 session
  (b, second) ← admitted 2 a
  (c, request) ← ok (acceptRequest first (RequestName 1) (EndpointId "provider") b)
  (d, subscription) ← ok (registerSubscription first (SubscriptionName 1) (EndpointId "events") ReplaceableState c)
  (e, _) ← ok (deliverEvent subscription (message 2 "v1") d)
  (f, _) ← ok (deliverEvent subscription (message 2 "v2") e)
  (g, ()) ← ok (applyOutcome first (SegmentWaiting "held" (WaitingOnRequest request)) f)
  (h, ()) ← ok (applyReplyIn request (ReplyResult (message 3 "answer")) g)
  (i, ()) ← ok (wakeTaskIn first h)
  (j, ()) ← ok (startSegment second i)
  (k, ()) ← ok (applyOutcome second (SegmentYielded "moved") j)
  pure k

spec ∷ Spec
spec = describe "determinism" $ do
  it "produces the same session from the same sequence of inputs" $ do
    once ← scripted
    twice ← scripted
    once `shouldBe` twice

  it "produces the same exit record from the same sequence of inputs" $ do
    once ← scripted
    twice ← scripted
    snd (stopSession once) `shouldBe` snd (stopSession twice)

  it "issues ordinals in one monotonic sequence, reused by nothing" $ do
    final ← scripted
    let ordinals = map taskOrdinal (Map.elems (sessionTasks final))
    length ordinals `shouldBe` 2
    distinct ordinals `shouldBe` True
    all (< sessionNextOrdinal final) ordinals `shouldBe` True
  where
    distinct ∷ [Ordinal] → Bool
    distinct values = length (Map.keys (Map.fromList [(value, ()) | value ← values])) == length values
