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
-- carries no consent; and that the private-session parent starts no child
-- without consent while a directly invoked child refuses before its scenario is
-- even looked up.
module Test.GLFW.Native.Guard (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (void)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Hetoimasia.Foundation.Resource (allocResource)
import System.Exit (ExitCode (..))
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
import Test.Hspec (Spec, describe, it, shouldBe, shouldContain, shouldReturn, shouldSatisfy)
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

    it "names the missing consent, the approved command, and the isolated alternative in every refusal" $
      mapM_
        ( \refusal → do
            let message = refusalMessage refusal
            message `shouldContain` consentVariable
            message `shouldContain` (consentVariable <> "=" <> desktopValue)
            message `shouldContain` "ask"
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
-- check passed, without starting anything.
recordingLauncher ∷ IO (IORef [String], String → IO (ExitCode, String, String))
recordingLauncher = do
  launched ← newIORef []
  pure
    ( launched
    , \name → do
        modifyIORef' launched (<> [name])
        pure (ExitSuccess, "glfw-native-tests " <> name <> ": every check passed\n", "")
    )

refused ∷ Either SomeException a → Bool
refused = either ((== Just (NativeSessionRefused NoConsent)) . fromException) (const False)

-- | Run a nested spec silently, independent of this run's own options.
runNested ∷ (Config → Config) → Spec → IO SpecResult
runNested adjust nested = do
  (config, forest) ← evalSpec defaultConfig nested
  runSpecForest forest (adjust config) {configFormat = Just (formatterToFormat silent)}
