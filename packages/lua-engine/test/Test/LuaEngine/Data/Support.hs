{-# LANGUAGE OverloadedStrings #-}

-- | What the raw-data provider examples share: a session of a real content root, inventory and
-- read pool, real supervised Lua owners (one VM each, with its own byte bank) that call the
-- provider through a binding written the way an engine facade writes it, and the Lua that drives
-- them.
--
-- Evidence from the real adapter and evidence that is injected are kept apart by name. The probe
-- wraps the real verified reader: a gated read still opens and hashes a real file once its gate
-- opens. 'injectedReader' replaces the reader outright and says so.
--
-- Nothing sleeps. An example knows what has happened by blocking in STM, on a gate, or on what a
-- script recorded, and the whole example is bounded.
module Test.LuaEngine.Data.Support
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
  , lineStarting
  , contentPath
  , rewrite
  , key'

    -- * The probe
  , Probe
  , closeGate
  , openGate
  , awaitStarted
  , startedPaths
  , readsStarted
  , maxActive

    -- * VMs
  , Timing (..)
  , Vm (..)
  , startVm
  , vmDiagnostics
  , awaitVmDiagnostic
  , awaitCharged
  , charged
  , admitDriver
  , stopInstance
  , command
  , commandWith
  , Fetch (..)
  , fetch
  , grantOne
  , grantStep
  , awaitEnd
  , awaitOwnerEnded
  , awaitFailure
  , instanceTicket
  , requestFailureOf
  , awaitPhase
  , awaitGate
  , poolReading
  , awaitPool

    -- * Re-exports
  , module Hetoimasia.LuaEngine.Data
  , module Hetoimasia.LuaEngine.Request
  , Necessity (..)
  , Credit (..)
  ) where

import Control.Concurrent (yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)
import Control.Concurrent.STM
  ( TVar
  , atomically
  , modifyTVar'
  , newTVarIO
  , readTVar
  , retry
  , writeTVar
  )
import Control.Exception (ExceptionWithContext (ExceptionWithContext), SomeException, finally, fromException, throwIO, tryWithContext)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
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
import Hetoimasia.Foundation.Log (Logger, MetadataProviders (..), callbackSink, defaultLogFilter, mkLoggerWith, unsafeComponent)
import Hetoimasia.Foundation.Time (DurationRequirement (RequirePositive), durationFromNanoseconds)
import Hetoimasia.LuaEngine.Data
import Hetoimasia.LuaEngine.Profile (ByteLimit (CopiedValueBytes), Bytes (Bytes), Count (Count), CountLimit (CopiedValueDepth, CopiedValueElements), Profile, bytesLimit, countLimit)
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
import Hetoimasia.Scripting.Lua.Admission (Credit (..), Necessity (..), admittedHandleType, newRequestHandles)
import Hetoimasia.Scripting.Lua.Instance
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
import qualified Data.ByteString as ByteString

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
  , ssGates ∷ !(IORef (Map Text (MVar ())))
  , ssEntered ∷ !(IORef (Map Text (MVar ())))
  , ssOpened ∷ !(IORef Bool)
  , ssIds ∷ !(IORef (Map Text InstanceId))
  , ssTickets ∷ !(IORef (Map Text InstanceTicket))
  }

-- | How the pool's reader is made from the real one and the session's probe.
type ReaderOf = Probe → Inventory → (ContentKey → Int → IO (Either ReadFailure ByteString)) → ContentKey → Int → IO (Either ReadFailure ByteString)

-- | The real verified reader behind the probe's gates and counts.
realReader ∷ ReaderOf
realReader probe _ = probeReader probe

-- | A reader that answers an expected I/O failure for the paths it is given and reads the rest
-- for real, behind the probe's gates. Injected: the failure is not one a filesystem produced.
injectedIoError ∷ [ByteString] → ReaderOf
injectedIoError paths probe inventory real = probeReader probe $ \key allowance ->
  if pathOfKey key `elem` paths
    then pure (Left (ReadFailure (inventoryRoot inventory) key (ReadIoError (Unreadable 5))))
    else real key allowance

-- | A reader that raises this for the paths it is given and reads the rest for real. Injected: an
-- engine defect, not an expected failure.
injectedDefect ∷ [ByteString] → IOError → ReaderOf
injectedDefect paths failure probe _ real = probeReader probe $ \key allowance ->
  if pathOfKey key `elem` paths then throwIO failure else real key allowance

-- | The scan limits the examples use: room for the fixed profile's 8 MiB of data and a little
-- more, and a 64 KiB buffer.
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

-- | Run an example over a session: a temporary content root with these files, scanned; a pool of
-- this many workers and slots whose reader is made by the given function; real supervision.
-- However the example ends the gates are opened and the owners' providers proved over, so a
-- failing example fails instead of waiting for what is right to wait.
withSession ∷ Profile → (Int, Int) → ReaderOf → Layout → (Session → RuntimeControl → LuaRuntime → IO a) → IO a
withSession profile (workers, slots) readerOf (Layout files) body =
  withSystemTempDirectory "hetoimasia-lua-engine-data" $ \tree → do
    mapM_ (\(path, bytes) → createDirectoryIfMissing True (takeDirectory (tree </> path)) >> ByteString.writeFile (tree </> path) bytes) files
    limits ← either (\refused → assertFailure ("scan limits refused: " <> show refused)) pure (inventoryLimits scanSpec)
    root' ← either (\refused → assertFailure ("root key refused: " <> show refused)) pure (rootKey "data-test")
    withContentRoot defaultContentLimits tree $ \root → do
      inventory ← scanInventory limits root' root >>= either (\refused → assertFailure ("scan refused: " <> show refused)) pure
      probe ← newProbe
      spec ← either (\refused → assertFailure ("pool refused: " <> show refused)) pure (poolSpec workers slots)
      withReadPoolUsing spec (readerOf probe inventory (readVerified inventory root)) $ \pool → do
        session ←
          Session profile tree inventory pool probe
            <$> newIORef []
            <*> newIORef Map.empty
            <*> newIORef Map.empty
            <*> newIORef False
            <*> newIORef Map.empty
            <*> newIORef Map.empty
        withLoggingLifetime quietLogger $ \lifetime →
          withSupervision lifetime $ \control → do
            runtime ← newLuaRuntime control
            outcome ← timeout exampleBound (body session control runtime) `finally` (writeIORef (ssOpened session) True >> openGates session >> openAllProbeGates probe)
            case outcome of
              Just value → pure value
              Nothing → do
                seen ← history session
                assertFailure ("the example did not finish within its bound; it had recorded: " <> show (reverse (take 12 (reverse seen))))

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
exampleBound = 15 * 1000 * 1000

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

-- | Wait for a line that starts with this, and answer it.
lineStarting ∷ Session → Text → IO Text
lineStarting session prefix = do
  seen ← history session
  case filter (Text.isPrefixOf prefix) seen of
    line : _ → pure line
    [] → yield >> lineStarting session prefix

-- The probe -----------------------------------------------------------------------------------

-- | What the wrapped reader did.
data Probe = Probe
  { prStarted ∷ !(TVar [ByteString])
  , prActive ∷ !(TVar Int)
  , prMax ∷ !(TVar Int)
  , prClosed ∷ !(TVar (Set ByteString))
  , prReleased ∷ !(TVar Bool)
  }

newProbe ∷ IO Probe
newProbe = Probe <$> newTVarIO [] <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO Set.empty <*> newTVarIO False

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
    `finally` atomically (modifyTVar' (prActive probe) (subtract 1))

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

-- | The paths the reader began, oldest first.
startedPaths ∷ Probe → IO [ByteString]
startedPaths = atomically . readTVar . prStarted

readsStarted ∷ Probe → IO Int
readsStarted probe = length <$> startedPaths probe

-- | The most reads that were inside the reader at once.
maxActive ∷ Probe → IO Int
maxActive = atomically . readTVar . prMax

pathOfKey ∷ ContentKey → ByteString
pathOfKey = logicalPathBytes . contentKeyPath

-- VMs ------------------------------------------------------------------------------------------

-- | How the owner's settlements reach Lua: an owner on elapsed time, or one on logical time.
data Timing = OnArrival | AtAssignedTick
  deriving (Eq, Show)

-- | One VM: its owner, its service and its byte bank.
data Vm = Vm
  { vmOwner ∷ !ScheduledOwner
  , vmService ∷ !DataService
  , vmBank ∷ !ByteBank
  }

requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaengine.data") (\_ → pure Unrecognized)

handleType ∷ Text
handleType = "dreq"

-- | A VM over the session's pool: its own byte bank (the profile's per-VM limit) and handle
-- registry, one owner on this timing. The pool and its workers are the session's.
startVm ∷ Session → LuaRuntime → Text → Timing → IO Vm
startVm session runtime label timing = do
  handles ← newRequestHandles
  requests ← either (\refused → assertFailure ("the profile was refused: " <> show refused)) pure (m1Requests (ssProfile session) handles)
  bank ← newByteBankFor (ssProfile session)
  service ← either (\refused → assertFailure ("the service was refused: " <> show refused)) pure (dataService requests (ssInventory session) (ssPool session) bank)
  let registered =
        either (error . ("registration refused: " <>) . show) id $
          registration [admittedHandleType handles handleType] (bindings session service requests)
      Bytes copied = bytesLimit (ssProfile session) CopiedValueBytes
      Count depth = countLimit (ssProfile session) CopiedValueDepth
      Count elements = countLimit (ssProfile session) CopiedValueElements
      limits = either (error . show) id (valueLimits (fromIntegral copied) (fromIntegral depth) (fromIntegral elements))
      vm =
        (vmConfig [LibraryBase, LibraryString, LibraryTable, LibraryMath])
          { vmRegistration = registered
          , vmPolicy = ["fx", "request", "data"]
          , vmOwnerName = label
          , vmModules = [driverSource]
          , vmValueLimits = limits
          }
      grant =
        RequestGrant
          [dataEndpoint service]
          64
          (if timing == OnArrival then SettleOnArrival else SettleAtAssignedTick Nothing)
      spec =
        (scheduledSpec vm requiredPolicy bounds)
          { scheduledInstances = Just (defaultInstanceConfig {instanceBounds = InstanceBounds 8 16 8 8, instanceSources = [commandSource]})
          , scheduledRequestHandles = Just handles
          , scheduledRequests = Just grant
          }
  startScheduledOwner runtime spec >>= \case
    ScheduledStarted owner → pure (Vm owner service bank)
    other → assertFailure ("expected an owner, found " <> take 80 (showStart other))
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

-- | The bindings: @fx.record@ and @fx.block@, the common operations from the adapter, and
-- @data.fetch(path [, offset [, optional]])@, written the way the facade will write it from
-- "Hetoimasia.LuaEngine.Data". This is the example's own scaffolding, not an API of the engine.
bindings ∷ Session → DataService → M1Requests → [Namespace]
bindings session service requests =
  [ namespace "fx" [recording, blocking]
  , namespace "request" (m1RequestBindings (M1Service handleType dataValueSchema))
  , namespace "data" [fetching]
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
        asynchronousNativeRequestIn "fetch" [SText, SOptional SInteger, SOptional SBoolean] (m1StartSchemas handleType) $ \context values →
          case requestFrom service values of
            Left why → throwIO (userError (Text.unpack why))
            Right asked → do
              started ← startData service asked context (note session "disposed")
              pure (m1StartResults handleType started)
    -- The facade's job: the checked address is a permanent argument error, then the host's own
    -- permanent refusals, each before anything is reserved.
    check owner values = case requestFrom service values of
      Left why → pure (Just why)
      Right asked → dataArgumentCheck service (const asked) owner values
    _ = requests

-- | The request a binding's copied arguments name.
requestFrom ∷ DataService → [Value] → Either Text DataRequest
requestFrom service = \case
  VText path : rest → do
    key <- either (\refused → Left ("address refused: " <> Text.pack (show refused))) Right (dataKey service (Text.encodeUtf8 path))
    let offset = case rest of
          VInteger given : _ → Just (offsetFromLua given)
          _ → Nothing
        optional = case rest of
          [_, VBoolean flag] → flag
          _ → False
    Right (DataRequest key (if optional then OptionalRequest else RequiredRequest) offset)
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

-- | Wait until a script is inside the call that holds this gate.
awaitGate ∷ Session → Text → IO ()
awaitGate session name = gateIn (ssEntered session) name >>= readMVar

-- | The Lua the commands run. A string is shown as its length and its first bytes in hex, so
-- NUL and invalid UTF-8 are exact; a table is shown with its keys in order.
driverSource ∷ ModuleSource
driverSource =
  ModuleSource (ModuleRef "driver" "1") (Text.encodeUtf8 (Text.unlines source)) hookEntries
  where
    source =
      [ "local function hex(s, n)"
      , "  local out = {}"
      , "  for i = 1, math.min(#s, n) do out[#out + 1] = string.format('%02x', s:byte(i)) end"
      , "  return table.concat(out)"
      , "end"
      , "local function fmt(v)"
      , "  local t = type(v)"
      , "  if t == 'string' then return v end"
      , "  if t ~= 'table' then"
      , "    if t == 'userdata' or t == 'function' then return '<' .. t .. '>' end"
      , "    return tostring(v)"
      , "  end"
      , "  local keys = {}"
      , "  for k in pairs(v) do keys[#keys + 1] = tostring(k) end"
      , "  table.sort(keys)"
      , "  local out = {}"
      , "  for _, k in ipairs(keys) do"
      , "    local x = v[k]"
      , "    if k == 'value' and type(x) == 'string' then out[#out + 1] = k .. '=bytes(' .. #x .. ')=' .. hex(x, 24)"
      , "    else out[#out + 1] = k .. '=' .. fmt(x) end"
      , "  end"
      , "  return '{' .. table.concat(out, ',') .. '}'"
      , "end"
      , "local function run(self, p)"
      , "  local key = p.key or 'a'"
      , "  local out = '?'"
      , "  if p.op == 'start' then"
      , "    local r, err = data.fetch(p.path or 'a.bin', p.offset, p.optional)"
      , "    if r then self.hs[key] = r out = 'started' else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'pstart' then"
      , "    local ok, r, err = pcall(data.fetch, p.path or 'a.bin', p.offset, p.optional)"
      , "    if not ok then out = 'error ' .. tostring(r)"
      , "    elseif r then self.hs[key] = r out = 'started'"
      , "    else out = 'busy:' .. err.code .. ':' .. err.message end"
      , "  elseif p.op == 'ready' then out = tostring(request.ready(self.hs[key]))"
      , "  elseif p.op == 'take' then out = fmt(request.take(self.hs[key]))"
      , "  elseif p.op == 'ptake' then"
      , "    local ok, r = pcall(request.take, self.hs[key])"
      , "    if ok then out = fmt(r) else out = 'error ' .. tostring(r) end"
      , "  elseif p.op == 'keep' then"
      , "    local r = request.take(self.hs[key])"
      , "    self.kept = r.value"
      , "    out = fmt(r)"
      , "  elseif p.op == 'kept' then out = 'bytes(' .. #self.kept .. ')=' .. hex(self.kept, 24)"
      , "  elseif p.op == 'cancel' then out = request.cancel(self.hs[key])"
      , "  elseif p.op == 'wait' then"
      , "    fx.record('waiting ' .. key)"
      , "    out = tostring(select('#', request.wait(self.hs[key])))"
      , "  elseif p.op == 'wait_take' then"
      , "    fx.record('waiting ' .. key)"
      , "    request.wait(self.hs[key])"
      , "    out = fmt(request.take(self.hs[key]))"
      , "  elseif p.op == 'length' then"
      , "    local r = request.take(self.hs[key])"
      , "    out = r.status .. ' ' .. #r.value .. ' ' .. hex(r.value, 4) .. ' ' .. hex(r.value:sub(-4), 4)"
      , "  elseif p.op == 'block' then fx.block(key) out = 'released'"
      , "  end"
      , "  local tag = ''"
      , "  if p.path and p.op ~= 'start' and p.op ~= 'pstart' then tag = ' #' .. p.path end"
      , "  fx.record(self.name .. ' ' .. p.op .. ' ' .. key .. ' ' .. out .. tag)"
      , "end"
      , "function init(self, api)"
      , "  self.hs = {}"
      , "  self.name = 'cmd'"
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
        , ("key", SOptional SText)
        , ("path", SOptional SText)
        , ("offset", SOptional SInteger)
        , ("optional", SOptional SBoolean)
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
  , fetchOptional ∷ !Bool
  }

-- | A required fetch of this path with the default offset.
fetch ∷ Text → Fetch
fetch path = Fetch path Nothing False

-- | Tell the instance of this name to do this with the request it keeps under the key.
command ∷ Session → Vm → Text → Text → Text → IO ()
command session vm name op key = commandWith session vm name op key Nothing

-- | The same, with what to fetch when the command starts a request.
commandWith ∷ Session → Vm → Text → Text → Text → Maybe Fetch → IO ()
commandWith session vm name op key asked = do
  identity ← (Map.! name) <$> readIORef (ssIds session)
  let payload =
        VRecord $
          [("op", VText op), ("key", VText key)]
            <> concat
              [ [("path", VText (fetchPath found))]
                  <> [("offset", VInteger (fromIntegral offset)) | Just offset ← [fetchOffset found]]
                  <> [("optional", VBoolean True) | fetchOptional found]
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

-- | What the VM's bank is charged now.
charged ∷ Vm → IO Word64
charged vm = atomically (byteBankCharged (vmBank vm))

-- | Block until the VM's bank is charged exactly this.
awaitCharged ∷ Vm → Word64 → IO ()
awaitCharged vm wanted = atomically $ do
  now ← byteBankCharged (vmBank vm)
  unless (now == wanted) retry

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

-- | The pool, read in one transaction.
poolReading ∷ Session → IO PoolStatus
poolReading session = atomically (status (ssPool session))

-- | Block until the pool reads like this.
awaitPool ∷ Session → (PoolStatus → Bool) → IO ()
awaitPool session wanted = atomically $ do
  reading ← status (ssPool session)
  unless (wanted reading) retry
