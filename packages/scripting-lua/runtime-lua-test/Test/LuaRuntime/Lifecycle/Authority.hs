-- | What a grant is the whole of: one registration shared by owners with different
-- grants, the refusal of what the grant does not cover without a word of whether it
-- exists, and the refusal of a grant that does not make sense.
module Test.LuaRuntime.Lifecycle.Authority (spec) where

import Control.Exception (SomeException, fromException, try)
import Data.List.NonEmpty (toList)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lifecycle
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VRecord))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Lifecycle.Support
import Test.LuaRuntime.Scheduled.Support (defaultSchedulerBounds, scheduled, startScheduled)
import Test.LuaRuntime.Support (bounded, requiredPolicy, withBoundary)

unauthorized ∷ Text
unauthorized = "{accepted=false,refusal=unauthorized}"

unknownTarget ∷ Text
unknownTarget = "{accepted=false,refusal=unknown_target}"

-- | The violations a grant is refused with.
refusedWith ∷ IFixture → LuaRuntime → InstanceConfig → LifecycleGrant → IO [LifecycleViolation]
refusedWith fixture runtime config grant = do
  outcome ← try @SomeException (startWith fixture runtime (lifeSpec fixture (lifeRegistration fixture) "refused" [echoer] config (Just grant)))
  case outcome of
    Left failure → case fromException failure of
      Just (LifecycleRefused violations) → pure (toList violations)
      Nothing → fail ("expected the refusal of the grant, found " <> show failure)
    Right _ → fail "the grant should have been refused"

spec ∷ Spec
spec = describe "authority" $ do
  it "gives owners with different grants of one shared registration exactly what each was granted, and an owner with none keeps the not-yet-supported refusal" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      tid ← tidValue targetFx "a"
      let one = lifeRegistration callerFx
      inspector ← startCallerWith callerFx one runtime "inspector" (Just (lifecycleGrant [grantOver owner [PermitInspect]]))
      controller ← startCallerWith callerFx one runtime "controller" (Just (lifecycleGrant [grantOver owner [PermitControl]]))
      plain ← startCallerWith callerFx one runtime "plain" Nothing
      admitCommander callerFx inspector "inspecting"
      admitCommander callerFx controller "controlling"
      admitCommander callerFx plain "plain"
      -- Inspection only: it sees, and cannot control.
      ask callerFx inspector "inspecting" "pause" (Just tid) Nothing >>= (`shouldBe` unauthorized)
      ask callerFx inspector "inspecting" "inspect" (Just tid) Nothing >>= (`shouldSatisfy` Text.isInfixOf "status=active")
      phaseOf targetFx owner "a" >>= (`shouldBe` Just Active)
      -- Control only: it controls, and cannot see.
      ask callerFx controller "controlling" "inspect" (Just tid) Nothing >>= (`shouldBe` "{ok=false,refusal=unauthorized}")
      ask callerFx controller "controlling" "inspect_owner" (Just tid) Nothing >>= (`shouldBe` "{instances={},ok=false,refusal=unauthorized,truncated=false}")
      ask callerFx controller "controlling" "pause" (Just tid) Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      awaitPhase targetFx owner "a" Paused
      -- Granted nothing, the call is the typed fault it always was, and nothing ran: the
      -- target was asked nothing more.
      tell callerFx plain "plain" "resume" (Just tid) Nothing
      awaitSettled callerFx "plain" >>= (`shouldSatisfy` notYetSupported)
      phaseOf targetFx owner "a" >>= (`shouldBe` Just Paused)

  it "refuses what no grant covers without testing it: an owner outside the grant, a foreign runtime's identity and an identity never issued answer alike, and only within the grant is a stale one unknown" $ bounded $ do
    targetFx ← newIFixture
    otherFx ← newIFixture
    callerFx ← newIFixture
    foreignFx ← newIFixture
    withBoundary $ \_ runtime → do
      covered ← startTarget targetFx runtime "covered" [echoer] (testConfig instanceBounds')
      outside ← startTarget otherFx runtime "outside" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx covered "a" (moduleNamed "echoer")
      _ ← admit otherFx outside "b" (moduleNamed "echoer")
      awaitPhase targetFx covered "a" Active
      awaitPhase otherFx outside "b" Active
      a ← tidValue targetFx "a"
      b ← tidValue otherFx "b"
      caller ← startCaller callerFx runtime "caller" (Just (target covered))
      admitCommander callerFx caller "cmdr"
      -- A foreign runtime's identity: a live instance of another runtime's owner.
      foreignTid ← withBoundary $ \_ foreignRuntime → do
        foreignOwner ← startTarget foreignFx foreignRuntime "foreign" [echoer] (testConfig instanceBounds')
        _ ← admit foreignFx foreignOwner "f" (moduleNamed "echoer")
        awaitPhase foreignFx foreignOwner "f" Active
        tidValue foreignFx "f"
      let numbers = \case
            VRecord [("runtime", VInteger r), ("owner", VInteger o), ("id", VInteger i)] → (r, o, i)
            _ → (0, 0, 0)
          (_, coveredOwner, _) = numbers a
          (runtimeNumber, outsideOwner, _) = numbers b
          forged owner local = VRecord [("runtime", VInteger runtimeNumber), ("owner", VInteger owner), ("id", VInteger local)]
      -- The same answer whether it is live, never issued, the covered owner's number with
      -- another's, or of another runtime: nothing is tested of the target.
      answers ←
        mapM
          (\tid → ask callerFx caller "cmdr" "pause" (Just tid) Nothing)
          [b, forged outsideOwner 999, forged 12345 1, foreignTid, forged (coveredOwner + 1000) 1]
      answers `shouldBe` replicate 5 unauthorized
      inspected ← mapM (\tid → ask callerFx caller "cmdr" "inspect" (Just tid) Nothing) [b, forged outsideOwner 999, foreignTid]
      inspected `shouldBe` replicate 3 "{ok=false,refusal=unauthorized}"
      -- Nothing was asked of the instance outside the grant, or of the foreign one.
      phaseOf otherFx outside "b" >>= (`shouldBe` Just Active)
      -- Within the grant a stale identity is unknown, and a live one is taken.
      ask callerFx caller "cmdr" "pause" (Just (forged coveredOwner 999)) Nothing >>= (`shouldBe` unknownTarget)
      ask callerFx caller "cmdr" "inspect" (Just (forged coveredOwner 999)) Nothing >>= (`shouldBe` "{ok=false,refusal=unknown_target}")
      _ ← settleControl targetFx covered "a" InstanceStop
      _ ← awaitSettled targetFx "a"
      ask callerFx caller "cmdr" "pause" (Just a) Nothing >>= (`shouldBe` unknownTarget)

  it "routes by identity and never by label: two owners with one label are told apart, and the grant covers only the one it names" $ bounded $ do
    firstFx ← newIFixture
    secondFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      first ← startTarget firstFx runtime "same label" [echoer] (testConfig instanceBounds')
      second ← startTarget secondFx runtime "same label" [echoer] (testConfig instanceBounds')
      _ ← admit firstFx first "a" (moduleNamed "echoer")
      _ ← admit secondFx second "b" (moduleNamed "echoer")
      awaitPhase firstFx first "a" Active
      awaitPhase secondFx second "b" Active
      a ← tidValue firstFx "a"
      b ← tidValue secondFx "b"
      caller ← startCaller callerFx runtime "caller" (Just (target first))
      admitCommander callerFx caller "cmdr"
      ask callerFx caller "cmdr" "pause" (Just b) Nothing >>= (`shouldBe` unauthorized)
      phaseOf secondFx second "b" >>= (`shouldBe` Just Active)
      ask callerFx caller "cmdr" "pause" (Just a) Nothing >>= (`shouldBe` "{accepted=true,receipt=0}")
      awaitPhase firstFx first "a" Paused
      phaseOf secondFx second "b" >>= (`shouldBe` Just Active)
      -- Both are called by the one label the application gave them.
      ask callerFx caller "cmdr" "inspect" (Just a) Nothing >>= (`shouldSatisfy` Text.isInfixOf "owner=same label")

  it "never reads who is calling from what the script passes: a call carrying a field of its own is refused as a fault at the boundary, and asked nothing" $ bounded $ do
    targetFx ← newIFixture
    callerFx ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startTarget targetFx runtime "target" [echoer] (testConfig instanceBounds')
      _ ← admit targetFx owner "a" (moduleNamed "echoer")
      awaitPhase targetFx owner "a" Active
      a ← tidValue targetFx "a"
      caller ← startCaller callerFx runtime "caller" (Just (target owner))
      _ ← admitWith callerFx caller "forger" (InstanceRequest (moduleNamed "commanderfailing") EventOnly (Just "forger") OrdinaryClass ["cmd"])
      awaitPhase callerFx caller "forger" Active
      tell callerFx caller "forger" "pause" (Just a) Nothing
      settled ← awaitSettled callerFx "forger"
      failureOf' settled `shouldSatisfy` isJust
      phaseOf targetFx owner "a" >>= (`shouldBe` Just Active)

  describe "a grant that does not make sense" $
    it "is refused before anything starts, naming every reason" $ bounded $ do
      fixture ← newIFixture
      peerFx ← newIFixture
      bareFx ← newIFixture
      withBoundary $ \_ runtime → do
        peer ← startTarget peerFx runtime "peer" [echoer] (testConfig instanceBounds')
        bare ← startScheduled (sf bareFx) runtime (scheduled (sf bareFx) "bare" requiredPolicy defaultSchedulerBounds)
        logical ← startTarget peerFx runtime "logical" [echoer] ((testConfig instanceBounds') {instanceControlAdmission = AdmitLogically})
        let config = testConfig instanceBounds'
            peerTarget = grantOver peer bothPermits
        refusedWith fixture runtime config (LifecycleGrant [peerTarget] 0 0)
          >>= (`shouldBe` [GrantBoundBelowOne "receipt bound" 0, GrantBoundBelowOne "snapshot bound" 0])
        refusedWith fixture runtime config (lifecycleGrant [peerTarget, peerTarget]) >>= (`shouldBe` [GrantDuplicateTarget "peer"])
        refusedWith fixture runtime config (lifecycleGrant [GrantTarget (GrantedEndpoint (scheduledEndpoint peer)) [] Nothing]) >>= (`shouldBe` [GrantNoPermits "peer"])
        refusedWith fixture runtime config (lifecycleGrant [grantOver peer [PermitInspect, PermitInspect]]) >>= (`shouldBe` [GrantRepeatedPermit "peer"])
        refusedWith fixture runtime config (lifecycleGrant [grantOver bare bothPermits]) >>= (`shouldBe` [GrantHostsNoInstances "bare"])
        refusedWith fixture runtime config (lifecycleGrant [GrantTarget GrantedSelf [] Nothing]) >>= (`shouldSatisfy` (GrantNoPermits "refused" `elem`))
        -- A permitted control of an owner that admits logically, with no assignment to place it.
        refusedWith fixture runtime config (lifecycleGrant [grantOver logical bothPermits]) >>= (`shouldBe` [GrantNeedsAssignment "logical"])
        -- An assignment for an owner that does not admit logically.
        refusedWith fixture runtime config (lifecycleGrant [GrantTarget (GrantedEndpoint (scheduledEndpoint peer)) bothPermits (Just (\_ → pure Nothing))])
          >>= (`shouldBe` [GrantAssignsNothing "peer"])
        -- A foreign runtime's owner.
        foreignFx ← newIFixture
        foreignEndpoint ← withBoundary $ \_ foreignRuntime → do
          foreignOwner ← startTarget foreignFx foreignRuntime "foreign" [echoer] (testConfig instanceBounds')
          pure (scheduledEndpoint foreignOwner)
        refusedWith fixture runtime config (lifecycleGrant [GrantTarget (GrantedEndpoint foreignEndpoint) bothPermits Nothing])
          >>= (`shouldBe` [GrantForeignRuntime "foreign"])
