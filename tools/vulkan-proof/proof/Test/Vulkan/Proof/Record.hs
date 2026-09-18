{-# LANGUAGE OverloadedRecordDot #-}

-- | The compatibility record the run prints and the PR retains.
--
-- It is written from the journal and the findings together, so a run that
-- stopped still says what it had established before it stopped. The verdict
-- line at the top is the run's own, and it is computed from the same values the
-- Hspec examples assert over — not narrated separately.
module Test.Vulkan.Proof.Record (renderRecord) where

import Data.Text (Text)
import qualified Data.Text as Text

import Test.Vulkan.Proof.Findings
import Test.Vulkan.Proof.Interop (describeProvenance)
import Test.Vulkan.Proof.Matrix (MatrixRow (..), describeEvidence, operationMatrix)

-- | The whole record, as Markdown.
renderRecord ∷ Text → Text → [Text] → Outcome → Bool → Text
renderRecord title invocation transcript outcome passed =
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
      <> [ ""
         , "## Operation and result matrix"
         , ""
         , "Rows marked *observed in this run* were produced by this run. The rest are"
         , "rare or destructive paths established from the specification and labelled as"
         , "such; no device loss was induced."
         , ""
         ]
      <> matrixTable
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
  Stopped failure →
    [ "## The run stopped"
    , ""
    , "Step: **" <> failure.failureStep <> "**"
    , ""
    , failure.failureDetail
    , ""
    , "Nothing below this line was established. This is not a proof of a narrower"
    , "profile; it is an absence of the proof the issue asks for."
    ]
  Proved findings →
    platformSection findings.findingsPlatform
      <> loaderSection findings.findingsLoader
      <> profileSection findings.findingsProfile
      <> completionSection findings.findingsCompletion
      <> abandonmentSection findings.findingsAbandonment
      <> captureSection findings.findingsCapture
      <> callbackSection findings.findingsCallbacks

platformSection ∷ PlatformFacts → [Text]
platformSection facts =
  [ "## The environment"
  , ""
  ]
    <> definitions
      [ ("repository revision", facts.platformRevision)
      , ("platform", facts.platformOs <> "/" <> facts.platformArch)
      , ("session authorization", facts.platformConsent)
      , ("VK_DRIVER_FILES", maybe "(unset)" id facts.platformDriverFiles)
      , ("VK_LAYER_PATH", maybe "(unset)" id facts.platformLayerPath)
      , ("cleared discovery overrides", listOrNone facts.platformClearedOverrides)
      , ("loader instance version", facts.platformInstanceVersion)
      , ("layers the pinned path offers", listOrNone [name <> " " <> version | (name, version) ← facts.platformAvailableLayers])
      , ("layers enabled", listOrNone facts.platformEnabledLayers)
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

matrixTable ∷ [Text]
matrixTable =
  [ "| operation | result | actual effects | ownership and retry | evidence |"
  , "| --- | --- | --- | --- | --- |"
  ]
    <> [ row
           [ "`" <> entry.rowOperation <> "`"
           , entry.rowResult
           , entry.rowEffects
           , entry.rowDisposition
           , describeEvidence entry.rowEvidence
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
