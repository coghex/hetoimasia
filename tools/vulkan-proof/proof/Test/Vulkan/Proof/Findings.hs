-- | Everything the native run observed, as data.
--
-- The Hspec examples in "Test.Vulkan.Proof.Spec" assert over these values and
-- make no native call of their own. That is what lets the verdict be computed
-- after all callback-producing teardown — including instance destruction — has
-- already happened: by the time an example runs, the session is gone and the
-- callback evidence is complete. It also keeps GLFW's main-thread rule intact
-- without a dispatcher, because Hspec's worker threads never reach a native
-- call.
module Test.Vulkan.Proof.Findings
  ( Findings (..)
  , PlatformFacts (..)
  , LoaderFacts (..)
  , ProfileFacts (..)
  , CompletionFacts (..)
  , FrameRecord (..)
  , PoolFacts (..)
  , DelayedFacts (..)
  , AbandonmentFacts (..)
  , ReleaseRecord (..)
  , CaptureFacts (..)
  , CallbackFacts (..)
  , TeardownFacts (..)
  , PhaseCount (..)
  , Diagnostic (..)
  , Outcome (..)
  , Failure (..)
  ) where

import Data.Text (Text)
import Data.Word (Word32, Word64)
import Test.Vulkan.Proof.Interop (Provenance)

-- | What the native run produced. A failure carries the step that failed, so a
-- refused or broken proof still names the requirement it stopped at.
data Outcome
  = Proved Findings
  | Stopped Failure
  deriving (Show)

data Failure = Failure
  { failureStep ∷ Text
  , failureDetail ∷ Text
  }
  deriving (Eq, Show)

data Findings = Findings
  { findingsPlatform ∷ PlatformFacts
  , findingsLoader ∷ LoaderFacts
  , findingsProfile ∷ ProfileFacts
  , findingsCompletion ∷ CompletionFacts
  , findingsAbandonment ∷ AbandonmentFacts
  , findingsCapture ∷ CaptureFacts
  , findingsCallbacks ∷ CallbackFacts
  , findingsTeardown ∷ TeardownFacts
  }
  deriving (Show)

-- | What teardown did, filled in after the cleanup stack has run.
--
-- A release that fails is not a detail: @vkDeviceWaitIdle@ can return device
-- loss, and a proof that let that pass while still reporting a verdict would be
-- claiming a clean session it never had. Every release still runs — one failure
-- must not hide the ones after it — and the failures are collected here so the
-- verdict can refuse them.
data TeardownFacts = TeardownFacts
  { teardownReleases ∷ [Text]
  , teardownFailures ∷ [Text]
  }
  deriving (Show)

-- | Requirement 2: the environment, explicit and recorded.
data PlatformFacts = PlatformFacts
  { platformOs ∷ Text
  , platformArch ∷ Text
  , platformRevision ∷ Text
    -- ^ The repository revision the harness was run from, for a reader who
    -- wants to find it in history. It is a convenience and can be inexact: a
    -- working tree can be dirty, and the Linux container has no checkout to
    -- ask, only the revision baked into it.
  , platformSourceDigest ∷ Text
    -- ^ The identity that is exact. A SHA-256 over the content of every source
    -- the proof is built from, so a retained record names the tree it was
    -- produced by whether or not a revision was resolvable, and a reader can
    -- recompute it. `tools/vulkan-proof/run-proof.sh` prints how.
  , platformConsent ∷ Text
  , platformDriverFiles ∷ Maybe Text
  , platformLayerPath ∷ Maybe Text
  , platformClearedOverrides ∷ [Text]
    -- ^ Discovery variables found set and removed from this process's
    -- environment before initialization, so the pinned selection is the only
    -- one in force.
  , platformInstanceVersion ∷ Text
  , platformAvailableLayers ∷ [(Text, Text)]
  , platformRequestedLayers ∷ [Text]
  , platformImplicitLayerPolicy ∷ Text
    -- ^ What the run did about implicit layers, which need no request from the
    -- application and would otherwise join the chain unrecorded. Clearing the
    -- ambient overrides is not enough: that restores the loader's *default*
    -- implicit search rather than disabling it, and @VK_LAYER_PATH@ governs
    -- explicit layers only.
  , platformValidationLayerLoaded ∷ Bool
    -- ^ Whether the validation layer is in the chain the loader actually built,
    -- observed by attributing a resolved device entry point to its image.
    -- Requesting a layer is not the same as loading one: the loader's filter
    -- variables can disable a requested layer, which would leave the run
    -- claiming validation coverage it did not have.
  , platformGlfwRequired ∷ [Text]
  }
  deriving (Show)

-- | Requirement 3: loader identity, by resolved address and image provenance.
data LoaderFacts = LoaderFacts
  { loaderBindingEntry ∷ Provenance
    -- ^ @vkGetInstanceProcAddr@ as the Haskell binding's own linked loader
    -- answers for it. This exact function pointer is what is handed to
    -- @glfwInitVulkanLoader@.
  , loaderGlfwEntry ∷ Provenance
    -- ^ What GLFW resolves the same name to once initialized.
  , loaderSampleName ∷ Text
  , loaderBindingSample ∷ Provenance
  , loaderGlfwSample ∷ Provenance
  , loaderDriverName ∷ Text
  , loaderDriverId ∷ Text
  , loaderDriverInfo ∷ Text
  , loaderConformance ∷ Text
  , loaderDeviceName ∷ Text
  , loaderDeviceApiVersion ∷ Text
  , loaderDeviceProcSample ∷ Provenance
  }
  deriving (Show)

-- | Requirement 4: the profile queried and enabled, never assumed.
data ProfileFacts = ProfileFacts
  { profileEnabledInstanceExtensions ∷ [Text]
  , profilePortabilityEnumeration ∷ Bool
  , profilePortabilitySubsetAdvertised ∷ Bool
  , profilePortabilitySubsetEnabled ∷ Bool
  , profileDynamicRenderingSupported ∷ Bool
  , profileSynchronization2Supported ∷ Bool
  , profileDynamicRenderingEnabled ∷ Bool
  , profileSynchronization2Enabled ∷ Bool
  , profileQueueFamily ∷ Word32
  , profileQueueGraphics ∷ Bool
  , profileQueuePresent ∷ Bool
  , profileSurfaceFormat ∷ Text
  , profileSurfaceColorSpace ∷ Text
  , profileSupportedUsages ∷ [Text]
  , profileRequestedUsages ∷ [Text]
  , profileTransferSourceSupported ∷ Bool
  , profilePresentModes ∷ [Text]
  , profileChosenPresentMode ∷ Text
  , profileSwapchainImages ∷ Int
  , profileMaintenanceVariant ∷ Text
  , profileMaintenanceDependencies ∷ [(Text, Bool)]
  , profileMaintenanceFeatureSupported ∷ Bool
  , profileMaintenanceFeatureEnabled ∷ Bool
  , profileMaintenanceAlias ∷ [(Text, Bool)]
    -- ^ Both spellings of the release entry point, and whether the device
    -- resolved each. The binding asks for the EXT name first and falls back to
    -- the KHR one, so which of the two answered is part of the profile.
  , profileEnabledDeviceExtensions ∷ [Text]
  }
  deriving (Show)

-- | Requirement 5: presentation completion.
data CompletionFacts = CompletionFacts
  { completionFrames ∷ [FrameRecord]
  , completionPool ∷ PoolFacts
  , completionDelayed ∷ DelayedFacts
  }
  deriving (Show)

data FrameRecord = FrameRecord
  { frameIndex ∷ Int
  , frameImage ∷ Word32
  , frameSemaphoreSlot ∷ Text
  , frameAcquireResult ∷ Text
  , frameRenderFenceSignalled ∷ Bool
  , framePresentResult ∷ Text
  , framePresentFenceStatusBeforeWait ∷ Text
  , framePresentFenceSignalled ∷ Bool
  , frameRetiredOn ∷ Text
    -- ^ The evidence on which this frame's presentation semaphore became
    -- reusable. Requirement 5 is that this is the present fence and never the
    -- rendering fence.
  }
  deriving (Show)

data PoolFacts = PoolFacts
  { poolSize ∷ Int
  , poolFramesPresented ∷ Int
  , poolReuses ∷ [(Text, Int)]
    -- ^ Each slot reuse: the slot, and the frame it was reused for.
  , poolEveryReuseBackedByPresentFence ∷ Bool
  , poolRenderFenceNeverRetiredASemaphore ∷ Bool
    -- ^ The harness's own retirement discipline, not a device observation:
    -- this run never attributed a reuse to a rendering fence. What the device
    -- supplied is the fence evidence each reuse waited on, frame by frame.
  }
  deriving (Show)

data DelayedFacts = DelayedFacts
  { delayedFrame ∷ Int
  , delayedRenderFenceSignalledBeforePresent ∷ Bool
  , delayedTurnsBetweenSubmitAndPresent ∷ Int
  , delayedSlotWithheldWhileUnpresented ∷ Bool
    -- ^ Also the harness's discipline rather than the driver's: the delayed
    -- frame's slot was not offered to another frame while its image was
    -- unpresented. The driver's part is the two facts either side of it — the
    -- rendering fence signalled first, and the present fence had not.
  , delayedSlotReusedOnlyAfterPresentFence ∷ Bool
  }
  deriving (Show)

-- | Requirement 6: safe abandonment.
data AbandonmentFacts = AbandonmentFacts
  { abandonUnsubmitted ∷ ReleaseRecord
  , abandonUnpresented ∷ ReleaseRecord
  , abandonSwapchainRebuilt ∷ Bool
  , abandonProgressAfterwards ∷ Maybe FrameRecord
  }
  deriving (Show)

data ReleaseRecord = ReleaseRecord
  { releaseImage ∷ Word32
  , releaseCleanup ∷ Text
    -- ^ What was submitted to settle the frame's synchronization before the
    -- image was given back.
  , releaseCleanupFenceSignalled ∷ Bool
  , releaseSemaphoreSettledBy ∷ Text
  , releaseResult ∷ Text
  , releaseSucceeded ∷ Bool
  }
  deriving (Show)

-- | The transfer-source capture the canonical review added to requirement 4's
-- capture usage: advertising @TRANSFER_SRC@ is not the same as reading a known
-- payload back through it.
data CaptureFacts = CaptureFacts
  { captureFormat ∷ Text
  , captureExtent ∷ (Word32, Word32)
  , captureExpected ∷ Text
  , captureObserved ∷ Text
  , captureMatched ∷ Bool
  , captureBytes ∷ Word64
  }
  deriving (Show)

-- | Requirement 8: callback and FFI behaviour on the pinned binding.
data CallbackFacts = CallbackFacts
  { callbackSafeForeignCalls ∷ Bool
    -- ^ That the binding was built with @+safe-foreign-calls@ is a build-time
    -- constraint, not something a process can introspect: this is the
    -- constraint `cabal.project.vulkan` carries and `tools/test/VulkanProof.hs`
    -- checks against the toolchain record. What the run itself demonstrates is
    -- 'callbackTotal' — with @unsafe@ imports a Vulkan call re-entering Haskell
    -- corrupts the RTS rather than arriving here at all.
  , callbackRtsThreaded ∷ Bool
  , callbackMainThreadBound ∷ Bool
  , callbackPhases ∷ [PhaseCount]
  , callbackAfterExplicitMessengerDestroyed ∷ Int
  , callbackDuringInstanceDestruction ∷ Int
  , callbackTotal ∷ Int
  , callbackStorageAliveAfterInstanceDestroyed ∷ Bool
    -- ^ Derived from a callback having actually arrived while
    -- @vkDestroyInstance@ ran, with none of them failing. The trampoline is
    -- registered for release before the instance, so it is freed after it.
  , callbackValidationErrors ∷ [Text]
  , callbackDiagnostics ∷ [Diagnostic]
  }
  deriving (Show)

-- | Callbacks observed in one phase, separated by how they were elicited.
data PhaseCount = PhaseCount
  { phaseName ∷ Text
  , phaseNatural ∷ Int
    -- ^ Diagnostics the loader or a layer emitted of its own accord.
  , phaseInjected ∷ Int
    -- ^ Deliveries elicited deliberately through @vkSubmitDebugUtilsMessageEXT@,
    -- which is a native call re-entering Haskell at a controlled point.
  }
  deriving (Eq, Show)

data Diagnostic = Diagnostic
  { diagnosticPhase ∷ Text
  , diagnosticSeverity ∷ Text
  , diagnosticTypes ∷ Text
  , diagnosticMessageId ∷ Text
  , diagnosticMessage ∷ Text
  , diagnosticInjected ∷ Bool
  }
  deriving (Eq, Show)
