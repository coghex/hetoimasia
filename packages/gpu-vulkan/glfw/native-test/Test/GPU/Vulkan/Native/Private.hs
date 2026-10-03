-- | Native cases that need roots of their own, each in a child process of this
-- executable.
--
-- The shared fixture holds one GLFW session, one instance and one device for
-- the whole run, so nothing that has to create, fail, or destroy those can run
-- beside it: GLFW allows one session per process, and a case whose point is
-- the destruction order of the roots, or a deliberate validation error, would
-- destroy or poison what every other example shares. Each such case therefore
-- runs in a child started with @--private-roots <scenario>@, on the child's own
-- process main thread, with private roots from start to teardown:
--
-- * @vk2-compatibility@ — VK-2's compatibility, completion, abandonment and
--   capture proof (#158), with its pure release decisions;
-- * @vk6-capture@ — VK-6's C-only validation capture (#217);
-- * @vk5-bridge@ — VK-5's loader-aware surface bridge (#216);
-- * @vk7-roots@ — VK-7's roots under the graphics owner, over two windows,
--   including the destruction order at the host's exit (#219);
-- * @vk11-recording@ — VK-11's managed resources and a recorded, discarded
--   triangle batch against a swapchain generation's image (#223), then a
--   buffer and an image of every kind created, named, released and disposed
--   of (#334);
-- * @vk12-frames@ — VK-12's frames: acquired, a triangle batch with its
--   capture submitted and awaited, and images returned through cleanup
--   submissions and maintenance release without presenting (#225);
-- * @vk13-presentation@ — VK-13's presentation to two windows with verified
--   present fences, a resized window's old generation retired only on that
--   evidence, the first window closed while the second keeps presenting, and
--   the session retired with every fence observed (#227);
-- * @vk14-recovery@ — VK-14's recovery: a lost surface and its swapchain
--   replaced on the same live window while a second window keeps presenting,
--   and an allocation that ran out of memory recovered by reclaiming a
--   retired generation (#229);
-- * @vk15-validation-stop@ — VK-15's validation error during rendering,
--   stopping the session at the next checkpoint and tearing it down with the
--   error as its primary failure (#231);
-- * @vk15-retention@ — VK-15's retained unverified resource, reported rather
--   than released, ending by process termination rather than orderly cleanup
--   (#231);
-- * @vk16-composed@ — VK-16's two targets rendered through the composed loop,
--   one hidden, suspended and shown again while the other keeps presenting,
--   and the host's exit through D-33 ("Test.GPU.Vulkan.Native.Composed", #232;
--   required on Wayland too since #357);
-- * @vk17-one-slot@ and @vk17-two-slots@ — VK-17's required profile: the
--   triangle sample's renderer in two windows, each captured, the first
--   resized and captured at its new extent and then closed while the second
--   keeps rendering, with one frame slot and with two
--   ("Test.GPU.Vulkan.Native.Triangle", #233);
-- * @vk19-capture@ — VK-19's consumer-built triangle pipeline, captured from
--   two targets through the production host with verification capture on
--   ("Test.GPU.Vulkan.Native.Capture", #299);
-- * @grs15-surface-free@ — GRS-15's surface-free session with no window: the
--   device created in the owner's startup, a pipeline layout and a pipeline
--   built and released through owner-thread actions and destroyed by the
--   owner's own progress, and a clean exit ("Test.GPU.Vulkan.Native.SurfaceFree",
--   #336);
-- * @grs15-surface-free-window@ — the same device start, then a window admitted
--   against its queue family and presented to (#336);
-- * @grs12-frameless@ — the same device start with no window, then frame-less
--   batches over a managed color target and buffer recorded through
--   owner-thread actions, submitted when each returns, and their tickets
--   waited for (#337);
-- * @grs5-offscreen@ — the same device start with no window, then managed
--   RGBA8 color targets, sRGB and linear, rendered into by frame-less batches,
--   copied to readback buffers and probed for exact bytes, each written as a
--   PNG to a temporary path that is printed and never committed (#338);
-- * @grs4-drawing@ — the same device start with no window, then the
--   session's shared ring, a pipeline with vertex input and a push-constant
--   range, and a frame-less batch that writes a quad, its 16-bit indices and
--   two instance offsets into ring regions, pushes a color, draws indexed and
--   instanced into an RGBA8 color target and reads it back, probed for exact
--   bytes inside each quad and outside both (#340);
-- * @grs6-uploads@ — the same device start with no window, then an RGBA8
--   texture of two levels uploaded over several turns, a BC7 one where the
--   device takes it — reported unsupported where it does not — and a quad's
--   vertex, instance-offset and index buffers, admitted off the owner's thread
--   and waited for with a deadline; every level copied back and compared
--   exactly, and the quad drawn from the uploaded buffers and probed (#342);
-- * @grs7-texture-table@ — the same device start with no window, then the
--   session's texture table: a texture registered before its upload drawn as
--   the transparent placeholder, two uploaded textures drawn through their
--   handles with a sampler each, a batch recorded with a texture's handle
--   that is then released and another texture registered before the batch
--   is submitted, which still draws the original, and the new texture drawn
--   beside the released handle, which resolves to the placeholder; every
--   batch read back and probed (#343);
-- * @grs3-ordering@ — GRS-3's managed depth target and buffer written by an
--   initializing batch, then by two batches submitted in order with no
--   completion wait between and no layout change, ordered only by the
--   recorder's checked transitions and boundary barriers
--   ("Test.GPU.Vulkan.Native.Ordering", #335);
-- * @synchronization-hazard@ — the negative control that proves
--   synchronization validation active ("Test.GPU.Vulkan.Native.Hazard");
-- * @debug-names@ — #250's provoked validation report on a named managed
--   resource inside a labelled batch ("Test.GPU.Vulkan.Native.Naming");
-- * @wayland-connection-loss@ — WL-4's compositor ended while the production
--   host renders to a Wayland surface ("Test.GPU.Vulkan.Native.ConnectionLoss",
--   #327). It runs only under the isolated compositor's consent; under any
--   other consent its example is pending, asserts nothing, and starts no child,
--   and the complete profile does not require it ('requiredScenarios').
--
-- A scenario with a named Wayland gap ('scenarioWaylandPending') would be
-- pending under the isolated compositor's consent, start no child, and not be
-- required there. None has one: @vk16-composed@'s, hiding a presenting window,
-- was closed by #357.
--
-- Every child requests the backend its consent names
-- ("Test.GPU.Vulkan.Native.Platform"): Wayland by name under the isolated
-- compositor's consent, and the platform's own backend otherwise.
--
-- The child asserts its migrated examples exactly as the proof did: the whole
-- spec and only the whole spec, through Hspec's own primitives with the
-- configuration-reading step left out, so an ambient @HSPEC_*@ or a @.hspec@
-- file cannot narrow what its verdict speaks for. The parent example passes
-- only when the child ran every one of them and every one passed. Its output,
-- and the record the child writes, go to the evidence directory the validation
-- runner names, so a failed or expired run keeps them.
--
-- Each child is bounded from outside ("Test.GPU.Vulkan.Native.Child"): its
-- deadline, 'childDeadline', covers its exit and the end of its output, and a
-- child still running at it is terminated with its process group and fails its
-- example as expired, whatever it printed.
--
-- The parent starts no child without the run's consent, and the child, which
-- inherits it, refuses on stderr with exit status 3 when started directly
-- without it, before it looks its scenario up; an unknown scenario under
-- consent exits 2.
module Test.GPU.Vulkan.Native.Private
  ( privateRootsFlag
  , scenarioNames
  , requiredScenarios
  , runScenario
  , spec
  , ChildRun (..)
  ) where

import Control.Monad (unless)
import Data.IORef (IORef, modifyIORef')
import Data.List (isInfixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import System.Environment (getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import Foreign.C.Types (CInt (..))
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import Test.Hspec (Spec, describe, expectationFailure, it, pendingWith)
import Test.Hspec.Runner (Config (configFailOnEmpty), defaultConfig, evalSpec, runSpecForest, specResultSuccess)

import Test.GPU.Vulkan.Native.Child (ChildEnd (..), Launched (..), launchCommand)
import Test.GPU.Vulkan.Native.Consent (Consent (..), Refusal, consentBackend, refusalMessage)
import Test.GPU.Vulkan.Native.Environment (checkValidationFeatures)
import Test.GPU.Vulkan.Native.Gate (Gate, admit)
import qualified Test.GPU.Vulkan.Native.Capture as Capture
import qualified Test.GPU.Vulkan.Native.Composed as Composed
import qualified Test.GPU.Vulkan.Native.ConnectionLoss as ConnectionLoss
import qualified Test.GPU.Vulkan.Native.Frames as Frames
import qualified Test.GPU.Vulkan.Native.Hazard as Hazard
import qualified Test.GPU.Vulkan.Native.Naming as Naming
import qualified Test.GPU.Vulkan.Native.Ordering as Ordering
import qualified Test.GPU.Vulkan.Native.Presentation as Presentation
import qualified Test.GPU.Vulkan.Native.Recovery as Recovery
import qualified Test.GPU.Vulkan.Native.Recording as Recording
import qualified Test.GPU.Vulkan.Native.SurfaceFree as SurfaceFree
import qualified Test.GPU.Vulkan.Native.Terminal as Terminal
import qualified Test.GPU.Vulkan.Native.Triangle as Triangle
import qualified Test.Vulkan.Proof.Bridge as Bridge
import qualified Test.Vulkan.Proof.BridgeSpec as BridgeSpec
import qualified Test.Vulkan.Proof.Diagnostics as Diagnostics
import qualified Test.Vulkan.Proof.DiagnosticsSpec as DiagnosticsSpec
import Test.Vulkan.Proof.Journal (Journal, entries, newEchoingJournal)
import Test.Vulkan.Proof.Record (bridgeSection, diagnosticsSection, renderRecord, rootsSection)
import qualified Test.Vulkan.Proof.Roots as Roots
import qualified Test.Vulkan.Proof.RootsSpec as RootsSpec
import Test.Vulkan.Proof.Run (runProof)
import qualified Test.Vulkan.Proof.Spec as Proof

-- | The flag that turns this executable into one scenario's child.
privateRootsFlag ∷ String
privateRootsFlag = "--private-roots"

-- | What one child's run cost, for the report the parent prints at the end.
data ChildRun = ChildRun
  { childScenario ∷ !String
  , childSeconds ∷ !Double
  , childStatus ∷ !ExitCode
  }
  deriving (Show)

-- | One scenario: what its example is called, and how the child runs it.
data Scenario = Scenario
  { scenarioName ∷ String
  , scenarioTitle ∷ String
  , scenarioWaylandOnly ∷ Bool
    -- ^ Whether it runs only under the isolated compositor's consent.
  , scenarioWaylandPending ∷ Maybe String
    -- ^ Why it is pending under the isolated compositor's consent, when it
    -- cannot run there: a known engine gap, named, never a silent skip.
  , scenarioRun ∷ Consent → Journal → Conclude → IO (Spec, Bool → [Text] → Text)
    -- ^ The native procedure, run to completion and torn down before it
    -- returns; then the examples that assert over what it saw, and the record
    -- that states their verdict. A procedure whose point is a lifetime that
    -- cannot end hands those to the 'Conclude' instead, which never returns.
  }

-- | Assert a scenario's examples, retain its record and end the process with
-- the verdict, from any thread and without unwinding anything: #220's
-- destructive boundary, for a case whose session deliberately retains what it
-- could not verify and therefore never returns.
type Conclude = (Spec, Bool → [Text] → Text) → IO ()

scenarios ∷ [Scenario]
scenarios =
  [ Scenario
      "vk2-compatibility"
      "proves the VK-2 compatibility profile, presentation completion, safe abandonment and capture"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← runProof journal consent
        pure (Proof.spec outcome, \passed transcript → renderRecord "The VK-2 native Vulkan compatibility record" (invocation consent) transcript outcome passed)
  , Scenario "vk6-capture" "proves VK-6's C-only validation capture on an instance of its own" False Nothing $ \_ journal _ → do
      outcome ← Diagnostics.runDiagnostics journal
      pure (DiagnosticsSpec.spec outcome, section "The VK-6 validation capture record" (diagnosticsSection outcome))
  , Scenario "vk5-bridge" "proves VK-5's loader-aware surface bridge in a session of its own" False Nothing $ \consent journal _ → do
      outcome ← Bridge.runBridge (consentBackend consent) journal
      pure (BridgeSpec.spec outcome, section "The VK-5 surface bridge record" (bridgeSection outcome))
  , Scenario "vk7-roots" "proves VK-7's roots under the graphics owner, through their destruction at the host's exit" False Nothing $ \consent journal _ → do
      outcome ← Roots.runRoots (consentBackend consent) journal
      pure (RootsSpec.spec outcome, section "The VK-7 Vulkan roots record" (rootsSection outcome))
  , Scenario
      "vk11-recording"
      "records and discards a triangle batch through VK-11's managed resources, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Recording.runRecording (consentBackend consent) journal
        pure (Recording.spec outcome, section "The VK-11 managed recording record" (Recording.recordingSection outcome))
  , Scenario
      "vk12-frames"
      "acquires, submits and awaits a triangle batch with its capture, and returns images without presenting, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Frames.runFrames (consentBackend consent) journal
        pure (Frames.spec outcome, section "The VK-12 frames record" (Frames.framesSection outcome))
  , Scenario
      "vk13-presentation"
      "presents to two windows on verified present fences, retires a resized generation and the first window on that evidence, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Presentation.runPresentation (consentBackend consent) journal
        pure (Presentation.spec outcome, section "The VK-13 presentation record" (Presentation.presentationSection outcome))
  , Scenario
      "vk14-recovery"
      "replaces a lost surface on its live window while another presents, and recovers an allocation by reclaiming a retired generation, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Recovery.runRecovery (consentBackend consent) journal
        pure (Recovery.spec outcome, section "The VK-14 recovery record" (Recovery.recoverySection outcome))
  , Scenario
      "vk15-validation-stop"
      "stops rendering at the checkpoint after an injected validation error, tearing down under the ordinary rules with the error as the primary and the final callbacks in the verdict"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Terminal.runValidationStop (consentBackend consent) journal
        pure (Terminal.validationSpec outcome, section "The VK-15 validation stop record" (Terminal.validationSection outcome))
  , Scenario
      "vk15-retention"
      "reports a deliberately retained unverified generation and its parents rather than releasing them, and ends by process termination"
      False
      Nothing
      $ \consent journal conclude →
        Terminal.runRetention (consentBackend consent) journal $ \outcome →
          conclude (Terminal.retentionSpec outcome, section "The VK-15 retention record" (Terminal.retentionSection outcome))
  , Scenario
      "vk16-composed"
      "renders two targets through the composed loop, suspending and resuming one while the other presents, and exits through D-33 with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Composed.runComposed (consentBackend consent) journal
        pure (Composed.spec outcome, section "The VK-16 composed loop record" (Composed.composedSection outcome))
  , Scenario
      "vk17-one-slot"
      "renders the triangle sample in two windows with one frame slot, capturing each, the first again after its resize, and the second after the first closes, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Triangle.runProfile (consentBackend consent) 1 journal
        pure (Triangle.spec 1 outcome, section "The VK-17 required profile record, one frame slot" (Triangle.profileSection outcome))
  , Scenario
      "vk17-two-slots"
      "renders the triangle sample in two windows with two frame slots, capturing each, the first again after its resize, and the second after the first closes, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Triangle.runProfile (consentBackend consent) 2 journal
        pure (Triangle.spec 2 outcome, section "The VK-17 required profile record, two frame slots" (Triangle.profileSection outcome))
  , Scenario
      "vk19-capture"
      "captures a consumer-built triangle from two targets through the production host, each beside its frame's verified presentation, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Capture.runCapture (consentBackend consent) journal
        pure (Capture.spec outcome, section "The VK-19 consumer pipeline and capture record" (Capture.captureSection outcome))
  , Scenario
      "grs15-surface-free"
      "creates the device with no surface and no window, builds and releases a pipeline through owner-thread actions, and retires cleanly, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← SurfaceFree.runSurfaceFree (consentBackend consent) journal
        pure (SurfaceFree.surfaceFreeSpec outcome, section "The GRS-15 surface-free session record" (SurfaceFree.surfaceFreeSection outcome))
  , Scenario
      "grs15-surface-free-window"
      "creates the device with no surface, then admits a window against its queue family and presents to it, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← SurfaceFree.runLaterWindow (consentBackend consent) journal
        pure (SurfaceFree.laterWindowSpec outcome, section "The GRS-15 later window record" (SurfaceFree.laterWindowSection outcome))
  , Scenario
      "grs3-ordering"
      "orders a managed depth target and buffer through checked transitions and boundary barriers across two batches submitted in order, with synchronization validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Ordering.runOrdering (consentBackend consent) journal
        pure (Ordering.spec outcome, section "The GRS-3 ordering record" (Ordering.orderingSection outcome))
  , Scenario
      "grs12-frameless"
      "records frame-less batches through owner-thread actions in a surface-free session, submits each when its action returns, waits for their tickets and retires cleanly, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← SurfaceFree.runFrameless (consentBackend consent) journal
        pure (SurfaceFree.framelessSpec outcome, section "The GRS-12 frame-less batches record" (SurfaceFree.framelessSection outcome))
  , Scenario
      "grs5-offscreen"
      "renders into managed RGBA8 color targets, sRGB and linear, in frame-less batches of a surface-free session, copies each to a readback buffer after its transition, and reads exact bytes inside and outside the triangle, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← SurfaceFree.runOffscreen (consentBackend consent) journal
        pure (SurfaceFree.offscreenSpec outcome, section "The GRS-5 offscreen color targets record" (SurfaceFree.offscreenSection outcome))
  , Scenario
      "grs4-drawing"
      "draws an indexed, instanced quad from the shared ring's regions with a pushed color into an RGBA8 color target in a frame-less batch of a surface-free session, and reads exact bytes inside each quad and outside both, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← SurfaceFree.runDrawing (consentBackend consent) journal
        pure (SurfaceFree.drawingSpec outcome, section "The GRS-4 drawing record" (SurfaceFree.drawingSection outcome))
  , Scenario
      "grs6-uploads"
      "uploads an RGBA8 texture of two levels over several turns, a BC7 one where the device takes it, and vertex, offset and index buffers through bounded staging in a surface-free session, admitted off the owner's thread and waited for with a deadline; copies every level back exactly and draws from the buffers, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← SurfaceFree.runUploads (consentBackend consent) journal
        pure (SurfaceFree.uploadsSpec outcome, section "The GRS-6 uploads record" (SurfaceFree.uploadsSection outcome))
  , Scenario
      "grs7-texture-table"
      "samples textures through bindless handles in frame-less batches of a surface-free session: the transparent placeholder before an upload, two uploaded textures each with its own sampler, and a batch recorded before its texture's release and submitted after it drawing the original, whose slot is reused only once that batch completes, with validation reporting nothing"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← SurfaceFree.runTable (consentBackend consent) journal
        pure (SurfaceFree.tableSpec outcome, section "The GRS-7 texture table record" (SurfaceFree.tableSection outcome))
  , Scenario
      "synchronization-hazard"
      "observes a deliberate synchronization hazard, proving synchronization validation active"
      False
      Nothing
      $ \_ journal _ → do
        outcome ← Hazard.runHazard journal
        pure (Hazard.spec outcome, section "The synchronization validation control record" (Hazard.hazardSection outcome))
  , Scenario
      "debug-names"
      "carries a provoked validation report's named managed resource, and its batch's label, into the capture"
      False
      Nothing
      $ \consent journal _ → do
        outcome ← Naming.runNaming (consentBackend consent) journal
        pure (Naming.spec outcome, section "The #250 debug names and labels record" (Naming.namingSection outcome))
  , Scenario
      "wayland-connection-loss"
      "ends its own compositor while the production host renders to a Wayland surface, and the session ends terminally with the loss, retired under the protected boundary with no completion recorded for interrupted work"
      True
      Nothing
      $ \consent journal _ → do
        case consent of
          IsolatedWayland _ → pure ()
          other → ioError (userError ("the connection-loss case runs only under the isolated compositor's consent, not " <> show other))
        outcome ← ConnectionLoss.runConnectionLoss journal
        pure (ConnectionLoss.spec outcome, section "The WL-4 connection loss record" (ConnectionLoss.lossSection outcome))
  ]
  where
    -- The command of the catalog group that runs this consent's profile.
    invocation = \case
      IsolatedWayland _ → "tools/display/wayland.sh -- bash tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete"
      _ → "tools/vulkan/run.sh native hetoimasia-gpu-vulkan-glfw:test:vulkan-native-tests -- --complete"
    section title body passed transcript =
      Text.unlines $
        ["# " <> title, "", "Verdict: **" <> (if passed then "pass" else "fail") <> "**."]
          <> body
          <> ["", "## Transcript", "", "```"]
          <> transcript
          <> ["```"]

scenarioNames ∷ [String]
scenarioNames = map scenarioName scenarios

-- | The scenarios a complete run under this consent must run to a pass: every
-- one, except that a Wayland-only one is required only under the isolated
-- compositor's consent, and one with a named Wayland gap is not required
-- there. A run without consent is held to the others.
requiredScenarios ∷ Either Refusal Consent → [String]
requiredScenarios consent =
  [ scenarioName scenario
  | scenario ← scenarios
  , if wayland then scenarioWaylandPending scenario == Nothing else not (scenarioWaylandOnly scenario)
  ]
  where
    wayland = case consent of
      Right (IsolatedWayland _) → True
      _ → False

-- | How long one child may take, from its start to its exit and the end of its
-- output, before it is terminated and its example fails as expired. Each takes
-- well under a second; this bounds a hung one inside the group's own budget.
childDeadline ∷ Double
childDeadline = 20

-- | The exit status of a child started without consent.
refusedExit ∷ ExitCode
refusedExit = ExitFailure 3

-- | The exit status of a consented child asked for no known scenario.
unknownScenarioExit ∷ ExitCode
unknownScenarioExit = ExitFailure 2

-- | Run one scenario as this process's whole work, on its main thread.
runScenario ∷ Either Refusal Consent → String → IO ()
runScenario refusedOrGranted name = case refusedOrGranted of
  Left refusal → do
    hPutStrLn stderr ("vulkan-native-tests " <> name <> ": " <> Text.unpack (refusalMessage refusal))
    exitWith refusedExit
  Right consent → case [scenario | scenario ← scenarios, scenarioName scenario == name] of
    [] → do
      hPutStrLn stderr ("vulkan-native-tests: unknown private roots scenario " <> show name)
      exitWith unknownScenarioExit
    scenario : _ → do
      -- The validation features every instance enables are compiled in; the
      -- run is refused if they are not the set the provisioned layer is pinned
      -- to, which is the set the receipt names.
      checkValidationFeatures >>= \case
        Right () → pure ()
        Left reason → do
          hPutStrLn stderr ("vulkan-native-tests " <> name <> ": " <> Text.unpack reason)
          exitWith (ExitFailure 1)
      journal ← newEchoingJournal
      let finish (examples, record) = do
            passed ← runCompleteSpec examples
            transcript ← entries journal
            retain (name <> ".md") (record passed transcript)
            putStrLn ("vulkan-native-tests " <> name <> ": " <> if passed then "every check passed" else "a check failed")
            pure passed
          -- Nothing is unwound: the session this ends is one that cannot end
          -- itself, and the operating system reclaims what it retained.
          terminate outcome = do
            passed ← finish outcome
            hFlush stdout
            hFlush stderr
            terminateProcess (if passed then 0 else 1)
      passed ← scenarioRun scenario consent journal terminate >>= finish
      unless passed (exitWith (ExitFailure 1))

-- | End the process at once with this status, running no finalizer and
-- unwinding nothing.
foreign import ccall unsafe "_exit" c_exit ∷ CInt → IO ()

terminateProcess ∷ CInt → IO a
terminateProcess status = c_exit status >> error "_exit returned"

-- | Run the whole spec, and only ever the whole spec, as the proof did.
--
-- Deliberately not `hspecWithResult`, which resolves its configuration from
-- the command line, @~/.hspec@, @./.hspec@ and @HSPEC_*@ — any of which could
-- select a subset whose success would then be reported as the scenario's.
runCompleteSpec ∷ Spec → IO Bool
runCompleteSpec examples = do
  (config, forest) ← evalSpec defaultConfig {configFailOnEmpty = True} examples
  specResultSuccess <$> runSpecForest forest config

-- | Write a file into the evidence directory the validation runner names, when
-- there is one. Evidence is kept, never required: a run outside the runner
-- still prints everything it asserts.
retain ∷ String → Text → IO ()
retain file contents =
  lookupEnv "HETOIMASIA_VALIDATION_EVIDENCE" >>= \case
    Nothing → pure ()
    Just "" → pure ()
    Just directory → Text.writeFile (directory </> file) contents

-- | One example per scenario, each starting its child only under consent, and
-- a Wayland-only one only under the isolated compositor's.
spec ∷ Gate → IORef [ChildRun] → Spec
spec gate timings = describe "with private roots in a child process" $
  mapM_ example scenarios
  where
    example scenario = it (scenarioTitle scenario) $ do
      consent ← admit gate
      case consent of
        IsolatedWayland _
          | Just reason ← scenarioWaylandPending scenario → pendingWith reason
          | otherwise → launch scenario
        _
          | scenarioWaylandOnly scenario →
              pendingWith "this case ends a Wayland compositor, and runs only under the isolated compositor's consent (tools/display/wayland.sh)"
          | otherwise → launch scenario
    launch scenario = do
      executable ← getExecutablePath
      started ← getCurrentTime
      Launched end out err _ ← launchCommand childDeadline executable [privateRootsFlag, scenarioName scenario]
      finished ← getCurrentTime
      let seconds = realToFrac (diffUTCTime finished started)
          status = case end of
            ChildExited code → code
            ChildExpired _ code → code
      modifyIORef' timings (ChildRun (scenarioName scenario) seconds status :)
      retain (scenarioName scenario <> ".log") (Text.pack (out <> err))
      let passedLine = "vulkan-native-tests " <> scenarioName scenario <> ": every check passed"
      case end of
        ChildExpired deadline _ →
          expectationFailure
            ("the private " <> scenarioName scenario <> " process had not finished at its " <> show deadline <> "s deadline and was terminated:\n" <> out <> err)
        ChildExited _ →
          unless (status == ExitSuccess && passedLine `isInfixOf` out) $
            expectationFailure
              ("the private " <> scenarioName scenario <> " process exited " <> show status <> ":\n" <> out <> err)
