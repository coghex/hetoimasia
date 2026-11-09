-- | The opt-in settlement seam and the declining hand-off (TRA-5): a provider that commits a change at a request's settlement reads
-- the request's eligibility and settles it in its own transaction, so that a script's cancel and the commit are one arbitration; a
-- provider that cannot reserve its own banks inside the engine's admission declines the request and the admission is taken back whole.
module Test.LuaRuntime.Admission.Seam (spec) where

import Control.Concurrent.STM (atomically, newTVarIO, readTVar, retry, writeTVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Control.Exception (throwIO)
import qualified Data.Text as Text
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Control.Monad (forM_, unless, void, when)
import Hetoimasia.Scripting.Lua.Admission
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Lease (Ownership (..))
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Scheduled (grantScheduledStep, scheduledEndpoint)
import Hetoimasia.Scripting.Lua.Value (Value (VInteger, VText))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Admission.Support
import Test.LuaRuntime.Instance.Support (expectControl, grantOne)
import Test.LuaRuntime.Request.Support (awaitDiagnostic, diagnostics, finishWork, onSubmit, submissions)
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Scheduler.Support (nanoseconds)
import Test.LuaRuntime.Support (bounded, expectFatal, requiredPolicy, withBoundary)

-- | The seam of the request the provider was last handed.
captured ∷ IORef (Maybe Settling) → Submission → IO ()
captured ref submission = writeIORef ref (submissionSettling submission)

spec ∷ Spec
spec = describe "the settlement seam and the declining hand-off" $ do
  it "takes a request back whole when the provider declines it as busy, and a later call may succeed" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "declines" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      onSubmit (afFake fixture) (\_ → throwIO (DeclinedBusy "terrain arenas"))
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a busy:busy"
      -- Nothing is held, and nothing reached the provider as an accepted request.
      d ← diagnostics owner
      (rdOutstanding d, rdHeld d, rdBusy d, rdRefused d) `shouldBe` (0, 0, 0, 0)
      -- The provider has room again: the same call is accepted.
      onSubmit (afFake fixture) (\_ → pure ())
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"

  it "settles an eligible request in the provider's own transaction, and a cancel that came first leaves nothing eligible" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "seam" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seam ← newIORef Nothing
      onSubmit (afFake fixture) (captured seam)
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      Just settling ← readIORef seam
      -- On elapsed time a request that is waiting is eligible, and settling it needs no position.
      atomically (settlingEligible settling) >>= (`shouldBe` True)
      atomically (settlingSettle settling (ProviderResult (VInteger 7))) >>= (`shouldBe` ReplySettled)
      atomically (settlingEligible settling) >>= (`shouldBe` False)
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=success,value={v=7}}"
      -- A second request: the script's cancel wins first, so it is no longer eligible and the commit would not be made.
      onSubmit (afFake fixture) (captured seam)
      acommand fixture owner "i" "start" "b"
      awaitNote fixture "cmd start b started"
      Just second ← readIORef seam
      atomically (settlingEligible second) >>= (`shouldBe` True)
      acommand fixture owner "i" "cancel" "b"
      awaitNote fixture "cmd cancel b cancelled"
      atomically (settlingEligible second) >>= (`shouldBe` False)
      submissions (afFake fixture) >>= (`shouldBe` 2)

  it "judges a reply as its settlement would, without writing anything, so a provider can refuse before it commits" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "judges" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seam ← newIORef Nothing
      onSubmit (afFake fixture) (captured seam)
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      Just settling ← readIORef seam
      -- A reply the request's result schema takes is one the host would settle with; one it does not take, and a failure with no
      -- code the service declared, are the provider's defects.
      settlingJudge settling (ProviderResult (VInteger 7)) `shouldBe` True
      settlingJudge settling (ProviderResult (VText "not an integer")) `shouldBe` False
      settlingJudge settling (ProviderFailure "an accounting defect") `shouldBe` False
      -- Judging wrote nothing: the request is still waiting, no defect was recorded, and its settlement is still the first.
      atomically (settlingEligible settling) >>= (`shouldBe` True)
      d ← diagnostics owner
      rdDefects d `shouldBe` 0
      atomically (settlingSettle settling (ProviderResult (VInteger 7))) >>= (`shouldBe` ReplySettled)

  it "settles a request without proving the provider's work over, so that its places return only when the provider's retirement says so" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "keeps" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seam ← newIORef Nothing
      onSubmit (afFake fixture) (captured seam)
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      Just settling ← readIORef seam
      atomically (settlingSettleKeeping settling (ProviderResult (VInteger 7))) >>= (`shouldBe` ReplySettled)
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=success,value={v=7}}"
      -- the request settled and was taken, and the provider has not said its work is over (it still holds what it borrowed): the work stays
      d ← diagnostics owner
      rdWorkPending d `shouldBe` 1
      -- the provider's retirement says so: the work is over
      finishWork (afFake fixture) 0
      awaitDiagnostic owner ((== 0) . rdWorkPending)

  it "holds a reply made before its tick without proving the provider's work over: invisible until the tick, and its work stays polled through the tick's service" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \control runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "keeps late" [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seam ← newIORef Nothing
      onSubmit (afFake fixture) (captured seam)
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      Just settling ← readIORef seam
      -- the reply arrives before the request's place: it is held for it, and a held completion made while the provider's work remains is
      -- not proof that the work is over
      atomically (settlingSettleKeeping settling (ProviderResult (VInteger 7))) >>= (`shouldBe` ReplyHeld)
      -- it is not visible until the place is reached
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=pending}"
      d ← diagnostics owner
      rdWorkPending d `shouldBe` 1
      -- the place is reached and served: the script takes it, and the provider's work is still not over
      grantOne control owner
      acommand fixture owner "i" "take" "a"
      awaitNote fixture "cmd take a {status=success,value={v=7}}"
      d' ← diagnostics owner
      rdWorkPending d' `shouldBe` 1
      finishWork (afFake fixture) 0
      awaitDiagnostic owner ((== 0) . rdWorkPending)

  -- Every way a request ends while a completion made with the provider's work remaining is held for its tick: none proves the work over.
  forM_
    [ ("the script cancelled it", \fixture owner → acommand fixture owner "i" "cancel" "a" >> awaitNote fixture "cmd cancel a cancelled")
    , ("an epoch change cancelled it", \_ owner → void (advanceRequestEpoch (scheduledEndpoint owner)))
    , ("its instance ended", \fixture owner → void (expectControl (afBase fixture) owner "i" InstanceStop))
    ]
    $ \(how, event) →
      it ("keeps the work of a held completion made while the provider's work remained, when " <> how) $ bounded $ do
        fixture ← newAFix 4
        withBoundary $ \_ runtime → settleAll fixture $ do
          owner ← startAdmitting fixture runtime "keeps held" [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy
          admitAdmitter fixture owner "i" "admitter"
          seam ← newIORef Nothing
          onSubmit (afFake fixture) (captured seam)
          acommand fixture owner "i" "start" "a"
          awaitNote fixture "cmd start a started"
          Just settling ← readIORef seam
          atomically (settlingSettleKeeping settling (ProviderResult (VInteger 7))) >>= (`shouldBe` ReplyHeld)
          event fixture owner
          -- the request is over, and the provider's work is not: it is still owed, and its places are still charged
          d ← diagnostics owner
          rdWorkPending d `shouldBe` 1
          finishWork (afFake fixture) 0
          awaitDiagnostic owner ((== 0) . rdWorkPending)

  -- A resource reply made before its request's tick is built at once and its success held for the tick: the provider's last look at the
  -- settlement is taken again where the tick settles it, since the resource may have become invalid in between.
  forM_ [(True, "still holds"), (False, "no longer holds")] $ \(holds, how) →
    it ("takes the provider's last look at an early resource reply again at the tick, and publishes the success only if the resource " <> how) $ bounded $ do
      fixture ← newAFix 4
      setPolicy fixture (\held → held {polLease = Just InstanceOwned, polNecessity = OptionalRequest})
      valid ← newTVarIO True
      withBoundary $ \control runtime → settleAll fixture $ do
        owner ← startAdmitting fixture runtime "early resource" [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy
        admitAdmitter fixture owner "i" "admitter"
        seam ← newIORef Nothing
        onSubmit (afFake fixture) (captured seam)
        acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
        awaitNote fixture "cmd start a started"
        Just settling ← readIORef seam
        let final = readTVar valid >>= \ok → pure (if ok then Nothing else Just (ExpectedFailure "not_found" "gone" Nothing Nothing))
        atomically (settlingSettleFinal settling final (ProviderResource (VInteger 4) (Adoption (\_ → resourceFor fixture "r1")))) >>= (`shouldBe` ReplyAdoption)
        -- built before the tick, and the success is held for it
        awaitNote fixture "acquire r1"
        -- built and held (the last look at the build is taken and the success is held for the tick)
        awaitDiagnostic owner ((>= 1) . rdHeldNow)
        -- the resource becomes invalid before the tick is granted
        unless holds (atomically (writeTVar valid False))
        grantOne control owner
        acommand fixture owner "i" "take" "a"
        line ← lineStarting fixture "cmd take a "
        if holds
          then line `shouldSatisfy` Text.isInfixOf "status=success"
          else do
            line `shouldSatisfy` Text.isInfixOf "status=failure"
            line `shouldSatisfy` Text.isInfixOf "not_found"
            -- and the resource that was built is released
            awaitNote fixture "release r1"

  -- The resource built for an early reply, its success held for the tick, is released whenever the request ends before the tick serves it.
  forM_
    [ ("the script cancelled the request", \fixture owner → acommand fixture owner "i" "cancel" "a" >> awaitNote fixture "cmd cancel a cancelled")
    , ("an epoch change cancelled the request", \_ owner → void (advanceRequestEpoch (scheduledEndpoint owner)))
    , ("its instance ended", \fixture owner → void (expectControl (afBase fixture) owner "i" InstanceStop))
    ]
    $ \(how, event) →
      it ("releases the resource built for an early reply whose success is held for the tick, when " <> how) $ bounded $ do
        fixture ← newAFix 4
        setPolicy fixture (\held → held {polLease = Just InstanceOwned, polNecessity = OptionalRequest})
        withBoundary $ \_ runtime → settleAll fixture $ do
          owner ← startAdmitting fixture runtime "early resource ends" [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy
          admitAdmitter fixture owner "i" "admitter"
          seam ← newIORef Nothing
          onSubmit (afFake fixture) (captured seam)
          acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
          awaitNote fixture "cmd start a started"
          Just settling ← readIORef seam
          let final = pure Nothing
          atomically (settlingSettleFinal settling final (ProviderResource (VInteger 4) (Adoption (\_ → resourceFor fixture "r1")))) >>= (`shouldBe` ReplyAdoption)
          -- built before the tick, and the success is held for it
          awaitNote fixture "acquire r1"
          awaitDiagnostic owner ((>= 1) . rdHeldNow)
          -- the request ends before the tick: the resource nobody will take is released
          event fixture owner
          awaitNote fixture "release r1"

  -- Every path by which a provider's expected failure reaches the model through the seam delivers the failure the check returned, whose message
  -- is cut at a character, visibly, to the bound: one example per path.
  let longFailure = ExpectedFailure "not_found" (Text.replicate 5000 "é") Nothing Nothing
      cutTaken = "cmd take a {error={code=not_found,message=" <> Text.replicate 1022 "é" <> "...},status=failure}"
  forM_
    [ ("settled at its position", False, False)
    , ("held for its tick", True, False)
    , ("held for its tick with the provider's work still owed", True, True)
    ]
    $ \(path, logicalTime, keeping) →
      it ("delivers an expected failure cut to the bound when it is " <> path) $ bounded $ do
        fixture ← newAFix 4
        setPolicy fixture (\held → held {polNecessity = OptionalRequest})
        withBoundary $ \control runtime → settleAll fixture $ do
          owner ← startAdmitting fixture runtime "cut seam" [admitter] aConfig (admissionGrant fixture 8 (if logicalTime then SettleAtAssignedTick Nothing else SettleOnArrival)) requiredPolicy
          admitAdmitter fixture owner "i" "admitter"
          seam ← newIORef Nothing
          onSubmit (afFake fixture) (captured seam)
          acommand fixture owner "i" "start" "a"
          awaitNote fixture "cmd start a started"
          Just settling ← readIORef seam
          let reply = ProviderExpected longFailure
          atomically (if keeping then settlingSettleKeeping settling reply else settlingSettle settling reply) >>= (`shouldBe` (if logicalTime then ReplyHeld else ReplySettled))
          when logicalTime (grantOne control owner)
          acommand fixture owner "i" "take" "a"
          awaitNote fixture cutTaken
  forM_
    [ ("when it is built", False)
    , ("at the tick", True)
    ]
    $ \(path, laterInvalid) →
      it ("delivers an expected failure cut to the bound, and releases the resource, when the last look at an early resource reply fails " <> path) $ bounded $ do
        fixture ← newAFix 4
        setPolicy fixture (\held → held {polLease = Just InstanceOwned, polNecessity = OptionalRequest})
        valid ← newTVarIO (laterInvalid)
        withBoundary $ \control runtime → settleAll fixture $ do
          owner ← startAdmitting fixture runtime "cut resource" [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy
          admitAdmitter fixture owner "i" "admitter"
          seam ← newIORef Nothing
          onSubmit (afFake fixture) (captured seam)
          acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
          awaitNote fixture "cmd start a started"
          Just settling ← readIORef seam
          let final = readTVar valid >>= \ok → pure (if ok then Nothing else Just longFailure)
          atomically (settlingSettleFinal settling final (ProviderResource (VInteger 4) (Adoption (\_ → resourceFor fixture "r1")))) >>= (`shouldBe` ReplyAdoption)
          awaitNote fixture "acquire r1"
          awaitDiagnostic owner ((>= 1) . rdHeldNow)
          -- a resource that is invalid when it is built fails there (held for the tick); one that is valid then fails where the tick settles it
          when laterInvalid (atomically (writeTVar valid False))
          grantOne control owner
          acommand fixture owner "i" "take" "a"
          awaitNote fixture cutTaken
          awaitNote fixture "release r1"

  it "treats every reply that comes while a resource reply waits to be built as a duplicate, whatever it is" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned})
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "duplicate" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seam ← newIORef Nothing
      onSubmit (afFake fixture) (captured seam)
      acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
      awaitNote fixture "cmd start a started"
      Just settling ← readIORef seam
      -- in one transaction, so the owner cannot have built the resource between the two replies
      (first, second) ←
        atomically $ do
          one ← settlingSettle settling (ProviderResource (VInteger 4) (Adoption (\_ → resourceFor fixture "r1")))
          two ← settlingSettle settling (ProviderResult (VInteger 9))
          pure (one, two)
      (first, second) `shouldBe` (ReplyAdoption, ReplyLate)
      -- the first reply is the one: the request settles with the resource, and the duplicate replaced nothing
      awaitNote fixture "acquire r1"
      acommand fixture owner "i" "wait_take" "a"
      line ← lineStarting fixture "cmd wait_take a "
      line `shouldSatisfy` (/= "")

  it "lets a request commit only when every earlier place of its tick has been answered, whichever was answered first" $ bounded $ do
    fixture ← newAFix 4
    withBoundary $ \_ runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "ordered" [admitter] aConfig (admissionGrant fixture 8 (SettleAtAssignedTick Nothing)) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seams ← newIORef []
      onSubmit (afFake fixture) (\submission → modifyIORef' seams (<> [submissionSettling submission]))
      acommand fixture owner "i" "start" "a"
      awaitNote fixture "cmd start a started"
      acommand fixture owner "i" "start" "b"
      awaitNote fixture "cmd start b started"
      Just earlier : Just later : _ ← readIORef seams
      -- the tick is granted: both requests are waiting at its boundary, the later one's provider is ready first
      void (grantScheduledStep (scheduledEndpoint owner) (nanoseconds 1))
      atomically (settlingEligible earlier >>= \ok → if ok then pure () else retry)
      atomically (settlingEligible later) >>= (`shouldBe` False)
      -- the earlier place is answered, and only then may the later one commit
      atomically (settlingSettle earlier (ProviderResult (VInteger 1))) >>= (`shouldBe` ReplySettled)
      atomically (settlingEligible later) >>= (`shouldBe` True)
      atomically (settlingSettle later (ProviderResult (VInteger 2))) >>= (`shouldBe` ReplySettled)

  it "treats a final verdict the service did not declare as the provider's defect, fatal even for an optional request, and builds nothing into the lease" $ bounded $ do
    fixture ← newAFix 4
    setPolicy fixture (\held → held {polLease = Just InstanceOwned, polNecessity = OptionalRequest})
    ExceptionWithContext _ failure ← expectFatal $ \control runtime → settleAll fixture $ do
      owner ← startAdmitting fixture runtime "final" [admitter] aConfig (admissionGrant fixture 8 SettleOnArrival) requiredPolicy
      admitAdmitter fixture owner "i" "admitter"
      seam ← newIORef Nothing
      onSubmit (afFake fixture) (captured seam)
      acommandWith fixture owner "i" "start" "a" (Just "res") (Just 1) Nothing
      awaitNote fixture "cmd start a started"
      Just settling ← readIORef seam
      let invalid = pure (Just (ExpectedFailure "unheard_of" "message" Nothing Nothing))
      atomically (settlingSettleFinal settling invalid (ProviderResource (VInteger 4) (Adoption (\_ → resourceFor fixture "r1")))) >>= (`shouldBe` ReplyAdoption)
      awaitScheduledTerminal control owner
    (fromException failure :: Maybe ProviderDefect) `shouldSatisfy` \case
      Just (ProviderDefect why) → not (Text.null why)
      Nothing → False
