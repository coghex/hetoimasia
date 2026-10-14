-- | The consent gate, proven without a session, a display, or a child process.
--
-- These examples need no consent themselves and are the approval-free
-- selection @--match "the native opt-in"@: how consent is read from an
-- environment, that an unapproved run's operations are refused before they
-- are dispatched — so a scripted owner records no acquisition — that a
-- consented example is refused before its body, so a body that forks and
-- waits on an operation never starts, and that a refusal reaching the real
-- owner fails its acquisition before any native step; that a dry run and an
-- empty selection still acquire nothing with consent absent; that an approved
-- run is served; that the interaction probe is inactive without its own
-- activation variable and is refused before its body either way when the run
-- carries no consent; that the private-session parent starts no child
-- without consent while a directly invoked child refuses before its scenario is
-- even looked up; and that the launcher's deadline holds against a descendant
-- that keeps the child's output open, with the check that the descendant has
-- ended proven against a running process, a zombie, and an absent one; and that
-- the launcher owns no output reader or pipe handle once it returns or
-- propagates, whether the child exited, expired, left a writer in another
-- session holding its output open, or the launch was interrupted.
module Test.GLFW.Native.Guard (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, throwTo)
import Control.Concurrent.STM (atomically, check)
import Control.Exception (annotateIO, someExceptionContext, ErrorCall (..), IOException, SomeException, bracket, displayException, finally, fromException, throwIO, try)
import Control.Exception.Annotation (ExceptionAnnotation)
import Control.Exception.Context (getExceptionAnnotations)
import Control.Monad (void)
import System.IO.Error (ioeGetErrorString)
import Data.Either (isLeft)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Resource (allocResource)
import GHC.Clock (getMonotonicTime)
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hIsClosed)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (nullSignal, sigKILL, signalProcess, signalProcessGroup)
import System.Posix.Types (ProcessID)
import System.Timeout (timeout)
import Text.Read (readMaybe)
import qualified Test.GLFW.Native.Child as Child
import Test.GLFW.Native.Consent
  ( Consent (..)
  , NativeSessionRefused (..)
  , Refusal (..)
  , consentFrom
  , consentVariable
  , desktopValue
  , isolatedValue
  , refusalMessage
  , waylandValue
  )
import Test.GLFW.Native.Fixture (Owner (..), OwnerReport (..), dispatch, runOwned)
import Test.GLFW.Native.Interaction
  ( Phase (phaseName)
  , ProbeInactive (..)
  , inactiveMessage
  , probeActivation
  , probePhases
  , probeVariable
  )
import Test.GLFW.Native.Presence (Presence (..), gone, inspectPresence, inspectPresenceUsing, presenceFrom, withZombie)
import qualified Test.GLFW.Native.Private as Private
import Test.GLFW.Native.Support
  ( ThreadCheck (..)
  , consented
  , gated
  , newGate
  , newThreadEvidence
  , refusals
  , sharedSessionOwner
  , threadChecks
  )
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)
import Test.Hspec.Core.Formatters.V2 (formatterToFormat, silent)
import Test.Hspec.Runner
  ( Config (configDryRun, configFailOnEmpty, configFilterPredicate, configFormat)
  , SpecResult
  , defaultConfig
  , evalSpec
  , resultItemIsFailure
  , runSpecForest
  , specResultItems
  , specResultSuccess
  )

spec ∷ Spec
spec = describe "the native opt-in" $ do
  describe "read from the environment" $ do
    it "finds no consent in an empty environment, a bare DISPLAY, or CI" $ do
      consentFrom "linux" [] `shouldBe` Left NoConsent
      consentFrom "darwin" [] `shouldBe` Left NoConsent
      consentFrom "linux" [("DISPLAY", ":0"), ("CI", "true")] `shouldBe` Left NoConsent
      consentFrom "darwin" [("CI", "true"), ("GITHUB_ACTIONS", "true")] `shouldBe` Left NoConsent

    it "finds no consent in an empty or unrecognized value" $ do
      consentFrom "linux" [(consentVariable, "")] `shouldBe` Left NoConsent
      consentFrom "linux" [(consentVariable, "yes")] `shouldBe` Left (UnknownConsent "yes")
      consentFrom "darwin" [(consentVariable, "Desktop")] `shouldBe` Left (UnknownConsent "Desktop")

    it "accepts the human's desktop consent on either platform" $ do
      consentFrom "linux" [(consentVariable, desktopValue)] `shouldBe` Right Desktop
      consentFrom "darwin" [(consentVariable, desktopValue), ("DISPLAY", ":0")] `shouldBe` Right Desktop

    it "accepts the isolated Wayland authorization only on Linux, for the socket it names, with no DISPLAY" $ do
      consentFrom "linux" [(consentVariable, waylandValue "wayland-7"), ("WAYLAND_DISPLAY", "wayland-7")]
        `shouldBe` Right (IsolatedWayland "wayland-7")
      -- A socket the run is not on, named or not.
      consentFrom "linux" [(consentVariable, waylandValue "wayland-7"), ("WAYLAND_DISPLAY", "wayland-0")]
        `shouldBe` Left (WaylandIsolationElsewhere "wayland-7" (Just "wayland-0"))
      consentFrom "linux" [(consentVariable, waylandValue "wayland-7")]
        `shouldBe` Left (WaylandIsolationElsewhere "wayland-7" Nothing)
      consentFrom "linux" [(consentVariable, waylandValue ""), ("WAYLAND_DISPLAY", "")]
        `shouldBe` Left (WaylandIsolationElsewhere "" (Just ""))
      -- Any DISPLAY at all, empty included, could serve X11 or XWayland
      -- instead of the compositor the helper started.
      consentFrom "linux" [(consentVariable, waylandValue "wayland-7"), ("WAYLAND_DISPLAY", "wayland-7"), ("DISPLAY", ":0")]
        `shouldBe` Left (WaylandIsolationBesideX11 "wayland-7" ":0")
      consentFrom "linux" [(consentVariable, waylandValue "wayland-7"), ("WAYLAND_DISPLAY", "wayland-7"), ("DISPLAY", "")]
        `shouldBe` Left (WaylandIsolationBesideX11 "wayland-7" "")
      consentFrom "darwin" [(consentVariable, waylandValue "wayland-7"), ("WAYLAND_DISPLAY", "wayland-7")]
        `shouldBe` Left (WaylandIsolationOffPlatform "wayland-7" "darwin")
      -- A bare WAYLAND_DISPLAY is no more consent than a bare DISPLAY.
      consentFrom "linux" [("WAYLAND_DISPLAY", "wayland-7")] `shouldBe` Left NoConsent

    it "accepts the isolated authorization only on Linux and only for the display it names" $ do
      consentFrom "linux" [(consentVariable, isolatedValue ":42"), ("DISPLAY", ":42")]
        `shouldBe` Right (IsolatedX11 ":42")
      consentFrom "linux" [(consentVariable, isolatedValue ":42"), ("DISPLAY", ":0")]
        `shouldBe` Left (IsolationElsewhere ":42" (Just ":0"))
      consentFrom "linux" [(consentVariable, isolatedValue ":42")]
        `shouldBe` Left (IsolationElsewhere ":42" Nothing)
      consentFrom "linux" [(consentVariable, isolatedValue ""), ("DISPLAY", "")]
        `shouldBe` Left (IsolationElsewhere "" (Just ""))
      consentFrom "darwin" [(consentVariable, isolatedValue ":42"), ("DISPLAY", ":42")]
        `shouldBe` Left (IsolationOffPlatform ":42" "darwin")

    it "names the missing consent, the desktop opt-in, the standing approval, and the isolated alternative in every refusal" $
      mapM_
        ( \refusal → do
            let message = refusalMessage refusal
            message `shouldContain` consentVariable
            message `shouldContain` (consentVariable <> "=" <> desktopValue)
            message `shouldContain` "standing approval"
            message `shouldContain` "tools/display/x11.sh"
            message `shouldContain` "tools/display/wayland.sh"
            message `shouldContain` "DISPLAY, WAYLAND_DISPLAY, and CI are not consent"
        )
        [ NoConsent
        , UnknownConsent "yes"
        , IsolationElsewhere ":42" Nothing
        , IsolationOffPlatform ":42" "darwin"
        , WaylandIsolationElsewhere "wayland-7" Nothing
        , WaylandIsolationBesideX11 "wayland-7" ":0"
        , WaylandIsolationOffPlatform "wayland-7" "darwin"
        ]

  describe "before the shared session" $ do
    it "refuses every operation of an unapproved run before it is dispatched, acquiring nothing" $ do
      (events, owner) ← recordingOwner
      gate ← newGate (Left NoConsent)
      (outcome, report) ←
        runOwned owner $ \fixture → do
          first ← try (gated gate fixture pure)
          second ← try (gated gate fixture pure)
          pure (refused first, refused second)
      either throwIO pure outcome `shouldReturn` (True, True)
      refusals gate `shouldReturn` 2
      reportAcquisitions report `shouldBe` 0
      reportServed report `shouldBe` 0
      readIORef events `shouldReturn` []

    it "acquires nothing for a dry run, and fails an empty selection without acquiring, with consent absent" $ do
      (events, owner) ← recordingOwner
      gate ← newGate (Left NoConsent)
      (outcome, report) ←
        runOwned owner $ \fixture → do
          let dispatching = it "dispatches an operation" (void (gated gate fixture pure))
          dry ← runNested (\config → config {configDryRun = True}) dispatching
          empty ←
            try $
              runNested
                (\config → config {configFailOnEmpty = True, configFilterPredicate = Just (const False)})
                dispatching
          pure
            ( specResultSuccess dry
            , length (specResultItems dry)
            , either (\(code ∷ ExitCode) → code /= ExitSuccess) (not . specResultSuccess) empty
            )
      either throwIO pure outcome `shouldReturn` (True, 1, True)
      refusals gate `shouldReturn` 0
      reportAcquisitions report `shouldBe` 0
      readIORef events `shouldReturn` []

    it "serves an approved run's operations, acquiring once" $
      mapM_
        ( \consent → do
            (events, owner) ← recordingOwner
            gate ← newGate (Right consent)
            (outcome, report) ←
              runOwned owner $ \fixture →
                (,) <$> gated gate fixture pure <*> gated gate fixture (pure . (+ 1))
            either throwIO pure outcome `shouldReturn` (7, 8)
            refusals gate `shouldReturn` 0
            reportAcquisitions report `shouldBe` 1
            readIORef events `shouldReturn` ["acquired", "released"]
        )
        [Desktop, IsolatedX11 ":42", IsolatedWayland "wayland-7"]

    it "refuses a native example before its body, so a body that forks and waits on an operation never starts" $ do
      -- The shape of the shared-session examples: a body that forks an
      -- operation and then waits for a signal that operation sends. Refused
      -- at the hook, the body never runs, so nothing is left waiting.
      (events, owner) ← recordingOwner
      gate ← newGate (Left NoConsent)
      ran ← newIORef False
      (outcome, report) ←
        runOwned owner $ \fixture → do
          started ← newEmptyMVar
          result ←
            runNested id . consented gate . it "forks an operation and waits for it" $ do
              writeIORef ran True
              _ ← forkIO (gated gate fixture (\value → putMVar started () >> pure value) >>= \_ → pure ())
              takeMVar started
          pure (length (specResultItems result), length (filter resultItemIsFailure (specResultItems result)))
      either throwIO pure outcome `shouldReturn` (1, 1)
      readIORef ran `shouldReturn` False
      refusals gate `shouldReturn` 1
      reportAcquisitions report `shouldBe` 0
      readIORef events `shouldReturn` []

    it "runs a consented example's body" $ do
      gate ← newGate (Right Desktop)
      ran ← newIORef False
      result ← runNested id . consented gate . it "runs" $ writeIORef ran True
      length (filter resultItemIsFailure (specResultItems result)) `shouldBe` 0
      readIORef ran `shouldReturn` True
      refusals gate `shouldReturn` 0

    it "fails the real owner's acquisition before any native step when a refusal reaches it" $ do
      evidence ← newThreadEvidence
      gate ← newGate (Left NoConsent)
      -- Dispatched directly, around the gate, so the owner's own check is what
      -- refuses: the acquisition ends before the session is initialized.
      (outcome, report) ←
        runOwned (sharedSessionOwner evidence gate) $ \fixture →
          try (dispatch fixture (\_ → pure ()))
      either throwIO pure outcome >>= (`shouldBe` True) . refused
      refusals gate `shouldReturn` 1
      reportAcquisitions report `shouldBe` 1
      reportServed report `shouldBe` 0
      (fromException =<< reportFailure report) `shouldBe` Just (NativeSessionRefused NoConsent)
      threadChecks evidence >>= (`shouldSatisfy` (SetupCheck `notElem`) . map fst)

  describe "before the interaction probe" $ do
    it "is inactive unless its own variable asks for a positive number of seconds" $ do
      probeActivation [] `shouldBe` Left ProbeNotRequested
      probeActivation [(probeVariable, "")] `shouldBe` Left ProbeNotRequested
      probeActivation [(consentVariable, desktopValue)] `shouldBe` Left ProbeNotRequested
      probeActivation [(probeVariable, "yes")] `shouldBe` Left (ProbeNotSeconds "yes")
      probeActivation [(probeVariable, "0")] `shouldBe` Left (ProbeNotSeconds "0")
      probeActivation [(probeVariable, "-5")] `shouldBe` Left (ProbeNotSeconds "-5")
      probeActivation [(probeVariable, "Infinity")] `shouldBe` Left (ProbeNotSeconds "Infinity")
      probeActivation [(probeVariable, "20")] `shouldBe` Right 20
      probeActivation [(probeVariable, "2.5"), (consentVariable, desktopValue)] `shouldBe` Right 2.5

    it "says why it is pending, what it would do to the desktop, and what activates it" $
      mapM_
        ( \inactive → do
            let message = inactiveMessage inactive
            message `shouldContain` probeVariable
            message `shouldContain` "menu bar"
            message `shouldContain` "no routine or CI run"
        )
        [ProbeNotRequested, ProbeNotSeconds "yes"]

    it "asks for an idle baseline first and then the three interactions, in order" $
      map phaseName probePhases
        `shouldBe` ["idle baseline", "window move", "window resize", "menu-bar interaction"]

    it "is refused before its body on an unapproved run, activated or not, so no window is opened" $
      mapM_
        ( \activated → do
            gate ← newGate (Left NoConsent)
            ran ← newIORef False
            result ←
              runNested id . consented gate . it "would run the interaction probe" $ do
                writeIORef ran True
                -- What the real body reads first; it never gets this far.
                probeActivation activated `shouldSatisfy` either (const False) (> 0)
            length (filter resultItemIsFailure (specResultItems result)) `shouldBe` 1
            readIORef ran `shouldReturn` False
            refusals gate `shouldReturn` 1
        )
        [[], [(probeVariable, "20")]]

  describe "before a private-session child" $ do
    it "refuses an unapproved run's scenario before starting a child" $ do
      (launched, launcher) ← recordingLauncher
      gate ← newGate (Left NoConsent)
      try (Private.launchWith gate launcher "session-lifecycle") >>= (`shouldBe` True) . refused
      refusals gate `shouldReturn` 1
      readIORef launched `shouldReturn` []

    it "starts the child for an approved run, and accepts its report" $ do
      (launched, launcher) ← recordingLauncher
      gate ← newGate (Right Desktop)
      Private.launchWith gate launcher "session-lifecycle"
      refusals gate `shouldReturn` 0
      readIORef launched `shouldReturn` ["session-lifecycle"]

    it "fails a child that expired at its deadline even though it printed that every check passed" $ do
      gate ← newGate (Right Desktop)
      let expired _ =
            pure
              Private.Launched
                { Private.launchedEnd = Private.ChildExpired Private.childDeadline (ExitFailure (-15))
                , Private.launchedOut = "glfw-native-tests session-lifecycle: every check passed\n"
                , Private.launchedErr = ""
                , Private.launchedPid = 0
                }
      verdict ← try (Private.launchWith gate expired "session-lifecycle")
      either (\(_ ∷ SomeException) → True) (const False) verdict `shouldBe` True

    it "fails a child that exited with success output but a failing status" $ do
      gate ← newGate (Right Desktop)
      let failing _ =
            pure
              Private.Launched
                { Private.launchedEnd = Private.ChildExited (ExitFailure 1)
                , Private.launchedOut = "glfw-native-tests session-lifecycle: every check passed\n"
                , Private.launchedErr = ""
                , Private.launchedPid = 0
                }
      verdict ← try (Private.launchWith gate failing "session-lifecycle")
      either (\(_ ∷ SomeException) → True) (const False) verdict `shouldBe` True

    -- A real process, but no session and no private-session child, so it
    -- needs no consent: the shell exits at once while the sleep it started
    -- keeps the shell's output open.
    it "keeps its deadline through output collection, ending a descendant that holds the child's output open" $ do
      started ← getMonotonicTime
      launched ← Private.launchCommand 1 "sh" ["-c", "sleep 300 & echo \"$!\"; exit 0"]
      elapsed ← subtract started <$> getMonotonicTime
      Private.launchedEnd launched `shouldBe` Private.ChildExpired 1 ExitSuccess
      -- A generous failure bound, not a performance threshold: without the
      -- deadline the launcher would wait for the sleep's 300 seconds.
      elapsed `shouldSatisfy` (< 1 + 2 * Private.terminationGrace + 10)
      descendant ←
        maybe (fail ("the shell printed no descendant: " <> show (Private.launchedOut launched))) pure $
          readMaybe (takeWhile (/= '\n') (Private.launchedOut launched))
      -- Killed, but not necessarily reaped: its shell exited at once, so the
      -- sleep was orphaned to whatever adopts orphans — init, tini under the
      -- CI containers' --init, launchd — and the launcher, which waits only
      -- for its own child, does not wait for it. Until that reaper runs it is
      -- a zombie, which still accepts signal 0, so ps's state is read instead:
      -- a zombie or an unlisted process has ended, a running one fails the
      -- example, and a ps that cannot answer fails it too.
      inspectPresence (fromInteger descendant) >>= (`shouldSatisfy` gone)

    -- The launcher's ownership. Each example below asks what the launch still
    -- holds after it has returned or propagated: the observer is shown the
    -- parent's pipe handles and each reader's completion the moment they are
    -- acquired, and the example reads them afterwards. A writer left running
    -- never supplies the end of file that would let a reader finish on its own,
    -- and none of this reads a clock, a thread count or a descriptor count.
    it "owns no reader or pipe handle after a child that exits with its output complete" $ do
      owned ← newIORef Nothing
      launched ← bounded (Child.launchCommandObserved (writeIORef owned . Just) Child.terminationGrace Nothing 30 "sh" ["-c", "echo out; echo err >&2"])
      Child.launchedEnd launched `shouldBe` Child.ChildExited ExitSuccess
      (Child.launchedOut launched, Child.launchedErr launched) `shouldBe` ("out\n", "err\n")
      readIORef owned >>= maybe (expectationFailure "the launch showed its observer nothing") reclaimed

    it "owns no reader or pipe handle after giving up on output a writer in another session holds open, and keeps what was read" $
      withEscapedWriter $ \pidFile → do
        owned ← newIORef Nothing
        let expected = ("escaped-out\npartial success\n", "escaped-err\npartial err\n")
            -- Waits for the fixture's whole output, so the deadline below starts
            -- only once the direct child has said everything and is exiting.
            observe o = do
              atomically (Child.ownedCaptured o >>= check . (== expected))
              writeIORef owned (Just o)
        launched ← bounded (Child.launchCommandObserved observe 0.05 Nothing 0.05 "python3" ["-c", escapedWriter, pidFile])
        Child.launchedEnd launched `shouldSatisfy` \case Child.ChildExpired _ _ → True; _ → False
        (Child.launchedOut launched, Child.launchedErr launched) `shouldBe` expected
        readIORef owned >>= maybe (expectationFailure "the launch showed its observer nothing") reclaimed
        -- The writer is still running, so nothing above was ended by it ending.
        escaped ← escapedPid pidFile
        try (signalProcess nullSignal escaped) >>= (`shouldSatisfy` either (\(_ ∷ IOException) → False) (const True))

    it "owns no reader or pipe handle when an interruption reaches the launch, and propagates the interruption" $ do
      acquired ← newEmptyMVar
      result ← newEmptyMVar
      launcher ← forkIO (try (Child.launchCommandObserved (putMVar acquired) Child.terminationGrace Nothing 300 "sh" ["-c", "sleep 300"]) >>= putMVar result)
      owned ← takeMVar acquired
      -- Whatever the child does next, it is ended with its group on the way out.
      ( do
          throwTo launcher (ErrorCall "the launch was interrupted")
          outcome ← bounded (takeMVar result)
          case outcome of
            Left failure → fmap (\(ErrorCall message) → message) (fromException failure) `shouldBe` Just "the launch was interrupted"
            Right (_ ∷ Child.Launched) → expectationFailure "the interrupted launch returned"
          reclaimed owned
          try (signalProcess nullSignal (Child.ownedPid owned)) >>= (`shouldSatisfy` either (\(_ ∷ IOException) → True) (const False))
        )
        `finally` void (try (signalProcessGroup sigKILL (Child.ownedPid owned)) ∷ IO (Either IOException ()))

    it "returns the status and output of every short-lived child, however soon it is reaped" $
      -- The identifier is read before anything waits on the child, so no child can be
      -- reaped between its start and the read. A child that exits at once is the case
      -- the order matters for.
      mapM_ (\_ → do
               launched ← bounded (Child.launchCommand 30 "true" [])
               Child.launchedEnd launched `shouldBe` Child.ChildExited ExitSuccess)
            [1 ∷ Int .. 200]

    it "propagates the exception that ended a launch with the context it carried, and still reclaims" $ do
      owned ← newIORef Nothing
      let observe o = writeIORef owned (Just o) >> annotateIO (Marker "the observer's own") (ioError (userError "the observer failed"))
      outcome ← bounded (try (Child.launchCommandObserved observe Child.terminationGrace Nothing 30 "sh" ["-c", "sleep 30"]))
      case outcome of
        Left (failure ∷ SomeException) → do
          fmap (\(e ∷ IOException) → ioeGetErrorString e) (fromException failure) `shouldBe` Just "the observer failed"
          (getExceptionAnnotations (someExceptionContext failure) ∷ [Marker]) `shouldBe` [Marker "the observer's own"]
        Right (_ ∷ Child.Launched) → expectationFailure "the launch returned though its observer failed"
      readIORef owned >>= maybe (expectationFailure "the launch showed its observer nothing") (\o → reclaimed o >> try (signalProcess nullSignal (Child.ownedPid o)) >>= (`shouldSatisfy` either (\(_ ∷ IOException) → True) (const False)))

    it "reads a running process as present, and an exited one as gone whether or not it has been reaped" $ do
      getProcessID >>= inspectPresence >>= (`shouldSatisfy` \case Running _ → True; _ → False)
      reaped ← withZombie $ \zombie → do
        inspectPresence zombie `shouldReturn` Zombie
        pure zombie
      inspectPresence reaped `shouldReturn` Absent

    it "reads only ps's own answers as a presence, and fails the inspection on anything else" $ do
      let linux code = presenceFrom "linux" (Private.ChildExited code)
          darwin code = presenceFrom "darwin" (Private.ChildExited code)
      darwin ExitSuccess "Z   \n" "" `shouldBe` Right Zombie
      linux ExitSuccess "Z\n" "" `shouldBe` Right Zombie
      linux ExitSuccess "Z+\n" "" `shouldBe` Right Zombie
      darwin ExitSuccess "Ss  \n" "" `shouldBe` Right (Running "Ss")
      darwin ExitSuccess "R+\n" "" `shouldBe` Right (Running "R+")
      linux ExitSuccess "Ssl+\n" "" `shouldBe` Right (Running "Ssl+")
      linux ExitSuccess "D<N\n" "" `shouldBe` Right (Running "D<N")
      darwin ExitSuccess "UEW\n" "" `shouldBe` Right (Running "UEW")
      linux (ExitFailure 1) "" "" `shouldBe` Right Absent
      darwin (ExitFailure 1) "" "" `shouldBe` Right Absent
      mapM_
        (`shouldSatisfy` isLeft)
        [ presenceFrom "linux" (Private.ChildExpired 10 (ExitFailure (-15))) "" ""
        , linux ExitSuccess "" ""
        , linux ExitSuccess "Z\nZ\n" ""
        , linux ExitSuccess "1234\n" ""
        , darwin ExitSuccess "S\n" "ps: warning\n"
        , linux (ExitFailure 1) "Z\n" ""
        , darwin (ExitFailure 1) "" "ps: process id too large: 999999\n"
        , linux (ExitFailure 2) "" ""
        , -- A Z-led word that is not a state, or a state with a modifier its
          -- platform's ps does not document, is malformed, never a zombie.
          linux ExitSuccess "Zgarbage\n" ""
        , darwin ExitSuccess "Zgarbage\n" ""
        , darwin ExitSuccess "Z!\n" ""
        , -- Each platform's letters are its own: D and t are Linux's, U and E
          -- macOS's.
          darwin ExitSuccess "D\n" ""
        , darwin ExitSuccess "t\n" ""
        , linux ExitSuccess "U\n" ""
        , linux ExitSuccess "SE\n" ""
        , presenceFrom "freebsd" (Private.ChildExited ExitSuccess) "Z\n" ""
        , presenceFrom "freebsd" (Private.ChildExited (ExitFailure 1)) "" ""
        ]
      -- A ps that cannot even be started is a failed inspection, not a gone
      -- process.
      missing ← getProcessID >>= try . inspectPresenceUsing "/nonexistent/hetoimasia-ps"
      either (\(problem ∷ IOException) → displayException problem) (const "") missing
        `shouldContain` "could not tell whether process"

    it "refuses a directly invoked child before looking up its scenario, and keeps the unknown-scenario exit for an approved one" $ do
      let plan consent name = either (\(code, message) → Left (code, message)) (Right . map fst) (Private.childPlan consent name)
      case plan (Left NoConsent) "session-lifecycle" of
        Left (code, message) → do
          code `shouldBe` Private.refusedExit
          message `shouldContain` "session-lifecycle"
          message `shouldContain` refusalMessage NoConsent
        Right names → fail ("an unapproved child planned " <> show names)
      case plan (Left NoConsent) "nonsense" of
        Left (code, _) → code `shouldBe` Private.refusedExit
        Right names → fail ("an unapproved child planned " <> show names)
      case plan (Right Desktop) "nonsense" of
        Left (code, message) → do
          code `shouldBe` Private.unknownScenarioExit
          message `shouldContain` "unknown private session scenario"
        Right names → fail ("an unknown scenario planned " <> show names)
      plan (Right (IsolatedX11 ":42")) "session-lifecycle"
        `shouldBe` Right
          [ "enters and leaves a real session"
          , "enters a second session after a complete teardown"
          , "observes an initialization error before any event polling"
          , "enters a session after the failed initialization rolled back"
          ]

-- | An owner that records its acquisition and release and serves 7.
recordingOwner ∷ IO (IORef [String], Owner Int)
recordingOwner = do
  events ← newIORef []
  let note event = modifyIORef' events (<> [event])
  pure
    ( events
    , Owner
        { ownerAcquire = allocResource (note "acquired" >> pure 7) (\_ → note "released")
        , ownerSettled = pure ()
        }
    )

-- | A launcher that records each scenario it is asked for and reports every
-- check passed, in time, without starting anything.
recordingLauncher ∷ IO (IORef [String], String → IO Private.Launched)
recordingLauncher = do
  launched ← newIORef []
  pure
    ( launched
    , \name → do
        modifyIORef' launched (<> [name])
        pure
          Private.Launched
            { Private.launchedEnd = Private.ChildExited ExitSuccess
            , Private.launchedOut = "glfw-native-tests " <> name <> ": every check passed\n"
            , Private.launchedErr = ""
            , Private.launchedPid = 0
            }
    )

refused ∷ Either SomeException a → Bool
refused = either ((== Just (NativeSessionRefused NoConsent)) . fromException) (const False)

-- | Run a nested spec silently, independent of this run's own options.
runNested ∷ (Config → Config) → Spec → IO SpecResult
runNested adjust nested = do
  (config, forest) ← evalSpec defaultConfig nested
  runSpecForest forest (adjust config) {configFormat = Just (formatterToFormat silent)}

-- | A caller's own annotation, used to prove a propagated failure keeps its context.
newtype Marker = Marker String
  deriving (Eq, Show)

instance ExceptionAnnotation Marker

-- | An example's wait, bounded so that a launcher that waits for an output pipe's
-- end of file, which an escaped writer never supplies, fails the example instead
-- of hanging the run. The bound is a failure bound, not a performance threshold.
bounded ∷ IO a → IO a
bounded = boundedBy "the launch did not return within a minute"

boundedBy ∷ String → IO a → IO a
boundedBy complaint action = timeout 60000000 action >>= maybe (fail complaint) pure

-- | Both parent-side handles closed and both readers finished. A handle's state
-- is read under its lock, which a reader still blocked on it holds, so a launch
-- that left a reader running answers this by never answering: that fails the
-- example here, by the bound, rather than hanging the run.
reclaimed ∷ Child.Owned → IO ()
reclaimed owned = do
  closed ← boundedBy "a pipe handle's state was never answered: a reader still holds it" (mapM hIsClosed (Child.ownedHandles owned))
  closed `shouldBe` [True, True]
  atomically (sequence (Child.ownedReadersFinished owned)) `shouldReturn` [True, True]

-- | A direct child that leaves a descendant in a session of its own holding
-- both inherited output pipes open, and waits for nothing else. The descendant
-- records its identifier, says one line on each stream, and tells the direct
-- child it is ready; the direct child then says one line on each stream and
-- exits. The descendant then blocks on a pipe nothing writes to, ending only when
-- it is killed.
escapedWriter ∷ String
escapedWriter =
  unlines
    [ "import os, sys"
    , "pid_file = sys.argv[1]"
    , "ready_read, ready_write = os.pipe()"
    , "if os.fork() == 0:"
    , "    os.setsid()"
    , "    os.close(ready_read)"
    , "    with open(pid_file + '.tmp', 'w') as f:"
    , "        f.write(str(os.getpid()))"
    , "    os.rename(pid_file + '.tmp', pid_file)"
    , "    sys.stdout.write('escaped-out\\n'); sys.stdout.flush()"
    , "    sys.stderr.write('escaped-err\\n'); sys.stderr.flush()"
    , "    os.write(ready_write, b'x')"
    , "    hold_read, hold_write = os.pipe()"
    , "    os.read(hold_read, 1)"
    , "    os._exit(0)"
    , "os.close(ready_write)"
    , "os.read(ready_read, 1)"
    , "sys.stdout.write('partial success\\n'); sys.stdout.flush()"
    , "sys.stderr.write('partial err\\n'); sys.stderr.flush()"
    , "os._exit(0)"
    ]

-- | A scratch directory for the escaped writer's identifier file, and the writer
-- killed on every way out: its identifier is read from the file once there is
-- one, so a failure at any point, even before the launcher returned, still ends it.
withEscapedWriter ∷ (FilePath → IO a) → IO a
withEscapedWriter body =
  bracket
    ( do
        temporary ← getTemporaryDirectory
        self ← getProcessID
        started ← getMonotonicTime
        let directory = temporary </> ("hetoimasia-launcher-" <> show self <> "-" <> show (round (started * 1000000) ∷ Integer))
        createDirectoryIfMissing True directory
        pure directory
    )
    ( \directory → do
        let pidFile = directory </> "escaped.pid"
        present ← doesFileExist pidFile
        if present then escapedPid pidFile >>= \escaped → void (try (signalProcess sigKILL escaped) ∷ IO (Either IOException ())) else pure ()
        removeDirectoryRecursive directory
    )
    (\directory → body (directory </> "escaped.pid"))

-- | The identifier the escaped writer recorded.
escapedPid ∷ FilePath → IO ProcessID
escapedPid pidFile = do
  text ← readFile pidFile
  maybe (fail ("the escaped writer's identifier file held " <> show text)) pure (readMaybe (takeWhile (/= '\n') text))
