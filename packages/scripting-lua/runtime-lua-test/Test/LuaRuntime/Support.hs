-- | What the runtime adapter's examples share: a real supervision boundary, a
-- registration whose bindings are fixtures, and the coordination the examples
-- use instead of sleeping.
--
-- Every fixture hands its caller fresh state. A gate is an 'MVar' a binding
-- waits on, and each gate has a twin that the binding opens as it is reached, so
-- an example knows a call is inside a binding by waiting for the twin and not by
-- guessing how long it takes.
module Test.LuaRuntime.Support
  ( -- * Failures
    Broken (..)
  , brokenIs
    -- * The boundary
  , withBoundary
  , quietLogger
  , expectFatal
  , bounded
    -- * The fixture
  , Fixture (..)
  , newFixture
  , releaseGate
  , awaitEntered
  , hasEntered
  , attemptWait
  , gate
  , applicationFault
  , applicationBoundaryFault
  , noted
  , note
    -- * Configurations
  , theModule
  , sampleRegistration
  , ownerSpec
  , quickSpec
  , requiredPolicy
  , optionalPolicy
  , bounds
  , sampleModule
  , moduleEntries
  , gcInitChunk
  , libraries
    -- * Coordination
  , awaitBlockedOnSTM
  , withModules
  , withChunks
  , failureOf
    -- * Creating and calling
  , expectOwner
  , startOwner
  , submit
  , accepted
  , settle
  , settleOutcome
  , awaitTerminal
  , awaitFatal
    -- * Reading outcomes
  , returnedValues
  , isDiscard
  ) where

import Control.Concurrent (ThreadId, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM (retry)
import Control.Exception
  ( Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , fromException
  , throw
  , throwIO
  , tryWithContext
  )
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Log
  ( Logger
  , MetadataProviders (..)
  , callbackSink
  , defaultLogFilter
  , mkLoggerWith
  , unsafeComponent
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Runtime.Supervision
  ( Recognition (Recognized, Unrecognized)
  , Role (Service)
  , RuntimeControl
  , WorkerPolicy (..)
  , WorkerStatus (WorkerLive)
  , awaitSupervised
  , withSupervision
  )
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (UTCTime), secondsToDiffTime)
import qualified Hetoimasia.Runtime.Supervision as Supervision
import Hetoimasia.Scripting.Lua.Internal.Value (VmIdentity (VmIdentity))
import Hetoimasia.Scripting.Lua.Owner
import Hetoimasia.Scripting.Lua.Registration
import Hetoimasia.Scripting.Lua.Runtime
import Hetoimasia.Scripting.Lua.Value
import System.Timeout (timeout)
import Test.Hspec (Expectation, expectationFailure)

-- Failures ---------------------------------------------------------------------

-- | A typed synthetic failure of the application's own code.
newtype Broken = Broken Text
  deriving (Eq, Show)

instance Exception Broken

brokenIs ∷ Text → SomeException → Bool
brokenIs expected failure = fromException failure == Just (Broken expected)

-- The boundary -----------------------------------------------------------------

fixedMetadata ∷ MetadataProviders
fixedMetadata =
  MetadataProviders
    { metadataClock = pure (UTCTime (fromGregorian 2026 10 16) (secondsToDiffTime 43200))
    , metadataThread = pure "1"
    }

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter fixedMetadata (callbackSink (\_ → pure ()))

-- | A real supervision boundary over a real worker group, with a runtime
-- boundary for the owners an example creates.
withBoundary ∷ (RuntimeControl → LuaRuntime → IO a) → IO a
withBoundary body =
  withLoggingLifetime quietLogger $ \lifetime →
    withSupervision lifetime $ \control → newLuaRuntime control >>= body control

-- | Run a boundary that is expected to fail, answering the failure it ended
-- with and keeping its context.
expectFatal ∷ (RuntimeControl → LuaRuntime → IO a) → IO (ExceptionWithContext SomeException)
expectFatal body =
  tryWithContext (withBoundary body) >>= \case
    Left failure → pure failure
    Right _ → throwIO (userError "expected the boundary to fail, but it returned")

-- | Stop an example that has already hung. Never a concurrency assertion.
bounded ∷ Expectation → Expectation
bounded action =
  timeout (60 * 1000 * 1000) action
    >>= maybe (expectationFailure "the example did not finish within its bound") pure

-- The fixture ------------------------------------------------------------------

-- | What the bindings observe and share.
data Fixture = Fixture
  { fixtureLog ∷ !(IORef [Text])
  , fixtureGates ∷ !(IORef (Map Text (MVar ())))
  , fixtureEntered ∷ !(IORef (Map Text (MVar ())))
  , fixtureEndpoints ∷ !(IORef (Map Text OwnerEndpoint))
  , fixtureTickets ∷ !(IORef (Map Text CallTicket))
  , fixturePrebuilt ∷ !(IORef (IO ()))
    -- ^ A wait built outside any callback, which @app.run_prebuilt@ runs.
  , fixtureControl ∷ !(IORef (Maybe RuntimeControl))
  , fixtureRuntime ∷ !(IORef (Maybe LuaRuntime))
  , fixtureLiveCheck ∷ !(IORef (IO ()))
    -- ^ What the application's own liveness check does before it answers.
  , fixtureProbe ∷ !(IORef [Text])
    -- ^ What the fixture's attempts to wait were answered with.
  , fixtureLiveFault ∷ !(IORef (Maybe BoundaryFault))
    -- ^ A fault the application's liveness check hides in a lazy answer.
  }

newFixture ∷ IO Fixture
newFixture =
  Fixture
    <$> newIORef []
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef Map.empty
    <*> newIORef (pure ())
    <*> newIORef Nothing
    <*> newIORef Nothing
    <*> newIORef (pure ())
    <*> newIORef []
    <*> newIORef Nothing

-- | The gate of this name, made when first asked for.
gateIn ∷ IORef (Map Text (MVar ())) → Text → IO (MVar ())
gateIn table name = do
  fresh ← newEmptyMVar
  atomicModifyIORef' table $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing → (Map.insert name fresh held, fresh)

gate ∷ Fixture → Text → IO (MVar ())
gate fixture = gateIn (fixtureGates fixture)

-- | Let the binding waiting on this gate go on. Harmless twice.
releaseGate ∷ Fixture → Text → IO ()
releaseGate fixture name = gate fixture name >>= void . (`tryPutMVar` ())

-- | Wait until a binding has reached this gate.
awaitEntered ∷ Fixture → Text → IO ()
awaitEntered fixture name = gateIn (fixtureEntered fixture) name >>= readMVar

-- | Whether a binding has reached this gate, without waiting for it to.
hasEntered ∷ Fixture → Text → IO Bool
hasEntered fixture name = gateIn (fixtureEntered fixture) name >>= fmap isJust . tryReadMVar

enter ∷ Fixture → Text → IO ()
enter fixture name = gateIn (fixtureEntered fixture) name >>= void . (`tryPutMVar` ())

-- | Wait on a gate, after saying it was reached.
blockOn ∷ Fixture → Text → IO ()
blockOn fixture name = enter fixture name >> gate fixture name >>= readMVar

note ∷ Fixture → Text → IO ()
note fixture entry = atomicModifyIORef' (fixtureLog fixture) (\held → (entry : held, ()))

-- | What the bindings noted, oldest first.
noted ∷ Fixture → IO [Text]
noted fixture = reverse <$> readIORef (fixtureLog fixture)

-- | A boundary fault of the application's own making, which its binding throws.
applicationBoundaryFault ∷ BoundaryFault
applicationBoundaryFault = applicationFault "application"

-- | A boundary fault of the application's own making, naming this chunk.
applicationFault ∷ Text → BoundaryFault
applicationFault chunk =
  BoundaryFault
    { boundaryOwner = "the application"
    , boundaryVm = VmIdentity 0
    , boundaryOperation = CallEntry
    , boundaryModule = Nothing
    , boundaryEntry = Nothing
    , boundaryBinding = Nothing
    , boundaryChunk = chunk
    , boundaryReason = InternalError "thrown by the application"
    , boundaryEffect = NoEffect
    , boundaryTraceback = Nothing
    }

-- Registration -----------------------------------------------------------------

ok ∷ Either RegistrationRefusal a → a
ok = either (error . ("registration refused: " <>) . show) id

-- | The registration the examples share. @app@ holds the bindings that are
-- fixtures for what the adapter does around them; @extra@ is a namespace an
-- owner may or may not be granted.
sampleRegistration ∷ Fixture → Registration
sampleRegistration fixture = ok (registration [capabilityType "ticket" alive] [app, extra])
  where
    alive _ = do
      check ← readIORef (fixtureLiveCheck fixture)
      check
      hidden ← readIORef (fixtureLiveFault fixture)
      -- Lazy on purpose: a fault hidden in the answer surfaces when it is read.
      pure (maybe True throw hidden)
    app =
      namespace
        "app"
        [ stateOperation "note" [SText] [] $ \arguments → do
            case arguments of
              [VText text] → note fixture text
              _ → pure ()
            pure []
        , stateOperation "block" [SText] [] $ \arguments → do
            case arguments of
              [VText name] → blockOn fixture name
              _ → pure ()
            pure []
        , stateOperation "fail" [SText] [] $ \arguments → do
            case arguments of
              [VText "boundary"] → throwIO applicationBoundaryFault
              [VText "lua"] → throwIO (LuaFault CallFailed "application" ErrorAbsent)
              [VText kind] → throwIO (Broken kind)
              _ → pure ()
            pure []
        , stateOperation "fail_lazy" [SText] [SInteger] $ \arguments → case arguments of
            -- The failure is hidden in the result, and surfaces when it is read.
            [VText "boundary"] → pure [VInteger (throw applicationBoundaryFault)]
            [VText "lua"] → pure [VInteger (throw (LuaFault CallFailed "application" ErrorAbsent))]
            _ → pure [VInteger 0]
        , stateOperation "submit" [SText, SInteger] [SInteger] $ \arguments →
            case arguments of
              [VText label, VInteger n] → do
                found ← Map.lookup label <$> readIORef (fixtureEndpoints fixture)
                case found of
                  Nothing → pure [VInteger 9]
                  Just endpoint →
                    submitCall endpoint theModule "echo" [VInteger n] >>= \case
                      CallAccepted ticket → do
                        atomicModifyIORef' (fixtureTickets fixture) (\held → (Map.insert label ticket held, ()))
                        pure [VInteger 0]
                      CallFull → pure [VInteger 1]
                      CallClosed → pure [VInteger 2]
              _ → pure []
        , stateOperation "wait" [SText] [SBoolean] $ \arguments →
            case arguments of
              [VText label] → do
                found ← Map.lookup label <$> readIORef (fixtureTickets fixture)
                case found of
                  Nothing → pure [VBoolean False]
                  Just ticket → do
                    refused ← refusal (void (waitCall ticket))
                    pure [VBoolean refused]
              _ → pure []
        , stateOperation "await" [SText] [SBoolean] $ \arguments →
            case arguments of
              [VText label] → do
                found ← Map.lookup label <$> readIORef (fixtureTickets fixture)
                control ← readIORef (fixtureControl fixture)
                case (found, control) of
                  (Just ticket, Just supervision) → do
                    refused ← refusal (void (awaitCall supervision ticket))
                    pure [VBoolean refused]
                  _ → pure [VBoolean False]
              _ → pure []
        , stateOperation "run_prebuilt" [] [SBoolean] $ \_ → do
            action ← readIORef (fixturePrebuilt fixture)
            refused ← refusal action
            pure [VBoolean refused]
        , stateOperation "make_owner" [] [SBoolean] $ \_ → do
            runtime ← readIORef (fixtureRuntime fixture)
            case runtime of
              Nothing → pure [VBoolean False]
              Just found → do
                refused ← refusal (void (startLuaOwner found (quickSpec fixture "made" [])))
                pure [VBoolean refused]
        , lifecycleOperation "lifecycle" [] [] (\_ → note fixture "lifecycle: ran" >> pure [])
        , finalizerEligible . stateOperation "gc" [SText] [] $ \arguments → do
            case arguments of
              [VText name] → note fixture ("gc " <> name) >> enter fixture name
              _ → pure ()
            pure []
        , finalizerEligible . stateOperation "gc_fail" [] [] $ \_ → throwIO (Broken "gc")
        , finalizerEligible . stateOperation "gc_block" [SText] [] $ \arguments → do
            case arguments of
              [VText name] → blockOn fixture name
              _ → pure ()
            pure []
        ]
    extra =
      namespace
        "extra"
        [ snapshotQuery "ping" [] [SText] (\_ → pure [VText "pong"])
        , stateOperation "fail" [SText] [] $ \arguments → case arguments of
            [VText kind] → throwIO (Broken kind)
            _ → pure []
        ]
    refusal = attemptWait fixture

-- | Run a wait, answering whether it was refused with the typed refusal and
-- recording what it was answered with. Anything else it raises is let through,
-- so a hang or another failure fails the example.
attemptWait ∷ Fixture → IO () → IO Bool
attemptWait fixture action = do
  outcome ← tryWithContext action
  case outcome of
    Right () → do
      atomicModifyIORef' (fixtureProbe fixture) (\held → ("waited" : held, ()))
      pure False
    Left (ExceptionWithContext _ failure) → case fromException failure of
      Just (CallbackWaitRefused name) → do
        atomicModifyIORef' (fixtureProbe fixture) (\held → (name : held, ()))
        pure True
      Nothing → throwIO failure

-- The module -------------------------------------------------------------------

-- | The identity of the module every owner loads.
theModule ∷ ModuleRef
theModule = ModuleRef "mod" "1"

required ∷ Text → [Schema] → [Schema] → EntryPoint
required name = EntryPoint name Required

moduleEntries ∷ [EntryPoint]
moduleEntries =
  [ required "add" [SInteger, SInteger] [SInteger]
  , required "echo" [SInteger] [SInteger]
  , required "boom" [] []
  , required "note" [SText] []
  , required "block_call" [SText] [SInteger]
  , required "block_then_fail" [SText, SText] []
  , required "host_fail" [SText] []
  , required "catch_then_call" [SText] []
  , required "fail_lazy" [SText] [SInteger]
  , required "swallow_then_fail" [SText] []
  , required "lifecycle" [] []
  , required "submit_to" [SText, SInteger] [SInteger]
  , required "wait_for" [SText] [SBoolean]
  , required "await_for" [SText] [SBoolean]
  , required "run_prebuilt" [] [SBoolean]
  , required "redeem" [SCapability "ticket"] [SInteger]
  , required "namespaces" [] [SText]
  , required "extra_fail" [SText] []
  , required "make_owner" [] [SBoolean]
  , EntryPoint "absent" Optional [] []
  ]

moduleSource ∷ ByteString
moduleSource =
  Text.encodeUtf8 . Text.unlines $
    [ "function add(a, b) return a + b end"
    , "function echo(n) return n end"
    , "function boom() error('script boom') end"
    , "function note(t) app.note(t) end"
    , "function block_call(name) app.block(name) return 1 end"
    , "function block_then_fail(name, kind) app.block(name) app.fail(kind) end"
    , "function host_fail(kind) app.fail(kind) end"
    , "function catch_then_call(kind) pcall(app.fail, kind) app.note('after') end"
    , "function fail_lazy(kind) return app.fail_lazy(kind) end"
    , "function swallow_then_fail(kind) pcall(app.note, 5) app.fail(kind) end"
    , "function lifecycle() app.lifecycle() end"
    , "function submit_to(label, n) return app.submit(label, n) end"
    , "function wait_for(label) return app.wait(label) end"
    , "function await_for(label) return app.await(label) end"
    , "function run_prebuilt() return app.run_prebuilt() end"
    , "function redeem(c) return 1 end"
    , "function make_owner() return app.make_owner() end"
    , "function extra_fail(kind) extra.fail(kind) end"
    , "function namespaces()"
    , "  local found = {}"
    , "  if app ~= nil then found[#found + 1] = 'app' end"
    , "  if extra ~= nil then found[#found + 1] = 'extra' end"
    , "  return table.concat(found, ',')"
    , "end"
    ]

-- | The module every owner of the examples loads.
sampleModule ∷ ModuleSource
sampleModule = ModuleSource theModule moduleSource moduleEntries

libraries ∷ [Library]
libraries = [LibraryBase, LibraryString, LibraryTable, LibraryMath]

-- | An initial chunk that leaves an object whose finalizer says, when the VM
-- closes, that it did: the evidence that the VM was closed, and when. Automatic
-- collection is stopped first, so nothing else runs the finalizer.
gcInitChunk ∷ Text → (ChunkName, ByteString)
gcInitChunk name =
  ( chunkName "gc-init"
  , Text.encodeUtf8 ("collectgarbage('stop') holder = setmetatable({}, {__gc = function() app.gc('" <> name <> "') end})")
  )

-- Configurations ---------------------------------------------------------------

bounds ∷ Int → Int → CallBounds
bounds = CallBounds

-- | An owner of this label granted these namespaces of the sample registration,
-- loading the sample module.
ownerSpec ∷ Fixture → Text → [Text] → WorkerPolicy → CallBounds → OwnerSpec
ownerSpec fixture label granted policy callBounds =
  OwnerSpec
    { ownerVm =
        (vmConfig libraries)
          { vmRegistration = sampleRegistration fixture
          , vmPolicy = granted
          , vmOwnerName = label
          , vmModules = [sampleModule]
          }
    , ownerPolicy = policy
    , ownerBounds = callBounds
    }

-- | A required owner of generous bounds, granted these namespaces.
quickSpec ∷ Fixture → Text → [Text] → OwnerSpec
quickSpec fixture label granted = ownerSpec fixture label granted requiredPolicy (bounds 64 64)

-- | A required worker whose component recognizes nothing.
requiredPolicy ∷ WorkerPolicy
requiredPolicy = WorkerPolicy Service Supervision.Required (unsafeComponent "test.luaruntime") (\_ → pure Unrecognized)

-- | An optional worker whose component recognizes the failures this says it
-- does.
optionalPolicy ∷ (SomeException → Bool) → WorkerPolicy
optionalPolicy recognizes =
  WorkerPolicy Service Supervision.Optional (unsafeComponent "test.luaruntime") $ \(ExceptionWithContext _ failure) →
    pure (if recognizes failure then Recognized else Unrecognized)

-- Creating and calling ---------------------------------------------------------

expectOwner ∷ OwnerStart → IO LuaOwner
expectOwner = \case
  OwnerStarted owner → pure owner
  OwnerUnavailable failure → throwIO (userError ("expected an owner, found it unavailable: " <> show failure))
  OwnerRejected → throwIO (userError "expected an owner, found the boundary closed")
  OwnerEnded → throwIO (userError "expected an owner, found it ended")

-- | Create an owner and expect it to be ready.
startOwner ∷ LuaRuntime → OwnerSpec → IO LuaOwner
startOwner runtime spec = startLuaOwner runtime spec >>= expectOwner

-- | Submit a call of the sample module.
submit ∷ OwnerEndpoint → Text → [Value] → IO Submission
submit endpoint = submitCall endpoint theModule

-- | The ticket of an accepted call; the example fails on any other answer.
accepted ∷ Submission → IO CallTicket
accepted = \case
  CallAccepted ticket → pure ticket
  CallFull → throwIO (userError "expected the call to be accepted, found it full")
  CallClosed → throwIO (userError "expected the call to be accepted, found it closed")

-- | Wait for a call's settlement.
settle ∷ CallTicket → IO Settlement
settle = waitCall

settleOutcome ∷ CallTicket → IO Outcome
settleOutcome ticket = settledOutcome <$> settle ticket

-- | Wait until the owner's worker has a terminal status committed by
-- supervision, through a supervised wait, and answer it.
awaitTerminal ∷ RuntimeControl → LuaOwner → IO WorkerStatus
awaitTerminal control owner =
  awaitSupervised control $
    ownerStatus owner >>= \case
      WorkerLive → retry
      status → pure status

-- | Wait through supervision for something that is expected to raise the
-- owner's fatal failure.
awaitFatal ∷ RuntimeControl → LuaOwner → IO WorkerStatus
awaitFatal = awaitTerminal

-- Reading outcomes -------------------------------------------------------------

returnedValues ∷ Outcome → Maybe [Value]
returnedValues = \case
  CallReturned (Returned values) → Just values
  _ → Nothing

isDiscard ∷ ExitKind → Progress → Outcome → Bool
isDiscard kind progress = \case
  CallDiscarded discard → discard == Discard kind progress
  _ → False

-- Coordination -----------------------------------------------------------------

-- | Wait until a thread is parked in an STM transaction.
awaitBlockedOnSTM ∷ ThreadId → IO ()
awaitBlockedOnSTM thread =
  threadStatus thread >>= \case
    ThreadBlocked BlockedOnSTM → pure ()
    _ → yield >> awaitBlockedOnSTM thread

-- | The same owner configuration loading these modules.
withModules ∷ [ModuleSource] → OwnerSpec → OwnerSpec
withModules modules spec = spec {ownerVm = (ownerVm spec) {vmModules = modules}}

-- | The same owner configuration running these initial chunks.
withChunks ∷ [(ChunkName, ByteString)] → OwnerSpec → OwnerSpec
withChunks chunks spec = spec {ownerVm = (ownerVm spec) {vmInitialChunks = chunks}}

-- | The exception a failure carries, as the type an example asks for.
failureOf ∷ Exception e ⇒ ExceptionWithContext SomeException → Maybe e
failureOf (ExceptionWithContext _ failure) = fromException failure
