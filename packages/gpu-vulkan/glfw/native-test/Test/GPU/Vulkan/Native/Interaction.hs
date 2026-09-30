-- | RR-4's owner-loop interaction probe, extended with the graphics owner
-- (VK-16): what the main thread's owner turn and the supervised graphics
-- owner each do while a person moves, resizes and uses the menu bar against
-- one rendering window.
--
-- The GLFW package's probe measured that on Cocoa a live resize and a menu
-- interaction block the native event call for as long as the person
-- interacts, with no owner turn in between. D-29 moved rendering to a separate
-- graphics owner so that the owner can keep rendering what it holds while the
-- main thread is blocked; whether it does is a native measurement, never an
-- inference, and this is that measurement.
--
-- = What runs
--
-- The production composition, 'withVulkanOwnerHost', over one ordinary
-- 640×480 window, with the validation layer and synchronization validation,
-- driven by the composed loop 'runVulkanOwnerLoop'. A thread of its own — not
-- the main thread — publishes a new scene every 16 ms, which is what a
-- simulation or animation thread does (D-31); the owner renders each new
-- scene to the window, clearing it to a colour that moves with the scene's
-- revision, so a frame that reached the screen can be told from the one before
-- it by eye. The session's bounded trace ("Hetoimasia.Runtime.GLFW.Trace") is
-- started, so the main thread's owner turns, the native event call's entry and
-- exit and every callback delivered inside it are recorded; and every frame
-- event the owner reports — each acquisition, each present request before its
-- call, each present call's return, and each present fence observed signalled
-- by the owner's own poll — is recorded into the same trace from the owner's
-- thread, in the same monotonic time domain.
--
-- = It is not part of any routine run
--
-- It is gated exactly as RR-4's probe is: it needs the run's native consent,
-- and it is inactive — reported pending, opening no window — unless
-- @HETOIMASIA_INTERACTION_PROBE_SECONDS@ asks for it. No validation group names
-- it; the required group @test.vulkan-native@ reports it pending. It exists to
-- be invoked deliberately, once, by a person who has agreed to the disruption
-- and performs the interactions. It runs in a child process of this executable
-- with the parent's terminal, so the person sees each phase's instruction as it
-- begins.
--
-- = What it reports, and asserts
--
-- For each phase: the owner turns, the pumps and the longest of them, and the
-- frame evidence apart — present requests, present returns and present-fence
-- completions — overall and inside each pump that blocked for a quarter of a
-- second or more. A successful present return proves only that the request
-- was admitted, and a signalled present fence only that the presentation
-- engine finished with the image; neither is visible progress, which needs
-- direct visual evidence the probe does not collect. It asserts that each
-- phase measured something, that no phase lost records or faulted, and that
-- validation reported nothing; it asserts nothing about whether a stall
-- happened or whether frames advanced during one.
module Test.GPU.Vulkan.Native.Interaction
  ( spec
  , interactionProbeFlag
  , runInteractionProbe

    -- * Activation
  , probeVariable
  , probeOutputVariable
  , ProbeInactive (..)
  , probeActivation
  , inactiveMessage

    -- * The interactions asked for
  , Phase (..)
  , probePhases
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.STM (atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM_, unless, when)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, isPrefixOf, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Version (showVersion)
import Numeric (showFFloat)
import Numeric.Natural (Natural)
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Info (arch, compilerName, fullCompilerVersion, os)
import System.Process (CreateProcess (..), StdStream (Inherit), createProcess, proc, waitForProcess)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith)
import Text.Read (readMaybe)

import Hetoimasia.Foundation.Log (Logger, callbackSink, defaultLogFilter, mkLoggerWith, systemMetadata)
import Hetoimasia.Foundation.Messaging.Payload (prepare)
import Hetoimasia.Foundation.Time
  ( Duration
  , DurationRequirement (RequirePositive)
  , Instant
  , MonotonicSource
  , addDuration
  , convertedDuration
  , deadlineReached
  , durationFromSeconds
  , durationNanoseconds
  , elapsedBetween
  , monotonicSource
  , readInstant
  )
import Hetoimasia.GLFW.Vulkan (withLoaderIntegration)
import Hetoimasia.GLFW.Window (defaultWindowConfig)
import Hetoimasia.GPU.Model.Budget (defaultBudgetRequest, validateBudgets)
import Hetoimasia.GPU.Model.Identity (TargetClass (..))
import Hetoimasia.GPU.Vulkan.Diagnostics (CaptureConfig (..), DiagnosticVerdict, defaultCaptureConfig, verdictIssues)
import Hetoimasia.GPU.Vulkan.GLFW
  ( ClearColor (..)
  , FrameEvent (..)
  , Readiness (..)
  , VulkanHandover (..)
  , VulkanHost (..)
  , VulkanHostConfig (..)
  , clearRenderer
  , handOverVulkanTarget
  , publishVulkanScene
  , readReadiness
  , readVulkanRoots
  , runVulkanOwnerLoop
  , vulkanHostConfig
  , withVulkanOwnerHost
  )
import Hetoimasia.GPU.Vulkan.Native.Roots (RootsView (..))
import Hetoimasia.Runtime.GLFW
  ( ScheduledStep (..)
  , ScheduledTurn (..)
  , TargetStanding (..)
  , Turn (..)
  , UpdateSchedule (..)
  , defaultHostConfig
  , defaultScheduledHooks
  , graphicsAttachment
  , hostWindowIdentities
  , readTargetStanding
  , runGraphicsOwnerApplication
  )
import Hetoimasia.Runtime.GLFW.Trace
  ( PumpMode (..)
  , Trace
  , TraceEvent (..)
  , TraceEvidence (..)
  , TraceRecord (..)
  , defaultTraceCapacity
  , evidenceComplete
  , hostTrace
  , recordTrace
  , startTrace
  , stopTrace
  , takeTrace
  )
import Hetoimasia.Runtime.Logging (withLoggingLifetime)
import Hetoimasia.GLFW.Session (Backend)
import Test.GPU.Vulkan.Native.Consent (Consent, Refusal, consentBackend, refusalMessage)
import Test.GPU.Vulkan.Native.Platform (requestingBackend)
import Test.GPU.Vulkan.Native.Environment (validationFeatures)
import Test.GPU.Vulkan.Native.Gate (Gate, admit)

-- ---------------------------------------------------------------------------
-- Activation

-- | The variable that activates the probe, holding the seconds each phase
-- lasts: the same one RR-4's probe reads. Unset, the probe is pending and
-- opens no window.
probeVariable ∷ String
probeVariable = "HETOIMASIA_INTERACTION_PROBE_SECONDS"

-- | An optional file the run writes every record to, so the timestamped
-- evidence can be retained beside a verdict: the same one RR-4's probe
-- reads. Unset, only the summary is printed.
probeOutputVariable ∷ String
probeOutputVariable = "HETOIMASIA_INTERACTION_PROBE_OUTPUT"

-- | Why the probe did not run.
data ProbeInactive
  = ProbeNotRequested
  | ProbeNotSeconds !String
  deriving (Eq, Show)

-- | Whether the environment activates the probe, and for how many seconds a
-- phase.
probeActivation ∷ [(String, String)] → Either ProbeInactive Double
probeActivation environment = case lookup probeVariable environment of
  Nothing → Left ProbeNotRequested
  Just "" → Left ProbeNotRequested
  Just value → case readMaybe value of
    Just seconds
      | seconds > 0 && not (isInfinite seconds) && not (isNaN seconds) → Right seconds
    _ → Left (ProbeNotSeconds value)

inactiveMessage ∷ ProbeInactive → String
inactiveMessage = \case
  ProbeNotRequested →
    "the graphics-owner interaction probe runs only when "
      <> probeVariable
      <> " names the seconds each phase lasts, and it needs a person at the desktop"
  ProbeNotSeconds value → probeVariable <> " is not a positive number of seconds: " <> show value

-- | The flag that turns this executable into the probe's child.
interactionProbeFlag ∷ String
interactionProbeFlag = "--interaction-probe"

-- ---------------------------------------------------------------------------
-- The interactions

-- | One interval of the measurement, and what the person is asked to do in
-- it.
data Phase = Phase
  { phaseName ∷ !Text
  , phaseInstruction ∷ !String
  }
  deriving (Eq, Show)

-- | RR-4's phases, in RR-4's order and words: an idle baseline first.
probePhases ∷ [Phase]
probePhases =
  [ Phase "idle baseline" "do not touch the window, the mouse, or the keyboard"
  , Phase "window move" "press and hold on the window's title bar and keep dragging it, without letting go"
  , Phase "window resize" "press and hold on an edge or a corner of the window and keep dragging it, without letting go"
  , Phase "menu-bar interaction" "open a menu in the menu bar, keep it open, and move through its entries"
  ]

-- ---------------------------------------------------------------------------
-- The example

spec ∷ Gate → Spec
spec gate = describe "graphics-owner progress during window interactions" $
  it "records the native pump, the callbacks inside it, owner turns, and the graphics owner's present requests and present-fence completions while a person moves, resizes, and uses the menu bar" $ do
    _ ← admit gate
    probeActivation <$> getEnvironment >>= \case
      Left inactive → pendingWith (inactiveMessage inactive)
      Right _ → do
        executable ← getExecutablePath
        -- The child shares this terminal, so the person sees each phase's
        -- instruction when it begins.
        (_, _, _, child) ← createProcess (proc executable [interactionProbeFlag]) {std_in = Inherit, std_out = Inherit, std_err = Inherit}
        waitForProcess child >>= \case
          ExitSuccess → pure ()
          status → expectationFailure ("the interaction probe's process exited " <> show status)

-- | The probe as this process's whole work, on its main thread.
runInteractionProbe ∷ Either Refusal Consent → IO ()
runInteractionProbe = \case
  Left refusal → do
    hPutStrLn stderr ("vulkan-native-tests interaction probe: " <> Text.unpack (refusalMessage refusal))
    exitWith (ExitFailure 3)
  Right consent → do
    environment ← getEnvironment
    seconds ← case probeActivation environment of
      Left inactive → hPutStrLn stderr (inactiveMessage inactive) >> exitWith (ExitFailure 2)
      Right seconds → pure seconds
    duration ← case durationFromSeconds RequirePositive seconds of
      Right converted → pure (convertedDuration converted)
      Left rejected → failWith (probeVariable <> " is not a duration: " <> show rejected)
    outcome ← try @SomeException (measure (consentBackend consent) duration)
    case outcome of
      Left failure → failWith ("the probe failed: " <> displayException failure)
      Right (device, verdict, results) → do
        putStr (report environment device seconds results verdict)
        hFlush stdout
        forM_ (lookup probeOutputVariable environment) $ \path → do
          writeFile path (dump environment device seconds results verdict)
          putStrLn ("vulkan-native-tests interaction probe: every record written to " <> path)
          hFlush stdout
        problems ← pure (concatMap checkPhase results <> verdictProblems verdict)
        unless (null problems) $ do
          mapM_ (hPutStrLn stderr . ("vulkan-native-tests interaction probe: " <>)) problems
          exitWith (ExitFailure 1)
        putStrLn "vulkan-native-tests interaction probe: every phase was measured with complete evidence"

failWith ∷ String → IO a
failWith message = hPutStrLn stderr ("vulkan-native-tests interaction probe: " <> message) >> exitWith (ExitFailure 1)

-- | What one phase produced.
data PhaseResult = PhaseResult
  { resultPhase ∷ !Phase
  , resultEvidence ∷ !TraceEvidence
  }

checkPhase ∷ PhaseResult → [String]
checkPhase result =
  [ "the " <> name <> " phase recorded no owner turn at all" | null [() | TurnBegan _ ← events]]
    <> ["the " <> name <> " phase recorded no complete native pump" | null (pumpIntervals (evidenceRecords evidence))]
    <> [ "the "
           <> name
           <> " phase lost "
           <> show (evidenceLost evidence)
           <> " record(s) and faulted "
           <> show (evidenceFaults evidence)
           <> " time(s), so its evidence is incomplete; shorten the phase and run it again"
       | not (evidenceComplete evidence)
       ]
  where
    evidence = resultEvidence result
    events = map recordEvent (evidenceRecords evidence)
    name = Text.unpack (phaseName (resultPhase result))

verdictProblems ∷ Maybe DiagnosticVerdict → [String]
verdictProblems = \case
  Nothing → ["the host returned no diagnostic verdict"]
  Just verdict → ["validation reported " <> show (verdictIssues verdict) | not (null (verdictIssues verdict))]

-- ---------------------------------------------------------------------------
-- Measuring

-- | Run the composed loop through every phase, on the process main thread.
measure ∷ Maybe Backend → Duration → IO (Text, Maybe DiagnosticVerdict, [PhaseResult])
measure backend duration = do
  traced ← newIORef Nothing
  collected ← newIORef []
  verdictHeld ← newIORef Nothing
  deviceHeld ← newIORef "unknown"
  -- The scene the owner renders is its publication's number.
  scene ← prepare (0 ∷ Natural)
  budgets ← either (\rejected → failWith ("the budgets were refused: " <> show rejected)) pure (validateBudgets defaultBudgetRequest)
  let host = requestingBackend backend (defaultHostConfig [defaultWindowConfig "Hetoimasia graphics-owner interaction probe" 640 480])
      config =
        (vulkanHostConfig host defaultCaptureConfig {captureTextBudget = 16384} budgets scene)
          { vulkanLayers = ["VK_LAYER_KHRONOS_validation"]
          , vulkanValidationFeatures = validationFeatures
          , vulkanRenderer = clearRenderer (\number _ → colour number)
          , -- Recorded on the owner's thread into the session's trace, once
            -- the host exists and the trace has been started.
            vulkanFrameObserver = \event → readIORef traced >>= mapM_ (\trace → recordTrace trace (Marked (describeFrame event)))
          }
  withLoaderIntegration $ \integration →
    runGraphicsOwnerApplication
      (withLoggingLifetime quietLogger)
      "vulkan-interaction-probe"
      ( \_ use → do
          (result, verdict) ← withVulkanOwnerHost quietLogger integration config use
          writeIORef verdictHeld (Just verdict)
          pure result
      )
      vulkanWindowHost
      (\vulkan _ → pure vulkan)
      (\vulkan control → body vulkan control traced collected deviceHeld)
  (,,) <$> readIORef deviceHeld <*> readIORef verdictHeld <*> readIORef collected
  where
    body vulkan control traced collected deviceHeld = do
      readiness ← atomically (readReadiness (vulkanController vulkan))
      _ ← waitUntil (atomically (readReadiness (vulkanController vulkan))) (/= RootsPending) readiness
      windows ← atomically (hostWindowIdentities (vulkanWindowHost vulkan))
      window ← case windows of
        [one] → pure one
        other → failWith ("the host holds " <> show (length other) <> " windows, not one")
      service ←
        handOverVulkanTarget vulkan window RequiredTarget >>= \case
          VulkanTargetHandedOver service → pure service
          other → failWith ("the window was not handed over: " <> show other)
      standing ← waitUntil (atomically (readTargetStanding (vulkanGraphicsOwner vulkan) (graphicsAttachment service))) settled Nothing
      unless (standing == Just TargetUsable) (failWith ("the target was not admitted: " <> show standing))
      roots ← atomically (readVulkanRoots (vulkanController vulkan))
      writeIORef deviceHeld (fromMaybe "unknown" (viewDeviceName roots))
      let trace = hostTrace (vulkanWindowHost vulkan)
      -- The scene thread: every 16 ms a new scene, from a thread that is not
      -- the main one, so a stalled main thread does not stall it.
      running ← newTVarIO True
      _ ← forkIO $
        let publish number = do
              continue ← readTVarIO running
              when continue $ do
                _ ← publishVulkanScene vulkan =<< prepare number
                threadDelay 16000
                publish (number + 1)
         in publish 1
      case probePhases of
        [] → pure ()
        first : rest → do
          pending ← newIORef rest
          current ← newIORef first
          announce first
          deadline ← newIORef =<< after clock duration
          startTrace trace clock defaultTraceCapacity
          writeIORef traced (Just trace)
          mark trace first "begins"
          runVulkanOwnerLoop vulkan control . defaultScheduledHooks quietLogger $ \turn → do
            let number = turnNumber (scheduledTurn turn)
            recordTrace trace (UpdateHookEntered number)
            now ← readInstant clock
            reached ← deadlineReached now <$> readIORef deadline
            recordTrace trace (UpdateHookLeft number)
            if reached
              then advance trace collected pending current deadline
              else pure (ContinueWith NoUpdateDemand)
          writeIORef traced Nothing
      atomically (writeTVar running False)
    settled = \case
      Just TargetConstructing → False
      Nothing → False
      _ → True
    clock = monotonicSource
    advance trace collected pending current deadline = do
      finished ← readIORef current
      mark trace finished "ends"
      evidence ← takeTrace trace
      modifyIORef' collected (<> [PhaseResult finished evidence])
      readIORef pending >>= \case
        [] → FinishWith () <$ stopTrace trace
        next : rest → do
          writeIORef pending rest
          writeIORef current next
          announce next
          writeIORef deadline =<< after clock duration
          mark trace next "begins"
          pure (ContinueWith NoUpdateDemand)

-- | Poll an action on the main thread until its answer is accepted, for at
-- most ten seconds; the host's own loop is not yet running, and nothing here
-- needs it to.
waitUntil ∷ IO a → (a → Bool) → a → IO a
waitUntil read' accepted = go (1000 ∷ Int)
  where
    go remaining latest
      | accepted latest = pure latest
      | remaining <= 0 = failWith "the host did not become ready within ten seconds"
      | otherwise = threadDelay 10000 >> read' >>= go (remaining - 1)

-- | A colour that moves around the hue circle with the scene's number, one
-- revolution in about four seconds at sixty scenes a second.
colour ∷ Natural → ClearColor
colour number = ClearColor (channel 0) (channel (1 / 3)) (channel (2 / 3)) 1
  where
    phase = fromIntegral (number `mod` 240) / 240 ∷ Float
    channel offset = 0.5 + 0.5 * cos (2 * pi * (phase + offset))

mark ∷ Trace → Phase → Text → IO ()
mark trace phase what = recordTrace trace (Marked (phaseName phase <> " " <> what))

announce ∷ Phase → IO ()
announce phase = do
  putStrLn ""
  putStrLn ("vulkan-native-tests interaction probe — " <> Text.unpack (phaseName phase))
  putStrLn ("  from now until this says otherwise: " <> phaseInstruction phase)
  hFlush stdout

after ∷ MonotonicSource → Duration → IO Instant
after clock duration = do
  now ← readInstant clock
  either (\overflow → failWith ("the phase deadline overflowed: " <> show overflow)) pure (addDuration now duration)

quietLogger ∷ Logger
quietLogger = mkLoggerWith defaultLogFilter systemMetadata (callbackSink (\_ → pure ()))

-- | How a frame event is placed in the trace. The prefix names the kind, so
-- the report can read the kinds back apart.
describeFrame ∷ FrameEvent → Text
describeFrame = \case
  FrameAcquired attachment frame image → "owner acquired " <> tshow frame <> " " <> tshow image <> " for " <> tshow attachment
  FramePending attachment reason → "owner pending " <> tshow reason <> " for " <> tshow attachment
  FrameSubmitted _ frame submission → "owner submitted " <> tshow frame <> " as " <> tshow submission
  FramePresentRequested _ frame image revision → "owner present-request " <> tshow frame <> " " <> tshow image <> " scene " <> tshow revision
  FramePresented _ frame presentation outcome → "owner present-returned " <> tshow frame <> " " <> tshow presentation <> " " <> tshow outcome
  FrameAbandoned _ frame reason → "owner abandoned " <> tshow frame <> ": " <> reason
  SubmissionCompleted submission → "owner submission-completed " <> tshow submission
  PresentationRetired presentation → "owner present-fence-signalled " <> tshow presentation

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show

-- ---------------------------------------------------------------------------
-- Reading the records

-- | One entry into the native event call and its matching exit.
data PumpInterval = PumpInterval
  { intervalMode ∷ !PumpMode
  , intervalStart ∷ !Instant
  , intervalEnd ∷ !Instant
  , intervalCallbacks ∷ !Int
  }

pumpIntervals ∷ [TraceRecord] → [PumpInterval]
pumpIntervals = go Nothing
  where
    go _ [] = []
    go open (record : rest) = case (recordEvent record, open) of
      (PumpEntered mode, _) → go (Just (mode, recordInstant record, 0)) rest
      (PumpLeft mode, Just (_, start, inside)) → PumpInterval mode start (recordInstant record) inside : go Nothing rest
      (CallbackDelivered _ _, Just (mode, start, inside)) → go (Just (mode, start, inside + 1)) rest
      _ → go open rest

intervalDuration ∷ PumpInterval → Duration
intervalDuration interval = elapsedBetween (intervalStart interval) (intervalEnd interval)

-- | The frame evidence kinds, read back from their marks.
data FrameKind = Requested | Returned | Completed
  deriving (Eq, Ord, Show)

frameKind ∷ TraceEvent → Maybe FrameKind
frameKind = \case
  Marked text
    | "owner present-request " `Text.isPrefixOf` text → Just Requested
    | "owner present-returned " `Text.isPrefixOf` text → Just Returned
    | "owner present-fence-signalled " `Text.isPrefixOf` text → Just Completed
  _ → Nothing

-- | How many of each kind fall inside this interval.
framesInside ∷ [TraceRecord] → PumpInterval → Map.Map FrameKind Int
framesInside records interval =
  Map.fromListWith
    (+)
    [ (kind, 1)
    | record ← records
    , Just kind ← [frameKind (recordEvent record)]
    , recordInstant record >= intervalStart interval
    , recordInstant record <= intervalEnd interval
    ]

-- | A pump that blocked for at least this long counts as a stall for the
-- report's frame counts; it is a reading threshold, not a verdict.
stallThreshold ∷ Double
stallThreshold = 0.25

-- ---------------------------------------------------------------------------
-- The report

report ∷ [(String, String)] → Text → Double → [PhaseResult] → Maybe DiagnosticVerdict → String
report environment device seconds results verdict =
  unlines $
    [ ""
    , "vulkan-native-tests graphics-owner interaction probe"
    ]
      <> map ("  " <>) (identity environment device seconds)
      <> ["  every instant below is an offset from the first record of its own phase, on one monotonic clock"]
      <> concatMap phaseReport results
      <> [ ""
         , "validation: " <> maybe "no verdict" (show . verdictIssues) verdict
         , "A present return proves only that the request was admitted, and a present fence only that the"
         , "presentation engine finished with the image. Neither is visible progress; that needs direct visual evidence."
         ]

identity ∷ [(String, String)] → Text → Double → [String]
identity environment device seconds =
  [ "platform " <> os <> " " <> arch <> "; compiler " <> compilerName <> " " <> showVersion fullCompilerVersion
  , "device " <> Text.unpack device
  , "seconds per phase " <> showSeconds seconds <> "; trace capacity " <> show defaultTraceCapacity <> " records"
  , "scenes published every 16 ms from a thread other than the main one"
  ]
    <> [ name <> " " <> value
       | (name, value) ← sortOn fst environment
       , any (`isPrefixOf` name) ["HETOIMASIA_VULKAN_", "VK_DRIVER_FILES", "VK_LAYER_PATH", "HETOIMASIA_NATIVE_PREFIX"]
       ]

phaseReport ∷ PhaseResult → [String]
phaseReport result =
  [ ""
  , "phase " <> show (Text.unpack (phaseName (resultPhase result)))
  , "  asked for: " <> phaseInstruction (resultPhase result)
  ]
    <> case records of
      [] → ["  nothing was recorded"]
      first : _ →
        let origin = recordInstant first
            intervals = pumpIntervals records
            stalls = [interval | interval ← intervals, secondsOf (intervalDuration interval) >= stallThreshold]
            counts = Map.fromListWith (+) [(kind, 1 ∷ Int) | Just kind ← map (frameKind . recordEvent) records]
         in [ "  owner turns "
                <> show (length [() | TurnBegan _ ← map recordEvent records])
                <> "; pumps "
                <> show (length intervals)
                <> "; callbacks "
                <> show (length [() | CallbackDelivered _ _ ← map recordEvent records])
            , "  frames: " <> showCounts counts
            , "  pumps blocked for " <> showSeconds (stallThreshold * 1000) <> " ms or more: " <> show (length stalls)
            , "  evidence "
                <> (if evidenceComplete evidence then "complete" else "INCOMPLETE")
                <> " ("
                <> show (evidenceLost evidence)
                <> " lost, "
                <> show (evidenceFaults evidence)
                <> " faults)"
            ]
              <> map (("    " <>) . describeStall origin) (take 5 (sortOn (Down . intervalDuration) stalls))
  where
    evidence = resultEvidence result
    records = evidenceRecords evidence
    describeStall origin interval =
      mode interval
        <> " took "
        <> showDuration (intervalDuration interval)
        <> " at +"
        <> showDuration (elapsedBetween origin (intervalStart interval))
        <> " with "
        <> show (intervalCallbacks interval)
        <> " callback(s); inside it the graphics owner made "
        <> showCounts (framesInside records interval)
    mode interval = case intervalMode interval of
      PolledEvents → "a poll"
      WaitedForEvents requested → "a wait of " <> showSeconds (requested * 1000) <> " ms"

showCounts ∷ Map.Map FrameKind Int → String
showCounts counts =
  intercalate
    ", "
    [ show (Map.findWithDefault 0 Requested counts) <> " present requests"
    , show (Map.findWithDefault 0 Returned counts) <> " present returns"
    , show (Map.findWithDefault 0 Completed counts) <> " present-fence completions"
    ]

secondsOf ∷ Duration → Double
secondsOf duration = fromIntegral (durationNanoseconds duration) / 1e9

showDuration ∷ Duration → String
showDuration duration = showSeconds (secondsOf duration * 1000) <> " ms"

showSeconds ∷ Double → String
showSeconds value = showFFloat (Just 3) value ""

-- ---------------------------------------------------------------------------
-- The retained dump

-- | The identities, then every record of every phase, one per line: its
-- sequence number, its offset from the first record of its phase, and the
-- event.
dump ∷ [(String, String)] → Text → Double → [PhaseResult] → Maybe DiagnosticVerdict → String
dump environment device seconds results verdict =
  unlines $
    ["# vulkan-native-tests graphics-owner interaction probe"]
      <> map ("# " <>) (identity environment device seconds)
      <> ["# validation: " <> maybe "no verdict" (show . verdictIssues) verdict]
      <> concatMap phaseDump results
  where
    phaseDump result =
      [ "# phase " <> Text.unpack (phaseName (resultPhase result))
      , "# asked for: " <> phaseInstruction (resultPhase result)
      , "# lost " <> show (evidenceLost evidence) <> "; faults " <> show (evidenceFaults evidence)
      , "# sequence\toffset_ms\tevent"
      ]
        <> case evidenceRecords evidence of
          [] → ["# no records"]
          first : _ → map (line (recordInstant first)) (evidenceRecords evidence)
      where
        evidence = resultEvidence result
    line origin record =
      show (recordSequence record)
        <> "\t"
        <> showSeconds (secondsOf (elapsedBetween origin (recordInstant record)) * 1000)
        <> "\t"
        <> describeEvent (recordEvent record)

describeEvent ∷ TraceEvent → String
describeEvent = \case
  TurnBegan number → "turn " <> show number <> " began"
  PumpEntered PolledEvents → "pump entered (poll)"
  PumpEntered (WaitedForEvents requested) → "pump entered (wait " <> showSeconds (requested * 1000) <> " ms)"
  PumpLeft PolledEvents → "pump left (poll)"
  PumpLeft (WaitedForEvents requested) → "pump left (wait " <> showSeconds (requested * 1000) <> " ms)"
  CallbackDelivered window name → "callback " <> Text.unpack name <> " on window " <> Text.unpack window
  UpdateHookEntered number → "update hook entered (turn " <> show number <> ")"
  UpdateHookLeft number → "update hook left (turn " <> show number <> ")"
  Marked what → "mark: " <> Text.unpack what
