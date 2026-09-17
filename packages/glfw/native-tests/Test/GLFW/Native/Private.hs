-- | Session lifecycles no shared session can host.
--
-- GLFW allows one session per process, and the shared fixture holds that one
-- for the whole run, so entering and leaving sessions in sequence, a forced
-- initialization failure and its rollback, a session over a faulting or tracing
-- native table, a monitor identity carried from one session into the next, and
-- wakes racing a session's termination each need a process of their own. Each example here starts this same
-- executable as a child with 'privateSessionFlag' and a scenario name; the
-- child runs that scenario's checks in order on its own process main thread,
-- prints one line per check, and exits non-zero if any failed. A dry run or a
-- selection that skips these examples starts no child.
--
-- Neither side starts without consent. The parent asks the run's 'Gate' before
-- it starts a child, so an unapproved run refuses the example and launches
-- nothing; the child inherits the parent's environment, so an approved run's
-- consent carries to it and it is never asked again. A child started directly
-- from an unapproved shell reads its own environment and refuses, on stderr
-- with 'refusedExit', before any scenario is looked up or any session entered.
module Test.GLFW.Native.Private
  ( spec
  , privateSessionFlag
  , runScenario

    -- * For the headless regressions
  , launchWith
  , childPlan
  , refusedExit
  , unknownScenarioExit
  ) where

import Control.Concurrent (forkIO, forkOS)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import qualified Control.Concurrent.STM as STM
import Control.Exception (ErrorCall (ErrorCall), SomeException, displayException, fromException, throw, try)
import Control.Monad (unless, when, (>=>))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Foreign.Ptr (nullFunPtr)
import qualified Data.Text as Text
import Hetoimasia.Foundation.Failure
  ( FailureCause (..)
  , FailureEvidence (..)
  , FailureOrigin (..)
  , OperationContext (..)
  , failureEvidence
  , operation
  , operationText
  )
import Hetoimasia.Foundation.Log
  ( callbackSink
  , componentText
  , defaultLogFilter
  , mkLoggerWith
  , systemMetadata
  )
import Hetoimasia.Foundation.Recovery (Disposition (Required))
import Hetoimasia.GLFW.Internal.Attachment (RetirementFact, RollbackOutcome (RollbackSafe), allRetirementFacts)
import qualified Hetoimasia.Runtime.GLFW.Internal as Runtime
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.Foundation.Messaging.Payload (preparedValue)
import Hetoimasia.Foundation.Messaging.Snapshot (observedValue, readSnapshot)
import Hetoimasia.Foundation.Resource (allocComposite, withScoped)
import Hetoimasia.GLFW.Internal.Native
  ( glfwPlatformUnavailable
  , installedMonitorCallbackForCheck
  , pollEventsForCheck
  , productionNative
  , setWindowSizeForCheck
  , waitEventsForCheck
  , wakeCountsForCheck
  )
import Hetoimasia.GLFW.Internal.Monitor (MonitorCallbackStorage (..), MonitorNative (..))
import Hetoimasia.GLFW.Internal.Session (Native (..), WindowCallbacks (..), sessionAssembly)
import Hetoimasia.GLFW.Internal.Window (windowStep)
import Hetoimasia.GLFW.Monitor
import Hetoimasia.GLFW.Session
import Hetoimasia.GLFW.Window
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Process (readProcessWithExitCode)
import Test.GLFW.Native.Consent (Consent, Refusal, refusalMessage)
import Test.GLFW.Native.Support (Gate, admit, hostBackend)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldContain)

-- | The argument that makes this executable a private-session child.
privateSessionFlag ∷ String
privateSessionFlag = "--private-session"

spec ∷ Gate → Spec
spec gate = describe "private sessions in a child process" $ do
  it "enters and leaves real sessions in sequence, fails a forced initialization, and enters again after its rollback" $
    privateScenario gate "session-lifecycle"

  it "rethrows a fault raised inside a real native callback at the owner boundary" $
    privateScenario gate "callback-fault"

  it "detaches the real monitor callback before termination, frees it last, and never resolves an ended session's identity" $
    privateScenario gate "monitor-lifecycle"

  it "lets no production wake enter GLFW once termination begins, with every admitted wake returned before it" $
    privateScenarioReporting gate "wake-teardown"

  it "destroys a real window only after a scripted owner retires through the protected host, and terminates after that" $
    privateScenarioReporting gate "protected-retirement"

privateScenario ∷ Gate → String → IO ()
privateScenario gate = launchWith gate $ \name → do
  executable ← getExecutablePath
  readProcessWithExitCode executable [privateSessionFlag, name] ""

-- | 'privateScenario', printing the child's report of each check, so the run
-- retains the scenario's evidence and not only its verdict.
privateScenarioReporting ∷ Gate → String → IO ()
privateScenarioReporting gate = launchWith gate $ \name → do
  executable ← getExecutablePath
  launched@(_, out, _) ← readProcessWithExitCode executable [privateSessionFlag, name] ""
  putStr out
  hFlush stdout
  pure launched

-- | Run one scenario through a launcher, once the gate admits the run, and
-- check that the child reported every check passed. A refused run raises the
-- refusal on the example's thread and never calls the launcher.
launchWith ∷ Gate → (String → IO (ExitCode, String, String)) → String → IO ()
launchWith gate launch name = do
  _ ← admit gate
  (status, out, err) ← launch name
  unless (status == ExitSuccess) $
    expectationFailure ("the private " <> name <> " process exited " <> show status <> ":\n" <> out <> err)
  out `shouldContain` ("glfw-native-tests " <> name <> ": every check passed")

-- | The child's exit when its own environment carries no consent.
refusedExit ∷ ExitCode
refusedExit = ExitFailure 3

-- | The child's exit for a scenario it does not know.
unknownScenarioExit ∷ ExitCode
unknownScenarioExit = ExitFailure 2

-- | What the child does with its consent and scenario name: exit with a
-- message, or run these checks. Consent is decided before the scenario is
-- looked up, so an unapproved child refuses whatever it was asked for.
childPlan ∷ Either Refusal Consent → String → Either (ExitCode, String) [(String, IO String)]
childPlan consent name = case consent of
  Left refusal → Left (refusedExit, "glfw-native-tests " <> name <> ": " <> refusalMessage refusal)
  Right _ → case lookup name scenarios of
    Nothing → Left (unknownScenarioExit, "glfw-native-tests: unknown private session scenario " <> show name)
    Just checks → Right checks

-- | Run one scenario as the child process, then exit.
runScenario ∷ Either Refusal Consent → String → IO ()
runScenario consent name = case childPlan consent name of
  Left (code, message) → do
    hPutStrLn stderr message
    exitWith code
  Right checks → do
    failures ← newIORef (0 ∷ Int)
    mapM_ (runCheck failures) checks
    count ← readIORef failures
    if count == 0
      then putStrLn ("glfw-native-tests " <> name <> ": every check passed")
      else do
        putStrLn ("glfw-native-tests " <> name <> ": " <> show count <> " check(s) failed")
        exitFailure

scenarios ∷ [(String, [(String, IO String)])]
scenarios =
  [ ( "session-lifecycle"
    , [ ("enters and leaves a real session", enterAndLeave)
      , ("enters a second session after a complete teardown", enterAndLeave)
      , ("observes an initialization error before any event polling", initializationError)
      , ("enters a session after the failed initialization rolled back", enterAndLeave)
      ]
    )
  , ( "callback-fault"
    , [("rethrows a fault raised inside a real native callback at the owner boundary", callbackFault)]
    )
  , ( "monitor-lifecycle"
    , [ ("detaches the installed monitor callback before termination and frees it after the last native call", monitorTeardown)
      , ("never resolves a monitor identity from a completed session in a later session", monitorAcrossSessions)
      ]
    )
  , ( "protected-retirement"
    , [ ( "destroys the window only after the scripted owner certified every retirement fact, and terminates with no native call afterwards"
        , protectedRetirement
        )
      ]
    )
  , ( "wake-teardown"
    , [ ( "workers on bound and unbound threads wake until terminal while their session closes, and none enters GLFW once termination begins"
        , wakeTeardown
        )
      , ("a capability retained from a closed session stays terminal in a later session and never enters GLFW", wakeAcrossSessions)
      ]
    )
  ]

runCheck ∷ IORef Int → (String, IO String) → IO ()
runCheck failures (name, check) = do
  outcome ← try check
  case outcome of
    Right detail → putStrLn ("ok   " <> name <> ": " <> detail)
    Left (failure ∷ SomeException) → do
      modifyIORef' failures (+ 1)
      putStrLn ("FAIL " <> name <> ": " <> displayException failure)
  hFlush stdout

enterAndLeave ∷ IO String
enterAndLeave = do
  (backend, reports) ← withSession defaultSessionConfig $ \session → do
    reports ← takeAsynchronousReports session
    pure (sessionBackend session, reports)
  unless (backend == hostBackend) $
    failCheck ("the session selected " <> show backend <> ", not " <> show hostBackend)
  pure ("backend " <> show backend <> ", asynchronous reports " <> show reports)

-- | A production table whose size callback copies a payload that raises, so the
-- fault is raised inside the model's trampoline while GLFW is calling it.
--
-- Cocoa calls the size callback inside the resize itself; X11 delivers it once
-- the server's configure event arrives. So after the resizing step, later owner
-- boundaries wait for events — returning as soon as one arrives — until the
-- callback has run and its fault is rethrown, within a bound of 'deliveryAttempts'
-- boundaries of at most 'deliveryWaitSeconds' each.
callbackFault ∷ IO String
callbackFault = do
  let faulting =
        productionNative
          { nativeNewWindowCallbacks = \callbacks →
              nativeNewWindowCallbacks
                productionNative
                callbacks
                  { onWindowSize = \_ height →
                      onWindowSize callbacks (throw (ErrorCall "injected size callback fault")) height
                  }
          }
  withScoped (allocComposite (sessionAssembly faulting defaultSessionConfig)) $ \session →
    withWindow session (hiddenTestWindowConfig "faulting" 200 150) $ \window → do
      let resize =
            windowStep window (operation "resize for check") $ \handle → do
              setWindowSizeForCheck handle 260 190
              pollEventsForCheck
          deliver attempt step = do
            outcome ← try step
            case outcome of
              Right (WindowAvailable ())
                | attempt < deliveryAttempts →
                    deliver (attempt + 1) $
                      windowStep window (operation "deliver events for check") (\_ → waitEventsForCheck deliveryWaitSeconds)
              _ → pure (attempt, outcome)
      (boundaries, outcome) ← deliver (0 ∷ Int) resize
      caught ←
        either
          pure
          (\result → failCheck ("after " <> show (boundaries + 1) <> " boundaries the last completed with " <> show result))
          outcome
      case fromException caught of
        Just (ErrorCall message) → do
          let contexts =
                [ (operationText (contextOperation context), contextIdentifiers context)
                | context ← failureContexts (failureEvidence caught)
                ]
          unless (any ((== "window callback") . fst) contexts) $
            failCheck ("the fault carries no callback context: " <> show contexts)
          after ← synchronizeWindow window
          case after of
            WindowAvailable _ → pure ()
            WindowEnded _ → failCheck "the window ended after a contained fault"
          pure ("rethrown " <> show message <> " at boundary " <> show (boundaries + 1) <> " with " <> show contexts)
        Nothing → failCheck ("unexpected failure: " <> displayException caught)

-- | A production table tracing the session's teardown: whether the callback GLFW
-- holds is the monitor callback's own storage when it is detached, whether GLFW
-- holds none afterwards, and where termination, the error callback's detach,
-- and the monitor callback's free fall around it.
monitorTeardown ∷ IO String
monitorTeardown = do
  trace ← newIORef []
  storage ← newIORef Nothing
  let note event = modifyIORef' trace (<> [event])
      monitors = nativeMonitor productionNative
      traced =
        productionNative
          { nativeTerminate = note "terminate" >> nativeTerminate productionNative
          , nativeDetachErrorCallback = note "detach error callback" >> nativeDetachErrorCallback productionNative
          , nativeMonitor =
              monitors
                { nativeNewMonitorCallback = \callback → do
                    allocated ← nativeNewMonitorCallback monitors callback
                    writeIORef storage (Just allocated)
                    pure allocated
                , nativeDetachMonitorCallback = do
                    installed ← installedMonitorCallbackForCheck
                    allocated ← readIORef storage
                    note (if Just installed == allocated then "detach installed callback" else "detach another callback")
                    nativeDetachMonitorCallback monitors
                    remaining ← installedMonitorCallbackForCheck
                    note (if remaining == MonitorCallbackStorage nullFunPtr then "none installed" else "still installed")
                , nativeFreeMonitorCallback = \allocated → note "free monitor callback" >> nativeFreeMonitorCallback monitors allocated
                }
          }
  (reader, count) ←
    withScoped (allocComposite (sessionAssembly traced defaultSessionConfig)) $ \session → do
      inventory ← synchronizeMonitors session
      pure (monitorInventory session, either (const 0) length (monitorList inventory))
  closed ← preparedValue . observedValue <$> atomically (readSnapshot reader)
  traced' ← readIORef trace
  let expected = ["detach installed callback", "none installed", "terminate", "detach error callback", "free monitor callback"]
  unless (traced' == expected) $ failCheck ("the teardown ran " <> show traced')
  unless (inventoryPhase closed == InventoryClosed) $ failCheck ("the inventory was left " <> show (inventoryPhase closed))
  pure (show count <> " monitor(s); teardown " <> intercalate' traced' <> "; closed at revision " <> show (inventoryRevision closed))
  where
    monitorList inventory = case inventoryMonitors inventory of
      Observed descriptions → Right descriptions
      Unavailable → Left ()
    intercalate' = foldr1 (\event rest → event <> ", " <> rest)

-- | Close sessions while workers wake them, over a production table that records,
-- immediately before @glfwTerminate@, how many production wake calls have
-- entered and returned from @glfwPostEmptyEvent@. Every round must find the two
-- equal there — no wake in flight as termination begins — and find the entered
-- count unchanged once the session has closed — no wake entered after it. Each
-- worker wakes until its capability answers 'WakeTerminal', and the close begins
-- only once every worker has posted, so wakes race the close in every round.
wakeTeardown ∷ IO String
wakeTeardown = do
  atTerminate ← newIORef Nothing
  let traced =
        productionNative
          { nativeTerminate = do
              wakeCountsForCheck >>= writeIORef atTerminate . Just
              nativeTerminate productionNative
          }
      forks = [forkIO, forkOS, forkIO, forkOS]
      round' index = do
        writeIORef atTerminate Nothing
        (before, _) ← wakeCountsForCheck
        (workers, stale) ←
          withScoped (allocComposite (sessionAssembly traced defaultSessionConfig)) $ \session → do
            let wake = sessionWake session
            posted ← mapM (const (newTVarIO False)) forks
            workers ← mapM (\(fork, flag) → startWaker fork wake flag) (zip forks posted)
            atomically (mapM_ (readTVar >=> STM.check) posted)
            pure (workers, wake)
        counts ← mapM (takeMVar >=> either (\failure → failCheck ("a waking worker failed: " <> displayException (failure ∷ SomeException))) pure) workers
        terminated ← readIORef atTerminate >>= maybe (failCheck "termination recorded no wake counts") pure
        afterClose ← wakeCountsForCheck
        staleOutcome ← wakeSession stale
        afterStale ← wakeCountsForCheck
        let (enteredAtTerminate, returnedAtTerminate) = terminated
        unless (enteredAtTerminate == returnedAtTerminate) $
          failCheck ("round " <> show index <> ": termination began with wake calls in flight: " <> show terminated)
        unless (fst afterClose == enteredAtTerminate && afterClose == afterStale) $
          failCheck ("round " <> show index <> ": wake calls entered GLFW after termination began: " <> show (terminated, afterClose, afterStale))
        unless (staleOutcome == WakeTerminal) $
          failCheck ("round " <> show index <> ": a stale capability answered " <> show staleOutcome)
        unless (fromIntegral (sum counts) == enteredAtTerminate - before) $
          failCheck ("round " <> show index <> ": workers posted " <> show counts <> " but " <> show (enteredAtTerminate - before) <> " calls entered")
        pure (sum counts)
  posts ← mapM round' [1 .. wakeRounds]
  (entered, returned) ← wakeCountsForCheck
  pure
    ( show wakeRounds
        <> " rounds of 4 workers; wakes posted per round "
        <> show posts
        <> "; in every round the wake calls entered equalled those returned when termination began, and none entered afterwards; "
        <> show entered
        <> " entered and "
        <> show returned
        <> " returned in total"
    )
  where
    startWaker fork wake posted = do
      done ← newEmptyMVar
      let loop count =
            wakeSession wake >>= \case
              WakePosted → atomically (writeTVar posted True) >> loop (count + 1)
              WakeTerminal → pure (count ∷ Int)
              WakeFailed reports → failCheck ("a wake failed: " <> show reports)
      _ ← fork (try (loop 0) >>= putMVar done)
      pure done

-- | Keep one real session's capability and use it during and after a later
-- session: it answers 'WakeTerminal' each time and no call enters GLFW.
wakeAcrossSessions ∷ IO String
wakeAcrossSessions = do
  stale ← withSession defaultSessionConfig (pure . sessionWake)
  (duringLater, before, after) ← withSession defaultSessionConfig $ \_ → do
    before ← wakeCountsForCheck
    duringLater ← wakeSession stale
    after ← wakeCountsForCheck
    pure (duringLater, before, after)
  afterLater ← wakeSession stale
  unless (duringLater == WakeTerminal && afterLater == WakeTerminal) $
    failCheck ("the stale capability answered " <> show (duringLater, afterLater))
  unless (before == after) $
    failCheck ("a stale wake entered GLFW: " <> show (before, after))
  pure ("the stale capability answered " <> show duringLater <> " during a later session and " <> show afterLater <> " after it, with wake counts " <> show after <> " unchanged")

-- | One real window, one scripted graphics owner, and the protected host
-- lifetime, in a session of this child's own.
--
-- The native destruction of the window must follow the owner's completion, and
-- the session's termination must follow that destruction, with no event
-- processing, wake, or window call entering GLFW afterwards. It claims nothing
-- about GPU synchronisation: the owner is a script and the facts it certifies
-- are CPU facts, exactly as the headless examples' are. What the real session
-- adds is that the destruction and the termination are the platform's own.
protectedRetirement ∷ IO String
protectedRetirement = do
  journal ← newIORef []
  calls ← newIORef (0 ∷ Int)
  remaining ← newIORef allRetirementFacts
  atTerminate ← newIORef Nothing
  let counted action = modifyIORef' calls (+ 1) >> action
      traced =
        productionNative
          { nativePollEvents = counted (nativePollEvents productionNative)
          , nativeWaitEventsTimeout = \seconds → counted (nativeWaitEventsTimeout productionNative seconds)
          , nativeDestroyWindow = \handle → do
              modifyIORef' journal (<> ["window destroyed"])
              counted (nativeDestroyWindow productionNative handle)
          , nativeTerminate = do
              modifyIORef' journal (<> ["session terminated"])
              wakes ← wakeCountsForCheck
              made ← readIORef calls
              writeIORef atTerminate (Just (wakes, made))
              nativeTerminate productionNative
          }
      config =
        (Runtime.defaultHostConfig [hiddenTestWindowConfig (Text.pack "protected") 64 48])
          {Runtime.hostIdleWait = 0.01}
      logger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))
  Runtime.runProtectedWindowApplication
    (withLoggingLifetime logger)
    (Text.pack "protected-retirement")
    ( \_ use →
        Runtime.withProtectedWindowHostIn
          logger
          (allocComposite (sessionAssembly traced defaultSessionConfig))
          config
          ( \host → do
              window ← onlyHostWindow host
              Runtime.attachHostWindow host window (scriptedOwner journal remaining host) >>= \case
                Runtime.AttachmentEstablished _ _ → pure ()
                other → failCheck ("the attachment was not established: " <> show other)
              use host
          )
    )
    id
    (\host _ → pure host)
    (\_ _ → pure ())
  entries ← readIORef journal
  let expected = map (\fact → "certified " <> show fact) allRetirementFacts <> ["window destroyed", "session terminated"]
  unless (entries == expected) $
    failCheck ("the protected host's order was " <> show entries <> ", not " <> show expected)
  (wakes, made) ← readIORef atTerminate >>= maybe (failCheck "termination recorded nothing") pure
  afterWakes ← wakeCountsForCheck
  afterCalls ← readIORef calls
  unless (afterWakes == wakes) $
    failCheck ("a wake entered GLFW after termination began: " <> show (wakes, afterWakes))
  unless (afterCalls == made) $
    failCheck ("a native event or window call was made after termination began: " <> show (made, afterCalls))
  pure
    ( "the order was "
        <> show entries
        <> "; "
        <> show made
        <> " event and window call(s) and wake counts "
        <> show wakes
        <> " when termination began, unchanged afterwards"
    )

-- | The scripted graphics owner: it certifies one retirement fact per bounded
-- opportunity, in order, and stalls once it has none left.
scriptedOwner
  ∷ IORef [String] → IORef [RetirementFact] → Runtime.WindowHost → Runtime.AttachmentProtocol
scriptedOwner journal remaining host =
  Runtime.AttachmentProtocol
    { Runtime.protocolConstruct = \_ _ → pure ()
    , Runtime.protocolRollback = pure RollbackSafe
    , Runtime.protocolStep = \_ acknowledgement →
        readIORef remaining >>= \case
          [] → pure Runtime.RetirementStalled
          fact : rest → do
            writeIORef remaining rest
            modifyIORef' journal (<> ["certified " <> show fact])
            _ ← Runtime.reportHostRetirementFact host acknowledgement fact
            pure Runtime.RetirementAdvanced
    , Runtime.protocolDisposition = Required
    , Runtime.protocolRecognizes = \_ → pure False
    }

onlyHostWindow ∷ Runtime.WindowHost → IO WindowId
onlyHostWindow host =
  atomically (Runtime.hostWindowIdentities host) >>= \case
    [identity] → pure identity
    windows → failCheck ("expected one window, found " <> show (length windows))

-- | How many sessions 'wakeTeardown' closes while workers wake them.
wakeRounds ∷ Int
wakeRounds = 20

-- | Carry every identity from one real session into the next.
monitorAcrossSessions ∷ IO String
monitorAcrossSessions = do
  earlier ← withSession defaultSessionConfig (fmap identitiesOf . synchronizeMonitors)
  when (null earlier) $ failCheck "the first session enumerated no monitor to carry into the next"
  (later, resolved) ←
    withSession defaultSessionConfig $ \session →
      (,) <$> (identitiesOf <$> synchronizeMonitors session) <*> mapM (resolveMonitor session) earlier
  unless (resolved == map MonitorDisconnected earlier) $
    failCheck ("an earlier session's identity resolved: " <> show resolved)
  pure ("identities " <> show earlier <> " answered disconnected in a session enumerating " <> show later)
  where
    identitiesOf inventory = case inventoryMonitors inventory of
      Observed descriptions → map monitorIdentity descriptions
      Unavailable → []

-- | Request a backend this platform's GLFW was not built with, past the model's
-- own refusal, so that GLFW's initialization itself fails and reports why.
initializationError ∷ IO String
initializationError = do
  let unavailable = if hostBackend == Cocoa then X11 else Cocoa
      forced =
        productionNative
          { nativeHostBackend = Just unavailable
          , nativePlatformSupported = \_ → pure True
          }
  outcome ← try (withScoped (allocComposite (sessionAssembly forced defaultSessionConfig)) (\_ → pure ()))
  caught ← either pure (\() → failCheck "initialization succeeded") outcome
  failure ← maybe (failCheck ("unexpected failure: " <> displayException caught)) pure (fromException caught)
  when (nativeOutcome failure /= NativeCallFailed) $
    failCheck ("initialization reported " <> show (nativeOutcome failure))
  let unavailableCode = fromIntegral glfwPlatformUnavailable
      reported = reportedErrors (nativeReports failure)
      matching =
        [ entry
        | entry ← reported
        , nativeErrorCode entry == unavailableCode
        , nativeErrorThread entry == ProcessMainThread
        ]
  when (null matching) $
    failCheck ("no GLFW_PLATFORM_UNAVAILABLE report on the main thread: " <> show reported)
  case failureCause (failureEvidence caught) of
    EngineOrigin origin → do
      let component = componentText (originComponent origin)
          operationName = operationText (originOperation origin)
      unless (component == "glfw" && operationName == "initialize") $
        failCheck ("attributed to " <> Text.unpack component <> " " <> Text.unpack operationName)
      pure
        ( "glfw initialize failed before polling: "
            <> concatMap (Text.unpack . nativeErrorDescription) matching
        )
    NativeCause → failCheck "the failure carries no engine origin"

-- | How many owner boundaries may wait for a callback the platform has yet to
-- deliver, and the most each waits for an event.
deliveryAttempts ∷ Int
deliveryAttempts = 100

deliveryWaitSeconds ∷ Double
deliveryWaitSeconds = 0.05

failCheck ∷ String → IO a
failCheck = ioError . userError
