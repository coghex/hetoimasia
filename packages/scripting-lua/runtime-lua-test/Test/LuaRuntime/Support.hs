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
  , withBoundaryOpening
  , quietLogger
  , recordingLogger
  , expectFatal
  , tryBoundaryOpening
  , tryExpected
  , alongsideOpening
  , expectFatalOpening
  , bounded
  , boundedAfter
    -- * The fixture
  , Fixture (..)
  , newFixture
  , Gated (..)
  , gateIn
  , openGatesIn
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

import Control.Concurrent (ThreadId, forkIO, killThread, myThreadId, throwTo, yield)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, readMVar, tryPutMVar, tryReadMVar, tryTakeMVar)
import Control.Concurrent.STM (retry)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , Exception
  , ExceptionWithContext (ExceptionWithContext)
  , SomeException
  , bracket_
  , finally
  , fromException
  , onException
  , throw
  , throwIO
  , try
  , tryWithContext
  )
import Control.Monad (void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Maybe (isJust)
import Data.Unique (Unique, newUnique)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import GHC.Conc (BlockReason (BlockedOnSTM), ThreadStatus (ThreadBlocked), threadStatus)
import Hetoimasia.Foundation.Log
  ( LogEntry
  , Logger
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
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (Timeout, timeout)
import Test.HUnit.Lang (HUnitFailure)
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

-- | A logger that keeps every entry it is handed, newest first.
recordingLogger ∷ IORef [LogEntry] → Logger
recordingLogger entries = mkLoggerWith defaultLogFilter fixedMetadata (callbackSink (\entry → atomicModifyIORef' entries (\held → (entry : held, ()))))

-- | A real supervision boundary over a real worker group, with a runtime
-- boundary for the owners an example creates.
withBoundary ∷ (RuntimeControl → LuaRuntime → IO a) → IO a
withBoundary body =
  withLoggingLifetime quietLogger $ \lifetime →
    withSupervision lifetime $ \control → newLuaRuntime control >>= body control

-- | 'withBoundary' for an example that holds a callback at a gate. The openers, which let
-- every gate of the fixtures the example holds callbacks at go on, run if the body ends
-- by raising anything (a failed assertion, say), and when the example's 'bounded' limit
-- expires; so they run inside the body and before control leaves the supervised
-- boundary, whose protected teardown waits for the callback a held gate holds. The body
-- that returns is left as it is: it has let its own gates go.
withBoundaryOpening ∷ [IO ()] → (RuntimeControl → LuaRuntime → IO a) → IO a
withBoundaryOpening openers body =
  openedAtBound openers . withBoundary $ \control runtime →
    body control runtime `onException` sequence_ openers

-- | What the example running on each thread holds callbacks at: the openers its bound runs.
{-# NOINLINE openersAtBound #-}
openersAtBound ∷ IORef [(ThreadId, Unique, [IO ()])]
openersAtBound = unsafePerformIO (newIORef [])

-- | Run the action with these openers registered for the 'bounded' limit of the example
-- running on this thread. An exception the limit throws cannot always end the example at
-- once: its thread may be inside a protected wait for the very callbacks a held gate holds,
-- as the script runner's retirement is, and no exception ends that.
openedAtBound ∷ [IO ()] → IO a → IO a
openedAtBound openers action = do
  example ← myThreadId
  token ← newUnique
  bracket_
    (atomicModifyIORef' openersAtBound (\held → ((example, token, openers) : held, ())))
    (atomicModifyIORef' openersAtBound (\held → ([entry | entry@(_, other, _) ← held, other /= token], ())))
    action

-- | Run a boundary that is expected to fail, answering the failure it ended
-- with and keeping its context.
expectFatal ∷ (RuntimeControl → LuaRuntime → IO a) → IO (ExceptionWithContext SomeException)
expectFatal body =
  tryWithContext (withBoundary body) >>= \case
    Left failure → pure failure
    Right _ → throwIO (userError "expected the boundary to fail, but it returned")

-- | Run a boundary that may end in a failure of the application's own, answering how
-- it ended, as 'withBoundaryOpening' lets the gates go. What it may fail with is the
-- application's own failure: a failed assertion of the example, or the example's
-- 'bounded' timeout, is never taken for it, and is raised as itself.
tryBoundaryOpening ∷ [IO ()] → (RuntimeControl → LuaRuntime → IO a) → IO (Either (ExceptionWithContext SomeException) a)
tryBoundaryOpening openers body = tryExpected (withBoundaryOpening openers body)

-- | Run an action that is expected to fail with a failure of the application's own, answering
-- how it ended and keeping its context. A failed assertion of the example, or the example's
-- 'bounded' timeout, is not that failure: it is raised as itself, and an example that expects
-- a failure cannot swallow what makes it fail.
tryExpected ∷ IO a → IO (Either (ExceptionWithContext SomeException) a)
tryExpected action =
  tryWithContext action >>= \case
    Left (ExceptionWithContext _ failure)
      | Just (_ ∷ HUnitFailure) ← fromException failure → throwIO failure
      | Just (_ ∷ Timeout) ← fromException failure → throwIO failure
    outcome → pure outcome

-- | 'expectFatal' for an example that holds a callback at a gate, with the gates let
-- go and the failures of the example raised as 'tryBoundaryOpening' does.
expectFatalOpening ∷ [IO ()] → (RuntimeControl → LuaRuntime → IO a) → IO (ExceptionWithContext SomeException)
expectFatalOpening openers body =
  tryBoundaryOpening openers body >>= \case
    Left failure → pure failure
    Right _ → throwIO (userError "expected the boundary to fail, but it returned")

-- | Run the helper on a thread of its own while the other action runs on this one, and
-- answer the other's result. The helper is stopped when the other action is over,
-- whatever it was waiting for. A helper that fails (a failed assertion, say) lets
-- these gates go on, and then raises its failure in the thread of the other action,
-- which is parked in a wait that depends on what the helper was to do and that no gate
-- opening would end; and the helper's failure, not what the other action made of it,
-- is what the example fails with.
alongsideOpening ∷ [IO ()] → IO () → IO a → IO a
alongsideOpening openers helper main' = do
  example ← myThreadId
  failed ← newEmptyMVar
  thread ← forkIO $
    try @SomeException helper >>= \case
      Left failure | fromException failure /= Just ThreadKilled → do
        putMVar failed failure
        sequence_ openers
        throwTo example failure
      _ → pure ()
  outcome ← try @SomeException main'
  killThread thread
  tryTakeMVar failed >>= \case
    Just failure → throwIO failure
    Nothing → either throwIO pure outcome

-- | Stop an example that has already hung. Never a concurrency assertion. As the limit
-- expires, the gates the example registered with 'withBoundaryOpening' are opened from a
-- thread of their own: an example parked in a protected wait for a held callback cannot
-- do it for itself, and the exception that interrupts it does not end that wait. The
-- expiry is recorded before they are opened, and an example that returns once they are
-- open has still not finished within its bound.
bounded ∷ Expectation → Expectation
bounded = boundedAfter exampleBound exampleBound

-- | 'bounded' with the time its gates are opened at apart from the limit the example is
-- interrupted at, so that the examples of the helper itself can have the gates opened first.
boundedAfter ∷ Int → Int → Expectation → Expectation
boundedAfter openAfter limit action = do
  example ← myThreadId
  finished ← newEmptyMVar
  expired ← newIORef False
  _ ← forkIO (timeout openAfter (readMVar finished) >>= maybe (atomicWriteIORef expired True >> openAtBound example) pure)
  outcome ← timeout limit action `finally` putMVar finished ()
  opened ← readIORef expired
  case outcome of
    Just () | not opened → pure ()
    _ → expectationFailure "the example did not finish within its bound"
  where
    openAtBound example = do
      held ← readIORef openersAtBound
      sequence_ (concat [openers | (thread, _, openers) ← held, thread == example])

-- | How long an example may run, in microseconds.
exampleBound ∷ Int
exampleBound = 60 * 1000 * 1000

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

-- | The gate of this name, made when first asked for: open at once if the table's
-- gates have all been let go ('openGatesIn'), as a callback that arrives at a gate
-- nobody has named yet is let through too.
gateIn ∷ IORef (Map Text (MVar ())) → Text → IO (MVar ())
gateIn table name = do
  fresh ← newEmptyMVar
  open ← newMVar ()
  atomicModifyIORef' table $ \held → case Map.lookup name held of
    Just existing → (held, existing)
    Nothing
      | Map.member allOpen held → (Map.insert name open held, open)
      | otherwise → (Map.insert name fresh held, fresh)

-- | The mark a table of gates carries once all of them are open. No gate has this name.
allOpen ∷ Text
allOpen = "\0all open"

-- | Let every gate of this table go on, the ones made so far and the ones made later.
openGatesIn ∷ IORef (Map Text (MVar ())) → IO ()
openGatesIn table = do
  mark ← newMVar ()
  held ← atomicModifyIORef' table (\gates → (Map.insert allOpen mark gates, gates))
  mapM_ (void . (`tryPutMVar` ())) held

-- | A fixture that holds callbacks at gates.
class Gated a where
  -- | Let every gate go on, now and for good. Harmless twice, as 'releaseGate' is.
  openAllGates ∷ a → IO ()

instance Gated Fixture where
  openAllGates = openGatesIn . fixtureGates

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
