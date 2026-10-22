-- | Bindings opted in to recoverable refusals, beside the ones that are not.
--
-- A binding made with 'recoverableRefusals' or 'withPrecondition' refuses what
-- it can refuse before its action as an ordinary Lua error: @pcall@ catches it,
-- the call it was caught in goes on and succeeds, and the action never ran. A
-- binding that is not opted in is the one the rest of the suite pins, and it is
-- exercised here on the same calls so the difference is read from one place.
--
-- Everything runs a chunk, or a module's entry point, in a real interpreter. The
-- fixture's bindings note what their actions did, so a refused call is seen to
-- have run nothing, and what stands for the engine's own state (the phase and the
-- active instance) is a reference only the Haskell side writes.
module Test.Lua.Boundary.Recoverable (spec) where

import Control.Exception (IOException, SomeException, fromException, try, tryWithContext)
import Control.Monad (forM, forM_, replicateM_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (nub)
import qualified Data.Set as Set
import Data.Set (Set)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Text.Unsafe (lengthWord8)
import Data.Word (Word64)
import GHC.Conc (getAllocationCounter)
import Hetoimasia.Scripting.Lua.Internal.Binding (argumentReason, ordinaryRule)
import Hetoimasia.Scripting.Lua.Internal.Owner
  ( OwnerConfig (..)
  , defaultOwnerConfig
  , ownedInternalVm
  )
import Hetoimasia.Scripting.Lua.Internal.Vm (stackDepth)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Value
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldSatisfy)
import Test.Lua.Boundary.Support (giantReason, refusal, run, runFault, withOwnerOf)
import Test.Lua.Owner.Support (evidenceCauses, runOwner)
import Test.Lua.Support (referenceSlot)

-- Fixture ------------------------------------------------------------------------

-- | What the bindings observe and what stands for the engine's own state.
data Fx = Fx
  { fxLog ∷ !(IORef [Text])
    -- ^ The actions that ran, oldest last.
  , fxLive ∷ !(IORef (Set Word64))
  , fxPhase ∷ !(IORef Text)
    -- ^ The phase the engine is in: engine-owned, written only from Haskell.
  , fxActive ∷ !(IORef Text)
    -- ^ The instance the engine is running on the shared VM.
  , fxBusy ∷ !(IORef Bool)
  , fxAdmitted ∷ !(IORef Int)
    -- ^ Request handles, provider calls and reservations the fixture made.
  , fxReason ∷ !(IORef Text)
    -- ^ What @checked.vet@'s precondition refuses with, when it is not empty.
  , fxChecks ∷ !(IORef Int)
    -- ^ How many times a precondition ran.
  }

newFx ∷ IO Fx
newFx = Fx <$> newIORef [] <*> newIORef Set.empty <*> newIORef "update" <*> newIORef "A" <*> newIORef False <*> newIORef 0 <*> newIORef "" <*> newIORef 0

note ∷ Fx → Text → IO ()
note fx entry = atomicModifyIORef' (fxLog fx) (\held → (entry : held, ()))

logged ∷ Fx → IO [Text]
logged fx = reverse <$> readIORef (fxLog fx)

count ∷ IORef Int → IO Int
count = readIORef

bump ∷ IORef Int → IO ()
bump ref = atomicModifyIORef' ref (\held → (held + 1, ()))

phaseIs ∷ Fx → Text → Precondition
phaseIs fx expected _ = do
  bump (fxChecks fx)
  phase ← readIORef (fxPhase fx)
  pure (if phase == expected then Nothing else Just ("wrong phase: " <> phase))

activeIs ∷ Fx → Text → Precondition
activeIs fx expected _ = do
  bump (fxChecks fx)
  active ← readIORef (fxActive fx)
  pure (if active == expected then Nothing else Just ("wrong instance: " <> active))

busyRecord ∷ Schema
busyRecord = SRecord [("code", SText), ("message", SText)]

-- | The bindings both namespaces hold, each wrapped as the namespace says.
family ∷ Fx → (Binding → Binding) → [Binding]
family fx wrap =
  [ wrap . snapshotQuery "add" [SInteger, SInteger] [SInteger] $ \arguments → do
      note fx "add"
      pure $ case arguments of
        [VInteger a, VInteger b] → [VInteger (a + b)]
        _ → []
  , wrap (snapshotQuery "echo_list" [SList SNumber] [SList SNumber] (\values → note fx "echo_list" >> pure values))
  , wrap (snapshotQuery "echo_record" [SRecord [("name", SText), ("count", SInteger)]] [SInteger] (\_ → note fx "echo_record" >> pure [VInteger 0]))
  , wrap (snapshotQuery "echo_text" [SText] [SText] (\values → note fx "echo_text" >> pure values))
  , wrap (snapshotQuery "redeem" [SCapability "ticket"] [SBoolean] (\_ → note fx "redeem" >> pure [VBoolean True]))
  , wrap (snapshotQuery "redeem_badge" [SCapability "badge"] [SBoolean] (\_ → note fx "redeem_badge" >> pure [VBoolean True]))
  , wrap (stateOperation "set_value" [SText, SInteger] [] (\_ → note fx "set_value" >> pure []))
  ]

-- | The registration: @checked@ is opted in, @plain@ is the generic behavior, and
-- @sched@ holds scheduler operations of each.
registrationOf ∷ Fx → Registration
registrationOf fx = either (error . ("registration refused: " <>) . show) id (registration [capabilityType "ticket" alive, capabilityType "badge" alive] [checked, plain, sched])
  where
    alive key = Set.member key <$> readIORef (fxLive fx)
    checked =
      namespace "checked" . concat $
        [ family fx recoverableRefusals
        , [ recoverableRefusals . stateOperation "fail" [SText] [] $ \_ → note fx "fail" >> ioError (userError "the action failed")
          , recoverableRefusals (snapshotQuery "wrong_result" [] [SInteger] (\_ → note fx "wrong_result" >> pure [VText "not an integer"]))
          , -- Busy is data: nothing was admitted, and nil and a record say so.
            recoverableRefusals . stateOperation "admit" [SInteger] [SOptional SInteger, SOptional busyRecord] $ \arguments → do
              note fx "admit"
              busy ← readIORef (fxBusy fx)
              if busy
                then pure [VNil, VRecord [("code", VText "busy"), ("message", VText "no capacity")]]
                else do
                  bump (fxAdmitted fx)
                  pure $ case arguments of
                    [VInteger n] → [VInteger n, VNil]
                    _ → [VNil, VNil]
          , withPrecondition (phaseIs fx "update") (stateOperation "in_phase" [SInteger] [SInteger] (\arguments → note fx "in_phase" >> pure arguments))
          , withPrecondition (activeIs fx "A") (stateOperation "as_instance" [] [] (\_ → note fx "as_instance" >> pure []))
          , withPrecondition
              ( \_ → do
                  bump (fxChecks fx)
                  reason ← readIORef (fxReason fx)
                  pure (if Text.null reason then Nothing else Just reason)
              )
              (stateOperation "vet" [SInteger] [] (\_ → note fx "vet" >> pure []))
          , withPrecondition (\_ → ioError (userError "the precondition failed")) (stateOperation "explode" [] [] (\_ → note fx "explode" >> pure []))
          , withPrecondition
              (\owner → pure (if fmap (fromLifecycleContext @Text) (contextLifecycle owner) == Just (Just "owner A") then Nothing else Just "not owner A"))
              (stateOperation "owned_by_a" [] [] (\_ → note fx "owned_by_a" >> pure []))
          , finalizerEligible (recoverableRefusals (stateOperation "note_gc" [SText] [] (\_ → note fx "note_gc" >> pure [])))
          , recoverableRefusals (lifecycleOperation "stop" [] [] (\_ → note fx "stop" >> pure []))
          , withPrecondition (phaseIs fx "update") (lifecycleOperation "stop_checked" [] [] (\_ → note fx "stop_checked" >> pure []))
          ]
        ]
    plain =
      namespace "plain" . concat $
        [ family fx id
        , [ snapshotQuery "ticket" [SInteger] [SCapability "ticket"] $ \arguments → do
              note fx "ticket"
              case arguments of
                [VInteger key] → do
                  atomicModifyIORef' (fxLive fx) (\held → (Set.insert (fromIntegral key) held, ()))
                  pure [VCapability (capability "ticket" (fromIntegral key))]
                _ → pure []
          ]
        ]
    sched =
      namespace
        "sched"
        [ withPrecondition (phaseIs fx "task") (waitOperation "wait_checked" WaitLogical [SInteger])
        , recoverableRefusals (waitOperation "wait_args" WaitLogical [SInteger])
        , waitOperation "wait_plain" WaitLogical [SInteger]
        , yieldOperation "yield"
        ]

-- | An owner of the fixture's registration, granted these namespaces, with the
-- scheduler module loaded.
configOf ∷ Fx → [Text] → VmConfig
configOf fx granted =
  (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath, LibraryCoroutine])
    { vmRegistration = registrationOf fx
    , vmPolicy = granted
    , vmOwnerName = "recoverable owner"
    , vmModules = [worker]
    }

limited ∷ Fx → Int → Int → Int → VmConfig
limited fx bytes depth elements = (configOf fx ["checked", "plain"]) {vmValueLimits = either (error . show) id (valueLimits bytes depth elements)}

withFx ∷ (Fx → OwnedVm → IO a) → IO a
withFx body = do
  fx ← newFx
  withOwnerOf (configOf fx ["checked", "plain", "sched"]) (body fx)

-- | The module the scheduler examples run.
worker ∷ ModuleSource
worker = ModuleSource (ModuleRef "worker" "1") (encodeUtf8 workerSource) workerEntries

workerSource ∷ Text
workerSource =
  Text.unlines
    [ "function finite_checked() local ok, why = pcall(sched.wait_checked, 3); return ok, why end"
    , "function finite_plain() local ok, why = pcall(sched.wait_plain, 3); return ok, why end"
    , "function task_args()"
    , "  local ok, why = pcall(sched.wait_args, 'soon')"
    , "  assert(ok == false and why == 'sched.wait_args: argument 1: expected integer, found string', tostring(why))"
    , "  sched.wait_args(4)"
    , "  return 1"
    , "end"
    , "function task_checked()"
    , "  local ok, why = pcall(sched.wait_checked, 1)"
    , "  sched.yield()"
    , "  return ok and 1 or 0"
    , "end"
    , "function task_wait() sched.wait_checked(5); return 1 end"
    ]

workerEntries ∷ [EntryPoint]
workerEntries =
  [ EntryPoint "finite_checked" Required [] [SBoolean, SText]
  , EntryPoint "finite_plain" Required [] [SBoolean, SText]
  , EntryPoint "task_args" Required [] [SInteger]
  , EntryPoint "task_checked" Required [] [SInteger]
  , EntryPoint "task_wait" Required [] [SInteger]
  ]

-- | What a chunk that catches the call, checks it was refused with this message,
-- and goes on says.
caught ∷ Text → Text → Text
caught call expected = "do local ok, err = pcall(function() " <> call <> " end); assert(ok == false and err == '" <> expected <> "', tostring(err)) end"

readings ∷ OwnedVm → IO (Int, Int)
readings owned = (,) <$> stackDepth (ownedInternalVm owned) <*> (fromIntegral <$> referenceSlot (ownedInternalVm owned))

spec ∷ Spec
spec = describe "recoverable refusals" $ do
  caughtSpec
  boundsSpec
  handlesSpec
  preconditionSpec
  busySpec
  schedulerSpec
  fatalSpec
  finalizerSpec
  disciplineSpec
  reasonSpec

-- Caught -------------------------------------------------------------------------

caughtSpec ∷ Spec
caughtSpec = describe "an opted-in binding" $ do
  it "refuses malformed arguments as errors pcall catches, runs no action, and lets the invocation succeed" $
    withFx $ \fx owned → do
      let cases =
            [ ("checked.add(1)", "checked.add: the arguments: expected 2 values, found 1")
            , ("checked.add(1, 2, 3)", "checked.add: the arguments: expected 2 values, found 3")
            , ("checked.add(1.5, 2)", "checked.add: argument 1: a float where an integer is declared")
            , ("checked.add(1, 'a')", "checked.add: argument 2: expected integer, found string")
            , ("checked.echo_list({1, 'two'})", "checked.echo_list: argument 1[2]: expected number, found string")
            , ("checked.echo_list({1, 2, nil, 4})", "checked.echo_list: argument 1: not a sequence")
            , ("checked.echo_list({[1] = 1, x = 2})", "checked.echo_list: argument 1: not a sequence")
            , ("checked.echo_list({{1}})", "checked.echo_list: argument 1[1]: expected number, found table")
            , ("checked.echo_record({name = 'n'})", "checked.echo_record: argument 1: missing field count")
            , ("checked.echo_record({name = 'n', count = 1, extra = 2})", "checked.echo_record: argument 1: unknown field extra")
            , ("checked.echo_record({name = 'n', count = 1, [1] = 2})", "checked.echo_record: argument 1: not a record")
            , ("checked.echo_text('\\xff')", "checked.echo_text: argument 1: text that is not valid UTF-8")
            , ("local t = {}; t[1] = t; checked.echo_list(t)", "checked.echo_list: argument 1: a table contains itself")
            , ("checked.echo_text(print)", "checked.echo_text: argument 1: a function cannot be passed")
            ]
      forM_ cases $ \(call, expected) → run owned (caught call expected)
      -- The invocation went on: a valid call returns what it should, and the chunk
      -- ends without a fault.
      run owned "assert(checked.add(1, 2) == 3)"
      -- Of everything above, only that call's action ran.
      logged fx >>= (`shouldBe` ["add"])

  it "refuses the same calls to a binding that is not opted in with a typed fault the script cannot hide" $
    withFx $ \fx owned → do
      forM_ ["plain.add(1)", "plain.add(1.5, 2)", "plain.echo_list({1, 'two'})", "plain.echo_text(print)"] $ \call → do
        fault ← runFault owned ("local ok = pcall(function() " <> call <> " end); assert(ok == false); plain.set_value('after', 1)")
        boundaryOperation fault `shouldBe` CallBinding
        boundaryBinding fault `shouldBe` Just ("plain", Text.takeWhile (/= '(') (Text.drop 6 call))
        shouldSatisfy (refusal fault) (maybe False (const True))
      -- The retained fault is the first refusal, and the action ran after it each time.
      logged fx >>= (`shouldBe` replicate 4 "set_value")

  it "raises an uncaught refusal as an ordinary Lua error, attributed to the chunk that called, with a bounded message" $
    withFx $ \fx owned → do
      outcome ← try @LuaFault (run owned "checked.add(1.5, 2)")
      case outcome of
        Left fault → do
          faultKind fault `shouldBe` CallFailed
          faultValue fault `shouldBe` ErrorMessage "checked.add: argument 1: a float where an integer is declared" False
        Right () → expectationFailure "the refusal did not fail the chunk"
      -- It is a failure of that chunk, not of the owner: the next one runs.
      run owned "assert(checked.add(2, 2) == 4)"
      logged fx >>= (`shouldBe` ["add"])

  it "touches no metamethod of what it refuses" $
    withFx $ \fx owned → do
      run
        owned
        ( Text.unlines
            [ "count = 0"
            , "local function touch() count = count + 1 end"
            , "local mt = {__index = touch, __newindex = touch, __len = touch, __eq = touch, __tostring = touch, __pairs = touch, __call = touch, __concat = touch, __lt = touch}"
            , "assert(pcall(checked.echo_list, setmetatable({1, 2, 3}, mt)) == false)"
            , "assert(pcall(checked.echo_record, setmetatable({name = 'n', count = 1}, mt)) == false)"
            , "assert(pcall(checked.echo_text, setmetatable({}, mt)) == false)"
            , "assert(pcall(checked.redeem, setmetatable({}, mt)) == false)"
            , "assert(count == 0, count)"
            ]
        )
      logged fx >>= (`shouldBe` [])

-- Bounds -------------------------------------------------------------------------

boundsSpec ∷ Spec
boundsSpec = describe "the value limits" $ do
  it "accepts a copy at the byte limit and refuses one past it as a catchable error" $ do
    fx ← newFx
    -- A list of n integers is 5 + 18n bytes, as for any binding.
    withOwnerOf (limited fx 59 8 4096) $ \owned → do
      run owned "assert(#checked.echo_list({1, 2, 3}) == 3)"
      run owned (caught "checked.echo_list({1, 2, 3, 4})" "checked.echo_list: argument 1: more than 59 bytes")
      run owned "assert(#checked.echo_list({1, 2, 3}) == 3)"
    logged fx >>= (`shouldBe` ["echo_list", "echo_list"])

  it "accepts a copy at the depth limit and refuses one past it" $ do
    fx ← newFx
    withOwnerOf (limited fx 65536 2 4096) $ \owned → do
      run owned "assert(#checked.echo_list({1}) == 1)"
      run owned (caught "checked.echo_list({{{1}}})" "checked.echo_list: argument 1: nested deeper than 2")
    logged fx >>= (`shouldBe` ["echo_list"])

  it "stops reading at the element limit however large the input is, and still lets the call be caught" $ do
    fx ← newFx
    withOwnerOf (limited fx 65536 8 100) $ \owned → do
      run owned (Text.unlines ["local t = {}", "for i = 1, 200000 do t[i] = i end", caught "checked.echo_list(t)" "checked.echo_list: argument 1: more than 100 values"])
      run owned "local t = {} for i = 1, 99 do t[i] = i end assert(#checked.echo_list(t) == 99)"
    logged fx >>= (`shouldBe` ["echo_list"])

  it "refuses an oversized string without reading past the limit" $ do
    fx ← newFx
    withOwnerOf (limited fx 1000 8 4096) $ \owned → do
      before ← getAllocationCounter
      run owned (caught "checked.echo_text(('x'):rep(50 * 1000 * 1000))" "checked.echo_text: argument 1: more than 1000 bytes")
      after ← getAllocationCounter
      -- The script's own string is Lua's allocation; the host copied none of it.
      (before - after) `shouldSatisfy` (< 2000000)
    logged fx >>= (`shouldBe` [])

-- Handles ------------------------------------------------------------------------

handlesSpec ∷ Spec
handlesSpec = describe "a capability" $ do
  it "is refused when it is imitated, of another type or retired, and each refusal can be caught" $
    withFx $ \fx owned → do
      run owned "ticket = plain.ticket(7); assert(checked.redeem(ticket) == true)"
      run owned (caught "checked.redeem(7)" "checked.redeem: argument 1: expected capability ticket, found integer")
      run owned (caught "checked.redeem({type = 'ticket', key = 7})" "checked.redeem: argument 1: expected capability ticket, found table")
      run owned (caught "checked.redeem_badge(ticket)" "checked.redeem_badge: argument 1: expected a badge handle, found a ticket handle")
      atomicModifyIORef' (fxLive fx) (\held → (Set.delete 7 held, ()))
      run owned (caught "checked.redeem(ticket)" "checked.redeem: argument 1: a ticket handle that has ended")
      -- The same retirement through a binding that is not opted in is the fault it was.
      fault ← runFault owned "pcall(plain.redeem, ticket)"
      fmap refusalRule (refusal fault) `shouldBe` Just (RuleRetiredHandle "ticket")
      logged fx >>= (`shouldBe` ["ticket", "redeem"])

-- Preconditions ------------------------------------------------------------------

preconditionSpec ∷ Spec
preconditionSpec = describe "a precondition" $ do
  it "refuses a call made in the wrong phase before its action, and the next call in the right one succeeds" $
    withFx $ \fx owned → do
      run owned "assert(checked.in_phase(1) == 1)"
      writeIORef (fxPhase fx) "init"
      run owned (caught "checked.in_phase(2)" "checked.in_phase: wrong phase: init")
      writeIORef (fxPhase fx) "update"
      run owned "assert(checked.in_phase(3) == 3)"
      logged fx >>= (`shouldBe` ["in_phase", "in_phase"])

  it "runs before an argument is read, and once for each call" $
    withFx $ \fx owned → do
      writeIORef (fxPhase fx) "init"
      -- Malformed too, but the engine's state is what refuses it.
      run owned (caught "checked.in_phase('text')" "checked.in_phase: wrong phase: init")
      count (fxChecks fx) >>= (`shouldBe` 1)
      writeIORef (fxPhase fx) "update"
      run owned (caught "checked.in_phase('text')" "checked.in_phase: argument 1: expected integer, found string")
      count (fxChecks fx) >>= (`shouldBe` 2)
      logged fx >>= (`shouldBe` [])

  it "refuses a wrong active instance on a VM two instances share, whatever the script writes where it can" $
    withFx $ \fx owned → do
      run owned "assert(pcall(checked.as_instance) == true)"
      writeIORef (fxActive fx) "B"
      run
        owned
        ( Text.unlines
            [ "instance = 'A'; active = 'A'; _G.phase = 'update'; _G.checked_instance = 'A'"
            , "rawset(_G, 'instance', 'A')"
            , "local t = {instance = 'A', active = 'A'}"
            , caught "checked.as_instance()" "checked.as_instance: wrong instance: B"
            ]
        )
      writeIORef (fxActive fx) "A"
      run owned "checked.as_instance()"
      logged fx >>= (`shouldBe` ["as_instance", "as_instance"])

  it "reads the owner's own context, so owners sharing a registration are told apart" $ do
    fx ← newFx
    let configFor name = (configOf fx ["checked"]) {vmLifecycle = Just (lifecycleContext (name ∷ Text))}
    withOwnerOf (configFor "owner A") $ \owned → run owned "checked.owned_by_a()"
    withOwnerOf (configFor "owner B") $ \owned → run owned (caught "checked.owned_by_a()" "checked.owned_by_a: not owner A")
    withOwnerOf (configOf fx ["checked"]) $ \owned → run owned (caught "checked.owned_by_a()" "checked.owned_by_a: not owner A")
    logged fx >>= (`shouldBe` ["owned_by_a"])

  it "is the application's own code: what it raises is raised, not turned into a refusal" $
    withFx $ \fx owned → do
      outcome ← try @SomeException (run owned "local ok = pcall(checked.explode); assert(ok == false)")
      case outcome of
        Left failure | Just raised ← fromException failure → show (raised ∷ IOException) `shouldBe` "user error (the precondition failed)"
        other → expectationFailure ("not the precondition's own failure: " <> show other)
      logged fx >>= (`shouldBe` [])

-- Busy ---------------------------------------------------------------------------

busySpec ∷ Spec
busySpec = describe "busy" $ do
  it "is data the binding returns: nil and a bounded record, with nothing admitted, and a later call succeeds" $
    withFx $ \fx owned → do
      writeIORef (fxBusy fx) True
      run
        owned
        ( Text.unlines
            [ "local ok, handle, err = pcall(checked.admit, 1)"
            , "assert(ok == true and handle == nil)"
            , "assert(type(err) == 'table' and err.code == 'busy' and err.message == 'no capacity')"
            , "local count = 0 for _ in pairs(err) do count = count + 1 end"
            , "assert(count == 2)"
            ]
        )
      count (fxAdmitted fx) >>= (`shouldBe` 0)
      writeIORef (fxBusy fx) False
      run owned "local handle, err = checked.admit(7); assert(handle == 7 and err == nil)"
      count (fxAdmitted fx) >>= (`shouldBe` 1)
      -- The action ran once for each call: nothing retried a refused admission.
      logged fx >>= (`shouldBe` ["admit", "admit"])

  it "keeps a malformed call an error while the binding is busy" $
    withFx $ \fx owned → do
      writeIORef (fxBusy fx) True
      run owned (caught "checked.admit('x')" "checked.admit: argument 1: expected integer, found string")
      logged fx >>= (`shouldBe` [])

-- Scheduler ----------------------------------------------------------------------

schedulerSpec ∷ Spec
schedulerSpec = describe "an opted-in scheduler operation" $ do
  it "is refused by its precondition in a call that cannot suspend, and nothing is reported suspended" $
    withFx $ \fx owned → do
      Just handle ← loadedModule owned (ModuleRef "worker" "1")
      writeIORef (fxPhase fx) "init"
      callEntry owned handle "finite_checked" [] >>= (`shouldBe` Returned [VBoolean False, VText "sched.wait_checked: wrong phase: init"])
      -- With the precondition passing, the host's own refusal is the typed fault it was.
      writeIORef (fxPhase fx) "task"
      fault ← try @BoundaryFault (callEntry owned handle "finite_checked" [])
      fmap boundaryReason (either Just (const Nothing) fault) `shouldBe` Just (SuspendRefused SuspendOutsideTask)

  it "keeps the typed fault, under pcall too, for a wait that is not opted in" $
    withFx $ \_ owned → do
      Just handle ← loadedModule owned (ModuleRef "worker" "1")
      fault ← try @BoundaryFault (callEntry owned handle "finite_plain" [])
      fmap boundaryReason (either Just (const Nothing) fault) `shouldBe` Just (SuspendRefused SuspendOutsideTask)

  it "refuses an invalid argument in a task as an error the task catches, and then waits" $
    withFx $ \_ owned → do
      Just handle ← loadedModule owned (ModuleRef "worker" "1")
      started ← startTask owned handle "task_args" []
      case started of
        TaskStarted task step → do
          step `shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_args" [VInteger 4])
          resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])
        TaskEntryAbsent → expectationFailure "the entry point was absent"

  it "refuses in a task by precondition, and the task goes on to yield and complete" $
    withFx $ \fx owned → do
      Just handle ← loadedModule owned (ModuleRef "worker" "1")
      writeIORef (fxPhase fx) "init"
      started ← startTask owned handle "task_checked" []
      case started of
        TaskStarted task step → do
          step `shouldBe` Yielded
          resumeTask owned task >>= (`shouldBe` Completed [VInteger 0])
        TaskEntryAbsent → expectationFailure "the entry point was absent"

  it "suspends the task when its precondition passes" $
    withFx $ \fx owned → do
      Just handle ← loadedModule owned (ModuleRef "worker" "1")
      writeIORef (fxPhase fx) "task"
      started ← startTask owned handle "task_wait" []
      case started of
        TaskStarted task step → do
          step `shouldBe` Waiting (WaitRequest WaitLogical "sched" "wait_checked" [VInteger 5])
          resumeTask owned task >>= (`shouldBe` Completed [VInteger 1])
        TaskEntryAbsent → expectationFailure "the entry point was absent"

-- Fatal --------------------------------------------------------------------------

fatalSpec ∷ Spec
fatalSpec = describe "what stays fatal" $ do
  it "keeps an action's own failure, under pcall, with its type" $
    withFx $ \fx owned → do
      outcome ← try @SomeException (run owned "local ok = pcall(checked.fail, 'x'); assert(ok == false)")
      case outcome of
        Left failure | Just raised ← fromException failure → show (raised ∷ IOException) `shouldBe` "user error (the action failed)"
        other → expectationFailure ("not the action's own failure: " <> show other)
      logged fx >>= (`shouldBe` ["fail"])

  it "keeps the refusal of a result as a fault of the call, under pcall" $
    withFx $ \fx owned → do
      fault ← runFault owned "pcall(checked.wrong_result)"
      fmap refusalSide (refusal fault) `shouldBe` Just Results
      boundaryEffect fault `shouldBe` BindingRan
      logged fx >>= (`shouldBe` ["wrong_result"])

  it "never erases a fault a refusal of a binding that is not opted in recorded, whatever follows" $
    withFx $ \fx owned → do
      fault ←
        runFault
          owned
          ( Text.unlines
              [ "pcall(plain.add, 1.5, 2)"
              , "assert(pcall(checked.add, 1.5, 2) == false)"
              , "assert(checked.admit(1) == 1)"
              , "assert(checked.add(1, 2) == 3)"
              ]
          )
      boundaryBinding fault `shouldBe` Just ("plain", "add")
      shouldSatisfy (refusal fault) (maybe False (const True))
      -- The later actions ran, and the fault says an action followed it.
      boundaryEffect fault `shouldBe` BindingRan
      logged fx >>= (`shouldBe` ["admit", "add"])

  it "keeps the refusal of a binding the owner has no context to deliver, before any precondition runs" $
    withFx $ \fx owned → do
      writeIORef (fxPhase fx) "init"
      forM_ ["checked.stop", "checked.stop_checked"] $ \name → do
        fault ← runFault owned ("pcall(" <> name <> ")")
        boundaryReason fault `shouldBe` NotYetSupported LifecycleOperation
      count (fxChecks fx) >>= (`shouldBe` 0)
      logged fx >>= (`shouldBe` [])

  it "never lets a caught refusal replace an application failure" $
    withFx $ \_ owned → do
      outcome ← try @SomeException (run owned "pcall(checked.fail, 'x'); pcall(checked.add, 1.5, 2); assert(checked.add(1, 2) == 3)")
      case outcome of
        Left failure | Just raised ← fromException failure → show (raised ∷ IOException) `shouldBe` "user error (the action failed)"
        other → expectationFailure ("the application's failure was lost: " <> show other)

-- Finalizers ---------------------------------------------------------------------

finalizerSpec ∷ Spec
finalizerSpec = describe "a refusal reached from a finalizer" $ do
  it "is a recorded fault of the running operation, where Lua would drop an error raised there" $
    withFx $ \fx owned → do
      fault ← runFault owned "setmetatable({}, {__gc = function() checked.add(1.5, 2) end}); collectgarbage(); collectgarbage()"
      boundaryBinding fault `shouldBe` Just ("checked", "add")
      fmap refusalRule (refusal fault) `shouldBe` Just RuleFloatForInteger
      logged fx >>= (`shouldBe` [])
      -- The same call made by the script itself is the ordinary error.
      run owned (caught "checked.add(1.5, 2)" "checked.add: argument 1: a float where an integer is declared")

  it "is kept as cleanup evidence when the finalizer runs during the close" $ do
    fx ← newFx
    outcome ←
      tryWithContext @SomeException $
        withOwnerOf
          (configOf fx ["checked"]) {vmInitialChunks = [(chunkName "guard", encodeUtf8 "guard = setmetatable({}, {__gc = function() pcall(checked.note_gc, 1.5) end})")]}
          (\_ → pure ())
    case outcome of
      Right () → expectationFailure "a refusal reached from a closing finalizer was dropped"
      Left failure → [fmap (fmap refusalRule . refusal) cause | cause ← evidenceCauses @BoundaryFault failure] `shouldBe` [Just (Just (RuleWrongType "text" "float"))]
    logged fx >>= (`shouldBe` [])

  it "keeps the recorded fault while a script has stopped the collector, which a finalizer's run is indistinguishable from" $
    withFx $ \_ owned → do
      fault ← runFault owned "collectgarbage('stop'); pcall(checked.add, 1.5, 2)"
      boundaryBinding fault `shouldBe` Just ("checked", "add")
      run owned "collectgarbage('restart')"

-- Discipline ---------------------------------------------------------------------

disciplineSpec ∷ Spec
disciplineSpec = describe "discipline" $ do
  it "leaves the stack and the registry as it found them across success, refusal, busy and error paths" $
    withFx $ \fx owned → do
      before ← readings owned
      replicateM_ 500 $ do
        run
          owned
          ( Text.unlines
              [ "assert(checked.add(1, 2) == 3)"
              , "assert(pcall(checked.add, 1.5, 2) == false)"
              , "assert(pcall(checked.echo_list, {1, 'x'}) == false)"
              , "assert(pcall(checked.in_phase, 'x') == false)"
              , "assert(checked.admit(1) == 1)"
              ]
          )
        _ ← try @LuaFault (run owned "checked.add(1.5, 2)")
        writeIORef (fxPhase fx) "init"
        run owned (caught "checked.in_phase(1)" "checked.in_phase: wrong phase: init")
        writeIORef (fxPhase fx) "update"
      readings owned >>= (`shouldBe` before)

  it "is a classified failure wherever memory runs out, including while the refusal is built" $ do
    fx ← newFx
    outcomes ←
      forM [0, 50 .. 100000] $ \budget → do
        result ←
          runOwner
            ( (defaultOwnerConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
                { ownerBudget = Just budget
                , ownerRegistration = registrationOf fx
                , ownerGranted = ["checked", "plain"]
                , ownerLimits = either (error . show) id (valueLimits 65536 64 4096)
                }
            )
            $ \owned → do
              depth ← stackDepth (ownedInternalVm owned)
              steps ← forM
                [ ("caught", "assert(pcall(checked.add, 1.5, 2) == false)")
                , ("arity", "assert(pcall(checked.echo_list) == false)")
                , ("valid", "assert(checked.add(1, 2) == 3)")
                , -- Under pcall, and deep enough that reading it has to grow the stack: the
                  -- copy running out of stack is a fault of the call, never an ordinary
                  -- error pcall hides, and what is refused for its type is the ordinary one.
                  ("deep", "local t = 1; for i = 1, 30 do t = {t} end; local ok, err = pcall(checked.echo_list, t); assert(ok == false and err:find('expected number', 1, true), tostring(err))")
                , ("busy", "checked.admit(1)")
                ]
                $ \(label, source) → do
                  outcome ← try @SomeException (run owned source)
                  after ← stackDepth (ownedInternalVm owned)
                  after `shouldBe` depth
                  pure (label <> ":" <> classified outcome)
              pure steps
        pure $ case result of
          Right steps → steps
          Left _ → ["construction"]
    let kinds = nub (concat outcomes)
    filter (Text.isInfixOf "unclassified") kinds `shouldBe` []
    kinds `shouldSatisfy` elem "caught:ok"
    -- Memory ran out where the refusal was built, and was a fault of the call.
    kinds `shouldSatisfy` elem "caught:memory at the boundary"
    kinds `shouldSatisfy` elem "deep:memory at the boundary"

classified ∷ Either SomeException a → Text
classified = \case
  Right _ → "ok"
  Left failure
    | Just (fault ∷ LuaFault) ← fromException failure, faultKind fault == MemoryExhausted → "memory in Lua"
    | Just (fault ∷ BoundaryFault) ← fromException failure → case boundaryReason fault of
        ScriptFailed MemoryExhausted _ → "memory at the boundary"
        other → "unclassified " <> Text.pack (show other)
    | otherwise → "unclassified " <> Text.pack (show failure)

-- Reasons ------------------------------------------------------------------------

reasonSpec ∷ Spec
reasonSpec = describe "a refusal's reason" $ do
  it "reaches Lua whole at the byte limit, and a longer one is a fault of the call, however large" $
    withFx $ \fx owned → do
      let reason = Text.replicate refusalReasonLimit "r"
      writeIORef (fxReason fx) reason
      run owned (caught "checked.vet(1)" ("checked.vet: " <> reason))
      -- Counted in bytes of UTF-8, not in characters.
      writeIORef (fxReason fx) (Text.replicate (refusalReasonLimit `div` 2) "é")
      run owned (caught "checked.vet(1)" ("checked.vet: " <> Text.replicate (refusalReasonLimit `div` 2) "é"))
      forM_ [Text.replicate (refusalReasonLimit + 1) "r", Text.replicate (refusalReasonLimit `div` 2 + 1) "é"] $ \tooLong → do
        writeIORef (fxReason fx) tooLong
        fault ← runFault owned "pcall(checked.vet, 1)"
        fmap refusalRule (refusal fault) `shouldBe` Just (RuleBytesLimit refusalReasonLimit)
        boundaryBinding fault `shouldBe` Just ("checked", "vet")
        boundaryEffect fault `shouldBe` LuaRan
      writeIORef (fxReason fx) giantReason
      Text.length giantReason `shouldBe` 20000000
      before ← getAllocationCounter
      fault ← runFault owned "pcall(checked.vet, 1)"
      after ← getAllocationCounter
      fmap refusalRule (refusal fault) `shouldBe` Just (RuleBytesLimit refusalReasonLimit)
      (before - after) `shouldSatisfy` (< 2000000)
      logged fx >>= (`shouldBe` [])

  it "makes every rule of a script's own value an ordinary error, and keeps the interpreter's running out of what the copy needs a fault" $ do
    let rules =
          [ RuleBytesLimit 1, RuleDepthLimit 1, RuleElementLimit 1, RuleCycle, RuleUnsupportedType "function", RuleMetatable
          , RuleKeyType, RuleWrongType "a" "b", RuleFloatForInteger, RuleInvalidUtf8, RuleNilInTable, RuleNotASequence
          , RuleNotARecord, RuleUnknownField "f", RuleMissingField "f", RuleDuplicateField "f", RuleArity 1 2
          , RuleForeignHandle, RuleHandleType "a" "b", RuleRetiredHandle "a", RuleUnknownCapability "a"
          ]
    forM_ rules $ \rule → ordinaryRule rule `shouldBe` True
    forM_ [RuleStack, RuleMemory] $ \rule → ordinaryRule rule `shouldBe` False

  it "says nothing past the bound of anything the script gave, whatever its names are" $ do
    let giant = Text.replicate 100000 "n"
        rules =
          [ RuleBytesLimit 1, RuleDepthLimit 1, RuleElementLimit 1, RuleCycle, RuleUnsupportedType giant, RuleMetatable
          , RuleKeyType, RuleStack, RuleMemory, RuleWrongType giant giant, RuleFloatForInteger, RuleInvalidUtf8
          , RuleNilInTable, RuleNotASequence, RuleNotARecord, RuleUnknownField giant, RuleMissingField giant
          , RuleDuplicateField giant, RuleArity 16 maxBound, RuleForeignHandle, RuleHandleType giant giant
          , RuleRetiredHandle giant, RuleUnknownCapability giant
          ]
        path = replicate 40 (AtField giant) <> [AtIndex maxBound]
    forM_ rules $ \rule → do
      let reason = argumentReason 16 path rule
      lengthWord8 reason `shouldSatisfy` (<= refusalReasonLimit)
      -- Cut at a character, never inside one.
      Text.length (Text.filter (== '\xFFFD') reason) `shouldBe` 0
