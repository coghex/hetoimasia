-- | What an instance's ending keeps of what happened to it, however the ending comes.
--
-- An instance's primary failure, with its traceback, once it is recorded is never
-- replaced by a later or secondary outcome: not by the owner's exit, not by a hook
-- that raised a failure of the host, not by a retirement that came back to an ending
-- that was interrupted. What became of the @shutdown@ hook is recorded once, when it
-- is decided, and every settlement reads that record. The matrix crosses what first
-- happened to the instance (a callback that raised a Lua error, a callback that raised
-- a failure of the host, nothing), what its @shutdown@ does (returns, raises a Lua
-- error, raises a failure of the host) and how the instance comes to its end (a stop
-- of its own, the owner's retirement in order, the owner's teardown by another's
-- failure), and holds the instance's settlement, the owner's exception and the
-- application's escalation to one model of all twenty-seven.
--
-- Every wait here is for a signal the code under test sets: the settlement, the
-- owner's terminal status, the notification the application's escalation makes.
module Test.LuaRuntime.Instance.Matrix (spec) where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, retry)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Control.Monad (forM_, unless, void, when)
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Owner (ModuleSource)
import Hetoimasia.Scripting.Lua.Runtime (Discard (Discard), ExitKind (ExitFailed), Progress (Started))
import Hetoimasia.Scripting.Lua.Scheduled
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Instance.Support
import Test.LuaRuntime.Scheduled.Support (awaitScheduledTerminal)
import Test.LuaRuntime.Support (Broken (Broken), bounded, brokenIs, expectFatal, requiredPolicy, withBoundary)

-- | What first happens to the instance.
data First = FirstLua | FirstHost | FirstNone
  deriving (Eq, Show, Enum, Bounded)

-- | What its @shutdown@ does.
data Hook = HookOk | HookLua | HookHost
  deriving (Eq, Show, Enum, Bounded)

-- | How the instance comes to its end.
data Route = RouteStop | RouteRetire | RouteTeardown
  deriving (Eq, Show, Enum, Bounded)

-- | What the instance, the owner and the application are held to.
data Shape = Shape
  { shapePhase ∷ InstancePhase
  , shapeDiscarded ∷ Bool
  , shapeDisposition ∷ ShutdownDisposition
  , shapeFirst ∷ Maybe (HookStage, Text)
    -- ^ The failure the instance settled with: where it was, and what it said.
  , shapeTraceback ∷ Bool
  , shapeSecondary ∷ [HookStage]
  , shapeTold ∷ Int
  , shapeHookRecorded ∷ Bool
  , shapeOwner ∷ Maybe Text
    -- ^ The failure of the host the owner exits with, if it does.
  }

-- | The model.
shapeOf ∷ First → Hook → Route → Shape
shapeOf first hook route = case first of
  FirstHost →
    -- The callback's failure ends the owner, and no hook runs for any instance after it.
    Shape Stopped True ShutdownSkippedUnsafe Nothing False [] 0 False (Just "callback host")
  FirstLua →
    Shape
      Failed
      False
      (case hook of HookOk → ShutdownRan; _ → ShutdownRaised)
      (Just (StageEvent "tick", "callback boom"))
      True
      [StageShutdown | hook == HookLua]
      1
      (hook == HookOk)
      ( case hook of
          HookHost → Just "shutdown host"
          _ | route == RouteTeardown → Just "boom"
          _ → Nothing
      )
  FirstNone
    | route == RouteTeardown → Shape Stopped True ShutdownSkippedUnsafe Nothing False [] 0 False (Just "boom")
    | otherwise → case hook of
        HookOk → Shape Stopped False ShutdownRan Nothing False [] 0 True Nothing
        HookLua → Shape Failed False ShutdownRaised (Just (StageShutdown, "shutdown boom")) True [] 1 False Nothing
        HookHost → Shape Stopped True ShutdownRaised Nothing False [] 0 False (Just "shutdown host")

tag ∷ First → Hook → Text
tag first hook =
  "mx"
    <> (case first of FirstLua → "lua"; FirstHost → "host"; FirstNone → "none")
    <> (case hook of HookOk → "ok"; HookLua → "lua"; HookHost → "host")

-- | An instance whose callback does this and whose @shutdown@ does that.
matrixModule ∷ First → Hook → ModuleSource
matrixModule first hook =
  hooksModule
    (tag first hook)
    [ "function init(self, api)"
    , "  self.id = inst.next()"
    , "  api.connect('tick', function(self, event) " <> callback <> " end)"
    , "end"
    , "function shutdown(self, reason) " <> shutdown <> " end"
    ]
  where
    callback = case first of
      FirstLua → "error('callback boom')"
      FirstHost → "fx.fail('callback host')"
      FirstNone → ""
    shutdown = case hook of
      HookOk → record <> "('shutdown ' .. self.id .. ' ' .. reason)"
      HookLua → "error('shutdown boom')"
      HookHost → "fx.fail('shutdown host')"

-- | A callback that asks for a wait the scheduler refuses, and a @shutdown@ that fails the
-- host.
refusedWaitHostShutdown ∷ ModuleSource
refusedWaitHostShutdown =
  hooksModule
    "refusedwaithostshutdown"
    [ "function init(self, api)"
    , "  api.connect('tick', function(self, event) sched.wait_ticks(0) end)"
    , "end"
    , "function shutdown(self, reason) fx.fail('shutdown host') end"
    ]

spec ∷ Spec
spec = describe "what an ending keeps" $ do
  forM_ [minBound .. maxBound] $ \first →
    forM_ [minBound .. maxBound] $ \hook →
      forM_ [minBound .. maxBound] $ \route →
        it (describe' first hook route) $ bounded (cell first hook route)
  it "keeps the failure of a callback whose wait the scheduler refused as primary when its shutdown then fails the host" $ bounded $ do
    fixture ← newIFixture
    told ← newTVarIO []
    let config = (testConfig instanceBounds') {instanceEscalate = \failure → atomically (modifyTVar' told (failure :)) >> pure Isolate}
    ExceptionWithContext _ raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "refused" [refusedWaitHostShutdown] config requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed "refusedwaithostshutdown")
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      void (awaitScheduledTerminal control owner)
    -- The instance's end came from the scheduler's close of its suspended coroutine, and
    -- its primary failure is the scheduler's refusal; the hook's failure of the host is the
    -- owner's, and the refusal is neither lost nor replaced when retirement settles it.
    raised `shouldSatisfy` brokenIs "shutdown host"
    atomically (readTVar told >>= \held → when (null held) retry)
    readTVarIO told >>= (`shouldSatisfy` ((== 1) . length))
    settled ← tickOf fixture "a" >>= pollInstance
    fmap resultPhase settled `shouldBe` Just Failed
    fmap (fmap (\failure → case failureError failure of ErrorRefusedWait _ → True; _ → False) . failureOf') settled `shouldBe` Just (Just True)
    fmap (terminationShutdown . resultTermination) settled `shouldBe` Just ShutdownRaised
  it "tells an owner that is exiting of a failed instance without raising what the application decides: the owner's own failure is what it exits with" $ bounded $ do
    fixture ← newIFixture
    told ← newTVarIO (0 ∷ Int)
    let config = (testConfig instanceBounds') {instanceEscalate = \_ → atomically (modifyTVar' told (+ 1)) >> pure Escalate}
    ExceptionWithContext context raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "escalating" [matrixModule FirstLua HookHost] config requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed (tag FirstLua HookHost))
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      void (awaitScheduledTerminal control owner)
    raised `shouldSatisfy` brokenIs "shutdown host"
    -- Nothing was raised by the telling, so there is no evidence of it beside the failure.
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` notElem "lua instance retirement"
    readTVarIO told >>= (`shouldBe` 1)
    settled ← tickOf fixture "a" >>= pollInstance
    fmap resultPhase settled `shouldBe` Just Failed
  it "keeps what telling the application raised beside the owner's own failure, and the instance as it settled" $ bounded $ do
    fixture ← newIFixture
    told ← newTVarIO (0 ∷ Int)
    let config = (testConfig instanceBounds') {instanceEscalate = \_ → atomically (modifyTVar' told (+ 1)) >> throwIO (Broken "escalation")}
    ExceptionWithContext context raised ← expectFatal $ \control runtime → do
      owner ← startInstances fixture runtime "told" [matrixModule FirstLua HookHost] config requiredPolicy
      _ ← admit fixture owner "a" (moduleNamed (tag FirstLua HookHost))
      awaitPhase fixture owner "a" Active
      expectDelivered fixture owner "a" 1
      void (awaitScheduledTerminal control owner)
    -- The owner's own failure is the shutdown's, a failure of the host; what the
    -- application's escalation raised as the instance was settled is cleanup evidence
    -- beside it, not lost, and not taken for the owner's own.
    raised `shouldSatisfy` brokenIs "shutdown host"
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua instance retirement"
    -- Told once, though settling the instance raised and retirement came back to it.
    readTVarIO told >>= (`shouldBe` 1)
    settled ← tickOf fixture "a" >>= pollInstance
    fmap resultPhase settled `shouldBe` Just Failed
    fmap (fmap failureMessage . failureOf') settled `shouldSatisfy` maybe False (maybe False (Text.isInfixOf "callback boom"))
  where
    describe' first hook route =
      "keeps the first failure and the true shutdown disposition: "
        <> Text.unpack (Text.intercalate ", " [Text.pack (show first), Text.pack (show hook), Text.pack (show route)])

-- | One cell of the matrix.
cell ∷ First → Hook → Route → IO ()
cell first hook route = do
  fixture ← newIFixture
  told ← newTVarIO []
  let shape = shapeOf first hook route
      config = (testConfig instanceBounds') {instanceEscalate = \failure → atomically (modifyTVar' told (failure :)) >> pure Isolate}
      modules = [matrixModule first hook] <> [hostFailing | route == RouteTeardown]
      -- The owner is gone once the callback's failure of the host, or the shutdown's, ended
      -- it: nothing is asked of it after.
      goneAtTick = first == FirstHost || (first == FirstLua && hook == HookHost)
      survives = isNothing (shapeOwner shape)
      body control runtime = do
        owner ← startInstances fixture runtime "matrix" modules config requiredPolicy
        _ ← admit fixture owner "a" (moduleNamed (tag first hook))
        when (route == RouteTeardown) $ do
          _ ← admit fixture owner "z" (moduleNamed "hostfailing")
          awaitPhase fixture owner "z" Active
        awaitPhase fixture owner "a" Active
        when (first /= FirstNone) $ expectDelivered fixture owner "a" 1
        -- A callback's failure ends its instance before the instance is asked to end.
        when (first == FirstLua && not goneAtTick) $ void (awaitSettled fixture "a")
        unless goneAtTick $ case route of
          RouteStop → when (first == FirstNone) $ void (settleControl fixture owner "a" InstanceStop)
          RouteRetire → retireScheduled owner
          RouteTeardown → expectDelivered fixture owner "z" 1
        -- An owner that survives what happened to the instance is brought down in order.
        when (survives && route /= RouteRetire) $ do
          void (awaitSettled fixture "a")
          retireScheduled owner
        void (awaitScheduledTerminal control owner)
  raised ←
    if survives
      then withBoundary body >> pure Nothing
      else Just . (\(ExceptionWithContext _ failure) → failure) <$> expectFatal (\control runtime → body control runtime)
  forM_ ((,) <$> shapeOwner shape <*> raised) $ \(message, failure) → failure `shouldSatisfy` brokenIs message
  when (not survives) $ raised `shouldSatisfy` isJust
  -- The notification is waited for, not assumed: it is made after the instance settled.
  atomically (readTVar told >>= \held → when (length held < shapeTold shape) retry)
  held ← readTVarIO told
  identity ← idOf fixture "a"
  map failureInstance held `shouldBe` replicate (shapeTold shape) identity
  settled ← tickOf fixture "a" >>= pollInstance
  case settled of
    Nothing → fail "the instance was never settled"
    Just result → do
      resultPhase result `shouldBe` shapePhase shape
      terminationShutdown (resultTermination result) `shouldBe` shapeDisposition shape
      case resultOutcome result of
        InstanceDiscarded (Discard ExitFailed Started) → shapeDiscarded shape `shouldBe` True
        InstanceDiscarded other → fail ("discarded as " <> show other)
        InstanceStopped → do
          shapeDiscarded shape `shouldBe` False
          shapePhase shape `shouldBe` Stopped
          isNothing (shapeFirst shape) `shouldBe` True
        InstanceCompleted → fail "a one-shot's completion"
        InstanceFailed failure → case shapeFirst shape of
          Nothing → fail "a failure was not expected"
          Just (stage, text) → do
            failureStage failure `shouldBe` stage
            failureMessage failure `shouldSatisfy` Text.isInfixOf text
            isJust (failureTraceback failure) `shouldBe` shapeTraceback shape
            map fst (failureSecondary failure) `shouldBe` shapeSecondary shape
  recorded ← any (Text.isPrefixOf "shutdown") <$> logged fixture
  recorded `shouldBe` shapeHookRecorded shape
