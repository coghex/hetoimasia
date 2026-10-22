-- | Bindings opted in to recoverable refusals, run under real supervision.
--
-- The host's own examples show that a refusal an opted-in binding makes before its
-- action is an ordinary Lua error. What these add is what a supervised owner makes
-- of the calls and tasks that catch one: a finite call and a scheduled task go on
-- and succeed after a caught refusal; an uncaught one is the script's fault, and
-- only its call's or task's; and what the opt-in does not touch is untouched. An
-- application's failure that a script caught still ends the owner under its policy
-- and with its own type, a cancellation is still delivered where it always was,
-- what closing a coroutine or a finalizer raised is still retained, and a fault a
-- binding that is not opted in latched is never erased by a later success.
module Test.LuaRuntime.Recoverable (spec) where

import Control.Concurrent.MVar (readMVar, tryPutMVar)
import Control.Exception (ExceptionWithContext (ExceptionWithContext), throwIO)
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Hetoimasia.Foundation.Resource (cleanupFailureLabel, cleanupFailuresInContext)
import Hetoimasia.Runtime.Supervision (WorkerPolicy, WorkerStatus (WorkerStopped, WorkerUnavailable))
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Test.LuaRuntime.Scheduled.Support
  ( SFixture (..)
  , awaitDiagnostics
  , cancelQueued
  , defaultSchedulerBounds
  , effects
  , newSFixture
  , outcomeOf
  , request
  , startScheduled
  , taskReturned
  )
import qualified Test.LuaRuntime.Scheduled.Support as Scheduled
import Test.LuaRuntime.Support
  ( Broken (Broken)
  , Fixture (fixtureEntered, fixtureGates)
  , Gated (openAllGates)
  , accepted
  , awaitTerminal
  , bounded
  , bounds
  , brokenIs
  , cancelPending
  , expectFatal
  , failExample
  , gateIn
  , isDiscard
  , newFixture
  , optionalPolicy
  , ownerSpec
  , requiredPolicy
  , returnedValues
  , settleOutcome
  , startOwner
  , withBoundary
  , withBoundaryOpening
  )
import qualified Test.LuaRuntime.Support as Finite

-- The registration ---------------------------------------------------------------

-- | The namespaces both kinds of owner share: @chk@ is opted in, @plain@ is not.
-- The one example that needs the engine's own state reads it from the reference.
namespaces ∷ IORef Bool → (Text → IO ()) → (Text → IO ()) → [Namespace]
namespaces open record block =
  [ namespace
      "chk"
      [ recoverableRefusals . snapshotQuery "add" [SInteger, SInteger] [SInteger] $ \arguments → do
          record "add"
          pure $ case arguments of
            [VInteger a, VInteger b] → [VInteger (a + b)]
            _ → []
      , recoverableRefusals . stateOperation "fail" [SText] [] $ \arguments → do
          case arguments of
            [VText kind] → throwIO (Broken kind)
            _ → pure ()
          pure []
      , recoverableRefusals . stateOperation "block" [SText] [] $ \arguments → do
          case arguments of
            [VText name] → block name
            _ → pure ()
          pure []
      , withPrecondition
          (\_ → (\isOpen → if isOpen then Nothing else Just "closed") <$> readIORef open)
          (stateOperation "when_open" [] [] (\_ → record "when_open" >> pure []))
      , finalizerEligible . recoverableRefusals . stateOperation "gc_fail" [] [] $ \_ → throwIO (Broken "gc")
      ]
  , namespace
      "plain"
      [ snapshotQuery "add" [SInteger, SInteger] [SInteger] $ \arguments → do
          record "plain add"
          pure $ case arguments of
            [VInteger a, VInteger b] → [VInteger (a + b)]
            _ → []
      ]
  ]

-- | A registration of exactly these namespaces and the scheduler's, when the
-- owner has one.
registrationOf ∷ [Namespace] → Registration
registrationOf = either (error . ("registration refused: " <>) . show) id . registration []

-- | What a script sees when it catches the refusal of @chk.add(1.5, 2)@.
refusedAdd ∷ Text
refusedAdd = "chk.add: argument 1: a float where an integer is declared"

-- Finite calls -------------------------------------------------------------------

recovModule ∷ ModuleSource
recovModule = ModuleSource (ModuleRef "recov" "1") finiteSource finiteEntries

finiteEntries ∷ [EntryPoint]
finiteEntries =
  [ EntryPoint "caught_then_value" Required [] [SInteger]
  , EntryPoint "uncaught" Required [] []
  , EntryPoint "catch_then_fail" Required [SText] []
  , EntryPoint "legacy_then_recoverable" Required [] [SInteger]
  , EntryPoint "blocked" Required [SText] [SInteger]
  ]

finiteSource ∷ ByteString
finiteSource =
  Text.encodeUtf8 . Text.unlines $
    [ "function caught_then_value()"
    , "  local ok, err = pcall(chk.add, 1.5, 2)"
    , "  assert(ok == false and err == '" <> refusedAdd <> "', tostring(err))"
    , "  return chk.add(1, 2)"
    , "end"
    , "function uncaught() chk.add(1.5, 2) end"
    , "function catch_then_fail(kind) pcall(chk.add, 1.5, 2) chk.fail(kind) end"
    , "function legacy_then_recoverable()"
    , "  pcall(plain.add, 1.5, 2)"
    , "  pcall(chk.add, 1.5, 2)"
    , "  return chk.add(1, 2)"
    , "end"
    , "function blocked(name) pcall(chk.add, 1.5, 2) chk.block(name) return 1 end"
    ]

-- | An owner of this label and policy over the opted-in namespaces, loading the
-- module above.
finiteOwner ∷ Fixture → Text → WorkerPolicy → OwnerSpec
finiteOwner fixture label policy =
  base {ownerVm = (ownerVm base) {vmRegistration = built, vmPolicy = ["chk", "plain"], vmModules = [recovModule]}}
  where
    base = ownerSpec fixture label [] policy (bounds 8 8)
    built = registrationOf (namespaces (unusedOpen) (Finite.note fixture) block)
    block name = do
      gateIn (fixtureEntered fixture) name >>= void . (`tryPutMVar` ())
      gateIn (fixtureGates fixture) name >>= readMVar

-- | What a finite example's engine state is when it has none.
unusedOpen ∷ IORef Bool
unusedOpen = error "this owner's example reads no engine state"
{-# NOINLINE unusedOpen #-}

call ∷ OwnerEndpoint → Text → [Value] → IO CallTicket
call endpoint entry arguments = submitCall endpoint (ModuleRef "recov" "1") entry arguments >>= accepted

finiteSpec ∷ Spec
finiteSpec = describe "a finite call" $ do
  it "goes on and succeeds after the refusal it caught, and the owner serves the next call" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (finiteOwner fixture "caught" requiredPolicy)
      first ← call (ownerEndpoint owner) "caught_then_value" []
      second ← call (ownerEndpoint owner) "caught_then_value" []
      returnedValues <$> settleOutcome first >>= (`shouldBe` Just [VInteger 3])
      returnedValues <$> settleOutcome second >>= (`shouldBe` Just [VInteger 3])
      Finite.noted fixture >>= (`shouldBe` ["add", "add"])
      retireOwner owner

  it "settles an uncaught refusal as the script's fault of that call alone, and serves the next" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (finiteOwner fixture "uncaught" requiredPolicy)
      refused ← call (ownerEndpoint owner) "uncaught" []
      next ← call (ownerEndpoint owner) "caught_then_value" []
      settleOutcome refused >>= \case
        CallFaulted (BoundaryFailed fault) → do
          boundaryReason fault `shouldBe` ScriptFailed CallFailed (ErrorMessage refusedAdd False)
          boundaryEffect fault `shouldBe` LuaRan
        other → failExample ("expected the script's fault, found " <> show other)
      returnedValues <$> settleOutcome next >>= (`shouldBe` Just [VInteger 3])
      retireOwner owner

  it "still ends the owner, under its policy and with its own type, for an application failure the script caught after a refusal" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \control runtime → do
      owner ← startOwner runtime (finiteOwner fixture "failing" (optionalPolicy (brokenIs "bang")))
      failing ← call (ownerEndpoint owner) "catch_then_fail" [VText "bang"]
      awaitTerminal control owner >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "bang"
        other → failExample ("expected an unavailable owner, found " <> show other)
      settleOutcome failing >>= (`shouldSatisfy` isDiscard ExitFailed Started)

  it "never lets a later recoverable response erase the fault a binding that is not opted in latched" $ bounded $ do
    fixture ← newFixture
    withBoundary $ \_ runtime → do
      owner ← startOwner runtime (finiteOwner fixture "latched" requiredPolicy)
      latched ← call (ownerEndpoint owner) "legacy_then_recoverable" []
      next ← call (ownerEndpoint owner) "caught_then_value" []
      settleOutcome latched >>= \case
        CallFaulted (BoundaryFailed fault) → do
          boundaryBinding fault `shouldBe` Just ("plain", "add")
          boundaryReason fault `shouldSatisfy` \case ValueRefused _ → True; _ → False
        other → failExample ("expected the latched refusal, found " <> show other)
      returnedValues <$> settleOutcome next >>= (`shouldBe` Just [VInteger 3])
      retireOwner owner

  it "delivers a cancellation where it always was: after the call that was inside a binding returns" $ bounded $ do
    fixture ← newFixture
    withBoundaryOpening [openAllGates fixture] $ \control runtime → do
      owner ← startOwner runtime (finiteOwner fixture "cancelled" requiredPolicy)
      inflight ← call (ownerEndpoint owner) "blocked" [VText "go"]
      Finite.awaitEntered fixture "go"
      cancelPending (cancelOwner owner)
      Finite.releaseGate fixture "go"
      awaitTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      settleOutcome inflight >>= (`shouldSatisfy` isDiscard ExitCancelled Started)

  it "keeps what a finalizer raised in the close beside the application's failure" $ bounded $ do
    fixture ← newFixture
    ExceptionWithContext context failure ← expectFatal $ \control runtime → do
      let base = finiteOwner fixture "evidence" (optionalPolicy (brokenIs "bang"))
          withFinalizer =
            base
              { ownerVm =
                  (ownerVm base)
                    { vmInitialChunks =
                        [(chunkName "gc", Text.encodeUtf8 "collectgarbage('stop') holder = setmetatable({}, {__gc = function() chk.gc_fail() end})")]
                    }
              }
      owner ← startOwner runtime withFinalizer
      _ ← call (ownerEndpoint owner) "catch_then_fail" [VText "bang"]
      awaitTerminal control owner
    failure `shouldSatisfy` brokenIs "bang"
    map cleanupFailureLabel (cleanupFailuresInContext context) `shouldSatisfy` elem "lua finalizer"

-- Scheduled tasks ----------------------------------------------------------------

tasksModule ∷ ModuleSource
tasksModule = ModuleSource (ModuleRef "recov-tasks" "1") taskSource taskEntries

taskEntries ∷ [EntryPoint]
taskEntries =
  [ EntryPoint "continue" Required [SText] [SInteger]
  , EntryPoint "uncaught" Required [SText] []
  , EntryPoint "catch_then_fail" Required [SText] []
  , EntryPoint "legacy_then_recoverable" Required [SText] [SInteger]
  , EntryPoint "blocked" Required [SText] [SInteger]
  , EntryPoint "guarded" Required [SText] []
  , EntryPoint "phases" Required [SText] [SInteger]
  ]

taskSource ∷ ByteString
taskSource =
  Text.encodeUtf8 . Text.unlines $
    [ "function continue(label)"
    , "  local ok, err = pcall(chk.add, 1.5, 2)"
    , "  assert(ok == false and err == '" <> refusedAdd <> "', tostring(err))"
    , "  fx.record(label .. ' caught')"
    , "  sched.yield()"
    , "  local total = chk.add(1, 2)"
    , "  fx.record(label .. ' ' .. total)"
    , "  return total"
    , "end"
    , "function uncaught(label) chk.add(1.5, 2) end"
    , "function catch_then_fail(kind) pcall(chk.add, 1.5, 2) sched.yield() chk.fail(kind) end"
    , "function legacy_then_recoverable(label)"
    , "  pcall(plain.add, 1.5, 2)"
    , "  pcall(chk.add, 1.5, 2)"
    , "  sched.yield()"
    , "  return chk.add(1, 2)"
    , "end"
    , "function blocked(name) pcall(chk.add, 1.5, 2) chk.block(name) return 1 end"
    , "function guarded(label)"
    , "  local guard <close> = setmetatable({}, {__close = function() fx.record(label .. ' closing') fx.fail('close boom') end})"
    , "  pcall(chk.add, 1.5, 2)"
    , "  sched.wait_ticks(1)"
    , "end"
    , "function phases(label)"
    , "  local closed = pcall(chk.when_open)"
    , "  fx.record(label .. ' ' .. tostring(closed))"
    , "  sched.yield()"
    , "  local open = pcall(chk.when_open)"
    , "  fx.record(label .. ' ' .. tostring(open))"
    , "  return 1"
    , "end"
    ]

-- | A scheduled owner of this label and policy over the opted-in namespaces beside
-- the scheduler's own, with the engine's state in the reference.
scheduledOwner ∷ SFixture → IORef Bool → Text → WorkerPolicy → ScheduledSpec
scheduledOwner fixture open label policy =
  base {scheduledVm = (scheduledVm base) {vmRegistration = built, vmPolicy = ["sched", "fx", "chk", "plain"], vmModules = [tasksModule]}}
  where
    base = Scheduled.scheduled fixture label policy defaultSchedulerBounds
    original = Scheduled.schedRegistration fixture
    record text = atomicModifyIORef' (sfLog fixture) (\held → (text : held, ()))
    block name = do
      gateIn (sfEntered fixture) name >>= void . (`tryPutMVar` ())
      gateIn (sfGates fixture) name >>= readMVar
    built =
      registrationOf
        ( registrationNamespaces original
            <> namespaces open record block
        )

task ∷ SFixture → ScheduledOwner → Text → [Value] → IO ScheduledTicket
task fixture owner entry arguments =
  Scheduled.admitTask' fixture owner entry (taskRequest entry arguments)

taskRequest ∷ Text → [Value] → TaskRequest
taskRequest entry arguments = (request entry arguments OrdinaryClass OneShot Nothing) {requestModule = ModuleRef "recov-tasks" "1"}

tasksSpec ∷ Spec
tasksSpec = describe "a scheduled task" $ do
  it "goes on and succeeds after the refusal it caught, and the owner serves the next task" $ bounded $ do
    fixture ← newSFixture
    open ← newIORef True
    withBoundary $ \_ runtime → do
      owner ← startScheduled fixture runtime (scheduledOwner fixture open "caught" requiredPolicy)
      one ← task fixture owner "continue" [VText "a"]
      two ← task fixture owner "continue" [VText "b"]
      taskReturned <$> outcomeOf one >>= (`shouldBe` Just [VInteger 3])
      taskReturned <$> outcomeOf two >>= (`shouldBe` Just [VInteger 3])
      effects fixture >>= (`shouldSatisfy` \held → all (`elem` held) ["a caught", "a 3", "b caught", "b 3"])
      retireScheduled owner

  it "reads the engine's state at each call, so a refusal in one segment is not one in the next" $ bounded $ do
    fixture ← newSFixture
    open ← newIORef False
    -- The application opens the gate as the second segment is about to run.
    writeIORef (sfObserver fixture) $ \context → when (contextSegment context >= 1) (writeIORef open True)
    withBoundary $ \_ runtime → do
      owner ← startScheduled fixture runtime (scheduledOwner fixture open "phases" requiredPolicy)
      ticket ← task fixture owner "phases" [VText "p"]
      taskReturned <$> outcomeOf ticket >>= (`shouldBe` Just [VInteger 1])
      effects fixture >>= (`shouldBe` ["p false", "when_open", "p true"])
      retireScheduled owner

  it "settles an uncaught refusal as that task's fault alone, and serves the next task" $ bounded $ do
    fixture ← newSFixture
    open ← newIORef True
    withBoundary $ \_ runtime → do
      owner ← startScheduled fixture runtime (scheduledOwner fixture open "uncaught" requiredPolicy)
      refused ← task fixture owner "uncaught" [VText "u"]
      next ← task fixture owner "continue" [VText "n"]
      outcomeOf refused >>= \case
        SettledFaulted (BoundaryFailed fault) → do
          boundaryReason fault `shouldBe` ScriptFailed CallFailed (ErrorMessage refusedAdd False)
          boundaryEffect fault `shouldBe` LuaRan
        other → failExample ("expected the task's fault, found " <> show other)
      taskReturned <$> outcomeOf next >>= (`shouldBe` Just [VInteger 3])
      retireScheduled owner

  it "still ends the owner, under its policy and with its own type, for an application failure the script caught after a refusal" $ bounded $ do
    fixture ← newSFixture
    open ← newIORef True
    withBoundary $ \control runtime → do
      owner ← startScheduled fixture runtime (scheduledOwner fixture open "failing" (optionalPolicy (brokenIs "bang")))
      failing ← task fixture owner "catch_then_fail" [VText "bang"]
      Scheduled.awaitScheduledTerminal control owner >>= \case
        WorkerUnavailable (ExceptionWithContext _ failure) → failure `shouldSatisfy` brokenIs "bang"
        other → failExample ("expected an unavailable owner, found " <> show other)
      outcomeOf failing >>= (`shouldSatisfy` \case SettledDiscarded (Discard ExitFailed Started) → True; _ → False)

  it "never lets a later recoverable response erase the fault a binding that is not opted in latched" $ bounded $ do
    fixture ← newSFixture
    open ← newIORef True
    withBoundary $ \_ runtime → do
      owner ← startScheduled fixture runtime (scheduledOwner fixture open "latched" requiredPolicy)
      latched ← task fixture owner "legacy_then_recoverable" [VText "l"]
      outcomeOf latched >>= \case
        SettledFaulted (BoundaryFailed fault) → do
          boundaryBinding fault `shouldBe` Just ("plain", "add")
          boundaryReason fault `shouldSatisfy` \case ValueRefused _ → True; _ → False
        other → failExample ("expected the latched refusal, found " <> show other)
      retireScheduled owner

  it "delivers a cancellation where it always was: behind the segment that was inside a binding" $ bounded $ do
    fixture ← newSFixture
    open ← newIORef True
    withBoundaryOpening [openAllGates fixture] $ \control runtime → do
      owner ← startScheduled fixture runtime (scheduledOwner fixture open "cancelled" requiredPolicy)
      inflight ← task fixture owner "blocked" [VText "go"]
      Scheduled.awaitEntered fixture "go"
      cancelQueued owner
      Scheduled.releaseGate fixture "go"
      Scheduled.awaitScheduledTerminal control owner >>= (`shouldSatisfy` \case WorkerStopped → True; _ → False)
      -- The segment that was inside the binding returned and finished the task: a
      -- task that completed keeps its result, and the cancellation landed behind it.
      taskReturned <$> outcomeOf inflight >>= (`shouldBe` Just [VInteger 1])

  it "keeps what closing a suspended coroutine raised beside the application's failure" $ bounded $ do
    fixture ← newSFixture
    open ← newIORef True
    ExceptionWithContext context failure ← expectFatal $ \control runtime → do
      owner ← startScheduled fixture runtime (scheduledOwner fixture open "evidence" (optionalPolicy (const True)))
      _ ← task fixture owner "guarded" [VText "g"]
      awaitDiagnostics owner (\counts → diagWaiting counts >= 1)
      _ ← task fixture owner "catch_then_fail" [VText "bang"]
      Scheduled.awaitScheduledTerminal control owner
    failure `shouldSatisfy` brokenIs "bang"
    length (cleanupFailuresInContext context) `shouldSatisfy` (>= 1)
    effects fixture >>= (`shouldSatisfy` elem "g closing")

spec ∷ Spec
spec = describe "recoverable refusals under supervision" $ do
  finiteSpec
  tasksSpec
