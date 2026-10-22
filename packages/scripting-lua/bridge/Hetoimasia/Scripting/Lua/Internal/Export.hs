-- | Export modules: Lua values an owner keeps in its VM, and the behaviors an
-- instance captures from them.
--
-- This is an opt-in facility beside the global-entry modules of
-- "Hetoimasia.Scripting.Lua.Internal.Module", which it replaces nothing of. A
-- module here is source text the application supplies under a stable identity.
-- Its chunk runs once, in an environment of its own that reads through to the
-- owner's (filtered) globals, and must return exactly one plain table: the
-- /export table/. The bridge keeps that very table, with the functions, tables and
-- cycles reachable from it, in a table of the registry that only it reaches, for
-- the VM's life. Nothing is serialized, copied or constrained to the value
-- boundary's schemas: the exports are trusted same-VM Lua values, and mutable
-- exports, closures, upvalues and shared library tables keep the semantics Lua
-- gives them. This is not hostile-code isolation and not a rollback.
--
-- = Identity and sticky failure
--
-- An identity is associated with its table, or with the failure that evaluating
-- it came to: a script error, a return that was not exactly one plain table, or
-- source past the limit. Asking again answers the same table, or the same
-- failure, and runs nothing. A failed identity is never retried with other
-- bytes, and what its chunk already did is not undone. Another VM has its own
-- environment, table, failure and state.
--
-- Records are bounded and never evicted: at most 'exportMaxIdentities' of them,
-- failed and in-progress ones included. A new identity while the owner holds that
-- many is refused before anything is evaluated and makes no record. Source past
-- 'exportMaxSourceBytes' is never compiled: while room remains it is a failed
-- record that counts, distinguishable from an evaluation failure. The source is
-- not kept; only the identity, the outcome and the table are.
--
-- = Behaviors
--
-- 'captureBehavior' validates one field of an export table as a behavior and
-- captures it for an instance: the very hook functions, a fresh @self@ table that
-- starts with the facade as @self.api@, and the facade. The field is read by raw
-- access and the behavior table by a raw traversal of at most six entries, so no
-- metamethod, indexing function or conversion runs and nothing walks a library
-- export. Later changes to the behavior table or the export table do not reach a
-- capture.
--
-- = Evaluation versus hook context
--
-- The facility grants no engine resource authority to a module's top level merely
-- because a caller has an instance facade: a facade is injected into a capture and
-- reaches only the hooks, as their second argument and @self.api@, and a module's
-- top level has no way to see one. It starts no service and owns no instance. The
-- later import and phase checks (LFE-9, LFE-12) need to tell the two apart, and the
-- VM's run context does: while an export module's top level runs, its entry is
-- absent (@Nothing@, as for any module being loaded); while a captured hook runs it
-- names the hook's entry. That is the explicit boundary they build on.
--
-- = Lifetime
--
-- Export tables last as long as the VM. A capture lasts until it is released or
-- the VM closes; its hooks, @self@ and facade are Lua values, so a coroutine that
-- is running or suspended on them keeps them whether or not the capture has been
-- released. Slots are issued once and never reused, so a stale handle names an
-- empty slot and is refused, never another capture's. Every operation runs on the
-- VM's owner through the protected foreign-call boundary.
module Hetoimasia.Scripting.Lua.Internal.Export
  ( -- * Export modules
    evaluateExport
  , retrieveExport
  , exportRecordCount
  , liveExportReferences
    -- * Behaviors
  , captureBehavior
  , releaseBehavior
  , liveCaptureReferences
  , liveCaptureSlots
  ) where

import Control.Exception (onException)
import Control.Monad (unless, void, when)
import qualified Data.ByteString as ByteString
import Data.IORef (modifyIORef', readIORef)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import GHC.Float (castWord64ToDouble)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Scripting.Lua.Internal.Binding (ensureValues, retiredIn)
import Hetoimasia.Scripting.Lua.Internal.Boundary
import Hetoimasia.Scripting.Lua.Internal.ExportTypes
import Hetoimasia.Scripting.Lua.Internal.Fault (ErrorValue (ErrorAbsent), classify, luaComponent, renderFailure)
import Hetoimasia.Scripting.Lua.Internal.Marshal
import Hetoimasia.Scripting.Lua.Internal.Module (Host (..), effectNow)
import Hetoimasia.Scripting.Lua.Internal.Value
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( nextModuleSlot
  , operationActionRuns
  , raiseEscape
  , runCallback
  , setRunContext
  , vmIdentity
  , withOpenVm
  )
import Lua (StatusCode, fromTypeCode, lua_gettop, lua_settop, lua_type, data LUA_OK, data LUA_TTABLE)

evaluateOperation, captureOperation, releaseOperation, lookupOperation ∷ Operation
evaluateOperation = operation "evaluate-export"
captureOperation = operation "capture-behavior"
releaseOperation = operation "release-behavior"
lookupOperation = operation "retrieve-export"

-- | A label as a reader sees it: control characters tamed and at most 128 bytes
-- of UTF-8, so a diagnostic stays bounded whatever identity was supplied. It
-- keys nothing.
labelOf ∷ Text → Text
labelOf label = Text.pack (go 0 (Text.unpack tamed))
  where
    tamed = Text.map (\character → if character < ' ' || character == '\DEL' then '.' else character) label
    go _ [] = []
    go used (character : rest)
      | used + width > 128 = []
      | otherwise = character : go (used + width) rest
      where
        width = ByteString.length (Text.encodeUtf8 (Text.singleton character))

-- | The fault for an export module, from nothing known yet.
faultFor ∷ Host → FaultOperation → Text → FaultReason → BoundaryFault
faultFor host op label reason =
  (blankFault (hostBoundary host) op reason)
    { boundaryModule = Just (sourceOf label)
    , boundaryChunk = moduleChunk (sourceOf label)
    }

-- | How an export module is named wherever its code is running or failing: its
-- bounded label and the version @export@. The chunk its source is loaded under is
-- the name that gives, as every module's is, so that the attribution of a script's
-- own error and of a binding's refusal agree.
sourceOf ∷ Text → ModuleRef
sourceOf label = ModuleRef (labelOf label) "export"

-- | Evaluate an export module, or answer what an identity already came to.
--
-- Refused before anything runs, with 'NoEffect', and with no record made: an
-- identity that is empty or past 'maxExportIdentityBytes', and a new identity
-- while the owner holds as many as its limit. An identity the owner already
-- holds answers its table or its failure without evaluating anything.
-- Everything else is an outcome: the table ('ExportReady'), or the sticky
-- failure ('ExportFailed') of a script error, a rejected chunk, a precompiled
-- chunk, a return that was not exactly one plain table, or oversized source. A
-- Haskell failure that reached a callback while the chunk ran is raised instead
-- and the identity is recorded as failed.
--
-- The owner's thread only.
evaluateExport ∷ HasCallStack ⇒ Host → ExportSource → IO ExportOutcome
evaluateExport host source =
  withOperationContext luaComponent evaluateOperation [("module", label)] $
    withOpenVm vm evaluateOperation $ \state → do
      entry ← lua_gettop state
      let refuse ∷ ∀ b. ModuleProblem → IO b
          refuse problem = throwFailure luaComponent evaluateOperation [] (faultFor host EvaluateExport label (ModuleRefused problem))
      when (ByteString.null raw || ByteString.length raw > maxExportIdentityBytes) $
        refuse (InvalidExportIdentity maxExportIdentityBytes)
      records ← readIORef (exportRecords held)
      case Map.lookup identity records of
        Just (ExportHeld slot source') → pure (ExportReady (ExportHandle (vmIdentity vm) slot (storedKey records) source'))
        Just (ExportBroken fault) → pure (ExportFailed fault)
        -- Nothing leaves a record behind in this state: an evaluation that
        -- cannot finish records its failure first.
        Just ExportEvaluating → pure (ExportFailed (broken "the evaluation did not finish"))
        Nothing → do
          when (Map.size records >= exportMaxIdentities limits) $
            refuse (TooManyExports (exportMaxIdentities limits))
          if ByteString.length (exportText source) > exportMaxSourceBytes limits
            then do
              -- Never compiled or run; the identity is charged and stays failed.
              let fault = faultFor host EvaluateExport label (ModuleRefused (SourceTooLarge (exportMaxSourceBytes limits)))
              modifyIORef' (exportRecords held) (Map.insert kept (ExportBroken fault))
              pure (ExportFailed fault)
            else evaluate state entry
  where
    vm = hostVm host
    held = hostExports host
    limits = exportLimits held
    identity = exportIdentity source
    ExportIdentity raw = identity
    -- What the records and handles retain is a copy that owns its bytes: a small slice
    -- of a large buffer would otherwise keep the whole buffer alive until the VM
    -- closes, and the identity bound would bound nothing.
    kept = ExportIdentity (ByteString.copy raw)
    storedKey records = maybe kept (fst . (`Map.elemAt` records)) (Map.lookupIndex identity records)
    label = exportLabel source
    broken why = faultFor host EvaluateExport label (InternalError why)
    evaluate state entry = do
      -- Anything that can fail before the chunk is made happens first, so that a
      -- failure there charges no identity.
      ensureValues vm state
      modifyIORef' (exportRecords held) (Map.insert kept ExportEvaluating)
      let abandon = modifyIORef' (exportRecords held) (Map.insert kept (ExportBroken (broken "the evaluation was abandoned")))
      -- A failure before the chunk could start (memory running out as the
      -- environment is made) executed nothing: it is raised, and the identity is
      -- not charged, so it can be asked for again.
      attempted ← (`onException` abandon) $ do
        setRunContext vm (moduleRefName (sourceOf label), "export", Nothing)
        slot ← nextModuleSlot vm
        evaluated ← evaluateExportSource state (exportText source) (moduleChunk (sourceOf label)) slot
        let started = evaluatedStarted evaluated
            failed ∷ FaultReason → Effect → Maybe Text → IO BoundaryFault
            failed reason effect trace = do
              -- Whatever failed it, a table that was already stored is not kept.
              when (evaluatedStored evaluated) (void (releaseExport state slot))
              lua_settop state entry
              -- A Haskell failure that reached a callback outranks whatever Lua
              -- reported, as everywhere else: raised, and the identity abandoned.
              raiseEscape vm
              let fault = (faultFor host EvaluateExport label reason) {boundaryEffect = effect, boundaryTraceback = trace}
              modifyIORef' (exportRecords held) (Map.insert kept (ExportBroken fault))
              pure fault
            -- Until the chunk starts nothing executes, so a failure before then
            -- says so.
            effectBefore
              | started = effectNow vm
              | otherwise = do
                  runs ← operationActionRuns vm
                  pure (if runs > 0 then BindingRan else NoEffect)
        if evaluatedStatus evaluated /= LUA_OK && not started
          then do
            value ← renderFailure state entry
            lua_settop state entry
            raiseEscape vm
            modifyIORef' (exportRecords held) (Map.delete identity)
            pure . Left $ (faultFor host EvaluateExport label (ScriptFailed (classify (evaluatedStatus evaluated)) value)) {boundaryEffect = NoEffect}
          else
            if evaluatedStatus evaluated /= LUA_OK
              then do
                value ← renderFailure state entry
                effect ← effectBefore
                Right . ExportFailed <$> failed (ScriptFailed (classify (evaluatedStatus evaluated)) value) effect (evaluatedTrace evaluated)
              else
              if evaluatedChunkStatus evaluated /= LUA_OK
                then do
                  value ← renderFailure state entry
                  -- Rejected by the parser, or a precompiled chunk refused: nothing ran.
                  Right . ExportFailed <$> failed (ScriptFailed (classify (evaluatedChunkStatus evaluated)) value) NoEffect Nothing
                else case shapeOf evaluated of
                  Just shape → do
                    effect ← effectNow vm
                    Right . ExportFailed <$> failed (ExportShapeRefused shape) effect Nothing
                  Nothing → do
                    lua_settop state entry
                    -- A callback the chunk reached may have failed with Lua catching
                    -- the marker, and the chunk still returned its table: the
                    -- failure is the caller's, and the table is not kept.
                    raiseEscape vm `onException` void (releaseExport state slot)
                    modifyIORef' (exportRecords held) (Map.insert kept (ExportHeld slot (sourceOf label)))
                    pure (Right (ExportReady (ExportHandle (vmIdentity vm) slot kept (sourceOf label))))
      either (throwFailure luaComponent evaluateOperation []) pure attempted
    shapeOf evaluated = case evaluatedShape evaluated of
      0 → Nothing
      1 → Just ExportNoResult
      2 → Just ExportNil
      3 → Just (ExportNotTable (luaTypeName (evaluatedResultType evaluated)))
      4 → Just ExportMultiple
      _ → Just ExportMetatable

-- | What an identity came to, without evaluating anything: 'Nothing' for an
-- identity the owner holds no record of. The owner's thread only.
retrieveExport ∷ HasCallStack ⇒ Host → ExportIdentity → IO (Maybe ExportOutcome)
retrieveExport host identity =
  withOpenVm (hostVm host) lookupOperation $ \_ → do
    records ← readIORef (exportRecords (hostExports host))
    pure $ case Map.lookup identity records of
      Nothing → Nothing
      Just (ExportHeld slot source') → Just (ExportReady (ExportHandle (vmIdentity (hostVm host)) slot (maybe identity (fst . (`Map.elemAt` records)) (Map.lookupIndex identity records)) source'))
      Just (ExportBroken fault) → Just (ExportFailed fault)
      Just ExportEvaluating → Nothing

-- | How many identities the owner holds a record of: held tables, failed
-- identities and any in progress. What the identity limit counts.
exportRecordCount ∷ HasCallStack ⇒ Host → IO Int
exportRecordCount host =
  withOpenVm (hostVm host) lookupOperation $ \_ →
    Map.size <$> readIORef (exportRecords (hostExports host))

-- | How many export tables the VM's registry holds: the references the bridge
-- retains for them, one for each.
liveExportReferences ∷ HasCallStack ⇒ Host → IO Int
liveExportReferences host =
  withOpenVm (hostVm host) (operation "count-exports") $ \state → do
    entry ← lua_gettop state
    counted ← exportReferences state
    lua_settop state entry
    either (countFailure host "count-exports") pure counted

-- | How many captured behaviors the VM's registry holds.
liveCaptureReferences ∷ HasCallStack ⇒ Host → IO Int
liveCaptureReferences host =
  withOpenVm (hostVm host) (operation "count-captures") $ \state → do
    entry ← lua_gettop state
    counted ← captureReferences state
    lua_settop state entry
    either (countFailure host "count-captures") pure counted

-- | The capture slots the owner believes live: what its own record holds, to be
-- compared with 'liveCaptureReferences'.
liveCaptureSlots ∷ HasCallStack ⇒ Host → IO [Int]
liveCaptureSlots host =
  withOpenVm (hostVm host) lookupOperation $ \_ →
    Set.toList <$> readIORef (exportCaptures (hostExports host))

countFailure ∷ Host → Text → StatusCode → IO a
countFailure host name status =
  throwFailure luaComponent (operation name) [] $
    blankFault (hostBoundary host) EvaluateExport (ScriptFailed (classify status) ErrorAbsent)

-- | Validate the field @select@ of the export table a handle names as a behavior,
-- and capture it with a facade.
--
-- Refused before anything runs, with 'NoEffect': a handle another owner issued,
-- one the owner holds no table for (the facade source's included), a facade value
-- past the value limits or holding a capability the application's own check
-- retires, and a selector that is empty or past 128 bytes. A behavior that does
-- not fit the schema is not a fault: it is answered as a 'BehaviorProblem' and
-- nothing is held, and a facade builder is never run for it. An allocation that
-- fails on the way is a fault, with nothing held either.
--
-- On success the capture is held until 'releaseBehavior' or the VM closes, and
-- the answer says which hooks it has and how its cadence fields read. The facade
-- is made last, after the behavior has validated and been captured: a copy of a
-- value, an existing table of a retained export, or what a builder function of one
-- returns ('FacadeSource'). If it cannot be made (a builder that raises, or
-- returns no table) the capture is released and the failure raised.
captureBehavior ∷ HasCallStack ⇒ Host → ExportHandle → Text → FacadeSource → IO (Either BehaviorProblem Captured)
captureBehavior host export select facade =
  withOperationContext luaComponent captureOperation [("behavior", select)] $
    withOpenVm vm captureOperation $ \state → do
      entry ← lua_gettop state
      let fault ∷ ∀ b. FaultReason → Effect → IO b
          fault reason effect =
            throwFailure luaComponent captureOperation [] $
              (blankFault boundary CaptureBehavior reason) {boundaryEffect = effect, boundaryChunk = labelOf select}
          refuse ∷ ∀ b. ModuleProblem → IO b
          refuse problem = fault (ModuleRefused problem) NoEffect
          refuseValue ∷ ∀ b. ValueRule → IO b
          refuseValue rule = fault (ValueRefused (ValueRefusal Arguments 1 [] rule 0)) NoEffect
          -- A handle must be this owner's and name a table it holds.
          held ∷ ExportHandle → IO ()
          held handle = do
            when (exportHandleVm handle /= vmIdentity vm) (refuse ExportHandleForeign)
            records ← readIORef (exportRecords (hostExports host))
            case Map.lookup (exportHandleIdentity handle) records of
              Just (ExportHeld slot _) | slot == exportHandleSlot handle → pure ()
              _ → refuse ExportHandleStale
          -- A value is within the limits and holds no retired capability, and is encoded
          -- before anything is made, so that a refusal costs nothing.
          encodedValue ∷ Value → IO ByteString.ByteString
          encodedValue value = do
            either refuseValue pure (checkLimits limits [value])
            retired ← runCallback vm (retiredIn boundary value)
            case retired of
              Just (path, typeName) → fault (ValueRefused (ValueRefusal Arguments 1 path (RuleRetiredHandle typeName) 0)) NoEffect
              Nothing → pure ()
            either refuseValue pure (encodeValues (boundaryContext boundary) limits [value])
          pushEncoded ∷ ByteString.ByteString → IO ()
          pushEncoded encoded = do
            pushed ← pushValues state limits encoded 1
            case pushed of
              Pushed → pure ()
              PushStatus status → do
                value ← renderFailure state entry
                lua_settop state entry
                fault (ScriptFailed (classify status) value) NoEffect
              PushMalformed which → do
                lua_settop state entry
                fault (InternalError ("the facade could not be built: " <> Text.pack (show which))) NoEffect
          -- A field of a retained export table, pushed, of the Lua type wanted.
          pushField ∷ ExportHandle → Text → Int → (Text → ModuleProblem) → IO ()
          pushField handle key wanted wrong = do
            (status, found) ← pushExportField state (exportHandleSlot handle) (Text.encodeUtf8 key)
            when (status /= LUA_OK) $ do
              value ← renderFailure state entry
              lua_settop state entry
              fault (ScriptFailed (classify status) value) NoEffect
            when (found /= wanted) $ do
              lua_settop state entry
              refuse (if found == 0 then FacadeFieldMissing key else wrong (luaTypeName found))
      when (exportHandleVm export /= vmIdentity vm) (refuse ExportHandleForeign)
      held export
      when (ByteString.null selector || ByteString.length selector > 128) $
        refuse (InvalidEntryName select)
      -- What a facade needs checked, and encoded, is settled before the behavior is. A copied
      -- facade is the table the capture promises: a record or a list, never nil or a scalar.
      let tableOnly value = case value of
            VRecord _ → pure ()
            VList _ → pure ()
            VNil → refuse (FacadeNotATable "nil")
            VBoolean _ → refuse (FacadeNotATable "boolean")
            VInteger _ → refuse (FacadeNotATable "number")
            VFloat _ → refuse (FacadeNotATable "number")
            VBytes _ → refuse (FacadeNotATable "string")
            VText _ → refuse (FacadeNotATable "string")
            VCapability _ → refuse (FacadeNotATable "userdata")
      prepared ← case facade of
        FacadeValue value → tableOnly value >> (Just <$> encodedValue value)
        FacadeField handle _ → Nothing <$ held handle
        FacadeBuilt handle _ context → held handle >> Just <$> encodedValue context
      ensureValues vm state
      setRunContext vm (labelOf select, "behavior", Nothing)
      slot ← nextModuleSlot vm
      (status, report) ← captureBehaviorFields state (exportHandleSlot export) selector slot
      if status /= LUA_OK
        then do
          value ← renderFailure state entry
          lua_settop state entry
          raiseEscape vm
          -- Nothing was published: the one store is the last step of the call.
          fault (ScriptFailed (classify status) value) NoEffect
        else
          if not (reportStored report)
            then do
              lua_settop state entry
              pure (Left (problemOfReport report))
            else do
              -- Stored, tracked and then given its facade; whatever fails from here lets
              -- go of what was stored, so no failure leaves a capture nobody holds.
              let undo = void (releaseCapture state slot) >> modifyIORef' (exportCaptures (hostExports host)) (Set.delete slot)
              (`onException` undo) $ do
                raiseEscape vm
                modifyIORef' (exportCaptures (hostExports host)) (Set.insert slot)
                case (facade, prepared) of
                  (FacadeValue _, Just encoded) → pushEncoded encoded
                  (FacadeField handle key, _) → pushField handle key 5 FacadeNotATable
                  (FacadeBuilt handle key _, Just encoded) → do
                    pushField handle key 6 FacadeBuilderNotAFunction
                    pushEncoded encoded
                    -- The builder is the engine's own Lua: what it allocated while the
                    -- collector was held is paid, and it runs under the traceback handler.
                    serviceCollector state
                    (called, trace) ← callProtected state 1 1
                    effect ← effectNow vm
                    -- A host failure a callback recorded while the builder ran outranks anything
                    -- that comes after, even if the builder caught Lua's side of it with
                    -- @pcall@ and returned a table: raised first, whatever follows.
                    when (called == LUA_OK) (raiseEscape vm)
                    when (called /= LUA_OK) $ do
                      value ← renderFailure state entry
                      lua_settop state entry
                      raiseEscape vm
                      throwFailure luaComponent captureOperation [] $
                        (blankFault boundary CaptureBehavior (ScriptFailed (classify called) value))
                          {boundaryEffect = effect, boundaryChunk = labelOf select, boundaryTraceback = trace}
                    kind ← lua_type state (-1)
                    when (kind /= LUA_TTABLE) $ do
                      lua_settop state entry
                      raiseEscape vm
                      fault (ModuleRefused (FacadeNotATable (luaTypeName (fromIntegral (fromTypeCode kind))))) effect
                  _ → fault (InternalError "a facade source was not prepared") NoEffect
                (attached, wasAttached) ← attachFacade state slot
                lua_settop state entry
                -- A builder ran if there was one: what a failure from here says had happened.
                ran ← case facade of
                  FacadeBuilt {} → effectNow vm
                  _ → pure NoEffect
                when (attached /= LUA_OK) $
                  fault (ScriptFailed (classify attached) ErrorAbsent) ran
                unless wasAttached $ fault (InternalError "the capture to attach a facade to is gone") ran
                raiseEscape vm
              pure (Right (Captured (CaptureHandle (vmIdentity vm) slot (exportHandleSource export)) (shapeOfReport report)))
  where
    vm = hostVm host
    boundary = hostBoundary host
    limits = boundaryLimits boundary
    selector = Text.encodeUtf8 select

-- | Let go of a capture: its hooks, @self@ and facade are no longer held by the
-- VM. Idempotent: a capture already released, or released by the VM's close, is
-- left as it is. A handle another owner issued is refused.
releaseBehavior ∷ HasCallStack ⇒ Host → CaptureHandle → IO ()
releaseBehavior host capture =
  withOpenVm vm releaseOperation $ \state → do
    entry ← lua_gettop state
    when (captureHandleVm capture /= vmIdentity vm) $
      throwFailure luaComponent releaseOperation [] $
        (blankFault (hostBoundary host) CaptureBehavior (ModuleRefused CaptureHandleForeign)) {boundaryEffect = NoEffect}
    live ← readIORef (exportCaptures (hostExports host))
    when (captureHandleSlot capture `Set.member` live) $ do
      status ← releaseCapture state (captureHandleSlot capture)
      lua_settop state entry
      if status /= LUA_OK
        then countFailure host "release-behavior" status
        else modifyIORef' (exportCaptures (hostExports host)) (Set.delete (captureHandleSlot capture))
  where
    vm = hostVm host

-- | What a captured behavior read as.
shapeOfReport ∷ BehaviorReport → BehaviorShape
shapeOfReport report =
  BehaviorShape
    { shapeInit = hasInit
    , shapeUpdate = hasUpdate
    , shapeShutdown = hasShutdown
    , shapeEveryTicks = fieldOf (reportTicks report)
    , shapeEverySeconds = fieldOf (reportSeconds report)
    }
  where
    (hasInit, hasUpdate, hasShutdown) = reportHooks report
    fieldOf (kind, integer, bits) = case kind of
      1 → FieldInteger integer
      2 → FieldFloat (castWord64ToDouble (fromIntegral bits))
      3 → FieldOther (luaTypeName (fromIntegral integer))
      _ → FieldAbsent

-- | Why the schema refused a behavior.
problemOfReport ∷ BehaviorReport → BehaviorProblem
problemOfReport report = case reportProblem report of
  1 → BehaviorNoExport
  2 → BehaviorMissing
  3 → BehaviorNotTable (luaTypeName (reportDetail report))
  4 → BehaviorHasMetatable
  5 → BehaviorNonTextKey (luaTypeName (reportDetail report))
  6 → BehaviorUnknownKey (reportName report)
  _ → BehaviorHookNotFunction (toEnum (max 0 (min 2 (reportDetail report)))) (luaTypeName (reportDetailType report))

-- | The name Lua gives a type code.
luaTypeName ∷ Int → Text
luaTypeName code = case code of
  0 → "nil"
  1 → "boolean"
  2 → "userdata"
  3 → "number"
  4 → "string"
  5 → "table"
  6 → "function"
  7 → "userdata"
  8 → "thread"
  _ → "unknown"
