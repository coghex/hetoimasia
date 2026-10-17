-- | Tasks: a module's entry point run as a Lua coroutine on its VM's owner.
--
-- The examples use real VMs and assert expected values. Nothing here is a
-- scheduler and none of them uses a clock, a timer or a queue: a wait is
-- reported with its arguments and resumed by the example when it chooses, which
-- is all the host does with one.
--
-- @sched@ stands for whatever namespace an application would register its
-- scheduler operations in; @probe@ for the rest of what its scripts call. Both
-- are fixtures, and name nothing of a game.
module Test.Lua.Boundary.Tasks (spec) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( AsyncException (UserInterrupt)
  , ExceptionWithContext (ExceptionWithContext)
  , IOException
  , SomeException
  , fromException
  , try
  )
import Control.Monad (forM, forM_, replicateM_, void)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Hetoimasia.Foundation.Resource (cleanupFailureException, cleanupFailureLabel, cleanupFailures)
import Hetoimasia.Scripting.Lua.Internal.Module (liveModuleReferences)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (ownerBudget, ownerGranted, ownerModules, ownerName, ownerRegistration)
  , defaultOwnerConfig
  , ownedHost
  , ownedInternalVm
  , withOwnedVm
  )
import Hetoimasia.Scripting.Lua.Internal.Task (liveTaskReferences)
import Hetoimasia.Scripting.Lua.Internal.Vm (probeReferenceSlot, stackDepth)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Support (Settled (settledOperation), awaitSettled, cancelling, observedCancellation, settling)
import Test.Support.Bounded (bounded)

-- | What the fixture's bindings did, oldest first, and the pair of signals a
-- binding that holds its owner uses.
data Probe = Probe
  { probeLog ∷ !(IORef [Text])
  , probeEntered ∷ !(MVar ())
  , probeRelease ∷ !(MVar ())
  , probeSelf ∷ !(IORef (Maybe (OwnedVm, ModuleHandle, Task)))
    -- ^ The VM and task the @poke@ binding's action tries to use.
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newIORef [] <*> newEmptyMVar <*> newEmptyMVar <*> newIORef Nothing

note ∷ Probe → Text → IO ()
note probe entry = atomicModifyIORef' (probeLog probe) (\held → (entry : held, ()))

logged ∷ Probe → IO [Text]
logged probe = reverse <$> readIORef (probeLog probe)

-- | The scheduler operations and the bindings the task modules call.
taskRegistration ∷ Probe → Registration
taskRegistration probe =
  either (error . ("registration refused: " <>) . show) id $
    registration
      []
      [ namespace
          "sched"
          [ yieldOperation "yield"
          , waitOperation "wait_elapsed" WaitElapsed [SFloat]
          , waitOperation "wait_tick" WaitLogical [SInteger]
          , waitOperation "wait_pair" WaitLogical [SInteger, SText]
          , waitOperation "wait_text" WaitElapsed [SText]
          , finalizerEligible (yieldOperation "yield_gc")
          ]
      , namespace
          "probe"
          [ stateOperation "note" [SText] [] $ \arguments → do
              note probe ("note " <> render arguments)
              pure []
          , finalizerEligible . stateOperation "note_gc" [SText] [] $ \arguments → do
              note probe ("note_gc " <> render arguments)
              pure []
          , snapshotQuery "integer_only" [SInteger] [] (\_ → note probe "integer_only" >> pure [])
          , stateOperation "fail" [] [] $ \_ → do
              note probe "fail"
              ioError (userError "the action failed")
          , stateOperation "raise" [SText] [] $ \arguments → do
              note probe ("raise " <> render arguments)
              ioError (userError (Text.unpack (render arguments)))
          , stateOperation "poke" [] [] $ \_ → do
              found ← readIORef (probeSelf probe)
              forM_ found $ \(owned, handle, task) → do
                started ← try @VmReentered (startTask owned handle "yield_once" [])
                resumed ← try @VmReentered (resumeTask owned task)
                closed ← try @VmReentered (closeTask owned task)
                note probe ("poke " <> Text.pack (show (isLeft' started, isLeft' resumed, isLeft' closed)))
              pure []
          , stateOperation "hold" [] [] $ \_ → do
              putMVar (probeEntered probe) ()
              takeMVar (probeRelease probe)
              pure []
          ]
      ]
  where
    render [VText text] = text
    render _ = "?"
    isLeft' = either (const True) (const False)

-- | Application-owned code that runs as tasks.
workerSource ∷ Text
workerSource =
  Text.unlines
    [ "function counter(n)"
    , "  local total = 0"
    , "  for i = 1, n do"
    , "    total = total + i"
    , "    sched.yield()"
    , "  end"
    , "  return total"
    , "end"
    , "function instant(a, b) return a + b end"
    , "function waiter()"
    , "  sched.wait_elapsed(1.5)"
    , "  sched.wait_tick(7)"
    , "  return 'done'"
    , "end"
    , "function wait_pair() sched.wait_pair(3, 'tag'); return 1 end"
    , "function wait_bad_type() sched.wait_tick('soon'); return 1 end"
    , "function wait_bad_arity() sched.wait_tick(); return 1 end"
    , "function wait_long() sched.wait_text(string.rep('x', 70000)); return 1 end"
    , "function wait_caught() print(pcall(sched.wait_tick, {})) return 1 end"
    , "function script_error()"
    , "  sched.yield()"
    , "  error('exploded in a segment')"
    , "end"
    , "function error_first() error('exploded at once') end"
    , "function bad_result() sched.yield(); return 'not an integer' end"
    , "function bad_count() sched.yield(); return 1, 2 end"
    , "function bad_argument() sched.yield(); probe.integer_only('text') end"
    , "function caught_refusal_then_yield()"
    , "  pcall(probe.integer_only, 'text')"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function caught_refusal_then_wait()"
    , "  pcall(probe.integer_only, 'text')"
    , "  sched.wait_tick(1)"
    , "  return 1"
    , "end"
    , "function caught_refusal_then_return()"
    , "  sched.yield()"
    , "  pcall(probe.integer_only, 'text')"
    , "  return 1"
    , "end"
    , "function caught_failure_then_yield()"
    , "  pcall(probe.fail)"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function resume_failure_then_wait()"
    , "  local co = coroutine.create(function() probe.fail() end)"
    , "  coroutine.resume(co)"
    , "  sched.wait_tick(2)"
    , "  return 1"
    , "end"
    , "function resume_refusal_then_yield()"
    , "  local co = coroutine.create(function() probe.integer_only('text') end)"
    , "  coroutine.resume(co)"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function failing_action() sched.yield(); probe.fail(); return 1 end"
    , "function with_guard(name)"
    , "  local guard <close> = setmetatable({}, {__close = function()"
    , "    closed = (closed or 0) + 1"
    , "    probe.note_gc('closed ' .. name)"
    , "  end})"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function with_failing_guard(name)"
    , "  local guard <close> = setmetatable({}, {__close = function() error('close of ' .. name .. ' failed') end})"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function with_refused_guard()"
    , "  local guard <close> = setmetatable({}, {__close = function() probe.note('refused') ; closed = (closed or 0) + 1 end})"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function two_guards()"
    , "  local first <close> = setmetatable({}, {__close = function() closed = (closed or 0) + 1 end})"
    , "  local second <close> = setmetatable({}, {__close = function() closed = (closed or 0) + 10 end})"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function guard_yield()"
    , "  local guard <close> = setmetatable({}, {__close = function() pcall(sched.yield); yielded_in_close = true end})"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function yield_in_pcall()"
    , "  local ok = pcall(sched.yield)"
    , "  local fine, why = xpcall(sched.wait_tick, function(m) return m end, 4)"
    , "  return (ok and fine) and 1 or 0"
    , "end"
    , "function share() shared = coroutine.running(); sched.yield(); return 1 end"
    , "function steal() local ok = coroutine.resume(shared); return ok end"
    , "function poker() sched.yield(); probe.poke(); return 1 end"
    , "function heap_kb() collectgarbage(); collectgarbage(); return math.floor(collectgarbage('count')) end"
    , "function double_failure()"
    , "  local guard <close> = setmetatable({}, {__close = function() probe.raise('CLEANUP') end})"
    , "  sched.yield()"
    , "  probe.raise('PRIMARY')"
    , "end"
    , "function script_error_then_cleanup_failure()"
    , "  local guard <close> = setmetatable({}, {__close = function() probe.raise('CLEANUP') end})"
    , "  sched.yield()"
    , "  error('the script failed')"
    , "end"
    , "function many_cleanup_failures()"
    , "  local a <close> = setmetatable({}, {__close = function() probe.raise('FIRST') end})"
    , "  local b <close> = setmetatable({}, {__close = function() probe.raise('SECOND') end})"
    , "  sched.yield()"
    , "  return 1"
    , "end"
    , "function late_failure_with_guard()"
    , "  shared = coroutine.running()"
    , "  local guard <close> = setmetatable({}, {__close = function() probe.note('cleanup ran'); error('the close failed') end})"
    , "  sched.yield()"
    , "  error('late failure')"
    , "end"
    , "function resume_shared() local ok = coroutine.resume(shared); return ok end"
    , "function closed_count() return closed or 0 end"
    , "function yielded_in_close_flag() return yielded_in_close == true end"
    , "function holder() sched.yield(); probe.hold(); sched.yield(); return 1 end"
    , "function yield_once() sched.yield(); return 1 end"
    , "function stray() coroutine.yield(1) return 1 end"
    , "function stray_pcall() pcall(coroutine.yield) return 1 end"
    , "function inner_yield()"
    , "  local co = coroutine.create(function() sched.yield() end)"
    , "  local ok, why = coroutine.resume(co)"
    , "  probe.note('inner resume ' .. tostring(ok))"
    , "  after_inner = true"
    , "  return ok, why"
    , "end"
    , "function wrapped_generator()"
    , "  local gen = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i) end end)"
    , "  local sum = 0"
    , "  for _ = 1, 3 do sum = sum + gen(); sched.yield() end"
    , "  return sum"
    , "end"
    , "function made_coroutine() return coroutine.create(function() end) end"
    , "function yield_in_metamethod()"
    , "  local t = setmetatable({}, {__index = function() sched.yield(); return 1 end})"
    , "  local x = t.anything"
    , "  return 1"
    , "end"
    , "function yield_in_sort()"
    , "  table.sort({3, 2, 1}, function(a, b) sched.yield(); return a < b end)"
    , "  return 1"
    , "end"
    , "function yield_in_gsub()"
    , "  string.gsub('abc', '.', function() sched.yield() end)"
    , "  return 1"
    , "end"
    , "function collect_and_yield()"
    , "  setmetatable({}, {__gc = function() pcall(sched.yield_gc); gc_ran = true end})"
    , "  collectgarbage()"
    , "  return gc_ran == true"
    , "end"
    , "function call_yield() sched.yield(); return 1 end"
    , "function local_state(start)"
    , "  local value = start"
    , "  while true do"
    , "    value = value + 1"
    , "    sched.wait_tick(value)"
    , "    if value >= start + 2 then return value end"
    , "  end"
    , "end"
    , "function boom_if(flag)"
    , "  sched.yield()"
    , "  if flag then error('task failed') end"
    , "  return 0"
    , "end"
    ]

-- | The entry points, with their schemas.
workerEntries ∷ [EntryPoint]
workerEntries =
  [ required "counter" [SInteger] [SInteger]
  , required "instant" [SInteger, SInteger] [SInteger]
  , required "waiter" [] [SText]
  , required "wait_pair" [] [SInteger]
  , required "wait_bad_type" [] [SInteger]
  , required "wait_bad_arity" [] [SInteger]
  , required "wait_long" [] [SInteger]
  , required "wait_caught" [] [SInteger]
  , required "script_error" [] []
  , required "error_first" [] []
  , required "bad_result" [] [SInteger]
  , required "bad_count" [] [SInteger]
  , required "bad_argument" [] []
  , required "caught_refusal_then_yield" [] [SInteger]
  , required "caught_refusal_then_wait" [] [SInteger]
  , required "caught_refusal_then_return" [] [SInteger]
  , required "caught_failure_then_yield" [] [SInteger]
  , required "resume_failure_then_wait" [] [SInteger]
  , required "resume_refusal_then_yield" [] [SInteger]
  , required "failing_action" [] [SInteger]
  , required "with_guard" [SText] [SInteger]
  , required "with_failing_guard" [SText] [SInteger]
  , required "with_refused_guard" [] [SInteger]
  , required "two_guards" [] [SInteger]
  , required "guard_yield" [] [SInteger]
  , required "yield_in_pcall" [] [SInteger]
  , required "share" [] [SInteger]
  , required "steal" [] [SBoolean]
  , required "poker" [] [SInteger]
  , required "heap_kb" [] [SInteger]
  , required "double_failure" [] []
  , required "script_error_then_cleanup_failure" [] []
  , required "many_cleanup_failures" [] [SInteger]
  , required "late_failure_with_guard" [] []
  , required "resume_shared" [] [SBoolean]
  , required "closed_count" [] [SInteger]
  , required "yielded_in_close_flag" [] [SBoolean]
  , required "holder" [] [SInteger]
  , required "yield_once" [] [SInteger]
  , required "stray" [] [SInteger]
  , required "stray_pcall" [] [SInteger]
  , required "inner_yield" [] [SBoolean, SOptional SText]
  , required "wrapped_generator" [] [SInteger]
  , required "made_coroutine" [] [SInteger]
  , required "yield_in_metamethod" [] [SInteger]
  , required "yield_in_sort" [] [SInteger]
  , required "yield_in_gsub" [] [SInteger]
  , required "collect_and_yield" [] [SBoolean]
  , required "call_yield" [] [SInteger]
  , required "local_state" [SInteger] [SInteger]
  , required "boom_if" [SBoolean] [SInteger]
  , optional "never_defined" [] []
  ]

required ∷ Text → [Schema] → [Schema] → EntryPoint
required name = EntryPoint name Required

optional ∷ Text → [Schema] → [Schema] → EntryPoint
optional name = EntryPoint name Optional

worker ∷ ModuleSource
worker = ModuleSource (ModuleRef "worker" "1") (encodeUtf8 workerSource) workerEntries

-- | An owner over the fixture, with the standard libraries tasks use.
taskConfig ∷ Probe → VmConfig
taskConfig probe =
  (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath, LibraryCoroutine])
    { vmRegistration = taskRegistration probe
    , vmPolicy = ["sched", "probe"]
    , vmOwnerName = "task owner"
    , vmModules = [worker]
    }

-- | A body over an owner and the worker's handle.
withWorker ∷ Probe → (OwnedVm → ModuleHandle → IO a) → IO a
withWorker probe body = withVmOwner (taskConfig probe) $ \owned → do
  found ← loadedModule owned (ModuleRef "worker" "1")
  case found of
    Just handle → body owned handle
    Nothing → error "the worker was not loaded"

-- | Start a task that must start.
begin ∷ OwnedVm → ModuleHandle → Text → [Value] → IO (Task, TaskStep)
begin owned handle name arguments = do
  started ← startTask owned handle name arguments
  case started of
    TaskStarted task step → pure (task, step)
    TaskEntryAbsent → error "the entry point was absent"

-- | The fault an operation raises.
faulted ∷ IO a → IO BoundaryFault
faulted action = do
  outcome ← try @BoundaryFault action
  case outcome of
    Left fault → pure fault
    Right _ → expectationFailure "no fault was raised" >> error "unreachable"

-- | What the VM's bookkeeping shows: the stack's depth, the registry slot a
-- temporary reference would take, the modules held and the tasks anchored.
bookkeeping ∷ OwnedVm → IO (Int, Int, Int, Int)
bookkeeping owned = do
  let vm = ownedInternalVm owned
  depth ← stackDepth vm
  slot ← probeReferenceSlot vm
  modules ← liveModuleReferences (ownedHost owned)
  tasks ← liveTaskReferences (ownedHost owned)
  pure (depth, fromIntegral slot, modules, tasks)

spec ∷ Spec
spec = describe "tasks" $ do
  executionSpec
  waitSpec
  faultSpec
  precedenceSpec
  cleanupSpec
  closingSpec
  refusalSpec
  librarySpec
  disciplineSpec
  teardownSpec
  cancellationSpec
  interleavingSpec

executionSpec ∷ Spec
executionSpec = describe "running an entry point as a coroutine" $ do
  it "starts with bounded arguments, yields, resumes, and completes with checked results" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, first) ← begin owned handle "counter" [VInteger 3]
      first `shouldBe` Yielded
      resumeTask owned task >>= (`shouldBe` Yielded)
      resumeTask owned task >>= (`shouldBe` Yielded)
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 6])

  it "completes at once when the entry point never yields, leaving a task that cannot be resumed" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, step) ← begin owned handle "instant" [VInteger 2, VInteger 40]
      step `shouldBe` Completed [VInteger 42]
      refused ← faulted (resumeTask owned task)
      boundaryReason refused `shouldBe` TaskRefused (TaskEnded TaskCompleted)
      boundaryEffect refused `shouldBe` NoEffect
      boundaryOperation refused `shouldBe` ResumeTask

  it "answers an optional entry point the module does not define without running anything" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      before ← bookkeeping owned
      startTask owned handle "never_defined" [] >>= (`shouldBe` TaskEntryAbsent)
      bookkeeping owned >>= (`shouldBe` before)

  it "checks the handle, the entry point and the arguments before anything runs, with no effect" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      undeclared ← faulted (startTask owned handle "nobody" [])
      boundaryReason undeclared `shouldBe` ModuleRefused (EntryUndeclared "nobody")
      boundaryEffect undeclared `shouldBe` NoEffect
      boundaryOperation undeclared `shouldBe` StartTask
      wrongType ← faulted (startTask owned handle "counter" [VText "three"])
      boundaryEffect wrongType `shouldBe` NoEffect
      wrongArity ← faulted (startTask owned handle "counter" [])
      boundaryEffect wrongArity `shouldBe` NoEffect
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "keeps a task's locals across its yields and waits" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, first) ← begin owned handle "local_state" [VInteger 10]
      first `shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 11])
      resumeTask owned task >>= (`shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 12]))
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 12])

waitSpec ∷ Spec
waitSpec = describe "waiting" $ do
  it "reports an elapsed wait and a logical wait with their arguments, and goes on when resumed" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, first) ← begin owned handle "waiter" []
      first `shouldBe` Waiting (WaitRequest WaitElapsed "sched" "wait_elapsed" [VFloat 1.5])
      resumeTask owned task >>= (`shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 7]))
      resumeTask owned task >>= (`shouldBe` Completed [VText "done"])

  it "reports every argument a wait was given, each checked against its schema" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (_, step) ← begin owned handle "wait_pair" []
      step `shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_pair" [VInteger 3, VText "tag"])

  it "refuses an argument of the wrong type, and the wrong count, as a fault of the call" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      wrongType ← faulted (startTask owned handle "wait_bad_type" [])
      boundaryOperation wrongType `shouldBe` CallBinding
      boundaryBinding wrongType `shouldBe` Just ("sched", "wait_tick")
      boundaryEffect wrongType `shouldBe` LuaRan
      boundaryModule wrongType `shouldBe` Just (ModuleRef "worker" "1")
      boundaryEntry wrongType `shouldBe` Just "wait_bad_type"
      case refusal wrongType of
        Just (ValueRefusal Arguments 1 [] (RuleWrongType "integer" "string") _) → pure ()
        other → expectationFailure ("unexpected refusal: " <> show other)
      wrongCount ← faulted (startTask owned handle "wait_bad_arity" [])
      case refusal wrongCount of
        Just (ValueRefusal Arguments 0 [] (RuleArity 1 0) _) → pure ()
        other → expectationFailure ("unexpected refusal: " <> show other)
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "refuses an argument past the owner's limits" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      long ← faulted (startTask owned handle "wait_long" [])
      case refusal long of
        Just (ValueRefusal Arguments 1 [] (RuleBytesLimit _) _) → pure ()
        other → expectationFailure ("unexpected refusal: " <> show other)
      boundaryEffect long `shouldBe` LuaRan
    where
      refusal fault = case boundaryReason fault of
        ValueRefused found → Just found
        _ → Nothing

faultSpec ∷ Spec
faultSpec = describe "a segment that fails" $ do
  it "raises a script error as a typed fault with its effect, traceback and names, and ends the task" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "script_error" []
      fault ← faulted (resumeTask owned task)
      boundaryOperation fault `shouldBe` ResumeTask
      boundaryModule fault `shouldBe` Just (ModuleRef "worker" "1")
      boundaryEntry fault `shouldBe` Just "script_error"
      boundaryEffect fault `shouldBe` LuaRan
      case boundaryReason fault of
        ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "exploded in a segment"
        other → expectationFailure ("unexpected reason: " <> show other)
      boundaryTraceback fault `shouldSatisfy` isJust
      again ← faulted (resumeTask owned task)
      boundaryReason again `shouldBe` TaskRefused (TaskEnded TaskFaulted)
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "raises an error in the first segment, and leaves no task" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (startTask owned handle "error_first" [])
      boundaryOperation fault `shouldBe` StartTask
      boundaryEffect fault `shouldBe` LuaRan
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "refuses a result the schema does not allow, and a wrong number of results, after the segment ran" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (wrong, _) ← begin owned handle "bad_result" []
      refused ← faulted (resumeTask owned wrong)
      boundaryEffect refused `shouldBe` LuaRan
      case boundaryReason refused of
        ValueRefused (ValueRefusal Results 1 [] _ _) → pure ()
        other → expectationFailure ("unexpected reason: " <> show other)
      (counted, _) ← begin owned handle "bad_count" []
      miscounted ← faulted (resumeTask owned counted)
      case boundaryReason miscounted of
        ValueRefused (ValueRefusal Results 0 [] (RuleArity 1 2) _) → pure ()
        other → expectationFailure ("unexpected reason: " <> show other)
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "refuses an argument a binding is called with, as a fault of that call" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "bad_argument" []
      fault ← faulted (resumeTask owned task)
      boundaryOperation fault `shouldBe` CallBinding
      boundaryBinding fault `shouldBe` Just ("probe", "integer_only")
      boundaryEffect fault `shouldBe` LuaRan
      logged probe >>= (`shouldBe` [])

  it "reports an exhausted allocator in a resumed segment as a typed fault" $ do
    probe ← newProbe
    let config =
          (defaultOwnerConfig [LibraryBase, LibraryString])
            { ownerRegistration = taskRegistration probe
            , ownerGranted = ["sched", "probe"]
            , ownerModules = [exhausting]
            , ownerName = "small"
            , ownerBudget = Just 200000
            }
        exhausting =
          ModuleSource
            (ModuleRef "exhausting" "1")
            "function eat() sched.yield(); local s = string.rep('x', 4000000); return #s end"
            [required "eat" [] [SInteger]]
    withOwnedVm config $ \owned → do
      Just handle ← loadedModule owned (ModuleRef "exhausting" "1")
      (task, step) ← begin owned handle "eat" []
      step `shouldBe` Yielded
      fault ← faulted (resumeTask owned task)
      case boundaryReason fault of
        ScriptFailed MemoryExhausted _ → pure ()
        other → expectationFailure ("unexpected reason: " <> show other)
      boundaryEffect fault `shouldBe` LuaRan
      (depth, _, _, tasks) ← bookkeeping owned
      tasks `shouldBe` 0
      depth `shouldBe` 0

precedenceSpec ∷ Spec
precedenceSpec = describe "a failure the script caught" $ do
  it "is raised instead of a successful yield, with its type, context and effect" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (startTask owned handle "caught_refusal_then_yield" [])
      boundaryOperation fault `shouldBe` CallBinding
      boundaryBinding fault `shouldBe` Just ("probe", "integer_only")
      boundaryEffect fault `shouldBe` LuaRan
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "is raised instead of a successful wait" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (startTask owned handle "caught_refusal_then_wait" [])
      boundaryBinding fault `shouldBe` Just ("probe", "integer_only")
      boundaryEffect fault `shouldBe` LuaRan

  it "is raised in preference to a completion, in a resumed segment" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, first) ← begin owned handle "caught_refusal_then_return" []
      first `shouldBe` Yielded
      fault ← faulted (resumeTask owned task)
      boundaryBinding fault `shouldBe` Just ("probe", "integer_only")
      boundaryOperation fault `shouldBe` CallBinding

  it "re-raises a binding's own failure unconverted instead of a yield, even through pcall" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      outcome ← try @IOException (startTask owned handle "caught_failure_then_yield" [])
      case outcome of
        Left failure → show failure `shouldSatisfy` Text.isInfixOf "the action failed" . Text.pack
        Right _ → expectationFailure "the failure was swallowed"
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "re-raises a binding's failure from a segment, whether the script caught it with coroutine.resume or let it run" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      caught ← try @IOException (startTask owned handle "resume_failure_then_wait" [])
      either (const (pure ())) (const (expectationFailure "the failure was swallowed")) caught
      (task, _) ← begin owned handle "failing_action" []
      uncaught ← try @IOException (resumeTask owned task)
      either (const (pure ())) (const (expectationFailure "the failure was swallowed")) uncaught
      again ← faulted (resumeTask owned task)
      boundaryReason again `shouldBe` TaskRefused (TaskEnded TaskFaulted)

  it "is raised instead of a yield that follows a refusal made inside a coroutine the script created" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (startTask owned handle "resume_refusal_then_yield" [])
      boundaryBinding fault `shouldBe` Just ("probe", "integer_only")

-- | The cleanup evidence a failure carries: each label with the exception's text.
evidenceOf ∷ SomeException → [(Text, Text)]
evidenceOf raised =
  [ (cleanupFailureLabel cleanup, Text.pack (show inner))
  | cleanup ← cleanupFailures raised
  , let ExceptionWithContext _ inner = cleanupFailureException cleanup
  ]

cleanupSpec ∷ Spec
cleanupSpec = describe "closing the coroutine of a segment that failed" $ do
  it "keeps a callback's failure during the close apart from the segment's own, each with its type" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "double_failure" []
      outcome ← try @SomeException (resumeTask owned task)
      case outcome of
        Right _ → expectationFailure "the failures were lost"
        Left raised → do
          fmap show (fromException raised ∷ Maybe IOException) `shouldBe` Just "user error (PRIMARY)"
          map fst (evidenceOf raised) `shouldBe` ["lua coroutine close"]
          map snd (evidenceOf raised) `shouldSatisfy` all (Text.isInfixOf "CLEANUP")
      logged probe >>= (`shouldBe` ["raise PRIMARY", "raise CLEANUP"])
      refused ← faulted (resumeTask owned task)
      boundaryReason refused `shouldBe` TaskRefused (TaskEnded TaskFaulted)

  it "reports a script's error as the failure, and a callback's failure while closing as evidence" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "script_error_then_cleanup_failure" []
      outcome ← try @SomeException (resumeTask owned task)
      case outcome of
        Right _ → expectationFailure "the failures were lost"
        Left raised → do
          case fromException raised of
            Just fault → case boundaryReason fault of
              ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "the script failed"
              other → expectationFailure ("unexpected reason: " <> show other)
            Nothing → expectationFailure ("not a fault: " <> show raised)
          map snd (evidenceOf raised) `shouldSatisfy` \found → length found == 1 && all (Text.isInfixOf "CLEANUP") found

  it "keeps every callback failure of a close, the first as the failure and the others beside it" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "many_cleanup_failures" []
      outcome ← try @SomeException (closeTask owned task)
      case outcome of
        Right _ → expectationFailure "the failures were lost"
        Left raised → do
          -- Lua closes the variables newest first.
          fmap show (fromException raised ∷ Maybe IOException) `shouldBe` Just "user error (SECOND)"
          map snd (evidenceOf raised) `shouldSatisfy` \found -> length found == 1 && all (Text.isInfixOf "FIRST") found
      closeTask owned task

  it "reports what closing ran when a script resumed the coroutine itself and it died holding a variable to close" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, step) ← begin owned handle "late_failure_with_guard" []
      step `shouldBe` Yielded
      callEntry owned handle "resume_shared" [] >>= (`shouldBe` Returned [VBoolean False])
      outcome ← try @SomeException (resumeTask owned task)
      case outcome of
        Right _ → expectationFailure "the close was not reported"
        Left raised → do
          fault ← maybe (expectationFailure "not a fault" >> error "unreachable") pure (fromException raised)
          boundaryReason fault `shouldBe` TaskRefused TaskNotSuspended
          boundaryEffect fault `shouldBe` BindingRan
          map fst (evidenceOf raised) `shouldBe` ["lua coroutine close"]
      logged probe >>= (`shouldBe` ["note cleanup ran"])
      again ← faulted (resumeTask owned task)
      boundaryReason again `shouldBe` TaskRefused (TaskEnded TaskFaulted)
      closeTask owned task
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

closingSpec ∷ Spec
closingSpec = describe "closing a task" $ do
  it "runs the pending to-be-closed variables of a suspended coroutine" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      Just inspect ← pure (Just handle)
      (task, step) ← begin owned handle "two_guards" []
      step `shouldBe` Yielded
      callEntry owned inspect "closed_count" [] >>= (`shouldBe` Returned [VInteger 0])
      closeTask owned task
      callEntry owned inspect "closed_count" [] >>= (`shouldBe` Returned [VInteger 11])
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "reports an error a to-be-closed variable raises, with the close, and is terminal and idempotent" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "with_failing_guard" [VText "g"]
      fault ← faulted (closeTask owned task)
      boundaryOperation fault `shouldBe` CloseTask
      boundaryEffect fault `shouldBe` LuaRan
      case boundaryReason fault of
        ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "close of g failed"
        other → expectationFailure ("unexpected reason: " <> show other)
      closeTask owned task
      closeTask owned task
      refused ← faulted (resumeTask owned task)
      boundaryReason refused `shouldBe` TaskRefused (TaskEnded TaskClosed)
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "is harmless twice, and after the task completed or failed" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (suspended, _) ← begin owned handle "yield_once" []
      closeTask owned suspended
      closeTask owned suspended
      (finished, _) ← begin owned handle "instant" [VInteger 1, VInteger 1]
      closeTask owned finished
      (broken, _) ← begin owned handle "script_error" []
      void (faulted (resumeTask owned broken))
      closeTask owned broken
      refused ← faulted (resumeTask owned suspended)
      boundaryReason refused `shouldBe` TaskRefused (TaskEnded TaskClosed)

  it "refuses to resume a task after it completed or was closed" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "yield_once" []
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])
      completed ← faulted (resumeTask owned task)
      boundaryReason completed `shouldBe` TaskRefused (TaskEnded TaskCompleted)
      boundaryEffect completed `shouldBe` NoEffect

  it "refuses a scheduler yield a to-be-closed variable makes while its coroutine closes" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "guard_yield" []
      fault ← faulted (closeTask owned task)
      boundaryReason fault `shouldBe` SuspendRefused SuspendOutsideTask
      boundaryOperation fault `shouldBe` CallBinding

refusalSpec ∷ Spec
refusalSpec = describe "a scheduler yield" $ do
  it "is refused from an entry point called once, and nothing yields to the caller" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (callEntry owned handle "call_yield" [])
      boundaryReason fault `shouldBe` SuspendRefused SuspendOutsideTask
      boundaryOperation fault `shouldBe` CallBinding
      boundaryBinding fault `shouldBe` Just ("sched", "yield")
      boundaryEntry fault `shouldBe` Just "call_yield"
      boundaryEffect fault `shouldBe` LuaRan

  it "is refused from an initial chunk" $ do
    probe ← newProbe
    withWorker probe $ \owned _ → do
      fault ← faulted (evalOwned owned (chunkName "chunk") "sched.yield()")
      boundaryReason fault `shouldBe` SuspendRefused SuspendOutsideTask

  it "is refused from a module's load" $ do
    probe ← newProbe
    withWorker probe $ \owned _ → do
      fault ← faulted (loadModule owned (ModuleSource (ModuleRef "loud" "1") "sched.yield()" []))
      boundaryReason fault `shouldBe` SuspendRefused SuspendOutsideTask
      boundaryOperation fault `shouldBe` CallBinding

  it "is refused from a finalizer, wherever it runs" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (callEntry owned handle "collect_and_yield" [])
      boundaryReason fault `shouldBe` SuspendRefused SuspendOutsideTask
      (task, _) ← begin owned handle "yield_once" []
      closeTask owned task

  it "is refused from a coroutine the script created, and the task goes on" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (startTask owned handle "inner_yield" [])
      boundaryReason fault `shouldBe` SuspendRefused SuspendOtherCoroutine
      -- The script's own resume saw a failure, not a suspension: nothing yielded
      -- to the wrong resumer.
      logged probe >>= (`shouldBe` ["note inner resume false"])
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "is refused inside a sort comparator and a pattern callback, where Lua cannot suspend" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      forM_ ["yield_in_sort", "yield_in_gsub"] $ \entry → do
        fault ← faulted (startTask owned handle entry [])
        boundaryReason fault `shouldBe` SuspendRefused SuspendNotYieldable
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "suspends the task from inside a metamethod, which Lua can suspend, and the task goes on" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, step) ← begin owned handle "yield_in_metamethod" []
      step `shouldBe` Yielded
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])

  it "is refused from another owner's VM, which has no task to suspend" $ do
    probe ← newProbe
    other ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "yield_once" []
      withWorker other $ \second secondHandle → do
        fault ← faulted (callEntry second secondHandle "call_yield" [])
        boundaryReason fault `shouldBe` SuspendRefused SuspendOutsideTask
        refusedTask ← faulted (resumeTask second task)
        boundaryReason refusedTask `shouldBe` TaskRefused TaskForeign
        refusedClose ← faulted (closeTask second task)
        boundaryReason refusedClose `shouldBe` TaskRefused TaskForeign
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])

  it "refuses a coroutine.yield made by the task itself, which would suspend it to no one" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (startTask owned handle "stray" [])
      boundaryReason fault `shouldBe` UnscheduledYield
      pcalled ← faulted (startTask owned handle "stray_pcall" [])
      boundaryReason pcalled `shouldBe` UnscheduledYield
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "is accepted through pcall and xpcall, which Lua can suspend" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, first) ← begin owned handle "yield_in_pcall" []
      first `shouldBe` Yielded
      resumeTask owned task >>= (`shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 4]))
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])

  it "leaves a task the host cannot resume when the script resumed its coroutine itself, and refuses a yield made then" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, step) ← begin owned handle "share" []
      step `shouldBe` Yielded
      callEntry owned handle "steal" [] >>= (`shouldBe` Returned [VBoolean True])
      stolen ← faulted (resumeTask owned task)
      boundaryReason stolen `shouldBe` TaskRefused TaskNotSuspended
      closeTask owned task
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0

  it "refuses what a binding's action asks of the VM that is running it, as the VM refuses any callback" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "poker" []
      writeIORef (probeSelf probe) (Just (owned, handle, task))
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])
      logged probe >>= (`shouldBe` ["poke (True,True,True)"])

librarySpec ∷ Spec
librarySpec = describe "the coroutine library" $ do
  it "is selectable, and works inside a task" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, first) ← begin owned handle "wrapped_generator" []
      first `shouldBe` Yielded
      resumeTask owned task >>= (`shouldBe` Yielded)
      resumeTask owned task >>= (`shouldBe` Yielded)
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 6])

  it "is absent unless it is chosen" $ do
    probe ← newProbe
    withVmOwner ((taskConfig probe) {vmLibraries = [LibraryBase]}) $ \owned → do
      outcome ← try @LuaFault (evalOwned owned (chunkName "absent") "coroutine.create(function() end)")
      outcome `shouldSatisfy` either (const True) (const False)

  it "still refuses a coroutine as a value" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      fault ← faulted (callEntry owned handle "made_coroutine" [])
      case boundaryReason fault of
        ValueRefused (ValueRefusal Results 1 [] (RuleUnsupportedType kind) _) → kind `shouldBe` "thread"
        other → expectationFailure ("unexpected reason: " <> show other)
      (task, _) ← begin owned handle "yield_once" []
      closeTask owned task

disciplineSpec ∷ Spec
disciplineSpec = describe "discipline" $ do
  it "leaves the stack, the registry and the tasks as they were across 1,000 cycles of every shape" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      before ← bookkeeping owned
      Returned [VInteger heapBefore] ← callEntry owned handle "heap_kb" []
      replicateM_ 250 $ do
        (completing, _) ← begin owned handle "counter" [VInteger 2]
        void (resumeTask owned completing)
        void (resumeTask owned completing)
        (closing, _) ← begin owned handle "with_guard" [VText "x"]
        closeTask owned closing
        (failing, _) ← begin owned handle "script_error" []
        void (faulted (resumeTask owned failing))
        void (faulted (startTask owned handle "error_first" []))
      bookkeeping owned >>= (`shouldBe` before)
      callEntry owned handle "closed_count" [] >>= (`shouldBe` Returned [VInteger 250])
      -- Nothing accumulates in the Lua heap either: the coroutines of ended tasks
      -- are garbage, and the collector takes them.
      Returned [VInteger heapAfter] ← callEntry owned handle "heap_kb" []
      (heapAfter - heapBefore) `shouldSatisfy` (< 64)

  it "keeps what live suspended tasks legitimately hold, and returns to the baseline when they end" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (depth, slot, modules, _) ← bookkeeping owned
      tasks ← forM [1 .. 20 :: Int] $ \_ → fst <$> begin owned handle "yield_once" []
      bookkeeping owned >>= (`shouldBe` (depth, slot, modules, 20))
      forM_ (take 10 tasks) (closeTask owned)
      bookkeeping owned >>= (`shouldBe` (depth, slot, modules, 10))
      forM_ (drop 10 tasks) (void . resumeTask owned)
      bookkeeping owned >>= (`shouldBe` (depth, slot, modules, 0))

  it "keeps the stack and registry across allocation failures while a coroutine is being made and run" $ do
    probe ← newProbe
    let sweeping =
          ModuleSource
            (ModuleRef "sweeping" "1")
            "function run(n) local t = {} for i = 1, n do t[i] = tostring(i) sched.yield() end return #t end"
            [required "run" [SInteger] [SInteger]]
        -- A VM whose heap is full to the last small table, less @k@ of them: the
        -- headroom a coroutine has to be made in.
        attempt k = do
          let config =
                (defaultOwnerConfig [LibraryBase, LibraryString])
                  { ownerRegistration = taskRegistration probe
                  , ownerGranted = ["sched", "probe"]
                  , ownerModules = [sweeping]
                  , ownerName = "swept"
                  , ownerBudget = Just 60000
                  }
          withOwnedVm config $ \owned → do
            Just handle ← loadedModule owned (ModuleRef "sweeping" "1")
            evalOwned owned (chunkName "fill") . encodeUtf8 . Text.unlines $
              [ "filler = {}"
              , "pcall(function() while true do filler[#filler + 1] = {} end end)"
              , "for _ = 1, " <> Text.pack (show (k ∷ Int)) <> " do filler[#filler] = nil end"
              , "collectgarbage()"
              ]
            before ← bookkeeping owned
            started ← try @BoundaryFault (startTask owned handle "run" [VInteger 3])
            outcome ← case started of
              Left fault → pure (Just (boundaryOperation fault, boundaryEffect fault, reasonKind fault))
              Right (TaskStarted task _) → do
                stepped ← try @BoundaryFault (replicateM_ 3 (resumeTask owned task))
                closed ← try @BoundaryFault (closeTask owned task)
                pure $ case (stepped, closed) of
                  (Left fault, _) → Just (boundaryOperation fault, boundaryEffect fault, reasonKind fault)
                  _ → Nothing
              Right TaskEntryAbsent → pure Nothing
            -- Whatever happened, nothing is left behind.
            bookkeeping owned >>= (`shouldBe` before)
            pure outcome
        reasonKind fault = case boundaryReason fault of
          ScriptFailed MemoryExhausted _ → "memory"
          _ → "other" ∷ Text
    results ← forM [0 .. 80] attempt
    -- The sweep reached the making of a coroutine, which failed there before
    -- anything of the script ran, as a typed fault and not a panic.
    (results `shouldSatisfy` elem (Just (StartTask, NoEffect, "memory"))) `orShow` results

teardownSpec ∷ Spec
teardownSpec = describe "a VM closed with suspended tasks" $ do
  it "closes every task first, on the owner's thread, with its callbacks alive under the finalizer allowlist" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      void (begin owned handle "with_guard" [VText "a"])
      void (begin owned handle "with_guard" [VText "b"])
    entries ← logged probe
    entries `shouldBe` ["note_gc closed a", "note_gc closed b"]

  it "attempts every close when one fails, and keeps the failure as the close's evidence" $ do
    probe ← newProbe
    outcome ← try @SomeException $
      withWorker probe $ \owned handle → do
        void (begin owned handle "with_guard" [VText "a"])
        void (begin owned handle "with_failing_guard" [VText "x"])
        void (begin owned handle "with_guard" [VText "b"])
    case outcome of
      Right _ → expectationFailure "the close failure was lost"
      Left raised → map cleanupFailureLabel (cleanupFailures raised) `shouldBe` ["lua coroutine close"]
    entries ← logged probe
    entries `shouldBe` ["note_gc closed a", "note_gc closed b"]

  it "refuses what the allowlist does not name, and keeps that as evidence beside the close" $ do
    probe ← newProbe
    outcome ← try @SomeException $
      withWorker probe $ \owned handle → void (begin owned handle "with_refused_guard" [])
    case outcome of
      Right _ → expectationFailure "the refusal was lost"
      Left raised → map cleanupFailureLabel (cleanupFailures raised) `shouldSatisfy` elem "lua finalizer refused"
    logged probe >>= (`shouldBe` [])

  it "leaves the VM closed, and a task of it refused with the VM's own answer" $ do
    probe ← newProbe
    kept ← newEmptyMVar
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "yield_once" []
      putMVar kept (owned, task)
    (owned, task) ← takeMVar kept
    resumed ← try @VmClosed (resumeTask owned task)
    resumed `shouldSatisfy` either (const True) (const False)
    closed ← try @VmClosed (closeTask owned task)
    closed `shouldSatisfy` either (const True) (const False)

  it "refuses every operation on a task from a thread that is not the owner's" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (task, _) ← begin owned handle "yield_once" []
      answers ← newEmptyMVar
      _ ← forkIO $ do
        started ← try @VmNotOwned (startTask owned handle "yield_once" [])
        resumed ← try @VmNotOwned (resumeTask owned task)
        closed ← try @VmNotOwned (closeTask owned task)
        putMVar answers (either (const True) (const False) started, either (const True) (const False) resumed, either (const True) (const False) closed)
      bounded (takeMVar answers) >>= (`shouldBe` (True, True, True))
      resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])

cancellationSpec ∷ Spec
cancellationSpec = describe "cancellation" $ do
  it "lands after a resumed segment, closing every suspended task and keeping the failure as evidence" $ do
    probe ← newProbe
    runner ←
      settling $
        withWorker probe $ \owned handle → do
          void (begin owned handle "with_guard" [VText "a"])
          void (begin owned handle "with_failing_guard" [VText "x"])
          (holding, _) ← begin owned handle "holder" []
          void (resumeTask owned holding)
    bounded (takeMVar (probeEntered probe))
    cancelling runner UserInterrupt (putMVar (probeRelease probe) ())
    settled ← awaitSettled runner
    observedCancellation settled `shouldBe` Just UserInterrupt
    logged probe >>= (`shouldBe` ["note_gc closed a"])
    case settledOperation settled of
      Right _ → expectationFailure "the cancellation was lost"
      Left raised → map cleanupFailureLabel (cleanupFailures raised) `shouldBe` ["lua coroutine close"]

  it "leaves the VM closed when the cancelled owner had tasks suspended" $ do
    probe ← newProbe
    runner ←
      settling $
        withWorker probe $ \owned handle → do
          void (begin owned handle "with_guard" [VText "kept"])
          (holding, _) ← begin owned handle "holder" []
          void (resumeTask owned holding)
    bounded (takeMVar (probeEntered probe))
    cancelling runner UserInterrupt (putMVar (probeRelease probe) ())
    settled ← awaitSettled runner
    observedCancellation settled `shouldBe` Just UserInterrupt
    logged probe >>= (`shouldBe` ["note_gc closed kept"])

interleavingSpec ∷ Spec
interleavingSpec = describe "two tasks on one VM" $ do
  it "keep separate continuations, waits and faults, and closing one leaves the other usable" $ do
    probe ← newProbe
    withWorker probe $ \owned handle → do
      (left, firstLeft) ← begin owned handle "local_state" [VInteger 100]
      (right, firstRight) ← begin owned handle "local_state" [VInteger 200]
      firstLeft `shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 101])
      firstRight `shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 201])
      resumeTask owned right >>= (`shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 202]))
      resumeTask owned left >>= (`shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_tick" [VInteger 102]))
      (broken, _) ← begin owned handle "boom_if" [VBoolean True]
      (fine, _) ← begin owned handle "boom_if" [VBoolean False]
      fault ← faulted (resumeTask owned broken)
      boundaryEntry fault `shouldBe` Just "boom_if"
      case boundaryReason fault of
        ScriptFailed CallFailed (ErrorMessage message _) → message `shouldSatisfy` Text.isInfixOf "task failed"
        other → expectationFailure ("unexpected reason: " <> show other)
      resumeTask owned fine >>= (`shouldBe` Completed [VInteger 0])
      closeTask owned left
      resumeTask owned right >>= (`shouldBe` Completed [VInteger 202])
      refused ← faulted (resumeTask owned left)
      boundaryReason refused `shouldBe` TaskRefused (TaskEnded TaskClosed)
      bookkeeping owned >>= \(_, _, _, tasks) → tasks `shouldBe` 0


orShow ∷ Show a ⇒ IO () → a → IO ()
orShow action shown = action `catchAny` \_ → expectationFailure (show shown)
  where
    catchAny io handler = either (\(e ∷ SomeException) → handler e) pure =<< try io
