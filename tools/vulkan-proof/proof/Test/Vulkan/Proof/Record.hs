{-# LANGUAGE OverloadedRecordDot #-}

-- | The compatibility record the run prints and the PR retains.
--
-- It is written from the journal and the findings together, so a run that
-- stopped still says what it had established before it stopped. The verdict
-- line at the top is the run's own, and it is computed from the same values the
-- Hspec examples assert over — not narrated separately.
module Test.Vulkan.Proof.Record (renderRecord, renderRecordWith, diagnosticsSection, achievedFrom, matrixTable) where

import Data.Text (Text)
import qualified Data.Text as Text

import qualified Data.Map.Strict as Map

import Hetoimasia.Foundation.Log (LogEntry (..))
import Hetoimasia.GPU.Vulkan.Diagnostics
  ( CaptureCounters (..)
  , CaptureStatus (..)
  , ConsumerOutcome (..)
  , DiagnosticVerdict (..)
  , verdictIssues
  )
import Hetoimasia.GPU.Vulkan.Native.Diagnostics (describeFfiConfiguration)
import Test.Vulkan.Proof.Diagnostics
  ( DiagnosticsFacts (..)
  , DiagnosticsOutcome (..)
  , PhaseReports (..)
  )
import Test.Vulkan.Proof.Findings
import Test.Vulkan.Proof.Interop (describeProvenance)
import Test.Vulkan.Proof.Matrix
  ( Achieved (..)
  , MatrixRow (..)
  , Observation
  , Standing
  , describeEvidence
  , operationMatrix
  , standing
  )

-- | The whole record, as Markdown.
renderRecord ∷ Text → Text → [Text] → Outcome → Bool → Text
renderRecord title invocation transcript outcome = renderRecordWith title invocation transcript outcome []

-- | The record with further sections — a later slice's native cases — placed
-- after the VK-2 findings and before the operation matrix.
renderRecordWith ∷ Text → Text → [Text] → Outcome → [Text] → Bool → Text
renderRecordWith title invocation transcript outcome extra passed =
  Text.unlines $
    [ "# " <> title
    , ""
    , "Verdict: **" <> (if passed then "pass" else "fail") <> "**."
    , ""
    , "The proof process's own command and the environment that decided which"
    , "loader, driver, and layers it used. `tools/vulkan-proof/run-proof.sh` is"
    , "what establishes this; see the README beside it for how to reproduce."
    , ""
    , "```"
    , invocation
    , "```"
    , ""
    ]
      <> body outcome
      <> extra
      <> [ ""
         , "## Operation and result matrix"
         , ""
         ]
      <> matrixPreamble outcome
      <> [""]
      <> matrixTable (standing (achievedFrom outcome))
      <> [ ""
         , "## Transcript"
         , ""
         , "```"
         ]
      <> transcript
      <> [ "```"
         ]

body ∷ Outcome → [Text]
body = \case
  Stopped failure facts →
    [ "## The run stopped"
    , ""
    , "Step: **" <> failure.failureStep <> "**"
    , ""
    , failure.failureDetail
    , ""
    , "No profile fact below was established. This is not a proof of a narrower"
    , "profile; it is an absence of the proof the issue asks for. The teardown"
    , "section that follows is the exception, and it is not a retraction: it says"
    , "what this run was able to release and what it had to hold, which is what a"
    , "reader of a failed run most needs. Teardown obtaining a completion the run"
    , "stopped waiting for does not revise the step above or the verdict."
    ]
      <> teardownSection facts
  Proved findings →
    platformSection findings.findingsPlatform
      <> loaderSection findings.findingsLoader
      <> profileSection findings.findingsProfile
      <> completionSection findings.findingsCompletion
      <> abandonmentSection findings.findingsAbandonment
      <> captureSection findings.findingsCapture
      <> callbackSection findings.findingsCallbacks
      <> teardownSection findings.findingsTeardown

platformSection ∷ PlatformFacts → [Text]
platformSection facts =
  [ "## The environment"
  , ""
  ]
    <> definitions
      [ ("source digest", facts.platformSourceDigest)
      , ("repository revision", facts.platformRevision)
      , ("platform", facts.platformOs <> "/" <> facts.platformArch)
      , ("session authorization", facts.platformConsent)
      , ("VK_DRIVER_FILES", maybe "(unset)" id facts.platformDriverFiles)
      , ("VK_LAYER_PATH", maybe "(unset)" id facts.platformLayerPath)
      , ("cleared discovery overrides", listOrNone facts.platformClearedOverrides)
      , ("loader instance version", facts.platformInstanceVersion)
      , ("layers the pinned path offers", listOrNone [name <> " " <> version | (name, version) ← facts.platformAvailableLayers])
      , ("implicit-layer policy", facts.platformImplicitLayerPolicy)
      , ("layers requested", listOrNone facts.platformRequestedLayers)
      , ("the validation layer is in the loaded chain", yesNo facts.platformValidationLayerLoaded)
      , ("surface extensions GLFW requires", listOrNone facts.platformGlfwRequired)
      ]

loaderSection ∷ LoaderFacts → [Text]
loaderSection facts =
  [ ""
  , "## One loader, by address and image"
  , ""
  , "GLFW was handed the Haskell binding's own `vkGetInstanceProcAddr` before"
  , "`glfwInit`, so the two cannot be independently found libraries that happen to"
  , "agree. The addresses and images below are what each side actually resolves."
  , ""
  ]
    <> definitions
      [ ("the binding's vkGetInstanceProcAddr", describeProvenance facts.loaderBindingEntry)
      , ("GLFW's vkGetInstanceProcAddr", describeProvenance facts.loaderGlfwEntry)
      , ("the binding's " <> facts.loaderSampleName, describeProvenance facts.loaderBindingSample)
      , ("GLFW's " <> facts.loaderSampleName, describeProvenance facts.loaderGlfwSample)
      , ("a device-level entry point", describeProvenance facts.loaderDeviceProcSample)
      , ("device", facts.loaderDeviceName)
      , ("device API version", facts.loaderDeviceApiVersion)
      , ("driver", facts.loaderDriverName <> " (" <> facts.loaderDriverId <> ")")
      , ("driver info", facts.loaderDriverInfo)
      , ("conformance version", facts.loaderConformance)
      ]

profileSection ∷ ProfileFacts → [Text]
profileSection facts =
  [ ""
  , "## The runtime profile, queried and enabled"
  , ""
  ]
    <> definitions
      [ ("instance extensions enabled", listOrNone facts.profileEnabledInstanceExtensions)
      , ("portability enumeration", yesNo facts.profilePortabilityEnumeration)
      , ("portability subset advertised", yesNo facts.profilePortabilitySubsetAdvertised)
      , ("portability subset enabled", yesNo facts.profilePortabilitySubsetEnabled)
      , ("dynamicRendering", supportedEnabled facts.profileDynamicRenderingSupported facts.profileDynamicRenderingEnabled)
      , ("synchronization2", supportedEnabled facts.profileSynchronization2Supported facts.profileSynchronization2Enabled)
      , ("queue family", number facts.profileQueueFamily <> ", graphics " <> yesNo facts.profileQueueGraphics <> ", presentation " <> yesNo facts.profileQueuePresent)
      , ("surface format", facts.profileSurfaceFormat <> " in " <> facts.profileSurfaceColorSpace)
      , ("usages the surface supports", listOrNone facts.profileSupportedUsages)
      , ("usages requested", listOrNone facts.profileRequestedUsages)
      , ("transfer-source capture supported", yesNo facts.profileTransferSourceSupported)
      , ("present modes offered", listOrNone facts.profilePresentModes)
      , ("present mode used", facts.profileChosenPresentMode)
      , ("swapchain images", Text.pack (show facts.profileSwapchainImages))
      , ("maintenance variant", facts.profileMaintenanceVariant)
      , ("its dependency chain", listOrNone [name <> " (" <> yesNo present <> ")" | (name, present) ← facts.profileMaintenanceDependencies])
      , ("swapchainMaintenance1 feature", supportedEnabled facts.profileMaintenanceFeatureSupported facts.profileMaintenanceFeatureEnabled)
      , ("release entry points resolved", listOrNone [name <> " (" <> yesNo resolved <> ")" | (name, resolved) ← facts.profileMaintenanceAlias])
      , ("device extensions enabled", listOrNone facts.profileEnabledDeviceExtensions)
      ]

completionSection ∷ CompletionFacts → [Text]
completionSection facts =
  [ ""
  , "## Presentation completion"
  , ""
  , "The per-frame columns are what the driver reported. The two rows marked as"
  , "this harness's own discipline below are not: they say what the proof's loop"
  , "did, which is the behaviour under test rather than evidence about the"
  , "driver. What the driver supplied for those is the fence evidence beside them."
  , ""
  , "| frame | image | slot | acquire | render fence | present | present fence before wait | present fence | retired on |"
  , "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
  ]
    <> [ row
           [ Text.pack (show frame.frameIndex)
           , number frame.frameImage
           , frame.frameSemaphoreSlot
           , frame.frameAcquireResult
           , yesNo frame.frameRenderFenceSignalled
           , frame.framePresentResult
           , frame.framePresentFenceStatusBeforeWait
           , yesNo frame.framePresentFenceSignalled
           , frame.frameRetiredOn
           ]
       | frame ← facts.completionFrames
       ]
    <> [""]
    <> definitions
      [ ("semaphore pool size", Text.pack (show facts.completionPool.poolSize))
      , ("frames presented", Text.pack (show facts.completionPool.poolFramesPresented))
      , ("slot reuses", listOrNone [slot <> " for frame " <> Text.pack (show frame) | (slot, frame) ← facts.completionPool.poolReuses])
      , ("every reuse backed by a present fence", yesNo facts.completionPool.poolEveryReuseBackedByPresentFence)
      , ("a rendering fence ever retired a presentation semaphore (this harness's own discipline)", yesNo (not facts.completionPool.poolRenderFenceNeverRetiredASemaphore))
      , ("delayed frame", Text.pack (show facts.completionDelayed.delayedFrame))
      , ("its rendering completed before presentation", yesNo facts.completionDelayed.delayedRenderFenceSignalledBeforePresent)
      , ("owner turns it was held unpresented", Text.pack (show facts.completionDelayed.delayedTurnsBetweenSubmitAndPresent))
      , ("its slot was withheld while unpresented (this harness's own discipline)", yesNo facts.completionDelayed.delayedSlotWithheldWhileUnpresented)
      , ("its slot was reused only after the present fence", yesNo facts.completionDelayed.delayedSlotReusedOnlyAfterPresentFence)
      ]

abandonmentSection ∷ AbandonmentFacts → [Text]
abandonmentSection facts =
  [ ""
  , "## Safe abandonment"
  , ""
  , "### An acquired image that was never rendered"
  , ""
  ]
    <> releaseDefinitions facts.abandonUnsubmitted
    <> [ ""
       , "### A submitted image that was never presented"
       , ""
       ]
    <> releaseDefinitions facts.abandonUnpresented
    <> [""]
    <> definitions
      [ ("the swapchain was rebuilt", yesNo facts.abandonSwapchainRebuilt)
      , ( "progress continued on the same swapchain afterwards"
        , case facts.abandonProgressAfterwards of
            Nothing → "no"
            Just frame → "yes, frame " <> Text.pack (show frame.frameIndex) <> " presented image " <> number frame.frameImage
        )
      ]

releaseDefinitions ∷ ReleaseRecord → [Text]
releaseDefinitions record =
  definitions
    [ ("image", number record.releaseImage)
    , ("cleanup", record.releaseCleanup)
    , ("its fence signalled", yesNo record.releaseCleanupFenceSignalled)
    , ("the semaphore was settled by", record.releaseSemaphoreSettledBy)
    , ("vkReleaseSwapchainImagesEXT returned", record.releaseResult)
    ]

captureSection ∷ CaptureFacts → [Text]
captureSection facts =
  [ ""
  , "## Transfer-source capture"
  , ""
  ]
    <> definitions
      [ ("format", facts.captureFormat)
      , ("extent", number (fst facts.captureExtent) <> "x" <> number (snd facts.captureExtent))
      , ("bytes read back", Text.pack (show facts.captureBytes))
      , ("expected first pixel", facts.captureExpected)
      , ("observed first pixel", facts.captureObserved)
      , ("matched", yesNo facts.captureMatched)
      ]

callbackSection ∷ CallbackFacts → [Text]
callbackSection facts =
  [ ""
  , "## Callback and FFI behaviour"
  , ""
  , "| phase | naturally emitted | elicited by injection |"
  , "| --- | --- | --- |"
  ]
    <> [ row [count.phaseName, Text.pack (show count.phaseNatural), Text.pack (show count.phaseInjected)]
       | count ← facts.callbackPhases
       ]
    <> [""]
    <> definitions
      [ ("binding constrained to safe foreign calls", yesNo facts.callbackSafeForeignCalls <> " (a build-time constraint; the reentry counted above is what demonstrates it works)")
      , ("threaded RTS", yesNo facts.callbackRtsThreaded)
      , ("GLFW calls on the process main thread", yesNo facts.callbackMainThreadBound)
      , ("callbacks in total", Text.pack (show facts.callbackTotal))
      , ("callbacks after the explicit messenger was destroyed", Text.pack (show facts.callbackAfterExplicitMessengerDestroyed))
      , ("callbacks during instance destruction", Text.pack (show facts.callbackDuringInstanceDestruction))
      , ("callback storage still valid while the instance was destroyed", yesNo facts.callbackStorageAliveAfterInstanceDestroyed)
      , ("validation errors", listOrNone facts.callbackValidationErrors)
      ]

teardownSection ∷ TeardownFacts → [Text]
teardownSection facts =
  [ ""
  , "## Teardown"
  , ""
  , "Releases run in the reverse of the order they were registered, and one that"
  , "fails never stops the rest. Which of them run at all is decided rather than"
  , "assumed: a handle whose completion evidence is missing is retained, because"
  , "queue or device idle alone is not evidence that a presentation has retired."
  , "The only way back from retained is the present fence itself signalling, or"
  , "the specification's device-loss rule; a retained handle is otherwise"
  , "released by process exit and by nothing else, because no native call here is"
  , "preemptible and no destroy is wrapped in a timeout. A failure fails the"
  , "verdict, and so does a retention: a session this proof could not finish"
  , "tearing down is not one it can report a clean result for."
  , ""
  ]
    <> definitions
      [ ("destruction rules in force", facts.teardownRoute)
      , ("released, in order", listOrNone facts.teardownReleases)
      , ("handles destroyed, in order", listOrNone facts.teardownDestroyed)
      , ( "handles retained, and why"
        , listOrNone [name <> " — " <> reason | (name, reason) ← facts.teardownRetained]
        )
      , ("releases that failed", listOrNone facts.teardownFailures)
      , ("the effects and results this decision was taken from", listOrNone facts.teardownObservations)
      ]

-- | What the run produced, reduced to what the matrix's labels depend on. A
-- run that stopped produced nothing, which is what 'Nothing' says.
achievedFrom ∷ Outcome → Maybe Achieved
achievedFrom = \case
  Stopped _ _ → Nothing
  Proved findings →
    Just
      Achieved
        { achievedAcquireResults = map (.frameAcquireResult) findings.findingsCompletion.completionFrames
        , achievedPresentResults = map (.framePresentResult) findings.findingsCompletion.completionFrames
        , achievedReleaseResults =
            [ findings.findingsAbandonment.abandonUnsubmitted.releaseResult
            , findings.findingsAbandonment.abandonUnpresented.releaseResult
            ]
        , achievedSubmissions = length findings.findingsCompletion.completionFrames
        }

-- | The sentence above the table, which has to match what the table will say.
matrixPreamble ∷ Outcome → [Text]
matrixPreamble = \case
  Stopped _ _ →
    [ "This run stopped, so it observed none of these. Every row below is either"
    , "specification text or a result this run never reached, and each says which."
    , "Nothing here is evidence that this platform does what the row describes."
    ]
  Proved _ →
    [ "Rows marked *observed in this run* were produced by this run, and that label"
    , "is derived from what the run recorded rather than written here. The rest are"
    , "rare or destructive paths established from the specification and labelled as"
    , "such; no device loss was induced."
    ]

matrixTable ∷ (Observation → Standing) → [Text]
matrixTable resolve =
  [ "| operation | result | actual effects | ownership and retry | evidence |"
  , "| --- | --- | --- | --- | --- |"
  ]
    <> [ row
           [ "`" <> entry.rowOperation <> "`"
           , entry.rowResult
           , entry.rowEffects
           , entry.rowDisposition
           , describeEvidence resolve entry.rowEvidence
           ]
       | entry ← operationMatrix
       ]

-- --------------------------------------------------------------------------
-- Small renderers

definitions ∷ [(Text, Text)] → [Text]
definitions entries = ["- " <> label <> ": " <> value | (label, value) ← entries]

row ∷ [Text] → Text
row cells = "| " <> Text.intercalate " | " (map escape cells) <> " |"
  where
    escape = Text.replace "|" "\\|"

listOrNone ∷ [Text] → Text
listOrNone [] = "none"
listOrNone values = Text.intercalate ", " values

yesNo ∷ Bool → Text
yesNo value = if value then "yes" else "no"

-- | A feature's two facts. "Requested and accepted" rather than "enabled",
-- because Vulkan offers no query for what a device was created with: what the
-- run can say is that it asked for the feature in @VkDeviceCreateInfo@ and that
-- @vkCreateDevice@ accepted it with the validation layer watching, which rejects
-- enabling a feature the device does not support.
supportedEnabled ∷ Bool → Bool → Text
supportedEnabled supported enabled =
  "supported " <> yesNo supported <> ", requested and accepted " <> yesNo enabled

number ∷ (Show a, Integral a) ⇒ a → Text
number = Text.pack . show

-- | VK-6's section: what reached the production C callback, step by step,
-- and the verdict the diagnostic lifetime reached after its last callback.
diagnosticsSection ∷ DiagnosticsOutcome → [Text]
diagnosticsSection = \case
  DiagnosticsStopped reason verdict phases →
    [ ""
    , "## VK-6: C-only validation capture"
    , ""
    , "The capture session stopped: " <> reason
    , ""
    ]
      <> maybe [] verdictLines verdict
      <> phaseTable phases
  DiagnosticsProved facts →
    [ ""
    , "## VK-6: C-only validation capture"
    , ""
    , "A second session on its own instance, with no window, whose only"
    , "debug-utils callback is the native backend package's C function handing"
    , "each report to the diagnostics package's C producer. Both messengers — the"
    , "one chained into `VkInstanceCreateInfo` and the explicit one — register it"
    , "with the capture storage as user data, and no Haskell callback is installed."
    , "Two calls go through genuine `unsafe` imports of the instance's and device's"
    , "own dispatch pointers. Each step's reports are read off the storage's own"
    , "counters around the call, so a report counted against an unsafe call"
    , "arrived inside it."
    , ""
    ]
      <> definitions
        ( [ ("device", facts.factsDevice)
          , ("messenger callback", describeProvenance facts.factsCallback)
          , ("this executable", facts.factsExecutable)
          , ("unsafe imports this session declares", listOrNone facts.factsUnsafeImports)
          , ("binding safe-foreign-calls in binding.pin", maybe "(unset)" id facts.factsPinnedSafeForeignCalls)
          , ("binding darwin-lib-dirs in binding.pin", maybe "(unset)" id facts.factsPinnedDarwinLibDirs)
          ]
            <> [("native package " <> label, value) | (label, value) ← describeFfiConfiguration facts.factsFfi]
        )
      <> [""]
      <> verdictLines facts.factsVerdict
      <> phaseTable facts.factsPhases
      <> deliveredTable facts.factsPhases

verdictLines ∷ DiagnosticVerdict → [Text]
verdictLines verdict =
  let counters = verdict.verdictStatus.statusCounters
   in definitions
        [ ("verdict issues", listOrNone (map (Text.pack . show) (verdictIssues verdict)))
        , ("error latched", yesNo verdict.verdictStatus.statusErrorLatched)
        , ("capture failure latched", yesNo verdict.verdictStatus.statusCaptureFailureLatched)
        , ("reports offered", tshow counters.countOffered)
        , ("admitted", tshow counters.countAdmitted)
        , ("dropped", tshow counters.countDropped)
        , ("truncated", tshow counters.countTruncated)
        , ("capture failures", tshow counters.countCaptureFailed)
        , ("error reports", tshow counters.countErrors)
        , ("delivered to the logger", tshow verdict.verdictDelivered)
        , ("undelivered", tshow verdict.verdictUndelivered)
        , ("drain worker", consumer verdict.verdictConsumer)
        ]
  where
    consumer = \case
      ConsumerCompleted → "completed"
      ConsumerSinkFailed failure → "sink failed: " <> Text.pack (show failure)
      ConsumerFailed failure → "failed: " <> Text.pack (show failure)
      ConsumerCancelled failure → "cancelled: " <> Text.pack (show failure)

phaseTable ∷ [PhaseReports] → [Text]
phaseTable phases =
  [ ""
  , "### Reports by step"
  , ""
  , row ["Step", "Reports", "Errors"]
  , row ["---", "---", "---"]
  ]
    <> [row [p.phaseName, tshow p.phaseReports, tshow p.phaseErrors] | p ← phases]

deliveredTable ∷ [PhaseReports] → [Text]
deliveredTable phases =
  [ ""
  , "### Delivered records"
  , ""
  , "Every record the drain worker handed to the logger, in delivery order, with"
  , "the step whose reports it was."
  , ""
  , row ["Step", "Severity", "Message id", "Message"]
  , row ["---", "---", "---", "---"]
  ]
    <> [ row [p.phaseName, field "severity" entry, field "message.id" entry, abbreviated (field "text" entry)]
       | p ← phases
       , entry ← p.phaseEntries
       ]
  where
    field key entry = Map.findWithDefault "" key entry.entryFields
    abbreviated text
      | Text.length text > 160 = Text.take 157 (Text.replace "\n" " " text) <> "..."
      | otherwise = Text.replace "\n" " " text

tshow ∷ Show a ⇒ a → Text
tshow = Text.pack . show
