-- | The module loader: ordered import chains that suspend on a dependency's source
-- and resume on the VM's owner.
--
-- This is the opt-in, engine-managed way to evaluate the export modules of
-- "Hetoimasia.Scripting.Lua.Internal.Export" when a module can discover a dependency
-- while it runs. The synchronous 'Hetoimasia.Scripting.Lua.Internal.Export.evaluateExport'
-- is unchanged and gives its module no @import@.
--
-- = The shape
--
-- Roots are admitted by a coordinator ('admitRoot') in the order it chooses: logical
-- tick and sequence order, or UI request-admission order. The loader keeps that order
-- and adds no priority, phase or second scheduler of its own. One /chain/ is active at
-- a time per VM. A root becomes the chain's first frame when it is at the head of the
-- queue, the coordinator's eligibility seam allows it and its verified source has
-- arrived; a root that is not eligible blocks every later one, however early its own
-- source arrived. A frame is the chunk of one module, run as a Lua coroutine of the VM
-- in an environment of its own that holds an @import@ bound to that module.
--
-- @import(path [, root_id])@ is resolved by the injected resolver to a canonical
-- identity. Inside a module's top level:
--
-- * a /ready/ identity returns its export table, the very one the VM holds, never a
--   copy, from anywhere Lua can call it, a @table.sort@ comparator or a finalizer
--   included;
-- * a /failed/ identity raises an ordinary Lua error, and latches the failure of the
--   module whose code called it, even if Lua catches the error;
-- * an identity on the active chain is a cycle: the same, with the chain of labels
--   named, and no extra frame for the edge that closes it;
-- * otherwise the importing coroutine is suspended, and the loader goes on. The
--   dependency's source is asked for if it was not already, a frame for it runs, depth
--   first, in Lua's call order, and the importer is resumed with its exports. The
--   suspension is made in C once every Haskell frame has returned.
--
-- Where Lua could not suspend (a coroutine the script created, a comparator, a
-- replacement callback, a finalizer, a to-be-closed handler) an import that is not
-- ready is refused before anything is admitted, and fails the containing module like any
-- other dependency failure. @pcall@, @xpcall@ and metamethods called from Lua code
-- suspend like any other call. A raw @coroutine.yield@ at a module's top level is a
-- failure of the module.
--
-- Outside module evaluation, in a hook or in a helper a module exported, @import@ is
-- the immediate lookup: ready returns the exports, failed raises the cached failure,
-- and an identity that is absent or not ready raises @module_not_ready@, reading
-- nothing, starting no work and suspending nothing.
--
-- = Who runs what
--
-- Every compile, evaluation, resume, cache publication and Lua-reference release is an
-- operation of the VM's owner, under its gate. A provider thread tells the owner by
-- whatever means the application has, and the owner calls 'deliverSource' and
-- 'advanceLoader'. Nothing here waits, enters Lua from another thread or calls across
-- VMs.
--
-- = One cache
--
-- Pending and evaluating identities are records of the same table as ready and failed
-- ones ('Hetoimasia.Scripting.Lua.Internal.ExportTypes.ExportRecord'): a second cache
-- could disagree with it. Every record counts against the identity bound until the
-- VM ends. A new identity is admitted only if there is room; one past the bound makes
-- no record and starts no read. Failures are sticky and the first one is the one kept.
--
-- = The ledger
--
-- Each identity the loader holds a record of and has not finished with has one
-- 'Entry': its source interest, acquired exactly once and released exactly once, and
-- the verified bytes if they arrived, held only until the frame that needs them has
-- been compiled. @acquired == released + held@ always, and a stopped loader holds none.
-- See the package README for the owner, creation and terminal transition of every
-- reference.
--
-- = Failures
--
-- A failure of the engine or of the application's own code (a supplier or resolver that
-- raises, an allocation that fails in a handler) is raised from the operation that
-- reached it, whatever Lua did with its stand-in error, and abandons the chain: every
-- suspended frame is closed and its identity recorded as failed. Failures closing
-- coroutines and releasing interests are kept as cleanup evidence beside the primary one
-- and raised with it. A failure of a module's own code is data: its identity's sticky
-- failure.
--
-- = Stop
--
-- 'stopLoader' closes admission, closes every suspended frame on the owner, withdraws
-- every source interest and marks every identity that was pending or evaluating
-- 'ModuleStopped'. It requires nothing to finish. Late and duplicate source deliveries
-- are refused. It is terminal and idempotent, and a stopped loader still answers
-- lookups of what it holds.
module Hetoimasia.Scripting.Lua.Internal.Loader
  ( Loader
  , newLoader
  , installLoader
  , loaderHost
    -- * Operations of the owner
  , admitRoot
  , deliverSource
  , advanceLoader
  , lookupModule
  , stopLoader
  , loaderCounts
  , module Hetoimasia.Scripting.Lua.Internal.LoaderTypes
  ) where

import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, evaluate, finally, fromException, onException, rethrowIO, tryWithContext)
import Control.Monad (forM, forM_, unless, void, when)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Sequence (Seq, ViewL (EmptyL, (:<)), (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Text.Unsafe (lengthWord8)
import Foreign.Ptr (nullPtr)
import GHC.Stack (HasCallStack)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure, withOperationContext)
import Hetoimasia.Foundation.Resource (composeCleanup)
import Hetoimasia.Scripting.Lua.Internal.Binding (argumentReason, boundReason, diagnosticLimits, ensureValues, ordinaryRule)
import Hetoimasia.Scripting.Lua.Internal.Boundary
import Hetoimasia.Scripting.Lua.Internal.Callback (Handler, failedResults, installImport, suspendResults)
import Hetoimasia.Scripting.Lua.Internal.Export (faultFor, labelOf, shapeOfCode, sourceOf)
import Hetoimasia.Scripting.Lua.Internal.ExportTypes
import Hetoimasia.Scripting.Lua.Internal.Fault (classify, fromApplication, luaComponent, raisedByApplication, renderFailure)
import Hetoimasia.Scripting.Lua.Internal.LoaderTypes
import Hetoimasia.Scripting.Lua.Internal.Marshal
import Hetoimasia.Scripting.Lua.Internal.Module (Host (..), effectNow)
import Hetoimasia.Scripting.Lua.Internal.Task (Cleanup (..), cleanUp, closeAnchored)
import Hetoimasia.Scripting.Lua.Internal.Value
import Hetoimasia.Scripting.Lua.Internal.Vm
  ( Vm
  , escapePending
  , nextModuleSlot
  , nextTaskSlot
  , noteTaskEnded
  , noteTaskLive
  , raiseEscape
  , runCallback
  , setRunContext
  , takeSuspension
  , vmIdentity
  , withOpenVm
  )
import Lua (NumResults (NumResults), StackIndex (StackIndex), State, fromStackIndex, lua_gettop, lua_remove, lua_settop, lua_tointegerx, data LUA_OK)

-- | A module loader over one owner's VM.
data Loader = Loader
  { loaderHost ∷ !Host
  , loaderSettings ∷ !LoaderConfig
  , loaderState ∷ !(IORef LoaderState)
  }

-- | What the loader keeps beside the records. Read and written by the owner's thread
-- and, while the owner is inside Lua, by a callback it is waiting for, never both at
-- once.
data LoaderState = LoaderState
  { lsOpen ∷ !Bool
  , lsQueue ∷ !(Seq ExportIdentity)
    -- ^ Roots admitted and not yet started, in the order the coordinator admitted
    -- them.
  , lsEntries ∷ !(Map.Map ExportIdentity Entry)
    -- ^ Exactly the identities whose record is pending.
  , lsChain ∷ ![Frame]
    -- ^ The active chain, the frame that runs first.
  , lsRunning ∷ !(Maybe Running)
    -- ^ While the loader runs a segment: whose.
  , lsNoted ∷ !(Maybe (ExportIdentity, Text))
    -- ^ The import the running segment asked to suspend on.
  , lsContexts ∷ !(Map.Map Int ImportContext)
    -- ^ Each module that was ever evaluated, by the number its @import@ closure
    -- carries. Bounded by the identity bound.
  , lsAcquired ∷ !Int
  , lsReleased ∷ !Int
  , lsEvidence ∷ ![(Text, ExceptionWithContext SomeException)]
    -- ^ Cleanup failures not yet raised, newest first.
  }

-- | The loader's record of an identity it asked a source for.
data Entry = Entry
  { entryLabel ∷ !Text
  , entryInterest ∷ !Bool
    -- ^ The supplier holds the loader's interest: acquired and not yet released.
  , entryArrival ∷ !Arrival
  }

data Arrival
  = Awaiting
  | Arrived !ByteString.ByteString
  | -- | Past the source bound: the bytes are not kept, only that there were too many.
    ArrivedOversize
  | ArrivedFailed !Text

-- | One module on the chain.
data Frame = Frame
  { frameIdentity ∷ !ExportIdentity
  , frameLabel ∷ !Text
  , frameTaskSlot ∷ !Int
  , frameModuleSlot ∷ !Int
  , frameLatched ∷ !(Maybe BoundaryFault)
    -- ^ The first failure that already condemns this module, whatever Lua does.
  , frameWaiting ∷ !(Maybe (ExportIdentity, Text))
    -- ^ The import it is suspended on.
  }

-- | Whose segment the loader is running.
newtype Running = Running
  { runningThread ∷ State
  }

admitOperation, deliverOperation, advanceOperation, lookupOperation, stopOperation, importOperation, countOperation ∷ Operation
admitOperation = operation "admit-root"
deliverOperation = operation "deliver-source"
advanceOperation = operation "advance-loader"
lookupOperation = operation "lookup-module"
stopOperation = operation "stop-loader"
importOperation = operation "import-module"
countOperation = operation "count-loader"

-- | A loader over the owner's host. It does nothing until 'installLoader' gives its
-- modules an @import@.
newLoader ∷ Host → LoaderConfig → IO Loader
newLoader host config =
  Loader host config
    <$> newIORef
      LoaderState
        { lsOpen = True
        , lsQueue = Seq.empty
        , lsEntries = Map.empty
        , lsChain = []
        , lsRunning = Nothing
        , lsNoted = Nothing
        , lsContexts = Map.empty
        , lsAcquired = 0
        , lsReleased = 0
        , lsEvidence = []
        }

-- | Install the handler every module's @import@ reaches in the owner's VM. Part of the
-- owner's construction, before any module runs.
installLoader ∷ HasCallStack ⇒ Loader → IO ()
installLoader loader = installImport (vmOf loader) (importHandler loader)

vmOf ∷ Loader → Vm
vmOf = hostVm . loaderHost

-- ---------------------------------------------------------------------------------
-- Small helpers

recordsRef ∷ Loader → IORef (Map.Map ExportIdentity ExportRecord)
recordsRef = exportRecords . hostExports . loaderHost

limitsOf ∷ Loader → ExportLimits
limitsOf = exportLimits . hostExports . loaderHost

readState ∷ Loader → IO LoaderState
readState = readIORef . loaderState

modifyState ∷ Loader → (LoaderState → LoaderState) → IO ()
modifyState loader = modifyIORef' (loaderState loader)

setRecord ∷ Loader → ExportIdentity → ExportRecord → IO ()
setRecord loader identity record = modifyIORef' (recordsRef loader) (Map.insert identity record)

-- | Application code: run as the application's, on a thread the VM knows is inside a
-- callback, so that a seam that asks the VM for anything is refused instead of left
-- waiting for the operation that called it.
application ∷ Loader → IO a → IO a
application loader = runCallback (vmOf loader) . fromApplication

-- | The fault for a module, with how much had happened.
faultOfModule ∷ Loader → Text → FaultReason → Effect → BoundaryFault
faultOfModule loader label reason effect = (faultFor (loaderHost loader) EvaluateExport label reason) {boundaryEffect = effect}

-- | What a failure of an identity that never ran is told as.
brokenBecause ∷ Loader → Text → Text → BoundaryFault
brokenBecause loader label why = faultFor (loaderHost loader) EvaluateExport label (InternalError why)

handleFor ∷ Loader → Map.Map ExportIdentity ExportRecord → ExportIdentity → Int → ModuleRef → ExportHandle
handleFor loader records identity slot source' =
  ExportHandle (vmIdentity (vmOf loader)) slot (maybe identity (fst . (`Map.elemAt` records)) (Map.lookupIndex identity records)) source'

statusOf ∷ Loader → Map.Map ExportIdentity ExportRecord → ExportIdentity → ModuleStatus
statusOf loader records identity = case Map.lookup identity records of
  Nothing → ModuleUnknown
  Just (ExportHeld slot source') → ModuleReady (handleFor loader records identity slot source')
  Just (ExportBroken fault) → ModuleFailed fault
  Just ExportPending → ModulePending
  Just ExportEvaluating → ModuleEvaluating
  Just ExportStopped → ModuleStopped

-- | Keep failures of closing and releasing, to be raised with the failure of whatever
-- is in progress, or on their own once it is over.
noteEvidence ∷ Loader → [(Text, ExceptionWithContext SomeException)] → IO ()
noteEvidence loader failures =
  unless (null failures) $ modifyState loader (\s → s {lsEvidence = reverse failures <> lsEvidence s})

-- | Raise the cleanup failures that are being kept, if there are any: the first is the
-- primary and the others stay beside it as cleanup evidence.
flushEvidence ∷ Loader → IO ()
flushEvidence loader = do
  held ← atomicModifyIORef' (loaderState loader) (\s → (s {lsEvidence = []}, reverse (lsEvidence s)))
  case held of
    [] → pure ()
    (_, first) : rest → do
      composed ← composeCleanup (Just first) rest
      rethrowIO (fromMaybe first composed)

-- | Release the supplier's interest in an identity, once. Counted before the call so a
-- release that raises is not asked for again, and its failure is kept.
releaseInterest ∷ Loader → ExportIdentity → IO ()
releaseInterest loader identity = do
  modifyState loader (\s → s {lsReleased = lsReleased s + 1})
  released ← tryWithContext @SomeException (application loader (supplierRelease (loaderSupplier (loaderSettings loader)) identity))
  case released of
    Right () → pure ()
    Left failure → noteEvidence loader [("lua source release", failure)]

-- | Make a source answer into what the entry holds: a copy that owns its bytes.
--
-- Source past the bound is never copied or kept: what is held for a pending identity is
-- bounded by the identity bound times the source bound.
arrivalOfAnswer ∷ ExportLimits → SourceAnswer → Arrival
arrivalOfAnswer limits = \case
  SourcePending → Awaiting
  SourceVerified bytes
    | ByteString.length bytes > exportMaxSourceBytes limits → ArrivedOversize
    | otherwise → Arrived (ByteString.copy bytes)
  SourceFailure why → ArrivedFailed (boundReason why)

-- ---------------------------------------------------------------------------------
-- Admission

-- | Ask the loader to evaluate a root.
--
-- A new identity is recorded as pending, its source is asked for through the supplier
-- and it is queued after the roots already admitted. An identity the loader already
-- holds makes no new record and takes no second interest in its source: a ready or
-- failed one answers its outcome, a pending or evaluating one is joined (and queued
-- as a root if it was only a dependency). A new identity past the bound, or one that
-- is empty or too long, is refused with nothing recorded and no source asked for.
--
-- An acquire that raises takes back what this admission recorded and raises: the
-- supplier holds no interest in an identity it did not acquire.
admitRoot ∷ HasCallStack ⇒ Loader → RootRequest → IO RootAdmission
admitRoot loader request =
  withOperationContext luaComponent admitOperation [("module", label)] $
    withOpenVm (vmOf loader) admitOperation $ \_ → do
      s ← readState loader
      let ExportIdentity raw = rootIdentity request
      if not (lsOpen s)
        then pure RootClosed
        else
          if ByteString.null raw || ByteString.length raw > maxExportIdentityBytes
            then pure (RootRefused (RootIdentityInvalid maxExportIdentityBytes))
            else do
              records ← readIORef (recordsRef loader)
              case Map.lookup identity records of
                Just ExportStopped → pure RootClosed
                Just ExportPending → enqueue identity >> pure RootJoined
                Just ExportEvaluating → enqueue identity >> pure RootJoined
                Just _ → pure (RootSettled (statusOf loader records identity))
                Nothing
                  | Map.size records >= exportMaxIdentities (limitsOf loader) →
                      pure (RootRefused (RootCacheFull (exportMaxIdentities (limitsOf loader))))
                  | otherwise → do
                      let kept = ExportIdentity (ByteString.copy raw)
                      -- Tracked before the supplier is asked, so no failure after the ask
                      -- leaves an interest nothing records.
                      setRecord loader kept ExportPending
                      modifyState loader (\st → st {lsEntries = Map.insert kept (Entry label False Awaiting) (lsEntries st)})
                      answer ← application loader (supplierAcquire (loaderSupplier (loaderSettings loader)) kept >>= evaluate)
                        `onException` forget kept
                      modifyState loader $ \st →
                        st
                          { lsEntries = Map.adjust (\entry → entry {entryInterest = True, entryArrival = arrivalOfAnswer (limitsOf loader) answer}) kept (lsEntries st)
                          , lsAcquired = lsAcquired st + 1
                          }
                      enqueue kept
                      pure RootQueued
  where
    identity = rootIdentity request
    label = labelOf (rootLabel request)
    enqueue key =
      modifyState loader $ \st →
        if any (== key) (lsQueue st) then st else st {lsQueue = lsQueue st |> key}
    forget kept = do
      modifyIORef' (recordsRef loader) (Map.delete kept)
      modifyState loader (\st → st {lsEntries = Map.delete kept (lsEntries st)})

-- | Deliver what the supplier found for an identity the loader asked about. It only
-- records the answer: nothing is compiled or evaluated until the loader is advanced.
--
-- Refused with no effect after the loader has stopped, for an identity it holds no
-- interest in, and for one whose source was delivered already.
deliverSource ∷ HasCallStack ⇒ Loader → ExportIdentity → SourceAnswer → IO SourceDelivery
deliverSource loader identity answer =
  withOperationContext luaComponent deliverOperation [] $
    withOpenVm (vmOf loader) deliverOperation $ \_ → do
      s ← readState loader
      if not (lsOpen s)
        then pure SourceAfterStop
        else case answer of
          SourcePending → pure SourceNotYet
          _ → case Map.lookup identity (lsEntries s) of
            Just (Entry _ _ Awaiting) → do
              modifyState loader (\st → st {lsEntries = Map.adjust (\entry → entry {entryArrival = arrivalOfAnswer (limitsOf loader) answer}) identity (lsEntries st)})
              pure SourceDelivered
            Just _ → pure SourceDuplicate
            Nothing → do
              records ← readIORef (recordsRef loader)
              pure (if Map.member identity records then SourceDuplicate else SourceUnwanted)

-- | What an identity is, without doing anything.
lookupModule ∷ HasCallStack ⇒ Loader → ExportIdentity → IO ModuleStatus
lookupModule loader identity =
  withOpenVm (vmOf loader) lookupOperation $ \_ → do
    records ← readIORef (recordsRef loader)
    pure (statusOf loader records identity)

-- | The loader's own bookkeeping.
loaderCounts ∷ HasCallStack ⇒ Loader → IO LoaderCounts
loaderCounts loader =
  withOpenVm (vmOf loader) countOperation $ \_ → do
    s ← readState loader
    records ← readIORef (recordsRef loader)
    let count p = length (filter p (Map.elems records))
    pure
      LoaderCounts
        { countPending = count (== ExportPending)
        , countEvaluating = count (== ExportEvaluating)
        , countReady = count (\case ExportHeld {} → True; _ → False)
        , countFailed = count (\case ExportBroken _ → True; _ → False)
        , countStopped = count (== ExportStopped)
        , countQueued = Seq.length (lsQueue s)
        , countChainDepth = length (lsChain s)
        , countInterestsHeld = length (filter entryInterest (Map.elems (lsEntries s)))
        , countInterestsAcquired = lsAcquired s
        , countInterestsReleased = lsReleased s
        , countSourcesHeld = length [() | Entry _ _ (Arrived _) ← Map.elems (lsEntries s)]
        , countContexts = Map.size (lsContexts s)
        }

-- ---------------------------------------------------------------------------------
-- The chain

-- | Run the loader as far as it can go: start the next eligible root whose source has
-- arrived, evaluate dependencies depth first, resume importers with what they asked
-- for, and return when everything that could run has finished or the active chain waits
-- for a source or the head of the queue is not eligible.
--
-- A failure of a module is its sticky outcome, reported in 'advanceSettled'. A failure
-- of the engine or the application is raised, with the chain abandoned and every
-- cleanup failure beside it.
advanceLoader ∷ HasCallStack ⇒ Loader → IO AdvanceReport
advanceLoader loader =
  withOperationContext luaComponent advanceOperation [] $
    withOpenVm (vmOf loader) advanceOperation $ \state → do
      entry ← lua_gettop state
      open ← lsOpen <$> readState loader
      if not open
        then pure (AdvanceReport [] BlockedStopped 0)
        else do
          ensureValues (vmOf loader) state
          settled ← newIORef []
          ran ← tryWithContext @SomeException (drive loader state entry settled)
          case ran of
            Left failure → do
              evidence ← abandonChain loader state entry
              lua_settop state entry
              noteEvidence loader evidence
              held ← atomicModifyIORef' (loaderState loader) (\s → (s {lsEvidence = []}, reverse (lsEvidence s)))
              composed ← composeCleanup (Just failure) (map id held)
              rethrowIO (fromMaybe failure composed)
            Right blocked → do
              flushEvidence loader
              found ← reverse <$> readIORef settled
              depth ← length . lsChain <$> readState loader
              pure (AdvanceReport found blocked depth)

-- | Settle an identity as failed, stickily.
settle ∷ Loader → IORef [(ExportIdentity, ModuleStatus)] → ExportIdentity → ExportRecord → IO ()
settle loader settled identity record = do
  setRecord loader identity record
  records ← readIORef (recordsRef loader)
  modifyIORef' settled ((identity, statusOf loader records identity) :)

-- | The driver loop. Answers what it blocked on.
drive ∷ Loader → State → StackIndex → IORef [(ExportIdentity, ModuleStatus)] → IO Blocked
drive loader state entry settled = loop
  where
    host = loaderHost loader
    vm = vmOf loader
    config = loaderSettings loader
    limits = limitsOf loader

    -- Every piece of module code the advance would run next passes through here first, so
    -- that an owner that is stopping finds the chain where it stood.
    loop = do
      allowed ← application loader (loaderMayRun config >>= evaluate)
      if not allowed
        then pure BlockedNotAllowed
        else do
          s ← readState loader
          case lsChain s of
            [] → startRoot s
            frame : _ → continueFrame frame

    -- The next root, if its turn has come.
    startRoot s = case Seq.viewl (lsQueue s) of
      EmptyL → pure BlockedIdle
      identity :< rest → do
        records ← readIORef (recordsRef loader)
        case Map.lookup identity records of
          Just ExportPending → do
            eligible ← application loader (loaderEligible config identity >>= evaluate)
            if not eligible
              then pure (BlockedIneligible identity)
              else case Map.lookup identity (lsEntries s) of
                Just (Entry _ _ Awaiting) → pure (BlockedSource identity)
                Just _ → do
                  modifyState loader (\st → st {lsQueue = rest})
                  startFrame identity
                  loop
                Nothing → do
                  -- A pending record always has its entry; this is a defect, made loud.
                  modifyState loader (\st → st {lsQueue = rest})
                  settle loader settled identity (ExportBroken (brokenBecause loader "the root" "a pending identity had no source entry"))
                  loop
          -- Already an outcome, as a dependency of an earlier chain, or stopped.
          _ → do
            modifyState loader (\st → st {lsQueue = rest})
            loop

    -- Resume the frame on top of the chain, or find what it waits for.
    continueFrame frame = case frameWaiting frame of
      Nothing → step frame ResumeStart
      Just (dependency, label) → do
        records ← readIORef (recordsRef loader)
        case Map.lookup dependency records of
          Just (ExportHeld slot _) → resume frame (ResumeExports slot)
          Just (ExportBroken fault) → do
            let reason = ModuleRefused (DependencyFailed label fault)
            latch frame (faultOfModule loader (frameLabel frame) reason LuaRan)
            resume frame (ResumeError (Text.encodeUtf8 (boundReason ("import: the module " <> label <> " failed"))))
          Just ExportPending → do
            s ← readState loader
            case Map.lookup dependency (lsEntries s) of
              Just (Entry _ _ Awaiting) → pure (BlockedSource dependency)
              Just _ → startFrame dependency >> loop
              Nothing → do
                settle loader settled dependency (ExportBroken (brokenBecause loader label "a pending identity had no source entry"))
                loop
          other → do
            -- Never the case: an importer waits only on an identity that is pending or
            -- an outcome. Made loud, and the importer fails with it.
            let why = "the module it waits for is " <> maybe "unknown" (const "being evaluated") other
            latch frame (brokenBecause loader (frameLabel frame) why)
            resume frame (ResumeError (Text.encodeUtf8 (boundReason ("import: " <> why))))

    resume frame how = do
      modifyState loader $ \s → s {lsChain = [f {frameWaiting = Nothing} | f ← take 1 (lsChain s)] <> drop 1 (lsChain s)}
      step frame {frameWaiting = Nothing} how

    latch frame fault = modifyState loader $ \s → case lsChain s of
      top : rest | frameIdentity top == frameIdentity frame → s {lsChain = top {frameLatched = Just (fromMaybe fault (frameLatched top))} : rest}
      _ → s

    -- Consume an identity's arrived source: compile it into a frame and push it, or
    -- settle it as a source failure. Its source interest ends here either way.
    startFrame identity = do
      s ← readState loader
      case Map.lookup identity (lsEntries s) of
        Nothing → pure ()
        Just consumed → do
          modifyState loader (\st → st {lsEntries = Map.delete identity (lsEntries st)})
          let label = entryLabel consumed
              ended ∷ ExportRecord → IO ()
              ended record = settle loader settled identity record
          started ← case entryArrival consumed of
            Awaiting → pure Nothing
            ArrivedFailed why → do
              ended (ExportBroken (faultOfModule loader label (ModuleRefused (SourceUnavailable label why)) NoEffect))
              pure Nothing
            ArrivedOversize → do
              ended (ExportBroken (faultOfModule loader label (ModuleRefused (SourceTooLarge (exportMaxSourceBytes limits))) NoEffect))
              pure Nothing
            Arrived bytes → compile identity label bytes
          -- The bytes are no longer needed, however compiling went.
          when (entryInterest consumed) (releaseInterest loader identity)
          forM_ started $ \frame → modifyState loader $ \st → st {lsChain = frame : lsChain st}

    compile identity label bytes = do
      moduleSlot ← nextModuleSlot vm
      taskSlot ← nextTaskSlot vm
      created ← newLoaderCoroutine state bytes (moduleChunkText label) taskSlot moduleSlot
      let fail' reason effect = do
            void (closeSlotQuietly taskSlot)
            lua_settop state entry
            settle loader settled identity (ExportBroken (faultOfModule loader label reason effect))
            pure Nothing
      if createdStatus created /= LUA_OK
        then do
          value ← renderFailure state entry
          fail' (ScriptFailed (classify (createdStatus created)) value) NoEffect
        else
          if createdChunkStatus created /= LUA_OK
            then do
              value ← renderFailure state entry
              fail' (ScriptFailed (classify (createdChunkStatus created)) value) NoEffect
            else do
              lua_settop state entry
              noteTaskLive vm taskSlot
              setRecord loader identity ExportEvaluating
              modifyState loader (\st → st {lsContexts = Map.insert moduleSlot (ImportContext identity label) (lsContexts st)})
              pure (Just (Frame identity label taskSlot moduleSlot Nothing Nothing))

    -- A coroutine a failed creation may have anchored.
    closeSlotQuietly slot = void (closeTaskCoroutine state slot)

    moduleChunkText = moduleChunk . sourceOf

    -- Run the top frame's next segment.
    step frame how = do
      setRunContext vm (moduleRefName (sourceOf (frameLabel frame)), "export", Nothing)
      thread ← taskThread state (frameTaskSlot frame)
      void (takeSuspension vm)
      modifyState loader (\s → s {lsRunning = Just (Running thread), lsNoted = Nothing})
      segment ←
        phased (resumeLoaderSegment state (frameTaskSlot frame) (frameModuleSlot frame) how)
          `onException` leaveSegment
      leaveSegment
      noted ← lsNoted <$> readState loader
      modifyState loader (\s → s {lsNoted = Nothing})
      -- Lua has run: a Haskell failure that reached a callback outranks whatever Lua
      -- reported, whatever it did with the stand-in.
      escaped ← escapePending vm
      refusal ←
        if escaped
          then do
            -- A chunk that caught the stand-in and returned its table was kept by the segment:
            -- the table is not kept, because the failure is not the module's to hide.
            when (loaderStored segment) (void (releaseExport state (frameModuleSlot frame)))
            lua_settop state entry
            raised ← tryWithContext @SomeException (raiseEscape vm)
            case raised of
              Right () → pure Nothing
              Left failure → case faultOfModuleCall failure of
                -- A refusal of a call the module made to a binding is a failure of the module
                -- and cannot be hidden by what its code did with the error it saw. Anything
                -- else that reached a callback is the engine's or the application's, and is
                -- raised.
                Just fault → pure (Just fault)
                Nothing → rethrowIO failure
          else pure Nothing
      current ← topFrame frame
      afterSegment current (frameLatched current) noted segment refusal

    leaveSegment = modifyState loader (\s → s {lsRunning = Nothing})

    -- Closing a module's coroutine runs its pending to-be-closed variables, which are the
    -- module's own code: the application's precondition holds for them as for its top level.
    phased ∷ IO x → IO x
    phased = inModulePhase config

    -- The frame as the chain holds it now: an import may have condemned it.
    topFrame frame = do
      s ← readState loader
      pure $ case lsChain s of
        top : _ | frameIdentity top == frameIdentity frame → top
        _ → frame

    afterSegment frame latched noted segment refusal
      | Just fault ← refusal = do
          -- The module called a binding and was refused; the coroutine is closed wherever it
          -- stands, finished or suspended, and the module fails with the refusal.
          closing ← phased (closeAnchored host state entry (frameTaskSlot frame))
          failFrame frame (fromMaybe fault latched) closing
      | loaderStatus segment /= LUA_OK = do
          -- The protected call itself failed: allocation failed making the answer or
          -- publishing the export table. A module failure of its own kind.
          value ← renderFailure state entry
          lua_settop state entry
          closing ← phased (closeAnchored host state entry (frameTaskSlot frame))
          effect ← if loaderResumed segment then effectNow vm else pure NoEffect
          when (loaderStored segment) (void (releaseExport state (frameModuleSlot frame)))
          failFrame frame (fromMaybe (faultOfModule loader (frameLabel frame) (ScriptFailed (classify (loaderStatus segment)) value) effect) latched) closing
      | otherwise = case loaderOutcome segment of
          SegmentYielded → case noted of
            Just target → do
              lua_settop state entry
              modifyState loader $ \s → s {lsChain = [f {frameWaiting = Just target} | f ← take 1 (lsChain s)] <> drop 1 (lsChain s)}
              loop
            Nothing → do
              -- A coroutine suspended to no one: the script called coroutine.yield at
              -- the top level of a module, which would never be resumed.
              lua_settop state entry
              closing ← phased (closeAnchored host state entry (frameTaskSlot frame))
              effect ← effectNow vm
              failFrame frame (fromMaybe (faultOfModule loader (frameLabel frame) UnscheduledYield effect) latched) closing
          SegmentCompleted → do
            lua_settop state entry
            effect ← effectNow vm
            case shapeOfCode (loaderShape segment) (loaderResultType segment) of
              Nothing
                | loaderStored segment → case latched of
                    Nothing → finishReady frame
                    Just fault → do
                      -- A table that was kept is not, whatever the module returned.
                      void (releaseExport state (frameModuleSlot frame))
                      failFrame frame fault []
                | otherwise → failFrame frame (fromMaybe (faultOfModule loader (frameLabel frame) (InternalError "the export table was not kept") effect) latched) []
              Just shape → failFrame frame (fromMaybe (faultOfModule loader (frameLabel frame) (ExportShapeRefused shape) effect) latched) []
          SegmentFailed → do
            -- The coroutine is closed apart from the segment, so what closing it raised
            -- is told from what the segment did.
            cleanup ← phased (cleanUp host state entry (frameTaskSlot frame))
            value ← renderFailure state entry
            lua_settop state entry
            effect ← effectNow vm
            let natural = (faultOfModule loader (frameLabel frame) (ScriptFailed (classify (loaderSegmentStatus segment)) value) effect) {boundaryTraceback = loaderTrace segment}
            failFrame frame (fromMaybe natural latched) (cleanupEvidence cleanup)
          _ → do
            lua_settop state entry
            closing ← phased (closeAnchored host state entry (frameTaskSlot frame))
            effect ← effectNow vm
            failFrame frame (fromMaybe (faultOfModule loader (frameLabel frame) (TaskRefused TaskNotSuspended) effect) latched) closing

    finishReady frame = do
      modifyState loader (\s → s {lsChain = drop 1 (lsChain s)})
      noteTaskEnded vm (frameTaskSlot frame)
      settle loader settled (frameIdentity frame) (ExportHeld (frameModuleSlot frame) (sourceOf (frameLabel frame)))
      loop

    failFrame frame fault evidence = do
      modifyState loader (\s → s {lsChain = drop 1 (lsChain s)})
      noteTaskEnded vm (frameTaskSlot frame)
      settle loader settled (frameIdentity frame) (ExportBroken fault)
      noteEvidence loader evidence
      loop

-- | The refusal of a call a module made to a binding, if that is what a failure that
-- reached a callback is: a fault of the call (a value refused, a call refused, a scheduler
-- operation where none can suspend, a kind not yet delivered, a script error raised
-- building a refusal), not marked as raised by application code. Whatever else reaches a
-- callback (the application's own failure, an engine defect, a seam's re-entry) is not.
faultOfModuleCall ∷ ExceptionWithContext SomeException → Maybe BoundaryFault
faultOfModuleCall (ExceptionWithContext context exception) = case fromException exception of
  Just fault
    | not (raisedByApplication context) → case boundaryReason fault of
        ValueRefused _ → Just fault
        BindingRefused _ → Just fault
        SuspendRefused _ → Just fault
        NotYetSupported _ → Just fault
        ScriptFailed _ _ → Just fault
        _ → Nothing
  _ → Nothing

-- | Run an action with the application's module phase set, and put it back as it was
-- however the action ends: the module's code runs under it, its top level and the
-- to-be-closed variables closing its coroutine run, alike.
inModulePhase ∷ LoaderConfig → IO a → IO a
inModulePhase config action = case loaderPhase config of
  Nothing → action
  Just phase → do
    before ← modulePhaseActive phase
    setModulePhase phase True
    action `finally` setModulePhase phase before

-- | Close every frame of the active chain, top first, recording each identity as
-- abandoned, and answer the failures of closing them.
abandonChain ∷ Loader → State → StackIndex → IO [(Text, ExceptionWithContext SomeException)]
abandonChain loader state entry = closeChain loader state entry (\label → ExportBroken (brokenBecause loader label "the evaluation was abandoned"))

-- | Close every frame of the active chain, recording each identity as what the function
-- says, and answer the failures of closing them.
closeChain ∷ Loader → State → StackIndex → (Text → ExportRecord) → IO [(Text, ExceptionWithContext SomeException)]
closeChain loader state entry recorded = do
  s ← readState loader
  evidence ← forM (lsChain s) $ \frame → do
    setRunContext (vmOf loader) (moduleRefName (sourceOf (frameLabel frame)), "export", Nothing)
    closing ← inModulePhase (loaderSettings loader) (closeAnchored (loaderHost loader) state entry (frameTaskSlot frame))
    noteTaskEnded (vmOf loader) (frameTaskSlot frame)
    setRecord loader (frameIdentity frame) (recorded (frameLabel frame))
    pure closing
  modifyState loader (\st → st {lsChain = [], lsRunning = Nothing, lsNoted = Nothing})
  pure (concat evidence)

-- ---------------------------------------------------------------------------------
-- Stop

-- | Stop the loader, once and for good.
--
-- Admission closes first. Every suspended frame is closed on the owner, its pending
-- to-be-closed variables run, and its identity reads 'ModuleStopped'; so does every
-- identity that was only pending. Every source interest is withdrawn, the delivered
-- bytes dropped and the queue emptied. No module is required to finish. Failures
-- closing coroutines and releasing interests are all attempted, kept, and raised
-- together, the first as the primary; the loader is stopped regardless, and a second
-- stop does nothing.
stopLoader ∷ HasCallStack ⇒ Loader → IO StopReport
stopLoader loader =
  withOperationContext luaComponent stopOperation [] $
    withOpenVm (vmOf loader) stopOperation $ \state → do
      entry ← lua_gettop state
      before ← readState loader
      if not (lsOpen before)
        then pure (StopReport [] 0 0 True)
        else do
          modifyState loader (\s → s {lsOpen = False})
          let frames = length (lsChain before)
          chainEvidence ← closeChain loader state entry (const ExportStopped)
          lua_settop state entry
          noteEvidence loader chainEvidence
          held ← lsEntries <$> readState loader
          -- Everything pending is stopped, and its interest withdrawn exactly once.
          forM_ (Map.keys held) $ \identity → setRecord loader identity ExportStopped
          let interests = [identity | (identity, entry') ← Map.toList held, entryInterest entry']
          forM_ interests (releaseInterest loader)
          modifyState loader (\s → s {lsEntries = Map.empty, lsQueue = Seq.empty})
          records ← readIORef (recordsRef loader)
          let stopped = [identity | (identity, ExportStopped) ← Map.toList records]
          flushEvidence loader
          pure (StopReport stopped frames (length interests) False)

-- ---------------------------------------------------------------------------------
-- @import@

-- | The handler every module's @import@ reaches. See the module header.
importHandler ∷ Loader → Handler
importHandler loader state restore = do
  context ← fromIntegral <$> lua_tointegerx state (StackIndex 1) nullPtr
  lua_remove state (StackIndex 1)
  entry ← lua_gettop state
  top ← fromIntegral . fromStackIndex <$> lua_gettop state
  s0 ← readState loader
  case Map.lookup (context ∷ Int) (lsContexts s0) of
    Nothing → do
      lua_settop state entry
      throwFailure luaComponent importOperation [] (blankFault boundary EvaluateExport (InternalError "an import was called by a module the loader does not know"))
    Just caller → do
      let label = importerLabel caller
          fault ∷ ∀ b. FaultReason → Effect → IO b
          fault reason effect = throwFailure luaComponent importOperation [] (faultOfModule loader label reason effect)
          current ∷ IO Effect
          current = effectNow vm
          -- The ordinary Lua error: the stack as it was on entry, the text on top, and
          -- the count that makes the C closure raise it once every Haskell frame has
          -- returned. Nothing is recorded on the VM, so Lua may catch it.
          raiseOrdinary ∷ Text → IO NumResults
          raiseOrdinary reason = do
            lua_settop state entry
            let message = boundReason ("import: " <> reason)
                allowance = either (const limits') id diagnosticLimits
            case encodeValues valueContext allowance [VText message] of
              Left rule → current >>= fault (ValueRefused (ValueRefusal Results 1 [] rule 0))
              Right bytes → do
                pushed ← pushValues state allowance bytes 1
                case pushed of
                  Pushed → do
                    serviceCollector state
                    pure failedResults
                  PushStatus status → do
                    value ← renderFailure state entry
                    lua_settop state entry
                    current >>= fault (ScriptFailed (classify status) value)
                  PushMalformed which → current >>= fault (InternalError (Text.pack ("a refusal could not be built: " <> show which)))
          -- Latch the failure of the module whose code made the call, which is the frame
          -- on top of the chain, and refuse the call. The error is an ordinary one, so
          -- Lua may catch it; the module fails regardless.
          condemn ∷ FaultReason → Text → IO NumResults
          condemn reason message = do
            effect ← current
            modifyState loader $ \st → case lsChain st of
              top' : rest → st {lsChain = top' {frameLatched = Just (fromMaybe (faultOfModule loader (frameLabel top') reason effect) (frameLatched top'))} : rest}
              [] → st
            raiseOrdinary message
          -- The dependency's export table, as the VM holds it.
          pushReady ∷ Int → IO NumResults
          pushReady slot = do
            (status, found) ← pushExportTable state slot
            if status /= LUA_OK
              then do
                value ← renderFailure state entry
                lua_settop state entry
                current >>= fault (ScriptFailed (classify status) value)
              else
                if found /= 5
                  then do
                    lua_settop state entry
                    current >>= fault (InternalError "the export table of a ready module is not held")
                  else pure (NumResults 1)
      arguments ← parseArguments loader state entry top fault current
      case arguments of
        Left reason → raiseOrdinary reason
        Right (path, rootId) → do
          -- The injected resolver: application code, unmasked, run before anything of
          -- this call is recorded.
          resolved ← fromApplication (restore (loaderResolver config caller path rootId >>= evaluate . forceResolved))
          case resolved of
            Left reason → raiseOrdinary reason
            Right address → do
              let identity = resolvedIdentity address
                  ExportIdentity raw = identity
                  target = labelOf (resolvedLabel address)
              when (ByteString.null raw || ByteString.length raw > maxExportIdentityBytes) $
                current >>= fault (ModuleRefused (InvalidExportIdentity maxExportIdentityBytes))
              s ← readState loader
              records ← readIORef (recordsRef loader)
              let known = Map.lookup identity records
              case lsRunning s of
                -- No chain is running Lua: a hook, or a helper a hook called. The
                -- immediate lookup, which reads nothing and waits for nothing.
                Nothing → case known of
                  Just (ExportHeld slot _) → pushReady slot
                  Just (ExportBroken _) → raiseOrdinary ("the required module " <> target <> " failed")
                  _ → raiseOrdinary ("module_not_ready: " <> target)
                Just running → case known of
                  Just (ExportHeld slot _) → pushReady slot
                  Just (ExportBroken failure) →
                    condemn (ModuleRefused (DependencyFailed target failure)) ("the module " <> target <> " failed")
                  -- Never met while a chain runs: stopping closes the chain first. Refused rather
                  -- than waited for, in case it ever is.
                  Just ExportStopped → raiseOrdinary ("the loader stopped before the module " <> target <> " was evaluated")
                  _ → do
                    let chain = lsChain s
                        closing = takeThrough ((== identity) . frameIdentity) chain
                    if any ((== identity) . frameIdentity) chain
                      then do
                        let names = map frameLabel (reverse closing) <> [target]
                        condemn (ModuleRefused (ImportCycle names)) ("import cycle: " <> Text.intercalate " -> " names)
                      else do
                        refusal ← suspensionReason state running
                        case refusal of
                          Just why →
                            condemn (ModuleRefused (ImportNotSuspendable why target)) ("the module " <> target <> " is not ready and Lua cannot suspend here")
                          Nothing
                            | isNew known && Map.size records >= exportMaxIdentities limits →
                                condemn (ModuleRefused (ImportCacheFull (exportMaxIdentities limits) target)) ("no room for the module " <> target)
                            | length chain + 1 > exportMaxChainDepth limits →
                                condemn (ModuleRefused (ImportChainTooDeep (exportMaxChainDepth limits) target)) ("the module " <> target <> " would make the chain longer than " <> Text.pack (show (exportMaxChainDepth limits)))
                            | otherwise → do
                                when (isNew known) (admitDependency identity raw target)
                                modifyState loader (\st → st {lsNoted = Just (identity, target)})
                                lua_settop state entry
                                pure suspendResults
  where
    vm = vmOf loader
    host = loaderHost loader
    boundary = hostBoundary host
    config = loaderSettings loader
    limits = limitsOf loader
    limits' = boundaryLimits boundary
    valueContext = boundaryContext boundary
    isNew = \case
      Nothing → True
      _ → False
    forceResolved ∷ Either Text ResolvedAddress → Either Text ResolvedAddress
    forceResolved = \case
      Left reason → lengthWord8 reason `seq` Left reason
      Right address → resolvedIdentity address `seq` lengthWord8 (resolvedLabel address) `seq` Right address
    -- The frames from the top of the chain through the first that satisfies the test.
    takeThrough p chain = let (before, rest) = break p chain in before <> take 1 rest
    -- A new identity: tracked before the supplier is asked, so that a failure of the ask
    -- leaves nothing behind, and the interest recorded the moment it exists.
    admitDependency identity raw target = do
      let kept = ExportIdentity (ByteString.copy raw)
          forget = do
            modifyIORef' (recordsRef loader) (Map.delete kept)
            modifyState loader (\st → st {lsEntries = Map.delete kept (lsEntries st)})
      setRecord loader kept ExportPending
      modifyState loader (\st → st {lsEntries = Map.insert kept (Entry target False Awaiting) (lsEntries st)})
      answer ←
        fromApplication (restore (supplierAcquire (loaderSupplier config) identity >>= evaluate))
          `onException` forget
      modifyState loader $ \st →
        st
          { lsEntries = Map.adjust (\e → e {entryInterest = True, entryArrival = arrivalOfAnswer limits answer}) kept (lsEntries st)
          , lsAcquired = lsAcquired st + 1
          }

-- | Why Lua cannot suspend the coroutine that called import right here, if it cannot:
-- it is a coroutine the script created, or Lua cannot yield where it is (a comparator,
-- a replacement callback, a finalizer, a metamethod reached from a library function).
suspensionReason ∷ State → Running → IO (Maybe SuspendRefusal)
suspensionReason state running
  | state /= runningThread running = pure (Just SuspendOtherCoroutine)
  | otherwise = do
      yieldable ← threadYieldable state
      pure (if yieldable then Nothing else Just SuspendNotYieldable)

-- | The path and the optional root of an import call, or why the arguments are refused
-- as an ordinary Lua error.
parseArguments
  ∷ Loader
  → State
  → StackIndex
  → Int
  → (∀ b. FaultReason → Effect → IO b)
  → IO Effect
  → IO (Either Text (Text, Maybe Text))
parseArguments loader state entry top fault current
  | top < 1 || top > 2 = pure (Left "expected a path and an optional root")
  | otherwise = do
      copied ← readValues state (boundaryLimits boundary) (vmIdentity (vmOf loader)) 1 top
      case copied of
        ReadStatus status → do
          value ← renderFailure state entry
          lua_settop state entry
          current >>= fault (ScriptFailed (classify status) value)
        ReadRefused rule index visited
          | ordinaryRule rule → pure (Left (argumentReason index [] rule))
          | otherwise → current >>= fault (ValueRefused (ValueRefusal Arguments index [] rule visited))
        ReadCopied bytes _ → case decodeValues top bytes of
          Left why → current >>= fault (InternalError why)
          Right raws → pure $ do
            conformed ← traverse conformOne (zip3 [1 ..] [SText, SOptional SText] raws)
            case conformed of
              [VText path] → Right (path, Nothing)
              [VText path, VNil] → Right (path, Nothing)
              [VText path, VText root] → Right (path, Just root)
              _ → Left "expected a path and an optional root"
  where
    boundary = hostBoundary (loaderHost loader)
    conformOne (index, schema, raw) =
      either (\(path, rule) → Left (argumentReason index path rule)) Right (conformRaw (boundaryContext boundary) schema raw)
