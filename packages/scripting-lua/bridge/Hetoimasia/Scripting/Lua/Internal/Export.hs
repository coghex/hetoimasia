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
import Control.Monad (void, when)
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
import Lua (StatusCode, lua_gettop, lua_settop, data LUA_OK)

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
    { boundaryModule = Just (ModuleRef (labelOf label) "export")
    , boundaryChunk = labelOf label
    }

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
        Just (ExportHeld slot) → pure (ExportReady (ExportHandle (vmIdentity vm) slot identity))
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
              modifyIORef' (exportRecords held) (Map.insert identity (ExportBroken fault))
              pure (ExportFailed fault)
            else evaluate state entry
  where
    vm = hostVm host
    held = hostExports host
    limits = exportLimits held
    identity = exportIdentity source
    ExportIdentity raw = identity
    label = exportLabel source
    broken why = faultFor host EvaluateExport label (InternalError why)
    evaluate state entry = do
      -- Anything that can fail before the chunk is made happens first, so that a
      -- failure there charges no identity.
      ensureValues vm state
      modifyIORef' (exportRecords held) (Map.insert identity ExportEvaluating)
      let abandon = modifyIORef' (exportRecords held) (Map.insert identity (ExportBroken (broken "the evaluation was abandoned")))
      -- A failure before the chunk could start (memory running out as the
      -- environment is made) executed nothing: it is raised, and the identity is
      -- not charged, so it can be asked for again.
      attempted ← (`onException` abandon) $ do
        setRunContext vm (labelOf label, "export", Nothing)
        slot ← nextModuleSlot vm
        evaluated ← evaluateExportSource state (exportText source) (labelOf label) slot
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
              modifyIORef' (exportRecords held) (Map.insert identity (ExportBroken fault))
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
                    modifyIORef' (exportRecords held) (Map.insert identity (ExportHeld slot))
                    pure (Right (ExportReady (ExportHandle (vmIdentity vm) slot identity)))
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
      Just (ExportHeld slot) → Just (ExportReady (ExportHandle (vmIdentity (hostVm host)) slot identity))
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
-- and capture it with the facade.
--
-- Refused before anything runs, with 'NoEffect': a handle another owner issued,
-- one the owner holds no table for, a facade past the value limits or holding a
-- capability the application's own check retires, and a selector that is empty or
-- past 128 bytes. A behavior that does not fit the schema is not a fault: it is
-- answered as a 'BehaviorProblem' and nothing is held. An allocation that fails
-- on the way is a fault, with nothing held either.
--
-- On success the capture is held until 'releaseBehavior' or the VM closes, and
-- the answer says which hooks it has and how its cadence fields read. The facade
-- is copied into a fresh Lua value for this capture alone.
captureBehavior ∷ HasCallStack ⇒ Host → ExportHandle → Text → Value → IO (Either BehaviorProblem Captured)
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
      when (exportHandleVm export /= vmIdentity vm) (refuse ExportHandleForeign)
      records ← readIORef (exportRecords (hostExports host))
      case Map.lookup (exportHandleIdentity export) records of
        Just (ExportHeld slot) | slot == exportHandleSlot export → pure ()
        _ → refuse ExportHandleStale
      when (ByteString.null selector || ByteString.length selector > 128) $
        refuse (InvalidEntryName select)
      let refuseFacade ∷ ∀ b. ValueRule → IO b
          refuseFacade rule = fault (ValueRefused (ValueRefusal Arguments 1 [] rule 0)) NoEffect
      either refuseFacade pure (checkLimits limits [facade])
      retired ← runCallback vm (retiredIn boundary facade)
      case retired of
        Just (path, typeName) → fault (ValueRefused (ValueRefusal Arguments 1 path (RuleRetiredHandle typeName) 0)) NoEffect
        Nothing → pure ()
      encoded ← either refuseFacade pure (encodeValues (boundaryContext boundary) limits [facade])
      ensureValues vm state
      setRunContext vm (labelOf select, "behavior", Nothing)
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
      slot ← nextModuleSlot vm
      (status, report) ← captureBehaviorFields state (exportHandleSlot export) selector slot True
      if status /= LUA_OK
        then do
          value ← renderFailure state entry
          lua_settop state entry
          raiseEscape vm
          -- Nothing was published: the one store is the last step of the call.
          fault (ScriptFailed (classify status) value) NoEffect
        else do
          lua_settop state entry
          if reportStored report
            then do
              -- Published and tracked in one masked step; were anything to
              -- interrupt it, what was stored is let go of.
              (`onException` void (releaseCapture state slot)) $ do
                raiseEscape vm
                modifyIORef' (exportCaptures (hostExports host)) (Set.insert slot)
              let handle = CaptureHandle (vmIdentity vm) slot
              pure (Right (Captured handle (shapeOfReport report)))
            else pure (Left (problemOfReport report))
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
