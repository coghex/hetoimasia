-- | What bounds the instance layer, and what it promises under the bounds: live
-- instances, retained results, reservations for controls, a configuration that does
-- not fit, and every accepted instance settling exactly once.
module Test.LuaRuntime.Instance.Capacity (spec) where

import Control.Concurrent (forkIO, yield)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), fromException)
import Control.Monad (forM, forM_, replicateM, void)
import Data.List.NonEmpty (toList)
import qualified Data.Text as Text
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (VmConfig (vmRegistration))
import Hetoimasia.Scripting.Lua.Registration (namespace, registration, registrationNamespaces)
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value (Schema (SCapability, SInteger, SList, SRecord))
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (defaultSchedulerBounds, scheduled, startScheduled)
import Test.LuaRuntime.Support (bounded, failExample, requiredPolicy, tryExpected, withBoundary)

-- | What admitting answered, as something an example compares.
full ∷ InstanceAdmission → Bool
full = \case InstanceFull → True; _ → False

closed ∷ InstanceAdmission → Bool
closed = \case InstanceAdmissionClosed → True; _ → False

accepted' ∷ InstanceAdmission → Bool
accepted' = \case InstanceAccepted _ _ → True; _ → False

-- | The violations a configuration is refused with.
refusedWith ∷ IFixture → LuaRuntime → InstanceConfig → IO [InstanceViolation]
refusedWith fixture runtime config = do
  outcome ← tryExpected (startInstances fixture runtime "refused" [echoer] config requiredPolicy)
  case outcome of
    Left (ExceptionWithContext _ failure) → case fromException failure of
      Just (InstancesRefused violations) → pure (toList violations)
      Nothing → failExample ("expected the refusal of the configuration, found " <> show failure)
    Right _ → failExample "the configuration should have been refused"

-- | Admit until the answer is not that a bound is held: a result or a place the
-- owner has yet to give back.
admitUntilTaken ∷ IFixture → ScheduledOwner → InstanceRequest → IO InstanceAdmission
admitUntilTaken fixture owner request =
  admitInstance (scheduledEndpoint owner) request >>= \case
    InstanceFull → yield >> admitUntilTaken fixture owner request
    answer → pure answer

spec ∷ Spec
spec = describe "capacity" $ do
  it "refuses an admission past the live bound, takes one again when an instance ended and was observed, under an identity not issued before" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "live bound" [echoer] (testConfig (InstanceBounds 2 4 8 8)) requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      let request = InstanceRequest (moduleNamed "echoer") EventOnly (Just "c") OrdinaryClass ["tick"]
      admitInstance (scheduledEndpoint owner) request >>= (`shouldSatisfy` full)
      awaitPhase fixture owner "a" Active
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      _ ← awaitSettled fixture "a"
      c ← admitInstance (scheduledEndpoint owner) request
      c `shouldSatisfy` accepted'
      case c of
        InstanceAccepted identity _ → do
          a ← idOf fixture "a"
          b ← idOf fixture "b"
          identity `shouldSatisfy` (`notElem` [a, b])
        _ → pure ()

  it "counts an ended instance's result against its bound until it is observed or abandoned" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "retained" [echoer] (testConfig (InstanceBounds 2 2 8 8)) requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "echoer")
      _ ← admit fixture owner "b" (moduleNamed "echoer")
      forM_ ["a", "b"] $ \name → awaitPhase fixture owner name Active
      forM_ ["a", "b"] $ \name → settleControl fixture owner name InstanceStop >>= (`shouldBe` ControlApplied)
      let request = InstanceRequest (moduleNamed "echoer") EventOnly (Just "c") OrdinaryClass ["tick"]
      -- Neither is live, and neither result has been read: the results are the bound.
      awaitPhase fixture owner "a" Stopped
      awaitPhase fixture owner "b" Stopped
      admitInstance (scheduledEndpoint owner) request >>= (`shouldSatisfy` full)
      -- Observing one gives its reservation back, and reading it again gives nothing.
      ticket ← tickOf fixture "a"
      void (pollInstance ticket)
      void (pollInstance ticket)
      pollInstance ticket >>= (`shouldSatisfy` \case Just _ → True; Nothing → False)
      admitInstance (scheduledEndpoint owner) request >>= (`shouldSatisfy` accepted')
      admitInstance (scheduledEndpoint owner) request >>= (`shouldSatisfy` full)
      -- Abandoning the other gives its reservation back at once.
      forgetInstance =<< tickOf fixture "b"
      admitInstance (scheduledEndpoint owner) request >>= (`shouldSatisfy` accepted')

  it "gives a live instance's reservation back when it ends, if its result was abandoned first" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "forgotten" [echoer] (testConfig (InstanceBounds 1 1 8 8)) requiredPolicy
      ticket ← admit fixture owner "a" (moduleNamed "echoer")
      awaitPhase fixture owner "a" Active
      forgetInstance ticket
      let request = InstanceRequest (moduleNamed "echoer") EventOnly (Just "b") OrdinaryClass ["tick"]
      admitInstance (scheduledEndpoint owner) request >>= (`shouldSatisfy` full)
      settleControl fixture owner "a" InstanceStop >>= (`shouldBe` ControlApplied)
      -- Ended and abandoned: its place and its result are free without a read.
      admitUntilTaken fixture owner request >>= (`shouldSatisfy` accepted')

  it "answers closed for an owner that hosts no instances, and reads none" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startScheduled (sf fixture) runtime (scheduled (sf fixture) "plain" requiredPolicy defaultSchedulerBounds)
      let endpoint = scheduledEndpoint owner
      admitInstance endpoint (InstanceRequest (moduleNamed "echoer") EventOnly Nothing OrdinaryClass []) >>= (`shouldSatisfy` closed)
      inspected ← atomically (inspectInstances endpoint)
      inspected `shouldBe` []

  it "refuses a configuration that does not fit, naming every violation, before anything starts" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      let base = testConfig instanceBounds'
      belowOne ← refusedWith fixture runtime base {instanceBounds = InstanceBounds 0 0 0 0}
      belowOne `shouldBe` [BoundBelowOne "live instances" 0, BoundBelowOne "retained instance results" 0, BoundBelowOne "invocation queue" 0, BoundBelowOne "instance controls" 0]
      refusedWith fixture runtime base {instanceBounds = InstanceBounds 4 2 8 8}
        >>= (`shouldBe` [RetainedBelowLive 2 4])
      -- The scheduler's own bounds must hold every instance's invocation and the result
      -- it has not yet given back.
      refusedWith fixture runtime base {instanceBounds = InstanceBounds 17 17 8 8}
        >>= (`shouldBe` [SchedulerRetainedTooSmall 32 17, SchedulerQueueTooSmall 16 17])
      refusedWith fixture runtime base {instanceSources = [EventSource "bad name" SInteger, EventSource "tick" SInteger, EventSource "tick" SInteger]}
        >>= (`shouldBe` [InvalidSourceName "bad name", DuplicateSource "tick"])
      refusedWith fixture runtime base {instanceSources = [EventSource "held" (SRecord [("a", SList (SCapability "thing"))])]}
        >>= (`shouldBe` [SourceCapability "held"])
      -- A name the prefix of the driver's entry point for it would push past the bound,
      -- and the longest one that fits.
      let longest = Text.replicate 58 "n"
      refusedWith fixture runtime base {instanceSources = [EventSource (longest <> "n") SInteger]}
        >>= (`shouldBe` [InvalidSourceName (longest <> "n")])
      fits ← startInstances fixture runtime "longest" [echoer] base {instanceSources = [EventSource longest SInteger]} requiredPolicy
      retireScheduled fits
      -- More sources than the driver can declare an entry point for.
      let many = [EventSource ("source" <> Text.pack (show n)) SInteger | n ← [1 .. 60 ∷ Int]]
      refusedWith fixture runtime base {instanceSources = many} >>= (`shouldBe` [TooManySources 60 59])
      -- A registration that already holds the layer's namespace cannot take it.
      taken ← tryExpected $ do
        let plain = instanceSpec fixture "taken" [echoer] base requiredPolicy defaultSchedulerBounds
            existing = either (error . show) id (registration [] (registrationNamespaces (vmRegistration (scheduledVm plain)) <> [namespace "hetoimasia_instance" []]))
        startScheduled (sf fixture) runtime plain {scheduledVm = (scheduledVm plain) {vmRegistration = existing}}
      case taken of
        Left (ExceptionWithContext _ failure) → case fromException failure of
          Just (InstancesRefused violations) → [reason | RegistrationRefused reason ← toList violations] `shouldSatisfy` (not . null)
          Nothing → failExample ("expected the refusal of the registration, found " <> show failure)
        Right _ → failExample "the registration should have been refused"

  it "settles every accepted instance exactly once when admissions race the owner's retirement" $ bounded $ do
    fixture ← newIFixture
    withBoundary $ \_ runtime → do
      owner ← startInstances fixture runtime "racing" [echoer] (testConfig instanceBounds') requiredPolicy
      let request = InstanceRequest (moduleNamed "echoer") EventOnly Nothing OrdinaryClass ["tick"]
          endpoint = scheduledEndpoint owner
      tickets ← forM [1 .. 4 ∷ Int] $ \_ → do
        finished ← newEmptyMVar
        _ ← forkIO $ do
          answers ← replicateM 20 (admitInstance endpoint request <* yield)
          putMVar finished [ticket | InstanceAccepted _ ticket ← answers]
        pure finished
      yield
      retireScheduled owner
      accepted ← concat <$> forM tickets takeMVar
      -- Whatever was accepted settles, once: a second read answers the same result.
      forM_ accepted $ \ticket → do
        first ← waitInstance ticket
        again ← pollInstance ticket
        fmap resultInstance again `shouldBe` Just (resultInstance first)
      admitInstance endpoint request >>= (`shouldSatisfy` closed)
