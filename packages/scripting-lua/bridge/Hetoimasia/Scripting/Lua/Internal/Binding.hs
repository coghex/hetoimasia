-- | A registration's bindings, installed in an owner's VM and called from Lua.
--
-- Installing is part of the owner's construction. For each namespace the owner's
-- policy grants, the namespace's table is created in the globals and each of its
-- bindings eligible for the trusted direct path is installed in it, before any
-- initial chunk or module runs. A binding not eligible for that path is not
-- installed, so it cannot run through it. The owner's set is fixed from then on:
-- nothing installs or removes a binding later.
--
-- = A call, step by step
--
-- A Lua call to a binding runs the 'Handler' made here, on the callback entry's
-- thread, with the VM's gate held by the operation that is running Lua:
--
-- 1. a binding of a kind this slice does not deliver is refused as not yet
--    supported (decision A1), and its action never runs;
-- 2. the number of arguments is checked against the schemas', and the arguments
--    are read into a bounded copy by a protected C call (nothing is converted,
--    no metamethod runs, and the reader stops at its limits);
-- 3. the copy is checked against the argument schemas, a capability against the
--    VM, its type, and the application's own liveness check, before the action;
-- 4. the action runs, unmasked, with copies and nothing else: no VM, no state, no
--    handle to its own VM;
-- 5. its results are checked against the result schemas and encoded under the same
--    limits, and built in Lua by a protected C call.
--
-- Every refusal is a fault of the call (decision C1): the failure is thrown from
-- the handler, so the callback entry records it on the VM and answers Lua with
-- the failure marker, and the operation that is running Lua raises it, typed,
-- whatever Lua did with the marker, a @pcall@ included. A refusal before the
-- action is 'Hetoimasia.Scripting.Lua.Internal.Boundary.LuaRan' or
-- 'Hetoimasia.Scripting.Lua.Internal.Boundary.BindingRan', never an effect-free
-- operation, because Lua was running; a refusal of a result is always
-- 'Hetoimasia.Scripting.Lua.Internal.Boundary.BindingRan', because the action
-- had run. A failure of the action itself is not converted: it is re-raised at
-- the owner's boundary with its type and context, as for any callback.
--
-- = Recoverable refusals
--
-- A binding opted in with
-- 'Hetoimasia.Scripting.Lua.Internal.Registration.recoverableRefusals' or
-- 'Hetoimasia.Scripting.Lua.Internal.Registration.withPrecondition' refuses what it
-- can before its action differently: its preconditions, run first (before the
-- host asks whether a scheduler operation can suspend, and before an argument is
-- read), and the refusals of step 2 and 3 are not thrown. The handler leaves a
-- bounded message on the stack, built by the same protected push the results use,
-- and answers 'failedResults'; the C closure raises it once every Haskell frame
-- has returned, as it raises the marker, but nothing is recorded on the VM. Lua
-- sees an ordinary error: @pcall@ catches it, the call it was caught in goes on and
-- can succeed, and the action did not run. An uncaught one is the script's own
-- error, and goes where any is reported.
--
-- What is not made recoverable: a precondition's or a validator's own exception,
-- which is the application's failure; the interpreter or the host running out of
-- stack or memory reading a value; a precondition's reason past
-- 'Hetoimasia.Scripting.Lua.Internal.Registration.refusalReasonLimit', which is a
-- defect of the application; the host's own refusal of a scheduler operation once
-- the preconditions have passed; everything after the action; and a refusal reached
-- from a finalizer. Lua turns an error raised in a finalizer into a warning and
-- says nothing, so a call made while the VM closes, or while the collector is not
-- running (which is how a running finalizer looks, and what a script that stopped
-- it looks like), keeps the recorded fault. Nothing ever clears one: a recoverable
-- refusal records nothing, and so removes nothing.
module Hetoimasia.Scripting.Lua.Internal.Binding
  ( installRegistration
  , valueHandler
  , retiredIn
  , ensureValues
  , argumentReason
  , ordinaryRule
  , boundReason
  , diagnosticLimits
  ) where

import Control.Exception (Exception, ExceptionWithContext (ExceptionWithContext), SomeException, evaluate, fromException, throwIO, toException, try)
import qualified Control.Exception as Exception
import Control.Monad (foldM, forM_, unless, when)
import Data.Foldable (for_)
import Data.List (nub)
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text.Unsafe (lengthWord8)
import qualified Data.Text as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Scripting.Lua.Internal.Boundary
import Hetoimasia.Scripting.Lua.Internal.Call (reportFault)
import Hetoimasia.Scripting.Lua.Internal.Callback (Handler, failedResults, installBinding)
import Hetoimasia.Scripting.Lua.Internal.Fault (CallRefusal (CallRefusal), OrdinaryCallRefusal (OrdinaryCallRefusal), classify, fromApplication, luaComponent, raisedByApplication, renderFailure)
import Hetoimasia.Scripting.Lua.Internal.Marshal
import Hetoimasia.Scripting.Lua.Internal.Registration
import Hetoimasia.Scripting.Lua.Internal.Value
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Phase (Closing)
  , Vm
  , markValuesPrepared
  , noteActionRun
  , activeTask
  , amendEscape
  , noteSuspension
  , operationActionRuns
  , Suspension (..)
  , runContext
  , valuesPrepared
  , vmIdentity
  , vmPhase
  , withOpenVm
  )
import Lua (NumResults (NumResults), State, StatusCode, fromStackIndex, lua_gettop, lua_settop, data LUA_OK)

-- | Install the bindings of the granted namespaces: each namespace's table, then
-- each direct-eligible binding in it. A policy that names a namespace the
-- registration does not declare is refused before anything is installed.
installRegistration ∷ HasCallStack ⇒ Boundary → Vm → [Text] → IO ()
installRegistration boundary vm granted = do
  let registered = boundaryRegistration boundary
      wanted = nub granted
  forM_ wanted $ \name → case lookupNamespace registered name of
    Just _ → pure ()
    Nothing →
      throwFailure luaComponent installOperation [("namespace", name)] $
        (blankFault boundary InstallBindings (PolicyUnknownNamespace name)) {boundaryChunk = name}
  unless (null wanted) $ withOperationContext luaComponent installOperation [] $
    withOpenVm vm installOperation $ \state → do
      ensureValues vm state
      forM_ wanted $ \name → do
        entry ← lua_gettop state
        (status, collision) ← declareNamespace state name
        unless (status == LUA_OK) (reportFault vm state entry installOperation (classify status) name)
        lua_settop state entry
        when collision $
          throwFailure luaComponent installOperation [("namespace", name)] $
            (blankFault boundary InstallBindings (NamespaceTaken name)) {boundaryChunk = name}
  forM_ wanted $ \name → forM_ (lookupNamespace registered name) $ \space →
    forM_ (directBindings space) $ \binding →
      installBinding vm name (bindingName binding) (isSuspending binding) (valueHandler boundary vm name binding)

-- | Make what the value boundary keeps in the registry, once for the VM: the
-- metatable every handle wears and the table the modules' slots live in. Called
-- inside an operation of the VM, before anything that needs either; a VM whose
-- owner uses neither never has it.
ensureValues ∷ HasCallStack ⇒ Vm → State → IO ()
ensureValues vm state = do
  ready ← valuesPrepared vm
  unless ready $ do
    entry ← lua_gettop state
    prepared ← prepareValues state
    unless (prepared == LUA_OK) (reportFault vm state entry installOperation (classify prepared) "values")
    lua_settop state entry
    markValuesPrepared vm

installOperation ∷ Operation
installOperation = operation "install-bindings"

callOperation ∷ Operation
callOperation = operation "call-binding"

-- | The handler of one binding. See the module header for what a call does.
valueHandler ∷ HasCallStack ⇒ Boundary → Vm → Text → Binding → Handler
valueHandler boundary vm space binding state restore = do
  entry ← lua_gettop state
  -- Whether a refusal may be an ordinary Lua error. Not when a finalizer may be the
  -- caller: Lua turns an error raised in one into a warning and says nothing, so
  -- a refusal that recorded nothing would be silent. Every call while the VM
  -- closes is a finalizer's, and Lua holds the collector while a finalizer runs
  -- and a script can stop it, so a call made with the collector stopped keeps
  -- the recorded fault too: it errs the way that is observable.
  ordinary ← if bindingRecoverable binding
    then do
      phase ← vmPhase vm
      running ← collectorRunning state
      pure (phase /= Closing && running)
    else pure False
  let context = boundaryContext boundary
      limits = boundaryLimits boundary
      declared = bindingArguments binding
      qualified = qualifiedName space (bindingName binding)
      faulted ∷ ∀ b. FaultReason → Effect → IO b
      faulted reason effect = do
        -- Where the script was when it called: its source chunk and a bounded
        -- traceback, and the module and entry point it was running, if any.
        (caller, traceback) ← captureContext state
        lua_settop state entry
        running0 ← runContext vm
        -- The module the operation is running names the fault only if the call
        -- was made from that module's own code. A finalizer of another module can
        -- run at any allocation, and is not the entry point that was called.
        let running = case running0 of
              Just (name, version, _) | sameChunk (moduleChunk (ModuleRef name version)) caller → running0
              _ → Nothing
        throwFailure luaComponent callOperation [("binding", qualified)] $
          (blankFault boundary CallBinding reason)
            { boundaryBinding = Just (space, bindingName binding)
            , boundaryChunk = fromMaybe qualified caller
            , boundaryEffect = effect
            , boundaryTraceback = traceback
            , boundaryModule = fmap (\(name, version, _) → ModuleRef name version) running
            , boundaryEntry = running >>= \(_, _, entryName) → entryName
            }
      -- Lua is running whenever a handler is: what changed is whether an action
      -- of this operation had run before.
      current ∷ IO Effect
      current = do
        runs ← operationActionRuns vm
        pure (if runs > 0 then BindingRan else LuaRan)
      refuseArguments ∷ ∀ b. Int → [PathStep] → ValueRule → Int → IO b
      refuseArguments index path rule visited
        -- An opted-in binding's refusal of what the script gave it is an ordinary
        -- Lua error, unless it is Lua or the host running out of what the copy
        -- needs. Nothing is recorded on the VM for it.
        | ordinary && ordinaryRule rule = throwIO (OrdinaryRefusal (argumentReason index path rule))
        | otherwise = do
            effect ← current
            faulted (ValueRefused (ValueRefusal Arguments index path rule visited)) effect
      -- A precondition's refusal. Too long a reason is a defect of the application,
      -- a fault of the call whether or not the binding is opted in.
      refusePrecondition ∷ ∀ b. Text → IO b
      refusePrecondition reason
        | lengthWord8 reason > refusalReasonLimit = do
            effect ← current
            faulted (ValueRefused (ValueRefusal Results 1 [] (RuleBytesLimit refusalReasonLimit) 0)) effect
        | ordinary = throwIO (OrdinaryRefusal reason)
        | otherwise = do
            effect ← current
            faulted (BindingRefused reason) effect
      -- The ordinary Lua error: the stack as it was on entry, the refusal's text on
      -- top, and the count that makes the C closure raise the value on top once
      -- every Haskell frame has returned. The text is built by the protected push
      -- the results use, so an allocation failure is a status and not a longjmp
      -- out of this frame, and it keeps the fault such a failure has.
      raiseOrdinary ∷ Text → IO NumResults
      raiseOrdinary reason = do
        lua_settop state entry
        let message = qualified <> ": " <> reason
            -- The owner's limits bound what crosses for the script's values; the
            -- diagnostic has a bound of its own, so that a small, valid limit cannot
            -- turn a refusal the script caught into a fault of the call.
            allowance = either (const limits) id diagnosticLimits
        encoded ← case encodeValues context allowance [VText message] of
          Left rule → do
            effect ← current
            faulted (ValueRefused (ValueRefusal Results 1 [] rule 0)) effect
          Right bytes → pure bytes
        pushed ← pushValues state allowance encoded 1
        case pushed of
          Pushed → do
            serviceCollector state
            pure failedResults
          PushStatus status → do
            value ← renderFailure state entry
            lua_settop state entry
            effect ← current
            faulted (ScriptFailed (classify status) value) effect
          PushMalformed which → do
            effect ← current
            faulted (InternalError (Text.pack ("a refusal could not be built: " <> show which))) effect
      refuseResults ∷ ∀ b. Int → [PathStep] → ValueRule → IO b
      refuseResults index path rule = faulted (ValueRefused (ValueRefusal Results index path rule 0)) BindingRan
      statusFault ∷ ∀ b. StatusCode → IO b
      statusFault status = do
        value ← renderFailure state entry
        lua_settop state entry
        effect ← current
        faulted (ScriptFailed (classify status) value) effect
  -- A lifecycle operation is delivered only by an owner configured with the context
  -- that delivers it, and that context is handed to its action; one a finalizer may
  -- call is never delivered, whatever the owner has, since nothing a finalizer runs
  -- may reach the application's lifecycle. Anything else of a reserved kind is
  -- refused as not yet supported, with its action never run.
  --
  -- An asynchronous request is delivered the same way, by an owner configured with the
  -- context that delivers it, and so is a wait for one's settlement: the host reports it
  -- to whatever resumed the task, and only an owner with a request service has anything
  -- to resume it.
  let delivered = case (bindingAction binding, boundaryLifecycle boundary, boundaryRequests boundary) of
        (LifecycleAction run, Just lifecycle, _) | not (bindingFinalizer binding) → ValuesAction (run lifecycle)
        (RequestAction run, _, Just requests) | not (bindingFinalizer binding) → ValuesAction (run requests)
        (other, _, _) → other
  case delivered of
    RequestAction _ → do
      effect ← current
      faulted (NotYetSupported (bindingKind binding)) effect
    LifecycleAction _ → do
      effect ← current
      faulted (NotYetSupported (bindingKind binding)) effect
    SuspendAction (SuspendWait WaitSettlement)
      | isNothing (boundaryRequests boundary) → do
          effect ← current
          faulted (NotYetSupported (bindingKind binding)) effect
    action → do
      -- Everything up to the action, where an opted-in binding's ordinary refusal
      -- is raised as the one private exception this catches, and nothing else is.
      -- An opted-in binding's preconditions come first, before anything else of the
      -- call: before the host asks whether a scheduler operation can suspend, and
      -- before an argument is read. They are the application's own code, so they
      -- run unmasked and what they raise is the application's failure.
      checked ← try $ do
        let owner = OwnerContexts (boundaryLifecycle boundary) (boundaryRequests boundary)
        for_ (bindingPreconditions binding) $ \check → do
          verdict ← fromApplication $ do
            found ← restore (check owner)
            found <$ evaluate (maybe () (\reason → lengthWord8 reason `seq` ()) found)
          forM_ verdict refusePrecondition
        -- A scheduler operation is refused next, wherever it cannot reach the
        -- scheduler, before anything of its arguments is read.
        case action of
          SuspendAction _ → do
            refusal ← suspensionRefusal vm state
            forM_ refusal $ \why → do
              effect ← current
              faulted (SuspendRefused why) effect
          _ → pure ()
        top ← fromIntegral . fromStackIndex <$> lua_gettop state
        when (top /= length declared) $
          refuseArguments 0 [] (RuleArity (length declared) top) 0
        raws ← do
          copied ← readValues state limits (vmIdentity vm) 1 top
          case copied of
            ReadStatus status → statusFault status
            ReadRefused rule index visited → refuseArguments index [] rule visited
            ReadCopied bytes visited → case decodeValues top bytes of
              Left why → faulted (InternalError why) =<< current
              Right found → pure (found, visited)
        let (found, visited) = raws
        values ← traverse
          ( \(index, schema, raw) → case conformRaw context schema raw of
              Left (path, rule) → refuseArguments index path rule visited
              Right value → pure value
          )
          (zip3 [1 ..] declared found)
        -- Every handle is checked for having ended before the action, except the one an
        -- explicit release is given: it was checked above for being this VM's, of the
        -- declared type, and its binding's only argument, and ending is what it answers.
        unless (acceptsRetired binding) $
          forM_ (zip [1 ..] values) $ \(index, value) → do
            -- The application's own check is application code, like the action: it
            -- runs unmasked.
            retired ← restore (retiredIn boundary value)
            forM_ retired $ \(path, typeName) →
              refuseArguments index path (RuleRetiredHandle typeName) visited
        -- The application's checks of the copied values come last, when the values are known to
        -- be of the declared shapes and live: they decide what only the values carry.
        for_ (bindingArgumentChecks binding) $ \check → do
          verdict ← fromApplication $ do
            answer ← restore (check owner values)
            answer <$ evaluate (maybe () (\reason → lengthWord8 reason `seq` ()) answer)
          forM_ verdict refusePrecondition
        pure values
      case checked of
        Left (OrdinaryRefusal reason) → raiseOrdinary reason
        Right values → do
          let runAction ∷ IO [Value] → IO NumResults
              runAction compute = do
                  -- Counted before it starts, so a fault of anything the action does is
                  -- one that happened after an action ran.
                  noteActionRun vm
                  -- A refusal the script caught and went on from is the operation's failure
                  -- (C1), and an action is about to run after it: what it reports as having
                  -- happened has to include that.
                  amendEscape vm upgradeEffect
                  -- The engine's own refusal of this call, raised by its API from inside
                  -- the action, is a fault of the call and not the application's failure.
                  -- It is caught outside the mark the action's failures get, so the mark
                  -- never reaches it.
                  outcome ←
                    (Right <$> compute)
                      `Exception.catches` [ Exception.Handler (\(CallRefusal why) → faulted (BindingRefused why) BindingRan)
                                , -- The refusal that is final and not a fault: an ordinary Lua error for a binding
                                  -- opted in to them, the fault of the call for any other.
                                  Exception.Handler (\(OrdinaryCallRefusal why) → if ordinary then pure (Left why) else faulted (BindingRefused why) BindingRan)
                                ]
                  case outcome of
                    Left why → raiseOrdinary why
                    Right produced → do
                      let expected = bindingResults binding
                      -- Bounded first: an action that built far more than the limits allow is
                      -- refused after visiting what the limits allow, plus one.
                      either (refuseResults 0 []) pure (checkLimits limits produced)
                      when (length produced /= length expected) $
                        refuseResults 0 [] (RuleArity (length expected) (length produced))
                      forM_ (zip3 [1 ..] expected produced) $ \(index, schema, value) →
                        case conformValue context schema value of
                          Left (path, rule) → refuseResults index path rule
                          Right () → pure ()
                      encoded ← case encodeValues context limits produced of
                        Left rule → refuseResults 0 [] rule
                        Right bytes → pure bytes
                      pushed ← pushValues state limits encoded (length produced)
                      case pushed of
                        Pushed → do
                          -- Back to the script: what building its results allocated while the
                          -- collector was held is paid now.
                          serviceCollector state
                          pure (NumResults (fromIntegral (length produced)))
                        PushStatus status → do
                          value ← renderFailure state entry
                          lua_settop state entry
                          faulted (ScriptFailed (classify status) value) BindingRan
                        PushMalformed which → faulted (InternalError (Text.pack ("a result could not be built: " <> show which))) BindingRan

          case action of
            SuspendAction suspend → do
              -- No application code runs: the task's coroutine is suspended once this
              -- handler returns, and the host is told what the script asked for.
              noteSuspension vm $ case suspend of
                SuspendYield → SuspensionYield
                SuspendWait kind → SuspensionWait kind space (bindingName binding) values
              pure (NumResults 0)
            -- What the action returns is evaluated inside the mark: a failure hidden in
            -- a lazy result is the application's, whenever it would have surfaced.
            -- The bounded check reaches every part of a result that can cross, and
            -- stops at a limit, so an endless result costs no more than a large one.
            ValuesAction run →
              runAction . fromApplication $ do
                returned ← restore (run values)
                returned <$ evaluate (checkLimits limits returned)
            ReleaseAction run →
              runAction . fromApplication $ do
                returned ← restore (run values)
                returned <$ evaluate (checkLimits limits returned)
            CommandAction run →
              runAction $ do
                answer ← fromApplication (restore (run values) >>= evaluate)
                case answer of
                  Accepted → pure [VBoolean True, VNil]
                  Rejected reason
                    -- Its length in bytes without copying it: the text is the application's
                    -- and may be as large as memory allows.
                    | lengthWord8 reason > commandReasonLimit →
                        refuseResults 2 [] (RuleBytesLimit commandReasonLimit)
                    | otherwise → pure [VBoolean False, VText reason]


-- | What the message of an ordinary refusal is encoded and pushed under: one string
-- of at most a qualified name (129 bytes), a separator and 'refusalReasonLimit' bytes,
-- with room to spare, whatever limits the owner crosses its script's values under.
diagnosticLimits ∷ Either LimitsRefusal ValueLimits
diagnosticLimits = valueLimits 1024 2 8

-- | The refusal of an opted-in binding that Lua is to see as an ordinary error:
-- why, bounded. Thrown by the checks before an action and caught around them and
-- nowhere else, so it never reaches the operation's boundary.
newtype OrdinaryRefusal = OrdinaryRefusal Text
  deriving (Show)

instance Exception OrdinaryRefusal

-- | Whether an opted-in binding's refusal under this rule is an ordinary Lua
-- error. Running out of stack or memory for the copy is not a refusal of the
-- script's value: it is the interpreter's, and keeps its fault.
ordinaryRule ∷ ValueRule → Bool
ordinaryRule = \case
  RuleStack → False
  RuleMemory → False
  _ → True

-- | What a refused argument is called to Lua, within 'refusalReasonLimit' bytes.
-- Nothing of the script's is copied past a few characters: a field name is cut
-- before it is joined to anything.
argumentReason ∷ Int → [PathStep] → ValueRule → Text
argumentReason index path rule = boundReason (subject <> ": " <> ruleReason rule)
  where
    subject
      | index == 0 = "the arguments"
      | otherwise = "argument " <> Text.pack (show index) <> foldMap step path
    step = \case
      AtIndex position → "[" <> Text.pack (show position) <> "]"
      AtField name → "." <> clip name

-- | What a rule says, in a few words.
ruleReason ∷ ValueRule → Text
ruleReason = \case
  RuleBytesLimit limit → "more than " <> count limit <> " bytes"
  RuleDepthLimit limit → "nested deeper than " <> count limit
  RuleElementLimit limit → "more than " <> count limit <> " values"
  RuleCycle → "a table contains itself"
  RuleUnsupportedType name → "a " <> clip name <> " cannot be passed"
  RuleMetatable → "a table has a metatable"
  RuleKeyType → "a table key is neither an integer nor a string"
  RuleStack → "no stack to read it"
  RuleMemory → "no memory to read it"
  RuleWrongType declared found → "expected " <> clip declared <> ", found " <> clip found
  RuleFloatForInteger → "a float where an integer is declared"
  RuleInvalidUtf8 → "text that is not valid UTF-8"
  RuleNilInTable → "a nil in a table"
  RuleNotASequence → "not a sequence"
  RuleNotARecord → "not a record"
  RuleUnknownField name → "unknown field " <> clip name
  RuleMissingField name → "missing field " <> clip name
  RuleDuplicateField name → "field " <> clip name <> " twice"
  RuleArity declared found → "expected " <> count declared <> " values, found " <> count found
  RuleForeignHandle → "a handle another VM issued"
  RuleHandleType declared found → "expected a " <> clip declared <> " handle, found a " <> clip found <> " handle"
  RuleRetiredHandle name → "a " <> clip name <> " handle that has ended"
  RuleUnknownCapability name → "unknown handle type " <> clip name
  where
    count = Text.pack . show

-- | The first few characters of a name.
clip ∷ Text → Text
clip name
  | Text.compareLength name clipLength == GT = Text.take clipLength name <> "..."
  | otherwise = name
  where
    clipLength = 32

-- | At most 'refusalReasonLimit' bytes of UTF-8, cut at a character.
boundReason ∷ Text → Text
boundReason text
  | lengthWord8 text <= refusalReasonLimit = text
  | otherwise = Text.pack (go 0 (Text.unpack (Text.take refusalReasonLimit text)))
  where
    go ∷ Int → String → String
    go _ [] = []
    go used (character : rest)
      | used' > refusalReasonLimit = []
      | otherwise = character : go used' rest
      where
        used' = used + lengthWord8 (Text.singleton character)

-- | The first capability in a value whose type the application's own check
-- refuses, with where it is. Checked in order, before the binding's action.
retiredIn ∷ Boundary → Value → IO (Maybe ([PathStep], Text))
retiredIn boundary = go []
  where
    registered = boundaryRegistration boundary
    go path = \case
      VCapability capability → do
        live ← case lookupCapability registered (capabilityTypeName capability) of
          Just kind → fromApplication (capabilityLive kind (capabilityKey capability) >>= evaluate)
          Nothing → pure False
        pure (if live then Nothing else Just (reverse path, capabilityTypeName capability))
      VList items → firstJust [go (AtIndex index : path) item | (index, item) ← zip [1 ..] items]
      VRecord entries → firstJust [go (AtField name : path) item | (name, item) ← entries]
      _ → pure Nothing
    firstJust = foldM (\found next → maybe next (pure . Just) found) Nothing

-- | A recorded boundary fault, now known to have an action after it, says a
-- binding's action ran.
upgradeEffect ∷ ExceptionWithContext SomeException → ExceptionWithContext SomeException
upgradeEffect captured@(ExceptionWithContext context exception) = case fromException exception of
  -- A failure the application raised is its own, however it is typed: it is not
  -- the boundary's report, so what it says is never rewritten.
  Just fault | boundaryEffect fault < BindingRan, not (raisedByApplication context) → ExceptionWithContext context (toException (fault {boundaryEffect = BindingRan}))
  _ → captured

-- | Whether the chunk a call was made from is this module's. Lua shortens a
-- chunk name to 59 bytes in the form a call record gives it, so a name that long
-- is matched by its prefix.
sameChunk ∷ Text → Maybe Text → Bool
sameChunk chunk = \case
  Nothing → False
  Just seen → seen == chunk || (Text.length seen >= 59 && seen `Text.isPrefixOf` chunk)

-- | Why a scheduler operation called from this thread cannot reach the scheduler,
-- if it cannot.
--
-- It can only when the host is resuming a task of this owner, the call is made by
-- that task's own coroutine, and Lua could suspend that coroutine right here. The
-- order is the order of what is cheapest and most general to say.
suspensionRefusal ∷ Vm → State → IO (Maybe SuspendRefusal)
suspensionRefusal vm state = do
  active ← activeTask vm
  case active of
    Nothing → pure (Just SuspendOutsideTask)
    Just task
      | task /= state → pure (Just SuspendOtherCoroutine)
      | otherwise → do
          yieldable ← threadYieldable state
          pure (if yieldable then Nothing else Just SuspendNotYieldable)
