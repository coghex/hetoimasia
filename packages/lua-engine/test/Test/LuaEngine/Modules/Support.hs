{-# LANGUAGE OverloadedStrings #-}

-- | What the module coordinator's examples share: a session of a real content root, inventory and
-- read pool whose reader sits behind gates the examples hold, real supervised Lua owners (one VM
-- each, with its own coordinator) that load modules through a binding written the way an engine
-- facade writes it, and the Lua that drives them.
--
-- Evidence from the real adapter and evidence that is injected are kept apart by name. The probe
-- wraps the real verified reader: a gated read still opens and hashes a real file once its gate
-- opens. 'injectedIoError' and 'injectedDefect' replace the reader's answer for the paths they
-- name, and say so.
--
-- Nothing sleeps. An example knows what has happened by blocking in STM, on a gate, or on what a
-- script recorded, and the whole example is bounded.
module Test.LuaEngine.Modules.Support
  ( -- * The session
    Session (..)
  , withSession
  , ReaderOf
  , realReader
  , injectedIoError
  , injectedDefect
  , fatalSession
  , Layout (..)
  , note
  , history
  , awaitNote
  , awaitHistory
  , countNotes
  , diagnostics
  , awaitDiagnostics
  , betweenCheckAndAdmission
  , contentPath
  , rewrite
  , key'

    -- * The probe
  , Probe
  , closeGate
  , openGate
  , awaitStarted
  , awaitFinished
  , startedPaths
  , finishedPaths
  , readsStarted
  , maxActive

    -- * Profiles
  , smaller
  , withSource

    -- * VMs
  , Timing (..)
  , VmOptions (..)
  , defaultOptions
  , Vm (..)
  , withVm
  , admitDriver
  , stopInstance
  , command
  , Fetch (..)
  , fetch
  , fetchAt
  , grantOne
  , grantStep
  , awaitTick
  , tickOf
  , retireVm
  , askRetire
  , openEverything
  , failingLogger
  , awaitEnd
  , awaitOwnerEnded
  , awaitFailure
  , instanceTicket
  , requestFailureOf
  , bootNow
  , awaitBootOutcome
  , awaitVmDiagnostic
  , vmDiagnostics
  , awaitPhase
  , awaitGate
  , releaseGate
  , counts
  , awaitCounts
  , poolReading
  , awaitPool

    -- * Re-exports
  , module Hetoimasia.LuaEngine.Modules
  , Necessity (..)
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , readTVarIO
  , retry
  , writeTVar
  )
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, fromException, throwIO, tryWithContext)
import Control.Monad (unless, void, when)
import Data.Maybe (isNothing)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import Data.Word (Word64)
import Hetoimasia.Content (FailureKind (Unreadable), defaultContentLimits, withContentRoot)
import Hetoimasia.Content.Identity (ContentKey, contentKeyPath, logicalPathBytes, parseReference, rootKey)
import Hetoimasia.Content.Inventory
  ( Inventory
  , InventorySpec (..)
  , ReadFailure (..)
  , ReadOutcome (ReadIoError)
  , inventoryIdentityLimits
  , inventoryLimits
  , inventoryLimitsOf
  , inventoryRoot
  , inventoryRootKey
  , readVerified
  , scanInventory
  )
import Hetoimasia.Content.ReadPool
  ( PoolStatus
  , ReadPool
  , poolSpec
  , status
  , withReadPoolUsing
  )
import Hetoimasia.Foundation.Log
  ( Logger
  , MetadataProviders (..)
  , callbackSink
  , defaultFormatOptions
  , defaultLogFilter
  , formatEntry
  , mkLoggerWith
  , unsafeComponent
  )
import Hetoimasia.Foundation.Time (DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Behavior (exportLimits)
import Hetoimasia.LuaEngine.Modules
import Hetoimasia.LuaEngine.Profile
  ( ByteLimit (ActiveChainReserveBytes, CopiedValueBytes, ModuleSourceBytes, SourceBankBytes)
  , Bytes (Bytes)
  , Count (Count)
  , CountLimit (CopiedValueDepth, CopiedValueElements)
  , Profile
  , bytesLimit
  , countLimit
  )
import Hetoimasia.LuaEngine.Request
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , WorkerStatus (..)
  , awaitSupervised
  , withSupervision
  )
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Admission (Necessity (..), admittedHandleType, newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
import Hetoimasia.Scripting.Lua.Loading (LoaderEndpoint, LoaderPlan)
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Provider
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime (LuaRuntime, newLuaRuntime)
import Hetoimasia.Scripting.Lua.Scheduled
import Hetoimasia.Scripting.Lua.Value
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.HUnit.Lang (HUnitFailure, assertFailure)
import Test.LuaEngine.Request.Profiles (bytesOf, smaller)

-- The session --------------------------------------------------------------------------------

-- | The files to create, relative to the content root.
newtype Layout = Layout [(FilePath, ByteString)]

-- | Everything an example shares: the profile, the real content root and inventory, the pool, the
-- probe around the pool's reader, and the record of what happened.
data Session = Session
  { ssProfile ∷ !Profile
  , ssTree ∷ !FilePath
  , ssInventory ∷ !Inventory
  , ssPool ∷ !ReadPool
  , ssProbe ∷ !Probe
  , ssLog ∷ !(IORef [Text])
  , ssDiagnostics ∷ !(TVar [Text])
  , ssLogger ∷ !Logger
  , ssGates ∷ !(IORef (Map Text (MVar ())))
  , ssEntered ∷ !(IORef (Map Text (MVar ())))
  , ssOpened ∷ !(IORef Bool)
  , ssIds ∷ !(IORef (Map Text InstanceId))
  , ssTickets ∷ !(IORef (Map Text InstanceTicket))
  , ssBetween ∷ !(IORef (Maybe (IO ())))
  -- ^ What another thread does between a request's argument check passing and its admission, once: set
  -- by an example that needs that exact interleaving, and run by the test binding's check.
  }

-- | How the pool's reader is made from the real one and the session's probe.
type ReaderOf = Probe → Inventory → (ContentKey → Int → IO (Either ReadFailure ByteString)) → ContentKey → Int → IO (Either ReadFailure ByteString)

-- | The real verified reader behind the probe's gates and counts.
realReader ∷ ReaderOf
realReader probe _ = probeReader probe

-- | A reader that answers an expected I/O failure for the paths it is given and reads the rest
-- for real, behind the probe's gates. Injected: the failure is not one a filesystem produced.
injectedIoError ∷ [ByteString] → ReaderOf
injectedIoError paths probe inventory real = probeReader probe $ \key allowance →
  if pathOfKey key `elem` paths
    then pure (Left (ReadFailure (inventoryRoot inventory) key (ReadIoError (Unreadable 5))))
    else real key allowance

-- | A reader that raises this for the paths it is given and reads the rest for real. Injected: an
-- engine defect, not an expected failure.
injectedDefect ∷ [ByteString] → IOError → ReaderOf
injectedDefect paths failure probe _ real = probeReader probe $ \key allowance →
  if pathOfKey key `elem` paths then throwIO failure else real key allowance

-- | The scan limits the examples use: room for the fixed profile's module source and a little more.
scanSpec ∷ InventorySpec
scanSpec =
  InventorySpec
    { specEntries = 100
    , specSegments = 8
    , specPathBytes = 200
    , specSegmentBytes = 40
    , specFileBytes = 16 * 1024 * 1024
    , specRootBytes = 64 * 1024 * 1024
    , specBufferBytes = 64 * 1024
    }

-- | A profile whose module source limit, and with it a reserve that holds one module, is this many
-- bytes, the bank this many: the validated smaller budgets the bank examples use.
withSource ∷ Word64 → Word64 → Word64 → Profile
withSource source reserve bank =
  bytesOf [(ModuleSourceBytes, source), (ActiveChainReserveBytes, reserve), (SourceBankBytes, bank)]

-- | Run an example over a session: a temporary content root with these files, scanned; a pool of
-- this many workers and slots whose reader is made by the given function; real supervision.
-- However the example ends the gates are opened, so a failing example fails instead of waiting.
withSession ∷ Profile → (Int, Int) → ReaderOf → Layout → (Session → RuntimeControl → LuaRuntime → IO a) → IO a
withSession profile (workers, slots) readerOf (Layout files) body =
  withSystemTempDirectory "hetoimasia-lua-engine-modules" $ \tree → do
    mapM_ (\(path, bytes) → createDirectoryIfMissing True (takeDirectory (tree </> path)) >> ByteString.writeFile (tree </> path) bytes) files
    limits ← either (\refused → assertFailure ("scan limits refused: " <> show refused)) pure (inventoryLimits scanSpec)
    root' ← either (\refused → assertFailure ("root key refused: " <> show refused)) pure (rootKey "modules-test")
    withContentRoot defaultContentLimits tree $ \root → do
      inventory ← scanInventory limits root' root >>= either (\refused → assertFailure ("scan refused: " <> show refused)) pure
      probe ← newProbe
      spec ← either (\refused → assertFailure ("pool refused: " <> show refused)) pure (poolSpec workers slots)
      diagnosticLog ← newTVarIO []
      let logger = mkLoggerWith defaultLogFilter metadata (callbackSink (\entry → atomically (modifyTVar' diagnosticLog (formatEntry defaultFormatOptions entry :))))
      withReadPoolUsing spec (readerOf probe inventory (readVerified inventory root)) $ \pool → do
        session ←
          Session profile tree inventory pool probe
            <$> newIORef []
            <*> pure diagnosticLog
            <*> pure logger
            <*> newIORef Map.empty
            <*> newIORef Map.empty
            <*> newIORef False
            <*> newIORef Map.empty
            <*> newIORef Map.empty
            <*> newIORef Nothing
        withLoggingLifetime quietLogger $ \lifetime →
          withSupervision lifetime $ \control → do
            runtime ← newLuaRuntime control
            outcome ← timeout exampleBound (body session control runtime) `finally` (writeIORef (ssOpened session) True >> openGates session >> openAllProbeGates probe)
            case outcome of
              Just value → pure value
              Nothing → do
                seen ← history session
                assertFailure ("the example did not finish within its bound; it had recorded: " <> show (reverse (take 60 (reverse seen))))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | An example whose owner is expected to end in a failure of the application's own, which
-- supervision raises at the boundary: answers the failure with its context. A failed assertion or
-- the example's bound is not that failure, and is raised as itself.
fatalSession ∷ Profile → (Int, Int) → ReaderOf → Layout → (Session → RuntimeControl → LuaRuntime → IO ()) → IO (ExceptionWithContext SomeException)
fatalSession profile sizes readerOf layout body =
  tryWithContext @SomeException (withSession profile sizes readerOf layout body) >>= \case
    Left failure@(ExceptionWithContext _ raised)
      | Just (_ ∷ HUnitFailure) ← fromException raised → throwIO raised
      | otherwise → pure failure
    Right () → assertFailure "expected the owner to fail, but the example returned"

-- | How long an example may run, in microseconds.
exampleBound ∷ Int
exampleBound = 20 * 1000 * 1000

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → pure ()))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | The absolute path of a file under the session's content root.
contentPath ∷ Session → FilePath → FilePath
contentPath session path = ssTree session </> path

-- | Replace a file's content on disk after the scan: an edit the inventory does not know of.
rewrite ∷ Session → FilePath → ByteString → IO ()
rewrite session path = ByteString.writeFile (contentPath session path)

-- | The key a path names in the session's root.
key' ∷ Session → ByteString → ContentKey
key' session path =
  either (\refused → error ("invalid fixture path " <> show path <> ": " <> show refused)) id $
    parseReference (inventoryIdentityLimits (inventoryLimitsOf (ssInventory session))) (inventoryRootKey (ssInventory session)) path

-- | Record that something happened, in the order the scripts and the fakes share.
note ∷ Session → Text → IO ()
note session entry = atomicModifyIORef' (ssLog session) (\held → (entry : held, ()))

-- | What happened, oldest first.
history ∷ Session → IO [Text]
history session = reverse <$> readIORef (ssLog session)

-- | Wait, without sleeping, until this was recorded.
awaitNote ∷ Session → Text → IO ()
awaitNote session wanted = awaitHistory session (wanted `elem`)

awaitHistory ∷ Session → ([Text] → Bool) → IO ()
awaitHistory session wanted = do
  seen ← history session
  if wanted seen then pure () else yield >> awaitHistory session wanted

-- | How many times this exact line was recorded.
countNotes ∷ Session → Text → IO Int
countNotes session wanted = length . filter (== wanted) <$> history session

-- | The diagnostics the coordinators wrote, oldest first, one line each.
diagnostics ∷ Session → IO [Text]
diagnostics session = reverse <$> readTVarIO (ssDiagnostics session)

-- | Do this once, on the next request's way from its argument check to its admission, as another
-- thread would.
betweenCheckAndAdmission ∷ Session → IO () → IO ()
betweenCheckAndAdmission session action = writeIORef (ssBetween session) (Just action)

-- | Block until the coordinators have written this many diagnostics. A diagnostic is written after the
-- transaction that decided it, on whichever thread published the outcome, so a count read at the
-- decision is not a count of what was written: the example waits for the write it expects, and for a
-- diagnostic it expects not to be written it reads the decision ('jobsDiagnosed'), which cannot lag.
awaitDiagnostics ∷ Session → Int → IO ()
awaitDiagnostics session wanted = atomically $ do
  written ← readTVar (ssDiagnostics session)
  when (length written < wanted) retry

-- The probe -----------------------------------------------------------------------------------

-- | What the wrapped reader did.
data Probe = Probe
  { prStarted ∷ !(TVar [ByteString])
  , prFinished ∷ !(TVar [ByteString])
  , prActive ∷ !(TVar Int)
  , prMax ∷ !(TVar Int)
  , prClosed ∷ !(TVar (Set ByteString))
  , prReleased ∷ !(TVar Bool)
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newTVarIO [] <*> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO Set.empty <*> newTVarIO False

probeReader ∷ Probe → (ContentKey → Int → IO a) → ContentKey → Int → IO a
probeReader probe inner key allowance = do
  let path = pathOfKey key
  atomically $ do
    modifyTVar' (prStarted probe) (<> [path])
    active ← readTVar (prActive probe)
    writeTVar (prActive probe) (active + 1)
    modifyTVar' (prMax probe) (max (active + 1))
  ( do
      atomically $ do
        closed ← readTVar (prClosed probe)
        released ← readTVar (prReleased probe)
        if Set.member path closed && not released then retry else pure ()
      inner key allowance
    )
    `finally` atomically (modifyTVar' (prActive probe) (subtract 1) >> modifyTVar' (prFinished probe) (<> [path]))

-- | Close the gate of a path: a read of it waits when it reaches the gate.
closeGate ∷ Probe → ByteString → IO ()
closeGate probe path = atomically (modifyTVar' (prClosed probe) (Set.insert path))

openGate ∷ Probe → ByteString → IO ()
openGate probe path = atomically (modifyTVar' (prClosed probe) (Set.delete path))

openAllProbeGates ∷ Probe → IO ()
openAllProbeGates probe = atomically (writeTVar (prReleased probe) True)

-- | Wait until this many reads have begun.
awaitStarted ∷ Probe → Int → IO ()
awaitStarted probe wanted = atomically $ do
  started ← readTVar (prStarted probe)
  unless (length started >= wanted) retry

-- | Wait until this many reads have returned from the reader.
awaitFinished ∷ Probe → Int → IO ()
awaitFinished probe wanted = atomically $ do
  finished ← readTVar (prFinished probe)
  unless (length finished >= wanted) retry

-- | The paths the reader began, oldest first.
startedPaths ∷ Probe → IO [ByteString]
startedPaths = atomically . readTVar . prStarted

-- | The paths the reader finished, in the order they finished.
finishedPaths ∷ Probe → IO [ByteString]
finishedPaths = atomically . readTVar . prFinished

readsStarted ∷ Probe → IO Int
readsStarted probe = length <$> startedPaths probe

-- | The most reads that were inside the reader at once.
maxActive ∷ Probe → IO Int
maxActive = atomically . readTVar . prMax

pathOfKey ∷ ContentKey → ByteString
pathOfKey = logicalPathBytes . contentKeyPath

-- VMs --------------------------------------------------------------------------------------------

-- | How the owner's settlements reach Lua: an owner on elapsed time, or one on logical time.
data Timing = OnArrival | AtAssignedTick
  deriving (Eq, Show)

-- | What an example chooses about a VM.
data VmOptions = VmOptions
  { optTiming ∷ !Timing
  , optSlots ∷ !Int
  -- ^ The pool slots its coordinator holds.
  , optBootWaiters ∷ !Int
  , optRequestBound ∷ !Int
  -- ^ The owner's request places.
  , optRole ∷ !Text
  , optWrap ∷ RequestEndpoint → RequestEndpoint
  -- ^ The endpoint the grant names, wrapped by the example: a wrapper that observes, duplicates or
  -- fails the provider's completion from outside it. The wrapper is the example's, and says so
  -- where it is used.
  , optLogger ∷ Maybe Logger
  -- ^ A logger of the example's own, instead of the session's.
  , optPlan ∷ LoaderPlan → LoaderPlan
  -- ^ The loader plan the coordinator made, as the example wants to observe it from outside (an
  -- example's hook that interleaves another thread at an exact point of the loader's own call).
  }

defaultOptions ∷ Timing → VmOptions
defaultOptions timing = VmOptions timing 4 2 64 "test" id Nothing id

-- | One VM: its owner, its coordinator and its loader endpoint.
data Vm = Vm
  { vmOwner ∷ !ScheduledOwner
  , vmCoordinator ∷ !Coordinator
  , vmEndpoint ∷ !LoaderEndpoint
  , vmLabel ∷ !Text
  }

requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaengine.modules") (\_ → pure Unrecognized)

handleType ∷ Text
handleType = "mreq"

-- | Run a body over a VM of this label: a coordinator over the session's pool, an owner on this
-- timing granted the module endpoint and loading through the coordinator's plan, and the
-- coordinator given its owner's loader. The pool and its workers are the session's.
withVm ∷ Session → LuaRuntime → Text → VmOptions → (Vm → IO a) → IO a
withVm session runtime label options body = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests (ssProfile session) handles)
  let resolver _ path root = pure (resolve session path root)
      moduleSpec =
        ModuleSpec
          { specRequests = requests
          , specInventory = ssInventory session
          , specPool = ssPool session
          , specResolve = resolver
          , specLogger = maybe (ssLogger session) id (optLogger options)
          , specRole = optRole options
          , specSlots = optSlots options
          , specBootWaiters = optBootWaiters options
          , specPhase = Nothing
          }
  withModuleCoordinator moduleSpec $ \coordinator → do
    let registered =
          either (error . ("registration refused: " <>) . show) id $
            registration [admittedHandleType handles handleType] (bindings session coordinator)
        Bytes copied = bytesLimit (ssProfile session) CopiedValueBytes
        Count depth = countLimit (ssProfile session) CopiedValueDepth
        Count elements = countLimit (ssProfile session) CopiedValueElements
        limits = either (error . show) id (valueLimits (fromIntegral copied) (fromIntegral depth) (fromIntegral elements))
        vm =
          (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
            { vmRegistration = registered
            , vmPolicy = ["fx", "request", "module"]
            , vmOwnerName = label
            , vmModules = [driverSource]
            , vmValueLimits = limits
            , vmExportLimits = exportLimits (ssProfile session)
            }
        grant =
          RequestGrant
            [optWrap options (coordinatorEndpoint coordinator)]
            (optRequestBound options)
            (if optTiming options == OnArrival then SettleOnArrival else SettleAtAssignedTick Nothing)
        spec =
          (scheduledSpec vm requiredPolicy bounds)
            { scheduledInstances = Just (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8, instanceSources = [commandSource]})
            , scheduledRequestHandles = Just handles
            , scheduledRequests = Just grant
            , scheduledLoader = Just (optPlan options (coordinatorPlan coordinator))
            }
    started ← startScheduledOwner runtime spec
    owner ← case started of
      ScheduledStarted found → pure found
      other → assertFailure ("expected an owner, found " <> take 80 (showStart other))
    endpoint ← maybe (assertFailure "the owner has no loader endpoint") pure (scheduledLoaderEndpoint owner)
    attachLoader coordinator endpoint
    body (Vm owner coordinator endpoint label)
  where
    bounds =
      SchedulerBounds
        { boundActiveTasks = 16
        , boundQueuedAdmissions = 16
        , boundRetainedResults = 32
        , boundQuanta = Quanta (Quantum 4) (Quantum 4) (Quantum 4)
        , boundOutstandingGrants = 4
        , boundControlRequests = 8
        , boundServiceBudget = Nothing
        }
    showStart = \case
      ScheduledUnavailable failure → "unavailable: " <> show failure
      ScheduledRejected → "rejected"
      ScheduledEnded → "ended"
      ScheduledStarted _ → "started"

-- | The address resolver the examples inject: a literal path in the game root, or the explicit
-- root @game@. Any other root is refused, as an unknown one is.
resolve ∷ Session → Text → Maybe Text → Either Text ContentKey
resolve session path root = case root of
  Just other | other /= "modules-test" → Left ("unknown root " <> other)
  _ →
    either (\refused → Left ("address refused: " <> Text.pack (show refused))) Right $
      parseReference (inventoryIdentityLimits (inventoryLimitsOf (ssInventory session))) (inventoryRootKey (ssInventory session)) (Text.encodeUtf8 path)

-- | The bindings: @fx.record@ and @fx.block@, the common operations from the adapter, and
-- @module.fetch(path [, offset])@ and @module.lookup(path)@, written the way the facade will write
-- them from "Hetoimasia.LuaEngine.Modules". This is the example's own scaffolding, not an API of the
-- engine.
bindings ∷ Session → Coordinator → [Namespace]
bindings session coordinator =
  [ namespace "fx" [recording, blocking]
  , namespace "request" (m1RequestBindings (M1Service handleType moduleValueSchema))
  , namespace "module" [fetching, looking]
  ]
  where
    recording =
      stateOperation "record" [SText] [] $ \arguments → do
        case arguments of
          [VText text] → note session text
          _ → pure ()
        pure []
    blocking =
      stateOperation "block" [SText] [] $ \arguments → do
        case arguments of
          [VText name] → do
            gateIn (ssEntered session) name >>= void . (`tryPutMVar` ())
            opened ← readIORef (ssOpened session)
            gate ← gateIn (ssGates session) name
            if opened then void (tryPutMVar gate ()) else pure ()
            readMVar gate
          _ → pure ()
        pure []
    fetching =
      withArgumentCheck check $
        asynchronousNativeRequestIn "fetch" [SText, SOptional SInteger] (m1StartSchemas handleType) $ \context values →
          case requestFrom session values of
            Left why → throwIO (userError (Text.unpack why))
            Right asked → do
              started ← startModule coordinator asked context (note session "disposed")
              case started of
                StartAnswered answer → pure (m1StartResults handleType answer)
                -- The same ordinary error the argument check raises.
                StartRefused why → throwIO (userError (Text.unpack why))
    check owner values = case requestFrom session values of
      Left why → pure (Just why)
      Right asked → do
        checked ← moduleArgumentCheck coordinator (const asked) owner values
        -- The window between the check and the admission, in which another thread may act.
        when (isNothing checked) $
          atomicModifyIORef' (ssBetween session) (\pending → (Nothing, pending)) >>= sequence_
        pure checked
    looking =
      stateOperation "lookup" [SText] [SText] $ \arguments → case arguments of
        [VText path] → case resolve session path Nothing of
          Left why → pure [VText ("refused " <> why)]
          Right key → do
            found ← atomically (lookupImmediate coordinator (moduleIdentity key))
            pure [VText (describeLookup found)]
        _ → pure [VText "?"]

describeLookup ∷ ImmediateLookup → Text
describeLookup = \case
  ImmediateNotReady → "not_ready"
  ImmediateReady _ → "ready"
  ImmediateFailed failure → "failed " <> failureCode failure

-- | The request a binding's copied arguments name.
requestFrom ∷ Session → [Value] → Either Text ModuleRequest
requestFrom session = \case
  VText path : rest → do
    key <- resolve session path Nothing
    let offset = case rest of
          VInteger given : _ → Just (offsetFromLua given)
          _ → Nothing
    Right (ModuleRequest key offset)
  _ → Left "a path is required"

gateIn ∷ IORef (Map Text (MVar ())) → Text → IO (MVar ())
gateIn table name = do
  fresh ← newEmptyMVar
  atomicModifyIORef' table $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing → (Map.insert name fresh held, fresh)

openGates ∷ Session → IO ()
openGates session = do
  held ← readIORef (ssGates session)
  mapM_ (void . (`tryPutMVar` ())) held

-- | Release a script held by @fx.block@.
releaseGate ∷ Session → Text → IO ()
releaseGate session name = gateIn (ssGates session) name >>= void . (`tryPutMVar` ())

-- | Wait until a script is inside the call that holds this gate.
awaitGate ∷ Session → Text → IO ()
awaitGate session name = gateIn (ssEntered session) name >>= readMVar

-- | The Lua the commands run. A table is shown with its keys in order; an export table by its @id@.
driverSource ∷ ModuleSource
driverSource =
  ModuleSource (ModuleRef "driver" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "local shared = {}"
      , "local function describe(v, depth)"
      , "  local t = type(v)"
      , "  if t == 'string' then return v end"
      , "  if t ~= 'table' then"
      , "    if t == 'userdata' or t == 'function' then return '<' .. t .. '>' end"
      , "    return tostring(v)"
      , "  end"
      , "  if depth >= 2 then return '<table>' end"
      , "  local keys = {}"
      , "  for k in pairs(v) do keys[#keys + 1] = tostring(k) end"
      , "  table.sort(keys)"
      , "  local out = {}"
      , "  for _, k in ipairs(keys) do"
      , "    local x = v[k]"
      , "    if k == 'value' and type(x) == 'table' then out[#out + 1] = k .. '=table(' .. tostring(x.id) .. ')'"
      , "    else out[#out + 1] = k .. '=' .. describe(x, depth + 1) end"
      , "  end"
      , "  return '{' .. table.concat(out, ',') .. '}'"
      , "end"
      , "local function run(self, p)"
      , "  local key = p.key or 'a'"
      , "  local out = '?'"
      , "  if p.op == 'start' then"
      , "    local r, err = module.fetch(p.path or 'a.lua', p.offset)"
      , "    if r then self.hs[key] = r out = 'started' else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'pstart' then"
      , "    local ok, r, err = pcall(module.fetch, p.path or 'a.lua', p.offset)"
      , "    if not ok then out = 'error ' .. tostring(r)"
      , "    elseif r then self.hs[key] = r out = 'started'"
      , "    else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'ready' then out = tostring(request.ready(self.hs[key]))"
      , "  elseif p.op == 'take' then out = describe(request.take(self.hs[key]), 0)"
      , "  elseif p.op == 'ptake' then"
      , "    local ok, r = pcall(request.take, self.hs[key])"
      , "    if ok then out = describe(r, 0) else out = 'error ' .. tostring(r) end"
      , "  elseif p.op == 'keep' then"
      , "    local r = request.take(self.hs[key])"
      , "    shared[p.name or key] = r.value"
      , "    out = describe(r, 0)"
      , "  elseif p.op == 'same' then out = tostring(rawequal(shared[key], shared[p.other]))"
      , "  elseif p.op == 'start_block' then"
      , "    local r, err = module.fetch(p.path or 'a.lua', p.offset)"
      , "    if r then self.hs[key] = r end"
      , "    fx.block(p.name or key)"
      , "    out = 'released'"
      , "  elseif p.op == 'call_same' then"
      , "    local ok, r = pcall(shared[key][p.field], p.text)"
      , "    out = ok and tostring(rawequal(r, shared[p.other])) or ('error ' .. tostring(r))"
      , "  elseif p.op == 'is_self' then out = tostring(rawequal(shared[key][p.field], shared[key]))"
      , "  elseif p.op == 'env' then"
      , "    local r = request.take(self.hs[key])"
      , "    shared[p.name or key] = r"
      , "    out = describe(r, 0)"
      , "  elseif p.op == 'wait_probe' then"
      , "    request.wait(self.hs[key])"
      , "    out = 'lookup=' .. module.lookup(p.path or 'a.lua') .. ' other_ready=' .. tostring(request.ready(self.hs[p.other]))"
      , "  elseif p.op == 'field' then"
      , "    local ok, r = pcall(function() return shared[key][p.field] end)"
      , "    out = ok and describe(r, 1) or ('error ' .. tostring(r))"
      , "  elseif p.op == 'set' then shared[key][p.field] = p.text out = 'set'"
      , "  elseif p.op == 'call' then"
      , "    local ok, r = pcall(shared[key][p.field], p.text)"
      , "    out = ok and describe(r, 1) or ('error ' .. tostring(r))"
      , "  elseif p.op == 'cancel' then out = request.cancel(self.hs[key])"
      , "  elseif p.op == 'wait' then"
      , "    fx.record('waiting ' .. key)"
      , "    out = tostring(select('#', request.wait(self.hs[key])))"
      , "  elseif p.op == 'wait_take' then"
      , "    fx.record('waiting ' .. key)"
      , "    request.wait(self.hs[key])"
      , "    out = describe(request.take(self.hs[key]), 0)"
      , "  elseif p.op == 'lookup' then out = module.lookup(p.path or 'a.lua')"
      , "  elseif p.op == 'block' then fx.block(key) out = 'released'"
      , "  end"
      , "  local tag = ''"
      , "  if p.path and p.op ~= 'start' and p.op ~= 'pstart' then tag = ' #' .. p.path end"
      , "  fx.record((p.who or 'cmd') .. ' ' .. p.op .. ' ' .. key .. ' ' .. out .. tag)"
      , "end"
      , "function init(self, api)"
      , "  self.hs = {}"
      , "  api.connect('cmd', function(self, event) run(self, event.payload) end)"
      , "end"
      , "function shutdown(self, reason) fx.record('shutdown ' .. reason) end"
      ]

commandSource ∷ EventSource
commandSource =
  EventSource
    "cmd"
    ( SRecord
        [ ("op", SText)
        , ("who", SOptional SText)
        , ("key", SOptional SText)
        , ("path", SOptional SText)
        , ("offset", SOptional SInteger)
        , ("name", SOptional SText)
        , ("other", SOptional SText)
        , ("field", SOptional SText)
        , ("text", SOptional SText)
        ]
    )

-- | Admit an instance of the driver under this name and wait until it is active.
admitDriver ∷ Session → Vm → Text → IO ()
admitDriver session vm name = do
  admitInstance (scheduledEndpoint (vmOwner vm)) (InstanceRequest (ModuleRef "driver" "1") EventOnly (Just name) OrdinaryClass ["cmd"]) >>= \case
    InstanceAccepted identity ticket → do
      atomicModifyIORef' (ssIds session) (\held → (Map.insert name identity held, ()))
      atomicModifyIORef' (ssTickets session) (\held → (Map.insert name ticket held, ()))
    other → assertFailure ("expected the instance accepted, found " <> take 80 (show other))
  awaitPhase session vm name Active

-- | Ask the instance of this name to stop, expecting the request accepted.
stopInstance ∷ Session → Vm → Text → IO ()
stopInstance session vm name = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  requestInstanceControl (scheduledEndpoint (vmOwner vm)) identity InstanceStop >>= \case
    InstanceControlAccepted _ → pure ()
    other → assertFailure ("expected the stop accepted, found " <> take 80 (show other))

-- | What a command starts.
data Fetch = Fetch
  { fetchPath ∷ !Text
  , fetchOffset ∷ !(Maybe Int)
  }

-- | A fetch of this path with the default offset.
fetch ∷ Text → Fetch
fetch path = Fetch path Nothing

-- | A fetch of this path with this tick offset.
fetchAt ∷ Int → Text → Fetch
fetchAt offset path = Fetch path (Just offset)

-- | Tell the instance of this name to do this with the request it keeps under the key, the extra
-- fields being those of the payload.
command ∷ Session → Vm → Text → Text → Text → [(Text, Value)] → Maybe Fetch → IO ()
command session vm name op key extra asked = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  let payload =
        VRecord $
          [("op", VText op), ("who", VText name), ("key", VText key)]
            <> extra
            <> concat
              [ [("path", VText (fetchPath found))]
                  <> [("offset", VInteger (fromIntegral offset)) | Just offset ← [fetchOffset found]]
              | Just found ← [asked]
              ]
  deliverEvent (scheduledEndpoint (vmOwner vm)) identity "cmd" payload >>= \case
    DeliveryAccepted _ → pure ()
    other → assertFailure ("expected the command accepted, found " <> take 80 (show other))

-- | Grant one logical step and wait for the tick to complete.
grantOne ∷ RuntimeControl → Vm → IO ()
grantOne control vm = grantStep vm >> void (awaitTicksComplete control (vmOwner vm))

-- | Grant one logical step without waiting for its tick to complete.
grantStep ∷ Vm → IO ()
grantStep vm = do
  one ← either (\refused → assertFailure (show refused)) pure (durationFromNanoseconds RequirePositive 1)
  void (grantScheduledStep (scheduledEndpoint (vmOwner vm)) one)

-- | The logical tick the VM has reached.
tickOf ∷ Vm → IO Word64
tickOf vm = atomically (scheduledTick (scheduledEndpoint (vmOwner vm)))

-- | Block, in STM and under supervision, until the VM's logical tick is this: an owner that fails
-- meanwhile raises its failure here instead of leaving the example waiting.
awaitTick ∷ RuntimeControl → Vm → Word64 → IO ()
awaitTick control vm wanted = awaitSupervised control $ do
  now ← scheduledTick (scheduledEndpoint (vmOwner vm))
  unless (now == wanted) retry

-- | Ask the owner to stop, and wait for it to be over.
retireVm ∷ RuntimeControl → Vm → IO ()
retireVm control vm = askRetire vm >> void (awaitEnd control vm)

-- | Ask the owner to stop, without waiting.
askRetire ∷ Vm → IO ()
askRetire = retireScheduled . vmOwner

-- | Open every gate there is: the probe's and the scripts'.
openEverything ∷ Session → IO ()
openEverything session = openGates session >> openAllProbeGates (ssProbe session)

-- | A logger whose sink fails with this text: a diagnostic that cannot be written.
failingLogger ∷ Text → Logger
failingLogger why = mkLoggerWith defaultLogFilter metadata (callbackSink (\_ → throwIO (userError (Text.unpack why))))
  where
    metadata =
      MetadataProviders
        { metadataClock = pure (UTCTime (fromGregorian 2026 10 22) (secondsToDiffTime 43200))
        , metadataThread = pure "1"
        }

-- | The owner's request service, read in one transaction.
vmDiagnostics ∷ Vm → IO ProviderDiagnostics
vmDiagnostics vm =
  atomically (requestDiagnostics (scheduledEndpoint (vmOwner vm))) >>= maybe (assertFailure "the owner has no request service") pure

-- | Block, in STM, until the owner's request service reads like this.
awaitVmDiagnostic ∷ Vm → (ProviderDiagnostics → Bool) → IO ()
awaitVmDiagnostic vm wanted = atomically $ do
  found ← requestDiagnostics (scheduledEndpoint (vmOwner vm))
  case found of
    Just reading | wanted reading → pure ()
    _ → retry

-- | Block until an instance is in this phase.
awaitPhase ∷ Session → Vm → Text → InstancePhase → IO ()
awaitPhase session vm name wanted = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  atomically $
    inspectInstance (scheduledEndpoint (vmOwner vm)) identity >>= \case
      Just snapshot | snapshotPhase snapshot == wanted → pure ()
      _ → retry

-- | Wait for the owner to end, and answer how.
awaitEnd ∷ RuntimeControl → Vm → IO WorkerStatus
awaitEnd control vm =
  awaitSupervised control $
    scheduledStatus (vmOwner vm) >>= \case
      WorkerLive → retry
      status' → pure status'

-- | Wait, without supervision's rethrow, until the owner is no longer live.
awaitOwnerEnded ∷ Vm → IO ()
awaitOwnerEnded vm = atomically $
  scheduledStatus (vmOwner vm) >>= \case
    WorkerLive → retry
    _ → pure ()

-- | The failure an instance settled with, waiting for it to settle.
awaitFailure ∷ Session → Text → IO (Maybe InstanceFailure)
awaitFailure session name = do
  ticket ← (Map.! name) <$> readIORef (ssTickets session)
  settlement ← waitInstance ticket
  pure $ case resultOutcome settlement of
    InstanceFailed failure → Just failure
    _ → Nothing

-- | The ticket of an instance admitted under this name: wait on it to see the instance settle.
instanceTicket ∷ Session → Text → IO InstanceTicket
instanceTicket session name = (Map.! name) <$> readIORef (ssTickets session)

-- | The endpoint and attributed text of a required request's failure.
requestFailureOf ∷ Maybe InstanceFailure → Maybe (Text, Text)
requestFailureOf failure = case fmap failureError failure of
  Just (ErrorRequest endpoint why) → Just (endpoint, why)
  _ → Nothing

-- | Ask for the boot load of a path, expecting it accepted.
bootNow ∷ Session → Vm → ByteString → IO BootTicket
bootNow session vm path =
  bootModule (vmCoordinator vm) (key' session path) >>= either (\refused → assertFailure ("expected the boot load accepted, found " <> show refused)) pure

-- | Wait, in STM, for a boot load's outcome.
awaitBootOutcome ∷ BootTicket → IO BootOutcome
awaitBootOutcome = atomically . awaitBoot

-- | The coordinator, read in one transaction.
counts ∷ Vm → IO Counts
counts vm = atomically (coordinatorCounts (vmCoordinator vm))

-- | Block, in STM, until the coordinator reads like this.
awaitCounts ∷ Vm → (Counts → Bool) → IO ()
awaitCounts vm wanted = atomically $ do
  reading ← coordinatorCounts (vmCoordinator vm)
  unless (wanted reading) retry

-- | The pool, read in one transaction.
poolReading ∷ Session → IO PoolStatus
poolReading session = atomically (status (ssPool session))

-- | Block until the pool reads like this.
awaitPool ∷ Session → (PoolStatus → Bool) → IO ()
awaitPool session wanted = atomically $ do
  reading ← status (ssPool session)
  unless (wanted reading) retry
