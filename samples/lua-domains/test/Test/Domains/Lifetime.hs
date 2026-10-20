-- | The two owners' lifetime (requirement 2): created under one supervision boundary, retired in an
-- order in which neither outlives what its bindings borrow, and nothing left live.
module Test.Domains.Lifetime (spec) where

import Control.Concurrent.STM (atomically, readTVarIO, retry)
import Control.Monad (unless)
import Control.Exception (IOException, SomeException, displayException, fromException, throwIO, try)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Maybe (isJust, isNothing)
import System.IO.Error (ioeGetErrorString)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Hetoimasia.Foundation.Worker (pollCompletion)
import Hetoimasia.Runtime.Supervision (SupervisedFailure (failedException), WorkerStatus (WorkerLive, WorkerStopped), supervisedFailures, supervisedWorker)
import Hetoimasia.Sample.LuaDomains
  ( Answer (Closed)
  , Domains (domainsGameplay, domainsShared, domainsUi)
  , DomainsConfig (configExtensions, configGameplaySource, configUiSource)
  , DomainsDefect (OwnerEndedDuringTick)
  , Extension (Extension)
  , Where (InGameplay)
  , OwnerEnd (endExit, endInstance)
  , Retirement (retiredGameplay, retiredUi)
  , Started (startedOwner)
  , retireDomains
  , withDomains
  )
import Hetoimasia.Sample.LuaDomains.Queue (isClosed, reserved)
import Hetoimasia.Sample.LuaDomains.Scripts (gameplaySource, interfaceSource)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Messaging.Snapshot (Publication (PublicationClosed), publish)
import Hetoimasia.Sample.LuaDomains.Intention (Submitted (Submitted))
import Hetoimasia.Sample.LuaDomains.Shared (Shared (sharedQueue, sharedTick), publisherOf, submit)
import Hetoimasia.Scripting.Lua.Instance (InstanceOutcome (InstanceStopped), InstanceSettlement (resultOutcome))
import Hetoimasia.Scripting.Lua.Runtime (ExitKind (ExitStopped), ExitRecord (exitKind, exitNotStarted, exitStarted))
import Hetoimasia.Scripting.Lua.Registration (namespace, stateOperation)
import Hetoimasia.Scripting.Lua.Scheduled (scheduledEndpoint, scheduledIdentity, scheduledStatus, scheduledSupervised, ticksOutstanding)
import Test.Domains.Support
import Test.Hspec

-- | The sample's own script with a @shutdown@ hook that records which owner stopped, and why.
recording ∷ Text → ByteString → ByteString
recording owner source =
  source <> luaLines ["", "function shutdown(self, reason) fx.record('" <> owner <> " shutdown ' .. reason) end"]

spec ∷ Spec
spec = describe "the owners' lifetime" $ do
  it "retires the UI owner before the gameplay owner, with clean exit records, and leaves nothing live" $ do
    (domains, ui) ←
      withSample
        (\config → config {configGameplaySource = recording "gameplay" gameplaySource, configUiSource = recording "ui" interfaceSource})
        $ \fx ui domains → do
          _ ← stepCommitted domains
          _ ← stepCommitted domains
          retirement ← retireDomains domains
          -- The UI owner's behavior was stopped, with its reason, before gameplay's.
          fxLines fx `shouldReturn` ["ui shutdown stopped", "gameplay shutdown stopped"]
          mapM_ (clean . ($ retirement)) [retiredUi, retiredGameplay]
          pure (domains, ui)
    -- Left the supervision boundary: both owners ended after being asked to, and nothing is armed.
    mapM_
      (\started → atomically (scheduledStatus (startedOwner started)) >>= (`shouldSatisfy` stopped))
      [domainsUi domains, domainsGameplay domains]
    liveCount ui `shouldReturn` 0
    -- The publication ended with the session and kept its last value.
    snapshot ← prepare . fst =<< snapshotNow domains
    atomically (publisherOf (domainsShared domains) >>= \publisher → publish publisher snapshot) >>= (`shouldSatisfy` closed)
    committedTick domains `shouldReturn` 2
    atomically (ticksOutstanding (scheduledEndpoint (startedOwner (domainsGameplay domains)))) `shouldReturn` 0
    atomically (reserved (sharedQueue (domainsShared domains))) `shouldReturn` 0
    -- Two owners of one runtime, each with an identity of its own.
    scheduledIdentity (startedOwner (domainsUi domains)) `shouldNotBe` scheduledIdentity (startedOwner (domainsGameplay domains))
  it "retires both owners, and closes admission, when the body fails" $ do
    captured ← newIORef Nothing
    outcome ←
      try $ withSample id $ \_ ui domains → do
        writeIORef captured (Just (domains, ui))
        _ ← stepCommitted domains
        throwIO (userError "the body failed")
    either ioeGetErrorString (const "returned") (outcome ∷ Either IOException ()) `shouldBe` "the body failed"
    (domains, ui) ← readIORef captured >>= maybe (fail "the session never started") pure
    mapM_
      (\started → atomically (scheduledStatus (startedOwner started)) >>= (`shouldSatisfy` stopped))
      [domainsUi domains, domainsGameplay domains]
    liveCount ui `shouldReturn` 0
    submit (domainsShared domains) (Submitted 1 0 0 0 1 0) `shouldReturn` Closed

  it "leaves a tick uncommitted and retires cleanly when the driver is cancelled in the middle of it" $
    withSample (\config → config {configGameplaySource = luaLines ["function update(self, dt) fx.hold('gameplay') staging.finish() end"]}) $
      \fx _ domains → withReleased fx ["gameplay"] $ do
        -- The driver is the application thread's own call, cancelled in the middle of the tick.
        driver ← cancelWhen (awaitEntered fx "gameplay") (stepCommitted domains)
        driver `shouldSatisfy` isNothing
        -- The held tick published nothing, and the session stays halted at it.
        (committedTick domains, revisionNow domains) `shouldBe'` (0, 0)
        readTVarIO (sharedTick (domainsShared domains)) >>= (`shouldSatisfy` isJust)
        releaseGate fx "gameplay"
        retirement ← retireDomains domains
        fmap exitKind (endExit (retiredGameplay retirement)) `shouldBe` Just ExitStopped
        fmap exitKind (endExit (retiredUi retirement)) `shouldBe` Just ExitStopped
        revisionNow domains `shouldReturn` 0

  it "ends the session, and still retires what is left, when a gameplay binding fails" $ do
    captured ← newIORef Nothing
    outcome ←
      try $
        withSample
          ( \config →
              config
                { configGameplaySource = luaLines ["function update(self, dt) boom.fail() end"]
                , configExtensions = \shared → configExtensions config shared <> [Extension (namespace "boom" [stateOperation "fail" [] [] (\_ → throwIO (userError "the gameplay binding failed"))]) InGameplay []]
                }
          )
          $ \_ ui domains → do
            writeIORef captured (Just (domains, ui))
            stepCommitted domains
    case outcome of
      Left failure → do
        -- Which of two supervised reports reaches the driver first is not fixed: the driver's own
        -- statement that the owner ended with the tick outstanding, with the owner's failure retained
        -- beside it, or the owner's failure itself. Either way the owner's failure, with its message,
        -- is in what the boundary raised.
        let evidence = displayException (failure ∷ SomeException) : map (displayException . failedException) (supervisedFailures failure)
        any ("the gameplay binding failed" `isInfixOf`) evidence `shouldBe` True
        (fromException failure == Just (OwnerEndedDuringTick 1) || "the gameplay binding failed" `isInfixOf` displayException failure) `shouldBe` True
      Right _ → expectationFailure "the tick committed"
    (domains, ui) ← readIORef captured >>= maybe (fail "the session never started") pure
    -- Neither owner is live, nothing was committed, and nothing is armed or admitted.
    mapM_
      (\started → atomically (scheduledStatus (startedOwner started)) >>= (`shouldSatisfy` notLive))
      [domainsUi domains, domainsGameplay domains]
    liveCount ui `shouldReturn` 0
    (committedTick domains, revisionNow domains) `shouldBe'` (0, 0)
    submit (domainsShared domains) (Submitted 1 0 0 0 1 0) `shouldReturn` Closed
  it "leaves neither owner live when it raises, though one failed while the other was inside a segment and supervision had latched the failure" $ do
    fx ← newFx
    ui ← newFakeUi
    let base = sampleConfig fx ui
        config =
          base
            { configGameplaySource = luaLines ["function update(self, dt) boom.fail() end"]
            , configUiSource = luaLines ["function update(self, dt) fx.hold('ui') ui.updated() end"]
            , configExtensions = \shared → configExtensions base shared <> [Extension (namespace "boom" [stateOperation "fail" [] [] (\_ → throwIO (userError "the gameplay binding failed"))]) InGameplay []]
            }
    facts ← newIORef Nothing
    -- The supervision boundary rethrows the failure it latched when it closes, so the facts are
    -- gathered inside it, while it is still open, and checked afterwards.
    _ ←
      try @SomeException . withBoundary $ \control → withReleased fx ["ui"] $ do
        outcome ←
          try . generous . withDomains control config $ \domains → do
            writeIORef facts (Just (Left domains))
            -- The UI owner is inside a held segment, and stays there until retirement has begun:
            -- admission has ended. The gameplay failure then ends the body. However the body ends, the segment is
            -- released, so the owners can end.
            withReleased fx ["ui"] $ do
              tickUi domains ui
              awaitEntered fx "ui"
              _ ← forkRegistered (atomically (isClosed (sharedQueue (domainsShared domains)) >>= \ended → unless ended retry) >> releaseGate fx "ui")
              stepCommitted domains
        let raised = either (\failure → const True (failure ∷ SomeException)) (const False) outcome
        domains ← readIORef facts >>= \held → case held of
          Just (Left found) → pure found
          _ → fail "the session never started"
        -- Still inside the boundary, which has drained nothing: both owners have actually ended,
        -- whatever supervision latched, and the publication has ended with them.
        ended ← mapM (\started → isJust . fmap (const ()) <$> atomically (pollCompletion (supervisedWorker (scheduledSupervised (startedOwner started))))) [domainsUi domains, domainsGameplay domains]
        armed ← liveCount ui
        snapshot ← prepare . fst =<< snapshotNow domains
        publication ← atomically (publisherOf (domainsShared domains) >>= \publisher → publish publisher snapshot)
        answer ← submit (domainsShared domains) (Submitted 1 0 0 0 1 0)
        writeIORef facts (Just (Right (raised, ended, armed, closed publication, answer)))
    readIORef facts >>= \case
      Just (Right found) → found `shouldBe` (True, [True, True], 0, True, Closed)
      _ → expectationFailure "the example never reached its checks"
  where
    shouldBe' (a, b) expected = ((,) <$> a <*> b) `shouldReturn` expected
    notLive = \case
      WorkerLive → False
      _ → True
    stopped = \case
      WorkerStopped → True
      _ → False
    closed = \case
      PublicationClosed → True
      _ → False
    clean end = do
      fmap exitKind (endExit end) `shouldBe` Just ExitStopped
      fmap exitNotStarted (endExit end) `shouldBe` Just 0
      fmap exitStarted (endExit end) `shouldBe` Just 0
      fmap (isStopped . resultOutcome) (endInstance end) `shouldBe` Just True
    isStopped = \case
      InstanceStopped → True
      _ → False
