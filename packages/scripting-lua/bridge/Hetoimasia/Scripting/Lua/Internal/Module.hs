-- | Application-owned Lua modules, and calling their entry points.
--
-- A module is source the application supplies, under an identity -- a name and
-- a version -- it chose. The host reads nothing from disk and searches no path:
-- there is no @require@ here, and nothing in this module turns a name into a
-- file. A module is loaded at initialization or from the owner's body, and is
-- known afterwards by an opaque 'ModuleHandle' that carries the identity of the
-- VM that issued it.
--
-- = The environment (decision B1)
--
-- Each module runs in an environment of its own. Its global assignments land in
-- that environment and no other, and the owner's standard libraries and granted
-- namespaces are visible to it by reading through to the globals. This is
-- isolation of names and nothing more; it is not a security boundary, and it
-- makes no claim against a module that reaches for the globals table through a
-- library it was given. Confinement is a later slice's.
--
-- = Entry points
--
-- The application declares the entry points a module has, each required or
-- optional, with the schemas of its arguments and results. They are looked up by
-- raw access in the module's environment, so no metamethod decides what is there.
-- A required entry point that the module does not define as a function fails the
-- load, naming module and entry. At call time a required one that has gone is a
-- fault, never an absent answer; an optional one that is not there answers
-- 'EntryAbsent' and nothing runs. One that is present and is not a function is a
-- fault in either case.
--
-- = Registry
--
-- A loaded module holds exactly one slot of a table the bridge keeps in the
-- registry, for as long as the owner lives. The slot is emptied if the load
-- fails after the module was stored, and every slot goes when the VM closes. A
-- call, a refusal and a failed load retain nothing.
module Hetoimasia.Scripting.Lua.Internal.Module
  ( -- * Describing a module
    Requirement (..)
  , EntryPoint (..)
  , ModuleSource (..)
  , ModuleHandle (..)
  , CallResult (..)
    -- * The owner's module state
  , Host (..)
  , newHost
    -- * Loading and calling
  , loadModule
  , callEntry
  , callEntryVia
  , entryDefined
  , Lead (..)
  , Prepared (..)
  , prepareEntry
  , prepareEntryWith
  , readResults
  , faultOf
  , effectNow
  , liveModuleReferences
  , loadedModule
    -- * Bounds
  , maxModules
  , maxSourceBytes
  , maxEntries
  , maxIdentityLength
  ) where

import Control.Exception (onException)
import Control.Monad (forM_, unless, void, when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Scripting.Lua.Internal.Binding (ensureValues, retiredIn)
import Hetoimasia.Scripting.Lua.Internal.Boundary
import Hetoimasia.Scripting.Lua.Internal.Fault (ErrorValue (ErrorAbsent), classify, luaComponent, renderFailure)
import Hetoimasia.Scripting.Lua.Internal.Marshal
import Hetoimasia.Scripting.Lua.Internal.Registration
import Hetoimasia.Scripting.Lua.Internal.Value
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Vm
  , nextModuleSlot
  , operationActionRuns
  , raiseEscape
  , runCallback
  , setRunContext
  , vmIdentity
  , withOpenVm
  )
import Lua (StackIndex, State, fromStackIndex, lua_gettop, lua_settop, data LUA_OK)

-- | Whether an entry point has to be there.
data Requirement = Required | Optional
  deriving (Eq, Show)

-- | An entry point a module is declared to have.
data EntryPoint = EntryPoint
  { entryName ∷ !Text
  , entryRequirement ∷ !Requirement
  , entryArguments ∷ ![Schema]
  , entryResults ∷ ![Schema]
  }
  deriving (Eq, Show)

-- | A module as the application supplies it.
data ModuleSource = ModuleSource
  { sourceIdentity ∷ !ModuleRef
  , sourceText ∷ !ByteString
    -- ^ Lua source. A precompiled chunk is refused.
  , sourceEntries ∷ ![EntryPoint]
  }

-- | A loaded module, known by the VM that issued it and its place there.
--
-- It is a value, not authority: it names a slot of one VM, and every use checks
-- that VM, so a copy of it grants nothing a holder did not have. Lua never sees
-- one.
data ModuleHandle = ModuleHandle
  { handleVm ∷ !VmIdentity
  , handleSlot ∷ !Int
  , handleModule ∷ !ModuleRef
  , handleEntries ∷ ![EntryPoint]
  }
  deriving (Eq, Show)

-- | What calling an entry point answered.
data CallResult
  = Returned ![Value]
  | -- | The entry point is optional and the module does not define it. Nothing
    -- ran.
    EntryAbsent
  deriving (Eq, Show)

-- | What an owner keeps to load and call modules: its VM, its boundary, and the
-- identities it has loaded.
data Host = Host
  { hostVm ∷ !Vm
  , hostBoundary ∷ !Boundary
  , hostLoaded ∷ !(IORef (Map ModuleRef ModuleHandle))
  }

newHost ∷ Vm → Boundary → IO Host
newHost vm boundary = Host vm boundary <$> newIORef Map.empty

-- | At most this many modules in one owner.
maxModules ∷ Int
maxModules = 256

-- | At most this many bytes of source in one module.
maxSourceBytes ∷ Int
maxSourceBytes = 1048576

-- | At most this many entry points declared by one module.
maxEntries ∷ Int
maxEntries = 64

-- | A module's name or version is at most this many bytes of UTF-8.
maxIdentityLength ∷ Int
maxIdentityLength = 128

loadOperation, callOperation ∷ Operation
loadOperation = operation "load-module"
callOperation = operation "call-entry"

-- | The fault for this module, from nothing known yet.
faultOf ∷ Host → FaultOperation → ModuleRef → Maybe Text → FaultReason → BoundaryFault
faultOf host op ref entry reason =
  (blankFault (hostBoundary host) op reason)
    { boundaryModule = Just ref
    , boundaryEntry = entry
    , boundaryChunk = chunkOf ref
    }

chunkOf ∷ ModuleRef → Text
chunkOf = moduleChunk

-- | The effect a fault has if it happens now, while Lua is running.
effectNow ∷ Vm → IO Effect
effectNow vm = do
  runs ← operationActionRuns vm
  pure (if runs > 0 then BindingRan else LuaRan)

-- | How many modules the registry holds.
liveModuleReferences ∷ Host → IO Int
liveModuleReferences host =
  withOpenVm (hostVm host) (operation "count-modules") $ \state → do
    entry ← lua_gettop state
    counted ← moduleReferences state
    lua_settop state entry
    case counted of
      Right count → pure count
      Left status →
        throwFailure luaComponent (operation "count-modules") [] $
          (blankFault (hostBoundary host) LoadModule (ScriptFailed (classify status) ErrorAbsent))

-- | The handle of a module this owner has loaded, by identity: how the body gets
-- at a module the owner loaded at initialization. Owner-checked like any other
-- operation on the VM.
loadedModule ∷ HasCallStack ⇒ Host → ModuleRef → IO (Maybe ModuleHandle)
loadedModule host ref =
  withOpenVm (hostVm host) (operation "lookup-module") $ \_ →
    Map.lookup ref <$> readIORef (hostLoaded host)

-- | Load a module in an environment of its own. See the module header.
--
-- Refused before anything runs: an identity or source that does not fit the
-- bounds, an entry point that is not declared correctly, a second load under an
-- identity the owner already holds. Then the source is loaded and run, and a
-- required entry point it does not define as a function fails the load.
loadModule ∷ HasCallStack ⇒ Host → ModuleSource → IO ModuleHandle
loadModule host source =
  withOperationContext luaComponent loadOperation [("module", moduleRefName ref), ("version", moduleRefVersion ref)] $
    withOpenVm vm loadOperation $ \state → do
      entry ← lua_gettop state
      loaded ← readIORef (hostLoaded host)
      let refuse ∷ ∀ b. ModuleProblem → IO b
          refuse problem = throwFailure luaComponent loadOperation [] (faultOf host LoadModule ref Nothing (ModuleRefused problem))
      validate refuse loaded
      ensureValues vm state
      setRunContext vm (moduleRefName ref, moduleRefVersion ref, Nothing)
      slot ← nextModuleSlot vm
      result ← loadModuleSource state (sourceText source) (chunkOf ref) required slot
      let finishFailed ∷ ∀ b. FaultReason → Effect → Maybe Text → IO b
          finishFailed reason effect trace = do
            -- Whatever failed it, a module that was already stored is not kept:
            -- the load failed, and nothing else could reach it.
            when (loadedStored result) (void (releaseModule state slot))
            lua_settop state entry
            -- A Haskell failure that reached a callback outranks whatever Lua
            -- reported, as everywhere else.
            raiseEscape vm
            throwFailure luaComponent loadOperation [] $
              (faultOf host LoadModule ref Nothing reason) {boundaryEffect = effect, boundaryTraceback = trace}
      -- Until the chunk starts nothing executes -- the collector, whose finalizers are
      -- script-defined Lua, is held -- so a load that failed before then says so.
      let loadEffect
            | loadedStarted result = effectNow vm
            | otherwise = do
                runs ← operationActionRuns vm
                pure (if runs > 0 then BindingRan else NoEffect)
      if loadedStatus result /= LUA_OK
        then do
          value ← renderFailure state entry
          effect ← loadEffect
          finishFailed (ScriptFailed (classify (loadedStatus result)) value) effect (loadedTrace result)
        else
          if loadedChunkStatus result /= LUA_OK
            then do
              value ← renderFailure state entry
              -- Rejected by the parser: nothing of the module ran.
              finishFailed (ScriptFailed (classify (loadedChunkStatus result)) value) NoEffect Nothing
            else
              if loadedMissing result /= 0
                then do
                  effect ← effectNow vm
                  let missing = required !! (loadedMissing result - 1)
                  lua_settop state entry
                  raiseEscape vm
                  throwFailure luaComponent loadOperation [] $
                    (faultOf host LoadModule ref (Just missing) (EntryMissing (loadedMissingPresent result)))
                      {boundaryEffect = effect}
                else do
                  lua_settop state entry
                  -- A callback the module's chunk called may have failed with
                  -- Lua catching the marker; the load fails then, and the slot
                  -- it just filled is emptied.
                  raiseEscape vm `onException` releaseModule state slot
                  let handle = ModuleHandle (vmIdentity vm) slot ref (sourceEntries source)
                  modifyIORef' (hostLoaded host) (Map.insert ref handle)
                  pure handle
  where
    vm = hostVm host
    ref = sourceIdentity source
    required = [entryName entryPoint | entryPoint ← sourceEntries source, entryRequirement entryPoint == Required]
    validate ∷ (ModuleProblem → IO ()) → Map ModuleRef ModuleHandle → IO ()
    validate refuse loaded = do
      unless (validIdentity (moduleRefName ref) && validIdentity (moduleRefVersion ref)) (refuse InvalidModuleIdentity)
      when (ref `Map.member` loaded) (refuse DuplicateModule)
      when (Map.size loaded >= maxModules) (refuse (TooManyModules maxModules))
      when (ByteString.length (sourceText source) > maxSourceBytes) (refuse (SourceTooLarge maxSourceBytes))
      when (length (sourceEntries source) > maxEntries) (refuse (TooManyEntries maxEntries))
      let names = map entryName (sourceEntries source)
      forM_ names $ \name → when (validName name /= Nothing) (refuse (InvalidEntryName name))
      forM_ (nub names) $ \name → when (length (filter (== name) names) > 1) (refuse (DuplicateEntry name))
      forM_ (sourceEntries source) $ \entryPoint → do
        let schemas = entryArguments entryPoint <> entryResults entryPoint
        when (length (entryArguments entryPoint) > maxArity) (refuse (EntryArityTooLarge (entryName entryPoint) (length (entryArguments entryPoint))))
        when (length (entryResults entryPoint) > maxArity) (refuse (EntryArityTooLarge (entryName entryPoint) (length (entryResults entryPoint))))
        forM_ schemas $ \schema →
          forM_ (schemaProblem (boundaryRegistration (hostBoundary host)) schema) $ \_ →
            refuse (EntrySchemaRefused (entryName entryPoint))
    validIdentity text =
      not (Text.null text)
        && ByteString.length (Text.encodeUtf8 text) <= maxIdentityLength
        && Text.all (\character → character >= ' ' && character /= '\DEL') text

-- | An entry point looked up, with its arguments checked and built.
data Prepared
  = -- | The entry point is optional and the module does not define it. Nothing
    -- ran.
    PreparedAbsent
  | -- | The function and its arguments are on the stack, in that order. The
    -- declaration, and how many arguments.
    PreparedReady !EntryPoint !Int

-- | Everything a call of an entry point does before it runs: the handle, the
-- declaration, the lookup by raw access, the arguments checked against the
-- schemas and the limits, and built on the stack.
--
-- Shared by the call that runs the entry point once and the one that starts it
-- as a task, which differ only in what they do with the function afterwards.
-- Refused before anything runs, with no effect, as 'callEntry' documents.
prepareEntry
  ∷ HasCallStack
  ⇒ Host → FaultOperation → Operation → ModuleHandle → Text → [Value] → State → StackIndex → IO Prepared
prepareEntry = prepareEntryWith NoLead

-- | The function an entry point is run through, when it is not run directly.
--
-- A lead is another module's entry point, a driver, that is the function the
-- coroutine or the call runs, and is handed the entry point looked up as its first
-- argument, before the values. What is checked, built and declared of the
-- arguments and the results is the driver's: the entry point is only looked up,
-- and has to be declared by its own module. This is how an owner keeps state in
-- its VM that a script reads but that is not a value: the driver holds it, and
-- the entry point is called on it.
data Lead
  = NoLead
  | -- | The driver's module and its entry point.
    Lead !ModuleHandle !Text

-- | 'prepareEntry' with an optional lead. With a lead the stack holds the
-- driver's function, then the entry point, then the arguments; the count is of
-- everything after the driver's function.
prepareEntryWith
  ∷ HasCallStack
  ⇒ Lead → Host → FaultOperation → Operation → ModuleHandle → Text → [Value] → State → StackIndex → IO Prepared
prepareEntryWith lead host op operationName handle name arguments state entry = do
  when (handleVm handle /= vmIdentity vm) (fault (ModuleRefused ModuleHandleForeign) NoEffect Nothing)
  hookDeclared ← case [entryPoint | entryPoint ← handleEntries handle, entryName entryPoint == name] of
    entryPoint : _ → pure entryPoint
    [] → fault (ModuleRefused (EntryUndeclared name)) NoEffect Nothing
  declared ← case lead of
    NoLead → pure hookDeclared
    Lead driver driverName → do
      when (handleVm driver /= vmIdentity vm) (fault (ModuleRefused ModuleHandleForeign) NoEffect Nothing)
      case [entryPoint | entryPoint ← handleEntries driver, entryName entryPoint == driverName] of
        entryPoint : _ → pure entryPoint
        [] → fault (ModuleRefused (EntryUndeclared driverName)) NoEffect Nothing
  setRunContext vm (moduleRefName ref, moduleRefVersion ref, Just name)
  case lead of
    NoLead → pure ()
    Lead driver driverName → do
      driving ← lookupEntry state (handleSlot driver) driverName
      case driving of
        LookupFunctionOnStack → pure ()
        LookupStatus status → do
          value ← renderFailure state entry
          lua_settop state entry
          raiseEscape vm
          fault (ScriptFailed (classify status) value) NoEffect Nothing
        _ → do
          lua_settop state entry
          fault (InternalError "the driver's entry point is not a function of its module") NoEffect Nothing
  found ← lookupEntry state (handleSlot handle) name
  case found of
    LookupStatus status → do
      value ← renderFailure state entry
      lua_settop state entry
      raiseEscape vm
      fault (ScriptFailed (classify status) value) NoEffect Nothing
    LookupNoModule → do
      lua_settop state entry
      fault (InternalError "the module's slot is empty") NoEffect Nothing
    LookupAbsent → do
      lua_settop state entry
      raiseEscape vm
      case entryRequirement hookDeclared of
        Optional → pure PreparedAbsent
        Required → fault (EntryMissing False) NoEffect Nothing
    LookupNotFunction → do
      lua_settop state entry
      fault EntryNotAFunction NoEffect Nothing
    LookupFunctionOnStack → do
      let schemas = entryArguments declared
          -- At most one past the declared count is ever counted, so an oversized
          -- or endless argument list costs no more to refuse than a small one.
          given = length (take (length schemas + 1) arguments)
      either (refuseArgument 0 []) pure (checkLimits limits arguments)
      when (given /= length schemas) $
        refuseArgument 0 [] (RuleArity (length schemas) given)
      forM_ (zip3 [1 ..] schemas arguments) $ \(index, schema, value) →
        case conformValue context schema value of
          Left (path, rule) → refuseArgument index path rule
          Right () → pure ()
      forM_ (zip [1 ..] arguments) $ \(index, value) → do
        -- The application's own check is application code: it runs as a callback,
        -- so a call it makes on this VM is refused and not waited for.
        retired ← runCallback vm (retiredIn boundary value)
        forM_ retired $ \(path, typeName) → refuseArgument index path (RuleRetiredHandle typeName)
      encoded ← case encodeValues context limits arguments of
        Left rule → refuseArgument 0 [] rule
        Right bytes → pure bytes
      pushed ← pushValues state limits encoded (length arguments)
      case pushed of
        Pushed → pure ()
        PushStatus status → do
          value ← renderFailure state entry
          lua_settop state entry
          fault (ScriptFailed (classify status) value) NoEffect Nothing
        PushMalformed which →
          lua_settop state entry >> fault (InternalError ("an argument could not be built: " <> Text.pack (show which))) NoEffect Nothing
      pure (PreparedReady declared (length arguments + leading))
  where
    leading = case lead of
      NoLead → 0
      Lead {} → 1
    vm = hostVm host
    boundary = hostBoundary host
    context = boundaryContext boundary
    limits = boundaryLimits boundary
    ref = handleModule handle
    fault ∷ ∀ b. FaultReason → Effect → Maybe Text → IO b
    fault reason effect trace =
      throwFailure luaComponent operationName [] $
        (faultOf host op ref (Just name) reason) {boundaryEffect = effect, boundaryTraceback = trace}
    refuseArgument ∷ ∀ b. Int → [PathStep] → ValueRule → IO b
    refuseArgument index path rule = do
      -- The entry point is on the stack by now; nothing has run.
      lua_settop state entry
      fault (ValueRefused (ValueRefusal Arguments index path rule 0)) NoEffect Nothing

-- | The results an entry point returned, copied off the stack from the slot after
-- @entry@ and checked against the declared schemas. The refusal, if there is
-- one, with the traceback to report it under.
--
-- The count has been checked against the schemas' by the caller.
readResults ∷ Host → State → StackIndex → [Schema] → Int → IO (Either (FaultReason, Maybe Text) [Value])
readResults host state entry expected count = do
  copied ← readValues state limits (vmIdentity (hostVm host)) (fromIntegral (fromStackIndex entry) + 1) count
  case copied of
    ReadStatus status → do
      value ← renderFailure state entry
      pure (Left (ScriptFailed (classify status) value, Nothing))
    ReadRefused rule index visited →
      pure (Left (ValueRefused (ValueRefusal Results index [] rule visited), Nothing))
    ReadCopied bytes visited → case decodeValues count bytes of
      Left why → pure (Left (InternalError why, Nothing))
      Right raws → do
        let conformed = traverse (\(schema, raw) → conformRaw context schema raw) (zip expected raws)
        pure $ case conformed of
          Left (path, rule) → Left (ValueRefused (ValueRefusal Results (locate raws) path rule visited), Nothing)
          Right values → Right values
  where
    boundary = hostBoundary host
    context = boundaryContext boundary
    limits = boundaryLimits boundary
    -- The 1-based position of the first result that does not conform.
    locate raws =
      case [index | (index, schema, raw) ← zip3 [1 ..] expected raws, Left _ ← [conformRaw context schema raw]] of
        index : _ → index
        [] → 0

-- | Call a module's entry point with bounded values.
--
-- Refused before anything runs, with no effect: a handle another owner issued,
-- an entry point the module was not declared to have, arguments that do not fit
-- the schemas or the limits, a capability the application's own check retires,
-- a required entry point that is gone, an entry point that is present and not a
-- function. An optional entry point that is absent answers 'EntryAbsent'.
callEntry ∷ HasCallStack ⇒ Host → ModuleHandle → Text → [Value] → IO CallResult
callEntry = callEntryWith NoLead

-- | Call an entry point through a driver's entry point: see 'Lead'. Nothing in the
-- call can suspend: a scheduler operation it reaches is refused as it is for any
-- call.
callEntryVia ∷ HasCallStack ⇒ Host → ModuleHandle → Text → ModuleHandle → Text → [Value] → IO CallResult
callEntryVia host driver driverName = callEntryWith (Lead driver driverName) host

-- | Whether a module defines an entry point as a function, looked up by raw access
-- as a call looks it up. Runs nothing of the module.
entryDefined ∷ HasCallStack ⇒ Host → ModuleHandle → Text → IO Bool
entryDefined host handle name =
  withOpenVm vm (operation "lookup-entry") $ \state → do
    entry ← lua_gettop state
    when (handleVm handle /= vmIdentity vm) $
      throwFailure luaComponent (operation "lookup-entry") [] $
        (faultOf host CallEntry (handleModule handle) (Just name) (ModuleRefused ModuleHandleForeign)) {boundaryEffect = NoEffect}
    found ← lookupEntry state (handleSlot handle) name
    lua_settop state entry
    pure $ case found of
      LookupFunctionOnStack → True
      _ → False
  where
    vm = hostVm host

callEntryWith ∷ HasCallStack ⇒ Lead → Host → ModuleHandle → Text → [Value] → IO CallResult
callEntryWith lead host handle name arguments =
  withOperationContext luaComponent callOperation [("module", moduleRefName ref), ("entry", name)] $
    withOpenVm vm callOperation $ \state → do
      entry ← lua_gettop state
      let fault ∷ ∀ b. FaultReason → Effect → Maybe Text → IO b
          fault reason effect trace =
            throwFailure luaComponent callOperation [] $
              (faultOf host CallEntry ref (Just name) reason) {boundaryEffect = effect, boundaryTraceback = trace}
          -- Lua has run by now: a callback's failure outranks what is reported.
          afterLua ∷ ∀ b. FaultReason → Maybe Text → IO b
          afterLua reason trace = do
            effect ← effectNow vm
            lua_settop state entry
            raiseEscape vm
            fault reason effect trace
      prepared ← prepareEntryWith lead host CallEntry callOperation handle name arguments state entry
      case prepared of
        PreparedAbsent → pure EntryAbsent
        PreparedReady declared count → do
          -- The entry point may run script code, so what building its arguments
          -- allocated while the collector was held is paid now.
          serviceCollector state
          (called, trace) ← callProtected state count (-1)
          if called /= LUA_OK
            then do
              value ← renderFailure state entry
              afterLua (ScriptFailed (classify called) value) trace
            else do
              top ← fromIntegral . fromStackIndex <$> lua_gettop state
              let results = top - fromIntegral (fromStackIndex entry)
                  expected = entryResults declared
              when (results /= length expected) $
                afterLua (ValueRefused (ValueRefusal Results 0 [] (RuleArity (length expected) results) 0)) Nothing
              read' ← readResults host state entry expected results
              case read' of
                Left (reason, traced) → afterLua reason traced
                Right values → do
                  lua_settop state entry
                  -- A callback the entry point reached may have failed
                  -- with Lua catching the marker, and the call still
                  -- returned: the failure is the caller's.
                  raiseEscape vm
                  pure (Returned values)
  where
    vm = hostVm host
    ref = handleModule handle
