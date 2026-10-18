-- | How the owner exits, for everything it leaves, whatever happens to it afterwards.
--
-- The first failure or cancellation of an owner's exit is how it exits: the instances it
-- leaves settle as discarded by that kind, the owner's exit record names it, and
-- supervision carries the exception that ended it. A later cancellation, an interrupted
-- close or a hook cut short while the owner is already exiting is cleanup evidence; it
-- replaces none of them. The sweep crosses what ended the owner first (a failure of the
-- host, a failure of a script that its escalation made the owner's, a stop, a
-- cancellation) with what happens to the teardown afterwards (a suspended coroutine whose
-- close is interrupted, a hook cut short as a cancellation is, nothing but an idle peer
-- to discard), and holds the instances, the exit record and supervision to one cause.
module Test.LuaRuntime.Instance.ExitKind (spec) where

import Control.Concurrent.STM (atomically)
import Control.Exception (AsyncException (ThreadKilled), ExceptionWithContext (ExceptionWithContext), SomeException, fromException, throwIO, tryWithContext)
import Control.Monad (forM_, void, when)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitCancelled, ExitFailed, ExitStopped), ExitRecord (exitKind))
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (SFixture (sfObserver), awaitScheduledTerminal)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, requiredPolicy, withBoundary)

-- | What ends the owner first.
data Cause = CauseHost | CauseLua | CauseStop | CauseCancel
  deriving (Eq, Show, Enum, Bounded)

-- | What happens to the teardown afterwards.
data Later = LaterClose | LaterKill | LaterDiscard
  deriving (Eq, Show, Enum, Bounded)

-- | The kind every instance the owner leaves is discarded by, if it is discarded.
discardedBy ∷ Cause → Later → Maybe ExitKind
discardedBy cause later = case cause of
  CauseHost → Just ExitFailed
  CauseLua → Just ExitFailed
  CauseCancel → Just ExitCancelled
  -- A stop is no failure: it gives way to the first cancellation of its own teardown.
  CauseStop | later == LaterDiscard → Nothing
  CauseStop → Just ExitCancelled

-- | What the owner's exit record names. It is written once, as the owner exits, so a stop
-- that its own teardown later cancels is recorded as the stop it was.
recordedAs ∷ Cause → ExitKind
recordedAs = \case
  CauseHost → ExitFailed
  CauseLua → ExitFailed
  CauseStop → ExitStopped
  CauseCancel → ExitCancelled

spec ∷ Spec
spec = describe "how the owner exits" $ do
  forM_ [minBound .. maxBound] $ \cause →
    forM_ [minBound .. maxBound] $ \later →
      it ("keeps the first cause for every instance, the exit record and supervision: " <> show cause <> ", then " <> show later) $
        bounded (cell cause later)
  it "keeps a failure of the host as the exit when closing the coroutine of a task that was inside a segment is interrupted at the owner's end" $ bounded $ do
    fixture ← newIFixture
    held ← newIORef Nothing
    ended ← tryWithContext @SomeException . withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "observed" [closeKilled, echoer] (testConfig instanceBounds') requiredPolicy
      writeIORef held (Just owner)
      void (admit fixture owner "k" (moduleNamed "closekilled"))
      void (admit fixture owner "p" (moduleNamed "echoer"))
      awaitPhase fixture owner "k" Active
      awaitPhase fixture owner "p" Active
      expectDelivered fixture owner "k" 1
      awaitDiagnosticsWaiting owner
      -- The application's observer fails the host as the task is resumed: its coroutine is
      -- not suspended then, so the scheduler does not close it; the owner's end does, and
      -- that close is interrupted.
      writeIORef (sfObserver (sf fixture)) (\_ → throwIO (Broken "observer"))
      grantOne control owner
      void (awaitScheduledTerminal control owner)
    case ended of
      Left (ExceptionWithContext _ raised) → raised `shouldSatisfy` brokenIs "observer"
      Right _ → fail "the observer's failure of the host was lost"
    forM_ ["k", "p"] $ \name → do
      settled ← tickOf fixture name >>= pollInstance
      fmap resultOutcome settled `shouldSatisfy` \case
        Just (InstanceDiscarded (Discard ExitFailed _)) → True
        _ → False
    readIORef held >>= \case
      Nothing → fail "the owner never started"
      Just owner → atomically (scheduledExitRecord owner) >>= (`shouldSatisfy` maybe False ((== ExitFailed) . exitKind))
  it "keeps a failure of the host as the exit when the application's escalation is cancelled while retirement settles the failed instance" $ bounded $ do
    fixture ← newIFixture
    let config = (testConfig instanceBounds') {instanceEscalate = \_ → throwIO ThreadKilled}
    ended ← tryWithContext @SomeException . withBoundary $ \control runtime → do
      owner ← startInstances fixture runtime "told" [failHookHost, echoer] config requiredPolicy
      void (admit fixture owner "a" (moduleNamed "failhookhost"))
      void (admit fixture owner "p" (moduleNamed "echoer"))
      awaitPhase fixture owner "a" Active
      awaitPhase fixture owner "p" Active
      expectDelivered fixture owner "a" 1
      void (awaitScheduledTerminal control owner)
    case ended of
      Left (ExceptionWithContext _ raised) → raised `shouldSatisfy` brokenIs "shutdown host"
      Right _ → fail "the shutdown's failure of the host was lost"
    -- The failed instance is told of and cancelled in the telling, and the one retired
    -- after it is still discarded by the first cause, not by the cancellation.
    a ← tickOf fixture "a" >>= pollInstance
    fmap resultPhase a `shouldBe` Just Failed
    p ← tickOf fixture "p" >>= pollInstance
    fmap resultOutcome p `shouldSatisfy` \case
      Just (InstanceDiscarded (Discard ExitFailed _)) → True
      _ → False

-- | A callback that raises a Lua error, and a @shutdown@ that fails the host.
failHookHost ∷ ModuleSource
failHookHost =
  hooksModule
    "failhookhost"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) error('callback boom') end)"
    , "end"
    , "function shutdown(self, reason) fx.fail('shutdown host') end"
    ]

cell ∷ Cause → Later → IO ()
cell cause later = do
  fixture ← newIFixture
  exitRecord ← newIORef Nothing
  let config = (testConfig instanceBounds') {instanceEscalate = \_ → pure (if cause == CauseLua then Escalate else Isolate)}
      laterModule = case later of
        LaterClose → [("k", closeKilled, "closekilled")]
        LaterKill → [("k", killShutdown, "killshutdown")]
        LaterDiscard → []
      trigger = case cause of
        CauseHost → [("t", hostFailing, "hostfailing")]
        CauseLua → [("t", failCallback, "failcallback")]
        -- Cancelled while the owner is inside a segment, held at a gate: where a cancellation
        -- lands is then not left to when it is delivered.
        CauseCancel → [("holder", holder, "holder")]
        CauseStop → []
      members = laterModule <> [("p", echoer, "echoer")] <> trigger
  ended ← tryWithContext @SomeException . withBoundary $ \control runtime → do
    owner ← startInstances fixture runtime "exit" [source | (_, source, _) ← members] config requiredPolicy
    forM_ [member | member@(name, _, _) ← members, name /= "holder"] $ \(name, _, identity) → void (admit fixture owner name (moduleNamed identity))
    forM_ [name | (name, _, _) ← members, name /= "holder"] $ \name → awaitPhase fixture owner name Active
    -- A suspended coroutine whose close the teardown will interrupt.
    when (later == LaterClose) $ do
      expectDelivered fixture owner "k" 1
      awaitDiagnosticsWaiting owner
    case cause of
      CauseHost → expectDelivered fixture owner "t" 1
      CauseLua → expectDelivered fixture owner "t" 1
      CauseStop → retireScheduled owner
      CauseCancel → holdOwner fixture owner >> cancelScheduled owner >> releaseOwner fixture
    -- A failing owner ends the boundary the example runs in, so the record is read after it.
    writeIORef exitRecord (Just owner)
    void (awaitScheduledTerminal control owner)
  -- Supervision: the exception that ended the owner is the first cause's.
  case (cause, ended) of
    (CauseHost, Left (ExceptionWithContext _ raised)) → raised `shouldSatisfy` brokenIs "boom"
    (CauseHost, Right _) → fail "the owner's host failure was lost"
    (CauseLua, Left (ExceptionWithContext _ raised)) → (fromException raised ∷ Maybe InstanceEscalated) `shouldSatisfy` isJust
    (CauseLua, Right _) → fail "the owner's escalation was lost"
    _ → pure ()
  -- The exit record: what the owner's exit discarded names the first cause.
  readIORef exitRecord >>= \case
    Nothing → fail "the owner never started"
    Just owner → atomically (scheduledExitRecord owner) >>= \case
      Just held → exitKind held `shouldBe` recordedAs cause
      Nothing → fail "the owner's exit was not recorded"
  -- Every instance the owner left is discarded by the same cause.
  forM_ [name | (name, _, _) ← members, name /= "t" || cause == CauseHost] $ \name → do
    settled ← tickOf fixture name >>= pollInstance
    case (settled, discardedBy cause later) of
      (Just result, Just kind) → case resultOutcome result of
        InstanceDiscarded (Discard actual _) → (name, actual) `shouldBe` (name, kind)
        other → fail (show name <> " settled as " <> show other <> ", expected discarded by " <> show kind)
      (Just result, Nothing) → resultOutcome result `shouldSatisfy` \case InstanceStopped → True; _ → False
      (Nothing, _) → fail (show name <> " was never settled")
