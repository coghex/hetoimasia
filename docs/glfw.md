# GLFW session and windows

**Review status at `727f59a`:** the original GLFW implementation is merged. Of
the four known defects that review recorded,
[#115](https://github.com/coghex/hetoimasia/issues/115)
(construction/rollback failure evidence) is repaired: a construction failure
whose rollback's own release failed now propagates as the host's primary
failure, interrupting the command and stopping the loop.
[#116](https://github.com/coghex/hetoimasia/issues/116)
(disconnect recovery across observations) is repaired: the recovery a settled
mode owes to its monitor's identity survives ordinary observations of the
platform's post-disconnect state, so the configured fallback runs however
observation and reconciliation are ordered.
[#117](https://github.com/coghex/hetoimasia/issues/117)
(restoration after partial departure) is repaired: a departure from an applied
windowed presentation retains the geometry it departs from as the saved
placement, whether the attempt's steps all return, one reports partway, or the
attempt is interrupted after a native step, so the configured fallback or a
later windowed return restores where the user left the window.
[#118](https://github.com/coghex/hetoimasia/issues/118)
(fixture settlement under repeated cancellation) is repaired: once an owner
failure or cancellation begins fixture settlement, further cancellation of the
owner is absorbed by the wait for the borrower rather than ending it, the
resource is still released only after the borrower finishes, and the run
reports the failure that began the settlement with its retained cleanup
evidence, including against a cancellation deferred through the
uninterruptible release. All four recorded defects are now repaired; see the
[completion review](project_review_114-101.md) for reproductions.

Current behavior of `hetoimasia-glfw`, the package that owns the native binding
to upstream GLFW 3.4, the one process-main-thread session over it, the
lexically scoped windows created in that session, and the window host and owner
loop that compose them with the runtime's application lifecycle. The accepted
direction and the later slices live in
[the GLFW integration design](glfw_integration_design.md) (P-1 to P-9, P-10's
monitor identity rules, P-11, P-13, D-4 to D-9, D-11 to D-13, D-17, D-19); this document
describes what the code does today.

A session is entered, its asynchronous native error reports are read, its
monitor inventory is published with disconnect-safe identities, windows are
created in it, observed through read-only snapshots, asked for fresh
observations and changed through bounded window command ports, and released
when their scopes end, and the session ends. A window host owns those together as an
application dependency, and its supervised owner loop processes native events,
drains the ports, refreshes the monitor inventory when monitors change, and
surfaces close requests to application policy. Ordinary controls — title, size,
position, size constraints, visibility, focus and attention requests, and
minimize, maximize, and restore — settle with honest outcomes. Each host window
has a bounded, ordered input feed with an acknowledged reset after overflow or
temporary suspension. Native key, character, button, cursor, enter, and scroll
callbacks copy a fixed payload and return; the owner boundary publishes ordered
events into that feed and coalesces cursor motion into the window observation.
There is no default close policy or rendering operation.

## Package layout

| Component | Visibility | Holds |
|---|---|---|
| `hetoimasia-glfw` | public | `Hetoimasia.GLFW.Session`, `Hetoimasia.GLFW.Monitor`, `Hetoimasia.GLFW.Window`, `Hetoimasia.GLFW.Command`, `Hetoimasia.GLFW.Demand`, and `Hetoimasia.GLFW.Input`, the supported interface |
| `hetoimasia-glfw:model` | private | The session, monitor inventory, and window models over a table of native operations, bounded error capture, window controls with their validation and capability descriptions, the window command protocol, including execution and settlement, the notification policy over the session's wake capability and the bounded demand slots, the input feed model with its private producer, warning, resumption, and closure, bounded input staging at the window callbacks, and the backend-neutral window attachment model. Binds nothing. |
| `hetoimasia-glfw:native` | private | The foreign imports, `native/cbits`, and the production native table. Native handles and ABI declarations stay here. |
| `hetoimasia-glfw:runtime-glfw` | public | `Hetoimasia.Runtime.GLFW`: the window host with its dynamically created and independently closed windows, its supervised owner loop and fair command dispatch, and the host's quiescence action. The one library that depends on `hetoimasia-runtime`. |
| `hetoimasia-glfw:runtime-glfw-core` | private | `Hetoimasia.Runtime.GLFW.Internal`: the window host's implementation, with the test-only host hooks the dynamic window examples use to deliver a cancellation after a window's registration |
| `hetoimasia-glfw:seam` | public, test-only | `Hetoimasia.GLFW.Seam`: the real models over a scripted native library, for CPU examples. Links no GLFW. Exports no window driver. |
| `hetoimasia-glfw:seam-core` | private | `Hetoimasia.GLFW.Internal.Seam`: the seam's implementation, including the window drivers that deliver scripted callbacks, queue them for the next poll or wait, and change close intent, the monitor drivers that change the scripted monitors and deliver or queue monitor callbacks, and the private window command executor |
| `glfw-tests` | test suite | The headless suite: the session, session wake, and admission-wake and demand examples over the seam, the window model, window command, window control, window host, dynamic window, monitor inventory, input feed, and window mode examples that use those drivers, that executor, the private input producer, and scripted input callbacks, the window attachment model examples, the link-declaration check, and the external-client opacity examples. Initializes no GLFW and needs no display. |
| `glfw-native-tests` | test suite | The shared native fixture, and real session, thread, monitor inventory, window, window control, window host, and native input-callback examples on the platform it runs on |

The main library and the `model`, `native`, `seam`, and `seam-core`
sublibraries depend on `hetoimasia-foundation` and not on `hetoimasia-runtime`.
`runtime-glfw` depends on both, and no library depends on it; only the
package's own `glfw-tests` and `glfw-native-tests` use it. The runtime integration therefore inverts no
dependency. It is a sublibrary with its own source root rather than a separate
package because the native suite must depend on it, and Cabal refuses that as a
cycle between packages. The package's logging imports are `Component`, for
failure identifiers, and `Logger` with `logWarning`, which only the input feed's
private overflow warning uses through a logger its owner injects; nothing else
takes a logger or writes to a sink.

## Public interface

```haskell
-- Hetoimasia.GLFW.Session
data Session
allocSession            ∷ SessionConfig → Scoped Session
withSession             ∷ SessionConfig → (Session → IO r) → IO r
sessionBackend          ∷ Session → Backend
takeAsynchronousReports ∷ Session → IO Reports

data SessionConfig = SessionConfig { requestedBackend ∷ Maybe Backend }
defaultSessionConfig ∷ SessionConfig      -- the platform's own backend
data Backend = X11 | Cocoa | Wayland

data Reports     = Reports { reportedErrors ∷ [NativeError], reportsLost ∷ Natural, callbackFaults ∷ Natural }
data NativeError = NativeError { nativeErrorCode ∷ Int, nativeErrorDescription ∷ Text
                               , nativeErrorTruncated ∷ Bool, nativeErrorThread ∷ ReportingThread }
data ReportingThread = ProcessMainThread | OtherThread
errorEvidenceCapacity, errorDescriptionLimit ∷ Int   -- 16 reports, 1024 bytes

data SessionMisuse = NotProcessMainThread | NotSessionOwner | SessionAlreadyActive
                   | SessionPoisoned | SessionEnded
data UnsupportedBackend  = UnsupportedBackend { unsupportedRequest ∷ Maybe Backend
                                              , unsupportedPlatformBackend ∷ Maybe Backend }
data BackendNotSelected  = BackendNotSelected { selectionRequested ∷ Backend, selectionReported ∷ Maybe Backend }
data NativeOutcome       = NativeCallReturned | NativeCallFailed
data NativeFailure       = NativeFailure { nativeOutcome ∷ NativeOutcome, nativeReports ∷ Reports }
newtype AsynchronousErrorsUnobserved = AsynchronousErrorsUnobserved Reports
glfwComponent ∷ Component                   -- "glfw"

data SessionWake                            -- opaque; no native handle, no session
sessionWake ∷ Session → SessionWake
wakeSession ∷ SessionWake → IO WakeOutcome  -- any thread
data WakeOutcome = WakePosted | WakeTerminal | WakeFailed Reports
```

```haskell
-- Hetoimasia.GLFW.Demand
data DemandRequest                           -- Eq, Show, Semigroup, Monoid; built and read with:
noDemand          ∷ DemandRequest
immediateDemand   ∷ DemandRequest
deadlineDemand    ∷ Instant → DemandRequest
demandIsImmediate ∷ DemandRequest → Bool
demandDeadline    ∷ DemandRequest → Maybe Instant
demandRequested   ∷ DemandRequest → Bool

data DemandPublisher                         -- opaque; publication only
publishDemand ∷ DemandPublisher → DemandRequest → IO PublishResult   -- any thread
data PublishResult = DemandPublished Natural | NoDemandPublished | DemandSlotClosed

data CapturedDemand = CapturedDemand { capturedRevision ∷ Natural, capturedRequest ∷ DemandRequest }
data DemandStatus   = DemandStatus { statusOpen ∷ Bool, statusRevision ∷ Natural
                                   , statusPending ∷ Maybe DemandRequest }
```

```haskell
-- Hetoimasia.GLFW.Monitor
monitorInventory    ∷ Session → SnapshotReader MonitorInventory
synchronizeMonitors ∷ Session → IO MonitorInventory
resolveMonitor      ∷ Session → MonitorId → IO (MonitorResult MonitorDescription)
data MonitorResult a = MonitorAvailable a | MonitorDisconnected MonitorId

data MonitorInventory                        -- Eq, Show, NFData; read with:
inventoryRevision ∷ MonitorInventory → Natural
inventoryPhase    ∷ MonitorInventory → InventoryPhase
inventoryMonitors ∷ MonitorInventory → Attribute [MonitorDescription]
data InventoryPhase = InventoryOpen | InventoryClosed

data MonitorId                               -- Eq, Ord, Show
monitorLocalIdentity ∷ MonitorId → Natural

data MonitorDescription                      -- Eq, Show, NFData; read with:
monitorIdentity     ∷ MonitorDescription → MonitorId
monitorName         ∷ MonitorDescription → Attribute Text
monitorPrimary      ∷ MonitorDescription → Attribute Bool
monitorPosition     ∷ MonitorDescription → Attribute MonitorPosition
monitorWorkArea     ∷ MonitorDescription → Attribute WorkArea
monitorPhysicalSize ∷ MonitorDescription → Attribute PhysicalSize
monitorContentScale ∷ MonitorDescription → Attribute ContentScale
monitorCurrentMode  ∷ MonitorDescription → Attribute VideoMode
monitorVideoModes   ∷ MonitorDescription → Attribute [VideoMode]
data MonitorPosition = MonitorPosition { monitorX, monitorY ∷ Int }
data WorkArea        = WorkArea { workAreaX, workAreaY, workAreaWidth, workAreaHeight ∷ Int }
data PhysicalSize    = PhysicalSize { physicalWidth, physicalHeight ∷ Int }   -- millimetres
data VideoMode       = VideoMode { modeWidth, modeHeight ∷ Int
                                 , modeRedBits, modeGreenBits, modeBlueBits, modeRefreshRate ∷ Attribute Int }
-- Attribute and ContentScale are the ones Hetoimasia.GLFW.Window exports.
```

```haskell
-- Hetoimasia.GLFW.Window
data Window
allocWindow        ∷ Session → WindowConfig → Scoped Window
withWindow         ∷ Session → WindowConfig → (Window → IO r) → IO r
windowIdentity     ∷ Window → WindowId
windowObservations ∷ Window → SnapshotReader WindowObservation
windowEnded        ∷ Window → IO Bool
synchronizeWindow  ∷ Window → IO (WindowResult WindowObservation)
data WindowResult a = WindowAvailable a | WindowEnded WindowId

data WindowConfig = WindowConfig { windowTitle ∷ Text, windowWidth, windowHeight ∷ Int
                                 , windowVisible, windowFocused, windowFocusOnShow ∷ Bool
                                 , windowStartupMode ∷ Maybe StartupMode }
defaultWindowConfig, hiddenTestWindowConfig ∷ Text → Int → Int → WindowConfig
validateWindowConfig ∷ WindowConfig → Either WindowConfigRejected ()
data WindowConfigRejected = WindowExtentRejected { rejectedWidth, rejectedHeight ∷ Int }
                          | WindowTitleRejected

data WindowId                                -- Eq, Ord, Show
windowLocalIdentity ∷ WindowId → Natural

data WindowObservation                       -- Eq, Show, NFData; read with:
observedWindow ∷ WindowObservation → WindowId
observedRevision ∷ WindowObservation → Natural
observedPhase ∷ WindowObservation → WindowPhase
observedLogicalExtent, observedFramebufferExtent ∷ WindowObservation → Attribute Extent
observedContentScale ∷ WindowObservation → Attribute ContentScale
observedPlacement ∷ WindowObservation → Attribute Placement
observedFocused, observedIconified, observedMaximized, observedVisible ∷ WindowObservation → Attribute Bool
observedCloseRequest ∷ WindowObservation → Maybe CloseRequest
observedDecorated ∷ WindowObservation → Attribute Bool
observedFullscreenMonitor ∷ WindowObservation → Attribute (Maybe MonitorId)
observedMode ∷ WindowObservation → ModeRecord
observedCursorPosition ∷ WindowObservation → Maybe CursorPosition
observedCursorInside ∷ WindowObservation → Maybe Bool

data WindowPhase  = WindowOpen | WindowClosing | WindowReleased | WindowDisposalFailed | WindowReleaseUncertain
data Attribute a  = Observed a | Unavailable
data Extent       = Extent { extentWidth, extentHeight ∷ Int }
data ContentScale = ContentScale { scaleX, scaleY ∷ Float }
data Placement    = Placement { placementX, placementY ∷ Int }
data CloseRequest                            -- Eq, Ord, Show
closeRequestWindow ∷ CloseRequest → WindowId
closeRequestNumber ∷ CloseRequest → Natural

data WindowCapabilities                      -- Eq, Show; read with:
sessionWindowCapabilities ∷ Session → WindowCapabilities
backendWindowCapabilities ∷ Backend → WindowCapabilities
unperformableOperations   ∷ WindowCapabilities → [(WindowOperation, Text)]
unreportableAttributes    ∷ WindowCapabilities → [(WindowReport, Text)]
data WindowOperation = SetTitleOperation | SetSizeOperation | SetPositionOperation | SetConstraintsOperation
                     | ShowOperation | HideOperation | FocusOperation | AttentionOperation
                     | MinimizeOperation | MaximizeOperation | RestoreOperation
                     | BorderlessOperation | FullscreenOperation
data WindowReport    = LogicalExtentReport | FramebufferExtentReport | ContentScaleReport | PlacementReport
                     | FocusedReport | IconifiedReport | MaximizedReport | VisibleReport
```

```haskell
-- Hetoimasia.GLFW.Command
data WindowCommandHost
newWindowCommandHost ∷ HasCallStack ⇒ Session → Integer → IO WindowCommandHost
windowCommandPort    ∷ WindowCommandHost → WindowCommandPort
closeWindowCommands  ∷ WindowCommandHost → STM Natural
commandStatistics    ∷ WindowCommandHost → STM CommandStatistics
performWindowCommand ∷ WindowCommandHost → [Window] → WindowCommand → IO Disposition
data CommandStatistics = CommandStatistics { commandsCapacity, commandsQueued, commandsActive, commandsPending ∷ Natural }

data WindowCommandPort
submitWindowCommand      ∷ HasCallStack ⇒ WindowCommandPort → [(Text, Text)] → WindowCommand → IO SubmitResult
awaitSubmitWindowCommand ∷ HasCallStack ⇒ WindowCommandPort → [(Text, Text)] → WindowCommand → IO WaitedSubmission
data SubmitResult     = SubmitAccepted CompletionTicket | SubmitFull | SubmitClosed
data WaitedSubmission = WaitAccepted CompletionTicket | WaitClosed

data WindowCommand                           -- Eq, Show, NFData
observeWindowCommand ∷ WindowId → WindowCommand
closeWindowCommand   ∷ WindowId → WindowCommand
createWindowCommand  ∷ WindowConfig → WindowCommand
commandWindow        ∷ WindowCommand → Maybe WindowId      -- Nothing for a creation

setWindowTitleCommand     ∷ WindowId → Text → WindowCommand
setWindowSizeCommand      ∷ WindowId → Extent → WindowCommand
setWindowPositionCommand  ∷ WindowId → Placement → WindowCommand
setSizeConstraintsCommand ∷ WindowId → SizeConstraints → WindowCommand
showWindowCommand, hideWindowCommand, requestFocusCommand, requestAttentionCommand,
  minimizeWindowCommand, maximizeWindowCommand, restoreWindowCommand ∷ WindowId → WindowCommand
data SizeConstraints                         -- Eq, Show, NFData; built and read with:
sizeConstraints       ∷ Extent → Extent → Maybe AspectRatio → SizeConstraints
constraintMinimum, constraintMaximum ∷ SizeConstraints → Extent
constraintAspectRatio ∷ SizeConstraints → Maybe AspectRatio
data AspectRatio = AspectRatio { aspectNumerator, aspectDenominator ∷ Int }
setWindowModeCommand ∷ WindowId → ModeRequest → WindowCommand

data RequestId                               -- Eq, Ord, Show
requestLocalIdentity ∷ RequestId → Natural
data CommandOrigin                           -- Eq, Show, NFData; read with:
submittedRequest ∷ CommandOrigin → RequestId
submittedWindow  ∷ CommandOrigin → Maybe WindowId
submittedAt      ∷ CommandOrigin → Maybe FailureSite
submittedContext ∷ CommandOrigin → [(Text, Text)]

data CompletionTicket                        -- Eq, Show
ticketOrigin    ∷ CompletionTicket → CommandOrigin
pollCompletion  ∷ CompletionTicket → STM (Maybe Disposition)
awaitCompletion ∷ HasCallStack ⇒ CompletionTicket → IO Disposition

data Disposition      = Performed CommandResult | Rejected CommandRejection | Unsupported UnsupportedControl
                      | Attempted ControlAttempt | Transitioned ModeTransition | NotExecuted | Interrupted RequestId
data CommandResult    = ObservationPublished { publishedWindow ∷ WindowId, publishedRevision ∷ Natural }
                      | WindowCreated { createdWindow ∷ WindowId }
                      | WindowCloseBegun { closingWindow ∷ WindowId }
data CommandRejection = WindowNotServed WindowId | WindowAlreadyEnded WindowId
                      | WindowNativeFailure { failedWindow ∷ WindowId, failedOperation ∷ Maybe Text
                                            , failedOutcome ∷ NativeOutcome, failedReports ∷ Reports }
                      | WindowIsClosing WindowId | CloseNotPermitted WindowId | CreationNotPermitted
                      | WindowConfigInvalid WindowConfigRejected | WindowCapacityReached Int
                      | WindowCreationPoisoned
                      | WindowCreationFailed { creationOperation ∷ Maybe Text
                                             , creationOutcome ∷ NativeOutcome, creationReports ∷ Reports }
                      | ControlRejected WindowId ControlRejection | ModeRejected WindowId ModeRejection
data ControlRejection = ControlExtentRejected Int Int | ControlPlacementRejected Int Int | ControlTitleRejected
                      | SizeOutsideConstraints Extent SizeConstraints | ActiveConstraintsIndeterminate
                      | ConstraintBoundRejected Extent Extent | ConstraintBoundsInverted Extent Extent
                      | AspectRatioRejected Int Int | ConstraintsExcludeCurrentSize Extent SizeConstraints
                      | CurrentSizeUnavailable | ModeTransitionInProgress
                      | ControlIneligibleInMode PresentationKind | ControlModeIndeterminate
data ModeTransition   = ModeTransition { transitionedWindow ∷ WindowId, transitionOutcome ∷ ModeOutcome
                                       , transitionObservation ∷ PostCallObservation }
data UnsupportedControl = UnsupportedControl { unsupportedWindow ∷ WindowId, unsupportedOperation ∷ WindowOperation
                                             , unsupportedReason ∷ Text }
data ControlAttempt   = ControlAttempt { attemptedWindow ∷ WindowId, attemptedOutcome ∷ ControlOutcome
                                       , attemptedObservation ∷ PostCallObservation }
data ControlOutcome   = ControlReturned
                      | ControlNativeError { controlFailedOperation ∷ Text, controlReports ∷ Reports }
                      | ConstraintUpdateFailed { constraintsReturned ∷ [ConstraintCall], constraintsFailed ∷ ConstraintCall
                                               , constraintsUnattempted ∷ [ConstraintCall], constraintReports ∷ Reports }
data ConstraintCall   = SizeLimitsCall | AspectRatioCall
constraintCallOrder   ∷ [ConstraintCall]                     -- [SizeLimitsCall, AspectRatioCall]
data PostCallObservation = PostCallRevision Natural
                         | PostCallSampleFailed { sampleOutcome ∷ NativeOutcome, sampleReports ∷ Reports }
data WindowCommandMisuse = OwnerThreadWouldWait

data WindowClient                            -- Show; read with:
clientWindow       ∷ WindowClient → WindowId
clientCommandPort  ∷ WindowClient → WindowCommandPort
clientObservations ∷ WindowClient → SnapshotReader WindowObservation
clientInputReader  ∷ WindowClient → InputReader
clientInputControl ∷ WindowClient → InputControl
clientDemandPublisher ∷ WindowClient → DemandPublisher
pollWindowClient   ∷ CompletionTicket → STM (Maybe WindowClient)
```

```haskell
-- Hetoimasia.GLFW.Mode
data WindowMode                              -- Eq, Show, NFData; built and read with:
windowedMode        ∷ WindowMode
borderlessMode      ∷ MonitorId → WindowMode
fullscreenMode      ∷ MonitorId → VideoModePreference → WindowMode
modePresentation    ∷ WindowMode → PresentationKind
modeMonitor         ∷ WindowMode → Maybe MonitorId
modeVideoPreference ∷ WindowMode → Maybe VideoModePreference
data PresentationKind = WindowedPresentation | BorderlessPresentation | FullscreenPresentation

data VideoModePreference                     -- Eq, Show, NFData; built and read with:
currentVideoMode   ∷ VideoModePreference
exactVideoMode     ∷ Extent → Maybe Int → VideoModePreference
preferredVideoMode ∷ VideoModePreference → Maybe (Extent, Maybe Int)

data ModeFallback                            -- Eq, Show, NFData; built and read with:
noModeFallback          ∷ ModeFallback
windowedFallback        ∷ Int → ModeFallback  -- fallback attempts, 1 .. maximumFallbackAttempts
fallbackAttempts        ∷ ModeFallback → Int
maximumFallbackAttempts ∷ Int                 -- 4

data ModeRequest                             -- Eq, Show, NFData; built and read with:
modeRequest       ∷ WindowMode → ModeFallback → ModeRequest
requestedMode     ∷ ModeRequest → WindowMode
requestedFallback ∷ ModeRequest → ModeFallback

data StartupMode                             -- Eq, Show, NFData; built and read with:
startupMode        ∷ ModeRequest → ModeRequirement → StartupMode
startupRequest     ∷ StartupMode → ModeRequest
startupRequirement ∷ StartupMode → ModeRequirement
data ModeRequirement = ModeRequired | ModeOptional

data ModeRecord                              -- Eq, Show, NFData; read with:
modeRequested      ∷ ModeRecord → WindowMode
modeFallback       ∷ ModeRecord → ModeFallback
modeApplied        ∷ ModeRecord → AppliedMode
modeSavedPlacement ∷ ModeRecord → Maybe SavedPlacement
modeLastOutcome    ∷ ModeRecord → Maybe ModeOutcome
data AppliedMode = AppliedWindowed | AppliedBorderless MonitorId | AppliedFullscreen MonitorId | AppliedIndeterminate
data SavedPlacement                          -- Eq, Show, NFData; read with:
savedPosition ∷ SavedPlacement → Placement
savedExtent   ∷ SavedPlacement → Extent

data ModeRejection = TransitionAlreadyInProgress | FallbackAttemptsRejected Int
                   | VideoModeRejected Int Int (Maybe Int) | ModeMonitorDisconnected MonitorId
                   | MonitorBusy MonitorId | VideoModeUnavailable MonitorId VideoModePreference
                   | WorkAreaUnavailable MonitorId | PlacementUnrepresentable Placement Extent
                   | NoReachablePlacement | PlacementExcluded Extent SizeConstraints
                   | WindowedConstraintsIndeterminate
data ModeStep      = ClearSizeLimitsStep | ClearAspectRatioStep | DecorationStep Bool
                   | PlacementStep Placement Extent | MonitorStep MonitorId Extent (Maybe Int)
                   | SizeLimitsStep Extent Extent | AspectRatioStep (Maybe AspectRatio)
data ModeAttemptKind    = TargetAttempt | WindowedFallbackAttempt
data ModeFailure        = RefusedBeforeMutation ModeRejection | UnsupportedTarget Text
                        | StoppedPartway { stoppedReturned ∷ [ModeStep], stoppedAt ∷ ModeStep
                                         , stoppedUnattempted ∷ [ModeStep], stoppedReports ∷ Reports }
data ModeAttemptFailure = ModeAttemptFailure { failedAttempt ∷ ModeAttemptKind, failedHow ∷ ModeFailure }
data ModeOutcome        = ModeInert
                        | ModeApplied { appliedBy ∷ ModeAttemptKind, appliedSteps ∷ [ModeStep]
                                      , appliedAfter ∷ [ModeAttemptFailure] }
                        | ModeFailed { failedAttempts ∷ [ModeAttemptFailure] }
                        | ModeRecoveryStopped { stoppedAttempts ∷ [ModeAttemptFailure], stoppedCleanup ∷ Reports }
```

```haskell
-- Hetoimasia.GLFW.Input
data InputReader                             -- no instances; read with:
inputReaderWindow ∷ InputReader → WindowId
readInput         ∷ InputReader → STM InputRead
awaitInput        ∷ InputReader → STM InputRead   -- waits while empty or paused
data InputRead = InputDelivered InputEvent | InputResetRequired ResetToken | InputPaused
               | InputEmpty | InputClosed

data InputEvent                              -- Eq, Show, NFData; read with:
inputWindow  ∷ InputEvent → WindowId
inputEpoch   ∷ InputEvent → InputEpoch
inputPayload ∷ InputEvent → InputPayload
data InputEpoch                              -- Eq, Ord, Show
epochNumber  ∷ InputEpoch → Natural
data InputPayload   = KeyInput KeyEvent | TextInput Char | ButtonInput ButtonEvent
                    | ScrollInput ScrollEvent | FocusInput Bool
data KeyEvent       = KeyEvent { keyCode, keyScancode ∷ Int, keyAction ∷ KeyAction, keyModifiers ∷ Modifiers }
data KeyAction      = KeyPressed | KeyRepeated | KeyReleased
data ButtonEvent    = ButtonEvent { buttonNumber ∷ Int, buttonAction ∷ ButtonAction
                                  , buttonCursor ∷ Maybe CursorPosition, buttonModifiers ∷ Modifiers }
data ButtonAction   = ButtonPressed | ButtonReleased
data ScrollEvent    = ScrollEvent { scrollX, scrollY ∷ Double }
data CursorPosition = CursorPosition { cursorX, cursorY ∷ Double }
data Modifiers      = Modifiers { modifierShift, modifierControl, modifierAlt, modifierSuper
                                , modifierCapsLock, modifierNumLock ∷ Bool }
noModifiers ∷ Modifiers
keyDomainLast, buttonDomainLast ∷ Int        -- 348 and 7

data ResetToken                              -- Eq, Show; read with:
resetWindow ∷ ResetToken → WindowId
resetEpoch  ∷ ResetToken → InputEpoch        -- the epoch the reset reserved
resetReason ∷ ResetToken → ResetReason
data ResetReason     = InputOverflowed | AdmissionSuspended
acknowledgeReset     ∷ InputReader → ResetToken → STM (Either InputMisuse Acknowledgement)
data Acknowledgement = Acknowledged | AlreadyAcknowledged | StaleAcknowledgement | AcknowledgementClosed
data InputMisuse     = ForeignResetToken { misuseTokenWindow, misuseFeedWindow ∷ WindowId }

data InputControl                            -- no instances
inputControlWindow ∷ InputControl → WindowId
enableInput, suspendInput ∷ InputControl → STM AdmissionChange
data AdmissionChange      = AdmissionOpened | AdmissionReset ResetToken | AdmissionClosedDuringReset
                          | AdmissionUnchanged | AdmissionFeedClosed
data ApplicationAdmission = AwaitingReadiness | InputEnabled | InputSuspended

inputStatistics ∷ InputReader → STM InputStatistics
data InputStatistics = InputStatistics
  { statisticsFeedWindow ∷ WindowId, statisticsPhase ∷ InputPhase, statisticsEpoch ∷ InputEpoch
  , statisticsAdmission ∷ ApplicationAdmission, statisticsFocused ∷ Bool
  , statisticsCapacity, statisticsQueued, statisticsHeld, statisticsAdmitted, statisticsDelivered
  , statisticsGated, statisticsUnpaired, statisticsSuppressed, statisticsOverflowed
  , statisticsDiscardedByReset, statisticsDiscardedAtClose, statisticsResets, statisticsGenerations ∷ Natural
  , statisticsLastReset ∷ Maybe ResetSummary }
data InputPhase   = InputRunning | InputResetPending | InputResetAcknowledged | InputFeedClosed
data ResetSummary = ResetSummary { summaryEpoch ∷ InputEpoch, summaryReason ∷ ResetReason
                                 , summaryDiscarded, summaryUnadmitted, summarySuppressed ∷ Natural
                                 , summaryWarning ∷ WarningState }
data WarningState = NoWarningOwed | WarningOwed | WarningAttempting | WarningWritten
                  | WarningFailed | WarningInterrupted
```

```haskell
-- Hetoimasia.Runtime.GLFW, in hetoimasia-glfw:runtime-glfw
data WindowHost
allocWindowHost       ∷ HasCallStack ⇒ HostConfig → Scoped WindowHost
allocWindowHostIn     ∷ HasCallStack ⇒ Scoped Session → HostConfig → Scoped WindowHost
hostMonitors          ∷ WindowHost → SnapshotReader MonitorInventory
hostCommandPort       ∷ WindowHost → WindowCommandPort
hostCommandStatistics ∷ WindowHost → STM CommandStatistics
hostActivity          ∷ WindowHost → STM HostActivity
quiesceWindowHost     ∷ WindowHost → STM ()
hostDemandPublisher   ∷ WindowHost → DemandPublisher
captureHostDemand     ∷ WindowHost → IO (Maybe CapturedDemand)          -- owner thread
captureWindowDemand   ∷ WindowHost → WindowId → IO (Maybe CapturedDemand)  -- owner thread
hostDemandStatus      ∷ WindowHost → STM DemandStatus
windowDemandStatus    ∷ WindowHost → WindowId → STM (Maybe DemandStatus)
data HostActivity = HostActivity { activityTurn ∷ Natural, activityWaiting ∷ Bool }
hostWindowCapabilities ∷ WindowHost → WindowCapabilities

hostWindowIdentities   ∷ WindowHost → STM [WindowId]
hostWindowClient       ∷ WindowHost → WindowId → STM (Maybe WindowClient)
withHostWindow         ∷ WindowHost → WindowId → (Window → IO r) → IO (WindowResult r)
closeHostWindow        ∷ WindowHost → WindowId → IO CloseStart
honourHostCloseRequest ∷ WindowHost → CloseRequest → IO CloseStart
data CloseStart = CloseStarted | CloseAlreadyStarted | CloseNotServed | CloseRequestSuperseded
hostBookkeeping        ∷ WindowHost → IO HostBookkeeping
data HostBookkeeping = HostBookkeeping { bookkeepingWindows, bookkeepingClosing, bookkeepingMembers
                                       , bookkeepingPorts ∷ Int, bookkeepingPendingCells ∷ Natural
                                       , bookkeepingSurfaced, bookkeepingBorrowed ∷ Int }

data HostConfig = HostConfig { hostSessionConfig ∷ SessionConfig, hostWindowConfigs ∷ [WindowConfig]
                             , hostWindowLimit ∷ Int, hostCommandCapacity, hostInputCapacity ∷ Integer
                             , hostCommandBudget, hostEventBudget ∷ Int, hostIdleWait ∷ Double }
defaultHostConfig  ∷ [WindowConfig] → HostConfig   -- 16 windows, capacities 64 and 256, budgets 16, idle wait 0.1 s
validateHostConfig ∷ HostConfig → Either HostConfigRejected ()
data HostConfigRejected = CommandBudgetRejected Int | EventBudgetRejected Int | IdleWaitRejected Double
                        | WindowLimitRejected Int | InputCapacityRejected Integer
hostComponent ∷ Component                   -- "glfw.runtime"

runOwnerLoop ∷ WindowHost → RuntimeControl → LoopHooks a → IO a
data LoopHooks a = LoopHooks { loopLogger ∷ Logger, loopEvent ∷ IO Bool, loopUpdate ∷ Turn → IO (TurnStep a) }
noApplicationEvents ∷ IO Bool
data Turn = Turn { turnNumber ∷ Natural, turnWaited ∷ Bool, turnCommands, turnEvents ∷ Int
                 , turnCloseRequests ∷ [CloseRequest] }
data TurnStep a = Continue | Finish a
rejectHostCloseRequest ∷ WindowHost → CloseRequest → IO Bool

runWindowApplication
  ∷ HasCallStack
  ⇒ (∀ r. (LoggingLifetime → IO r) → IO r) → Text → Scoped dependencies
  → (dependencies → WindowHost)                     -- where the host is
  → (dependencies → RuntimeControl → IO services)   -- startup
  → (services → RuntimeControl → IO a)              -- the action
  → IO a
```

`Session`, `MonitorInventory`, `MonitorDescription`, `MonitorId`, `Window`,
`WindowObservation`, `WindowId`, `CloseRequest`, `WindowHost`, `WindowCommandHost`, `WindowCommandPort`, `CompletionTicket`,
`CommandOrigin`, `RequestId`, `WindowCommand`, `SizeConstraints`, `WindowCapabilities`, `WindowClient`, `InputReader`,
`InputControl`, `InputEvent`, `InputEpoch`, `DemandRequest`, `DemandPublisher`, and `ResetToken` are exported
without their constructors, and their readers are functions rather than record
fields, so no client can build or rewrite one. No public
type holds a native window or monitor pointer, and no snapshot publisher is
handed out: clients receive only read endpoints. No public operation reaches the
host's window collection, a collection member, or a release, and none reaches an
input feed's channel, state, or producer. Nothing assumes a
single or primary window or monitor.

Every failure is raised through `throwFailure` with the `glfw` component, the
operation (`enter session`, `initialize`, `verify backend`, `terminate`,
`detach error callback`, `take asynchronous reports`, `attach monitor callback`,
`detach monitor callback`, `sample monitors`, `synchronize monitors`,
`resolve monitor`, `reconcile monitor events`, `monitor callback`, `create window`,
`sample window`, `attach window callbacks`, `synchronize window`,
`begin window closing`, `detach window callbacks`, `destroy window`,
`new window command host`, `submit window command`, `await window command`,
`execute window command`, `perform window command`, `process window events`,
`reconcile window events`, `reject close request`, `control window`), and identifiers such as
`backend`, `title`, `monitor`, `window`, or `request`, so `failureEvidence` reads
the origin back without a logger. The host's own failures are raised under the
`glfw.runtime` component: a configuration rejection under
`construct window host`, and an owner-thread refusal under `run owner loop`,
`reject close request`, `borrow host window`, `close host window`,
`honour close request`, `capture demand`, or `read host bookkeeping`. The one
diagnostic the host's own boundary writes, besides the input overflow warning,
is the wake path's degradation warning, under `glfw.wake`.

## Entry

`allocSession` constructs the session as a staged composite. In order:

1. **Backend.** The request is resolved against the backend this platform
   supports: X11 on Linux and Cocoa on macOS, each selected explicitly. Wayland
   is never selected, and neither is another platform's backend; either request
   is `UnsupportedBackend` before anything else happens, so no XWayland run is
   ever presented as Wayland.
2. **Thread.** The calling thread must be bound and must be the OS thread that
   entered the process main function, or entry is `NotProcessMainThread`. A
   bound worker thread is not enough: the OS identity comes from a C shim
   (`pthread_main_np` on macOS, `gettid() == getpid()` on Linux). An unbound
   thread is rejected even if it runs there, because it could migrate. The
   threaded runtime is therefore required.
3. **Exclusivity.** A process-wide guard is claimed. An active session, entered
   from any thread, makes this `SessionAlreadyActive`; a poisoned guard makes it
   `SessionPoisoned`.
4. **Support.** `glfwPlatformSupported` must accept the backend, or entry is
   `UnsupportedBackend` and the guard is released.
5. **Callback.** The error callback is installed.
6. **Initialization.** The platform hint and `GLFW_COCOA_CHDIR_RESOURCES = false`
   are set, so session configuration never changes the process working
   directory, and `glfwInit` runs. A false return is a `NativeFailure` carrying
   the reports GLFW made during the call. That is how an initialization error is
   observed before any event is polled.
7. **Verification.** Reports from a successful initialization are raised only
   now, after termination has been registered, and `glfwGetPlatform` must name
   the selected backend, or entry is `BackendNotSelected`.
8. **Monitor callback.** The monitor callback's storage is allocated, its detach
   is registered, and it is attached with `glfwSetMonitorCallback`. An
   attachment that raises poisons the guard.
9. **Monitor inventory.** The monitors are enumerated and described, anything
   the callback captured since attachment is folded in, and the prepared
   inventory becomes revision zero of a fresh snapshot. See [Monitors](#monitors).

Steps 1 to 3 change no native state, so every misuse and unsupported request is
rejected before native mutation. A failure at any later step releases exactly
what the earlier steps acquired, with the triggering failure primary and every
cleanup failure retained, as [composite construction](resources.md#composite-construction)
guarantees. Sequential sessions work after a complete, safe teardown.

## Owner, thread, and lifetime

The owner is the thread that entered the session. `takeAsynchronousReports` and
every window operation check, before any native call, that they run on the
owner (`NotSessionOwner`) and that the session is still live (`SessionEnded`).
The session lives until its enclosing `withScoped` continuation returns or
throws. Like any scoped value, it must not escape that scope.

### Waking the owner

`sessionWake` lends the session's wake capability, and `wakeSession` posts
GLFW's documented cross-thread empty event, so an owner blocked in a native
event wait returns. It is the only native call this package makes off the owner
thread: event pumping, timed waits, and every window and monitor operation stay
owner-only. The capability is opaque. It exposes no native handle, no session
representation, and no other authority, which the external-client opacity
examples prove.

A wake is a hint. It carries no message, may be coalesced with other wakes, and
proves nothing about work: whatever state made the wake worthwhile stays
authoritative. Any thread may call it — bound, unbound, or the owner itself. A
call makes at most one empty-event post plus bounded, non-blocking bookkeeping:
a never-retrying transaction to be admitted, one to leave, and the error
capture's own updates. It invokes no caller-supplied IO and takes no lock that
an owner operation or a callback could hold.

| Outcome | Meaning |
|---|---|
| `WakePosted` | The empty event was posted and nothing was reported during the call. |
| `WakeTerminal` | The session has begun closing or has closed. GLFW was not entered. |
| `WakeFailed reports` | An expected platform failure, with the evidence [attributed to this call](#native-error-evidence): every report recorded for the call is `GLFW_PLATFORM_ERROR`, none was lost or faulted, and the error the call left in its thread's GLFW error state is that code or none. |

Any other evidence is not an ordinary outcome. It raises a `NativeFailure`
attributed to `glfw` `wake session` and carrying the call's reports. That covers
another code (such as `GLFW_NOT_INITIALIZED`, alone or beside a platform error),
a report lost to the bound, a callback fault, and an error the call left that no
report recorded, which is counted as a callback fault. These are programming or
lifetime violations, or evidence that cannot be classified, so they keep the
package's typed-failure semantics rather than becoming a failure a caller might
recover from by degrading. A native table that raises is a programming failure
too. Its exception propagates unchanged. Either way, the call's accounting has
settled first. No outcome retries the wake,
reclassifies other work, or chooses a degradation policy. That policy is the
notifier's, described under [the degradation
policy](#the-degradation-policy): what command admission and demand publication
do with an expected failure, and the one warning it owes.

### Wake lifetime

Each session owns a wake gate: open, closing with a count of admitted calls, or
closed. A wake is admitted by raising that count in the same transaction that
finds the gate open, and leaves by lowering it once its native call returns.
Admission, the call, and leaving run masked, so no asynchronous exception can
separate the accounting from the call it accounts for. A cancelled waker, cancelled
inside its native call or with a cancellation pending when the call completes,
still leaves, and the cancellation stays observable.

The session's first release closes the gate and then waits, uninterruptibly,
until every admitted call has left (see
[teardown](#teardown-poisoning-and-controlled-blocking)). A new wake from then
on answers `WakeTerminal` without entering GLFW. So `glfwTerminate` never runs
while a wake is inside GLFW, no wake enters GLFW once termination has begun, and
no callback storage is freed while a wake could report through it. This is a
real exclusion, not a flag read before the FFI call. A capability retained past
its session is terminal forever. It cannot reach a later session, even one with
the same backend, because that session has its own gate. A construction that
rolls back never lends a capability.

## Native error evidence

GLFW reports an error through one process-wide callback, possibly on another
thread, with a description that is valid only during the call. The installed
callback runs uninterruptibly and does only bounded work. It copies at most
`errorDescriptionLimit` bytes, decodes them leniently as UTF-8, and records
truncation. It stores one `NativeError` with a non-blocking `IORef` update and
returns. It invokes no sink, takes no lock, and waits for nothing, so a callback
made synchronously from inside an owner call cannot deadlock. No Haskell
exception unwinds into C: a callback that cannot record its report adds to
`callbackFaults` instead.

Reports are sorted by facts about the reporting OS thread, never by Haskell
thread identity (a callback runs in a Haskell thread of its own):

- A report made during a wake call's native call, on the OS thread making it,
  belongs to that wake call. The binding makes the post with the call's own
  wake mark in that OS thread's thread-local storage. The callback reads the
  mark on the thread GLFW invokes it on, so the post, the report, and the
  attribution share one OS thread whichever Haskell thread called
  `wakeSession`. Each call has its own bucket, removed when the call returns,
  so two concurrent wakes each receive their own reports. Neither takes a
  report from a concurrent owner operation or from the asynchronous reports,
  and neither leaves one behind for `takeAsynchronousReports`,
  `AsynchronousErrorsUnobserved`, or another operation to raise again.
- Otherwise, a report made on the process main thread during an operation's
  native call belongs to that operation. The operation takes it after the call
  returns and fails with a `NativeFailure` naming whether the call itself
  failed.
- Any other report is asynchronous. It is never attributed to whichever
  operation is running when it is observed. `takeAsynchronousReports` reads it.
  A report whose wake mark could not be read, or that names a call whose bucket
  has closed, cannot be attributed and is counted here as a callback fault.

Each class, and each wake call, keeps its first `errorEvidenceCapacity` reports
and counts later ones in `reportsLost`. A lost report or a callback fault still
counts as reported, so full storage can never turn a native failure into
success. The same C call that posts also clears the calling thread's GLFW error
state before the post and reads it after. If the post left an error and the call
has no evidence at all, the wake adds a callback fault. Lost or faulted evidence
therefore never becomes `WakePosted`, and, being unclassifiable, is raised rather
than answered as `WakeFailed` (see [Waking the owner](#waking-the-owner)).

### The degradation policy

Command admission and demand publication reach the owner through one notifier
per session, which pairs the session's wake capability with the session's own
wake-path state. Every host over that session shares it, including hosts that
borrow the session in turn; a later session has a capability and a state of its
own and starts healthy.

The first `WakeFailed` — an expected platform failure, with the evidence
attributed to that call alone — degrades that session's wake path and retains
that evidence. Every later admission and publication in the session then skips
the native call, and the owner's finite idle wait is the bounded polling that
keeps work moving. Nothing is retried, no ticket or slot changes, and no
admitted work is reclassified as rejected. A concurrent second failure changes
nothing and keeps the first call's evidence. A programming or lifetime violation
is not degraded around: `wakeSession` raises it, it propagates to whichever
thread was notifying, and the work that thread had already committed stays
committed and still settles.

Degradation owes exactly one guarded diagnostic attempt. The owner loop claims
it at a safe boundary — outside transactions, callbacks, releases, and the
[wake lifetime](#wake-lifetime)'s native exclusion — and writes one structured
warning through the `Logger` the application injects on `LoopHooks`, under the
`glfw.wake` component, with the retained evidence's counts and first report. The
claim is spent whatever happens: an entry the logger filters out, a sink
failure, and a cancellation each end the attempt and are recorded, and none is
retried. A sink failure and a cancellation propagate as themselves, as every
logging attempt does, and neither undoes the degradation.

## Teardown, poisoning, and controlled blocking

The composite declares its release order:

| Release | What it does |
|---|---|
| `glfw wake gate` | Closes the wake gate to new calls, then waits uninterruptibly until every admitted wake call has returned from its native call and left. No native call. |
| `glfw monitor inventory` | Ends every monitor identity, publishes the last descriptions as the `InventoryClosed` inventory, and closes the snapshot, in one transaction. No native call. |
| `glfw monitor callback` | Takes any monitor callback fault latched since the last boundary, detaches the callback, then raises any report made during that call, and then the fault |
| `glfw terminate` | Marks the session ended, calls `glfwTerminate`, then raises any report made during that call |
| `glfw error callback` | Detaches the callback, frees its storage only if teardown has been safe so far, then raises any asynchronous report nobody read as `AsynchronousErrorsUnobserved` |
| `glfw monitor callback storage` | Frees the monitor callback's storage, after the session's last native call, only if teardown has been safe so far |
| `glfw session occupancy` | Vacates the guard after a safe teardown, or poisons it |

A release-time native error is checked after the native call returns, without
logging or pumping events. It is retained through
[the failure table](resources.md#the-failure-table): beside a failing body as a
labelled cleanup failure, or as the scope's own failure after a successful body.
It does not poison.

Poisoning is the answer when teardown cannot establish that native ownership
and callback registration ended safely. That is the case when termination or
detaching either callback raises instead of returning, when initialization or attachment raises
with the native state unknown, or when a release runs on a thread other than
the owner. The callback storages are then deliberately leaked rather than freed
while they might still be called. The guard stays occupied-and-poisoned, so every
later entry fails with `SessionPoisoned` before any native call.

The storage is safe to free after a normal detach because of the owner-thread
rules. This package makes every GLFW call on the owner thread, and GLFW reports
errors from inside the failing call. Once the owner has detached the callback,
GLFW can no longer invoke it.

These releases satisfy [what a release may do](resources.md#what-a-release-may-do).
Each native call is a bounded GLFW call on the owner thread that waits for no
other thread and no event, and the bookkeeping is a non-blocking atomic `IORef`
update. The wake gate's wait is the one wait on another thread, and it is
bounded: it waits only for calls already admitted, each making one empty-event
post and non-blocking bookkeeping, and no new call can be admitted once it has
begun. No release contains a queue, fence, device wait, or logger. Closing the
gate never changes teardown safety. A session whose teardown was otherwise safe
is not poisoned by it, including when the owner is cancelled while the wait
runs.

## The binding

Only the operations the models use are bound: `glfwPlatformSupported`,
`glfwSetErrorCallback`, `glfwInitHint`, `glfwInit`, `glfwGetPlatform`,
`glfwTerminate`, `glfwSetMonitorCallback`, `glfwGetMonitors`,
`glfwGetPrimaryMonitor`, `glfwGetMonitorName`, `glfwGetMonitorPos`,
`glfwGetMonitorWorkarea`, `glfwGetMonitorPhysicalSize`,
`glfwGetMonitorContentScale`, `glfwGetVideoMode`, `glfwGetVideoModes`,
`glfwDefaultWindowHints`, `glfwWindowHint`, `glfwCreateWindow`,
`glfwDestroyWindow`, `glfwGetWindowSize`, `glfwGetFramebufferSize`,
`glfwGetWindowContentScale`, `glfwGetWindowPos`, `glfwGetWindowAttrib`, and the
size, framebuffer size, content scale, position, focus, iconify, maximize,
refresh, close, key, character, mouse button, cursor position, cursor enter,
and scroll callback setters, the owner loop's `glfwPollEvents` and
`glfwWaitEventsTimeout`, and the wake capability's `glfwPostEmptyEvent` with
`glfwGetError`. `glfwSetWindowSize` is called for the native examples only, as
is the progress note's own `glfwPostEmptyEvent`; no production path calls
them. The native
examples also invoke the registered input trampolines through
`hetoimasia_glfw_inject_*_for_check`.

- Imports go through `native/cbits/hetoimasia_glfw.h`, which includes the
  installed `GLFW/glfw3.h` with `GLFW_INCLUDE_NONE`. The C compiler therefore
  checks each CAPI declaration, and every constant comes from the header. The
  exceptions are `glfwSetErrorCallback` and `glfwSetMonitorCallback`, `ccall`
  imports, because CAPI cannot spell their function-pointer types.
- `glfwGetMonitors`, `glfwGetMonitorName`, `glfwGetVideoMode`, and
  `glfwGetVideoModes` are reached through shim accessors
  (`hetoimasia_glfw_monitors` and its siblings) that only restate GLFW's `const`
  return types as the generated wrappers declare them, keeping the C build
  warning-clean. Each video mode is copied field by field through
  `hetoimasia_glfw_video_mode_at`, which reads the header's own `GLFWvidmode`, so
  no structure layout is assumed. Every array and string GLFW returns is copied
  before the operation returns, and a negative count, or a positive count
  beside a null array, is reported as inconsistent rather than read.
- Every GLFW import is `safe`. Any of them may re-enter Haskell through the
  error callback, and a safe call lets other Haskell threads run while it is in
  C. The thread-identity and wake-mark shims call nothing and are `unsafe`.
- The production wake is made through the shim's
  `hetoimasia_glfw_post_empty_event`, a `safe` import callable from any thread.
  In one C call on the calling OS thread it clears that thread's GLFW error
  state with `glfwGetError`, sets the call's wake mark in C11 thread-local
  storage, calls `glfwPostEmptyEvent`, clears the mark, and returns the code
  `glfwGetError` then reads. The error callback reads the mark through the
  `unsafe` `hetoimasia_glfw_current_wake_mark`. The shim also counts calls that
  entered and returned from the post, and records the sequence number of the
  wait in progress as it posts. Only the native examples read these records,
  through `wakeCountsForCheck` and `takeLastWaitForCheck`.
- The production finite wait is made through the shim's
  `hetoimasia_glfw_wait_events_timeout`, a `safe` import that records the
  waiting OS thread and gives each wait an odd sequence number, then calls
  `glfwWaitEventsTimeout`. That observation is the shim's only state, and no
  production path reads it: the native examples' progress note lands only when
  the same wait's sequence number surrounds a kernel report that the waiting
  thread is blocked — `TH_STATE_WAITING` on macOS, state `S` in
  `/proc/self/task/<tid>/stat` on Linux — so it lands only inside GLFW's own
  wait. `blockedWaitForCheck` makes the same observation and posts nothing, so
  the wake examples can prove a wait was blocked without a test wake that would
  confound the production one. As each wait returns, the shim records its
  sequence number and whether a production wake named it. The shim holds no
  queue or game logic.

The window callback setters are `ccall` imports for the same reason. Each
callback wrapper only drops the window pointer and calls the model's callback,
which is already contained.

## Monitors

`Hetoimasia.GLFW.Monitor` publishes the monitor inventory the session owns. Its
model is `Hetoimasia.GLFW.Internal.Monitor`; the session performs its stages and
wraps every operation in the owner-thread and liveness checks.

### Inventory ownership

The session constructs the inventory at entry and ends it at teardown. A
`MonitorInventory` is immutable and prepared to normal form before it is
published through a [latest-value snapshot](messaging.md#latest-value-snapshots).
It carries a revision equal to the snapshot's, a phase, and every connected
monitor as a copied `MonitorDescription`, in the order GLFW enumerated them:

| Attribute | Source |
|---|---|
| Identity | Issued by the session, per connection |
| Name | `glfwGetMonitorName` |
| Primary | Whether `glfwGetPrimaryMonitor` names this monitor |
| Position | `glfwGetMonitorPos`; desktop screen coordinates, negative or nonzero as reported |
| Work area | `glfwGetMonitorWorkarea` |
| Physical size | `glfwGetMonitorPhysicalSize`; millimetres |
| Content scale | `glfwGetMonitorContentScale` |
| Current mode, video modes | `glfwGetVideoMode`, `glfwGetVideoModes` |

An empty list is an ordinary observation of a desktop with no monitor. Any
thread may read `monitorInventory`, and the window host lends the same endpoint
as `hostMonitors`. Only the owner thread refreshes: `synchronizeMonitors` always
does, `resolveMonitor` does before it answers, and the host's
[owner loop](#the-owner-turn) does after native events whenever the monitor
callback captured a change. A refresh enumerates the monitors, queries each, and
publishes a new revision only when a description or an identity changed. GLFW's
monitor callback reports connection changes only, so a change of work area,
content scale, or mode on a monitor that stays connected appears at the next
`synchronizeMonitors`. Nothing selects or assumes a primary monitor: the
platform's designation is an attribute, and nothing assumes it starts at the
desktop origin.

### Identity lifetime

A `MonitorId` is the session's identity and a local number starting at one that
the session never reissues, issued once per connection. Between boundaries the
session keeps each connection's native monitor address beside its identity as a
private correlation token. A token is only compared; it is never turned back into
a pointer, and no pointer is retained between owner boundaries. At a refresh:

- a captured connection or disconnection for an address ends the identity that
  address held, so a monitor disconnected and reconnected at the same address
  before one boundary still receives a fresh identity, even though the final
  enumeration is unchanged;
- a lost change ends every identity, because which connection it concerned is
  unknown (see [Callback containment](#callback-containment));
- every enumerated monitor whose address still holds an identity keeps it,
  wherever the enumeration now lists it, and every other one receives a fresh
  identity;
- an identity whose address is no longer enumerated ends.

An ended identity never resolves again. An identity from another session —
including a completed earlier session whose local numbers and native addresses
repeat — never resolves either, because the session identity differs. A copied
description stays readable, with its identity, after that identity ends.

`resolveMonitor` re-resolves an identity at an owner boundary: it refreshes,
which enumerates the monitors GLFW reports at that moment, and answers
`MonitorAvailable` with the fresh description, or `MonitorDisconnected` before any
native operation targets that monitor. Operations that need a live monitor, such
as the mode transitions still to come, use the model's private
`withResolvedMonitor`, which lends the pointer that same enumeration returned to
one native step and keeps nothing.

### Validation

Every native number is checked before it becomes an observed value, and an
inconsistent report becomes `Unavailable` rather than a fabricated value:

| Report | Observation |
|---|---|
| An enumeration with an inconsistent count, a null monitor, or a repeated monitor | The inventory's monitors are `Unavailable`, and every identity ends |
| A primary monitor that is not among those enumerated | Every monitor's primary attribute is `Unavailable`; no designated primary is `False` |
| A null name | `Unavailable` |
| A negative work area width or height | `Unavailable` |
| A zero or negative physical width or height, as GLFW reports an unknown size | `Unavailable` |
| A non-finite or non-positive content scale on either axis | `Unavailable`, checked before conversion |
| A null current mode, or a mode with a non-positive width or height | `Unavailable` |
| A video mode list with an inconsistent count, or holding an invalid mode | `Unavailable` |
| A negative bit depth, or a zero or negative refresh rate | `Unavailable` within that mode |

As for windows, a query that reports only `GLFW_FEATURE_UNAVAILABLE` is
`Unavailable`, and any other report fails the boundary with `NativeFailure`
under `sample monitors`.

### Callback containment

The monitor callback is a protected resource of the session. It runs
uninterruptibly, copies the monitor's address and the event code, records them
into the session's capture latch with one non-blocking `IORef` update, and
returns. It calls no application code and no native function, waits for
nothing, and lets no Haskell exception unwind into C. The latch keeps at most 64
changes between boundaries. A change beyond that, an event code GLFW does not
define, or a fault in the callback is a lost change: it is never dropped
silently, and the next refresh ends every identity before any further monitor
use. A fault is also latched with its context and rethrown, once that refresh
has committed, with the `monitor callback` operation and the `callback` and
`later-faults` identifiers.

A refresh reads the latch without clearing it and clears what it folded only in
the masked commit that publishes, and only if the callback recorded nothing
since the read; otherwise it starts again. A cancellation or failure before the
commit leaves every capture latched and the inventory unchanged.

The callback's storage stays valid through the session's last native call. At
teardown the inventory closes first; the callback is then detached before
termination, taking any fault latched since the last boundary so no detach
outcome can abandon it — raised on its own after a detach that succeeded, and
retained as a `glfw monitor callback fault` cleanup failure beside one that
failed — and its storage is freed after the error callback's detach, only if
teardown stayed safe. A detach that raises, or runs off the owner thread, keeps
the storage and poisons the guard, as for the error callback.

### Session completion

When the session ends, every identity ends, the last descriptions are published
as the `InventoryClosed` inventory with the next revision, and the snapshot is
closed in the same transaction, so waiting readers wake, receive that
observation, and then `EndOfStream`. The closed inventory stays readable for as
long as a reader holds the endpoint.

### Platform restrictions

- Monitors are observed on X11 and Cocoa, the backends a session selects.
- GLFW 3.4 on X11 enumerates connected RandR outputs with active CRTCs, falling
  back to one monitor for the screen when RandR is unusable. RandR 1.5 virtual
  monitor objects are not GLFW monitors, so `xrandr --setmonitor` does not add
  one. The isolated Xvfb display in CI exposes exactly one 1280 by 1024 monitor
  at the origin and cannot simulate hotplug or a multi-monitor topology.
- Empty inventories, several monitors at negative and nonzero origins,
  disconnects, reconnects at a reused address, stale resolution, inconsistent
  numbers, and lost changes are therefore proven by the CPU examples; real
  attach and detach is local interactive evidence (see
  [The native suite](#the-native-suite)).
- A monitor's physical size may be unknown, which GLFW reports as zero, and a
  refresh rate may be unknown; both are `Unavailable`.

## Windows

`allocWindow` creates a window as a lexical scoped resource, for the rest of the
enclosing `withScoped` scope, and `withWindow` is that scope on its own. Any
number may be live in one session. The window host creates windows dynamically
and closes them in any order as members of a
[scoped collection](resources.md#scoped-resource-collections), acquiring each
from the same `Assembly` as one member; there is no second acquisition or cleanup
path. See [Dynamic windows](#dynamic-windows).

### Owner, thread, and lifetime

The owner is the session's owner, the process main thread. Creation,
`synchronizeWindow`, and every release run there and check, before any native
call, that they do (`NotSessionOwner`) and that the session is live
(`SessionEnded`). A window lives until its enclosing scope ends, which must be
inside the session's. Its handle turns terminal as the first step of release,
after every borrowing scope has ended: `windowEnded` answers `True`, and
`synchronizeWindow` answers `WindowEnded` without a native call. The session
survives a window's release and can create another window.

A `WindowId` is the session's identity and a local number starting at one that
the session never reissues, even for a creation that failed. A later window
never answers to an ended handle.

### Creation

`allocWindow` constructs the window as a staged composite. In order:

1. **Validation.** Both dimensions must lie in `1 .. 2147483647` and the title
   must contain no NUL, or creation is `WindowConfigRejected` before any
   conversion to C or native call. `validateWindowConfig` is the same check.
2. **Owner.** The owner thread and liveness are checked. A session whose
   teardown safety has been lost refuses with `SessionPoisoned`, the answer its
   next entry would give. The local identity is issued.
3. **Callback storage.** One wrapper per callback is allocated.
4. **Native window.** Every hint is reset with `glfwDefaultWindowHints`, then
   `GLFW_CLIENT_API = GLFW_NO_API`, `GLFW_VISIBLE`, `GLFW_FOCUSED`, and
   `GLFW_FOCUS_ON_SHOW` are set explicitly from the configuration, so one
   window's configuration cannot leak into the next. When `glfwCreateWindow`
   returns a live pointer, its destruction is registered before any report
   from the same call is raised.
5. **Callbacks.** The callbacks' detach is registered, and then every callback
   is attached. An attachment that reports an error, raises part-way, or is
   interrupted is therefore detached before the window is destroyed.
6. **Initial observation.** Every attribute is sampled at that owner boundary,
   reconciled with anything captured since attachment, prepared, and published
   as revision zero of a fresh snapshot.

A failure at any stage releases exactly what the earlier stages acquired, in the
release order below, with the triggering failure primary.
`hiddenTestWindowConfig` is hidden, unfocused, and not focused on show;
`defaultWindowConfig` is shown and focused.

### Observations

A `WindowObservation` is immutable and prepared to normal form in producer `IO`
before it is published through the window's
[latest-value snapshot](messaging.md#latest-value-snapshots). It carries the
window's identity, a revision equal to the snapshot's, a phase, and the
attributes:

| Attribute | Source |
|---|---|
| Logical extent | `glfwGetWindowSize`, size callback; screen coordinates |
| Framebuffer extent | `glfwGetFramebufferSize`, framebuffer size callback; pixels |
| Content scale | `glfwGetWindowContentScale`, content scale callback |
| Placement | `glfwGetWindowPos`, position callback; desktop screen coordinates |
| Focused, iconified, maximized | `glfwGetWindowAttrib`, their callbacks |
| Visible | `glfwGetWindowAttrib` |
| Close request | close callback |
| Cursor position | cursor position callback; coalesced, never sampled |
| Cursor inside | cursor enter/leave callback; coalesced |

Observed fields hold only sampled or called-back values, never the requested
configuration; a sampled value may of course equal the request. Each query is
bracketed by the error capture. A query that reports only
`GLFW_FEATURE_UNAVAILABLE` is `Unavailable` rather than a fabricated value, and
any other report fails the boundary with `NativeFailure`. A zero framebuffer
extent, as an iconified window reports, is an ordinary nondrawable observation.

Getters sampled together are an engine observation, not an atomic snapshot of
the OS. Geometry and attributes coalesce to their latest values; a snapshot
preserves no event history.

### Callbacks and the reconciliation boundary

The size, framebuffer size, content scale, position, focus, iconify, maximize,
refresh, close, key, character, mouse button, cursor position, cursor enter,
and scroll callbacks are contained at the trampoline. Each runs
uninterruptibly, copies and forces its fixed payload, records it into the
window's capture latch with one non-blocking `IORef` update, and returns. None
calls application code, waits for capacity, joins a worker, polls, logs, or
destroys a native object. Anything a callback raises is caught there with its
context and latched rather than unwinding into C; the first is kept and later
ones are counted. The focus callback is the one owner of focus: it coalesces
the latest flag into the observation and stages an ordered focus event for the
input feed. Cursor motion coalesces into the observation and the feed's cursor
sample; it is not an input event. The latest cursor sample stays in the
capture latch across boundaries, so a later turn's button still copies it. Key, character, button, scroll, and focus
transitions are staged in a bounded buffer of `inputStagingCapacity` (256)
events and are never coalesced. A button callback copies the latest cursor
sample at that moment, so later motion does not move a click already staged.
Overflow of that buffer sets a loss latch that remains set while the buffer is
full. At the next owner boundary the latch is checked before any staged prefix
is published: the ambiguous batch is discarded and the attached feed begins
the same overflow reset a full channel would, with `unadmitted` equal to the
discarded prefix plus every callback that arrived after the latch. Coalesced
focus is applied in that same reset transaction, so resumption cannot reopen
an unfocused window and the focus callback is not counted twice. A window with no feed attached discards staged input at that boundary
without a reset. Publication of a captured batch is uninterruptible, so a
cancellation cannot admit a prefix and drop the rest.

Captures are reconciled on the owner thread at an owner boundary: at creation
after the initial sampling, at `synchronizeWindow` after it samples, and after
any private owner step's native calls return, whether that call was a setter or
a poll. An observation request executes through the same boundary, and so
does the window host's [owner loop](#the-window-host-and-owner-loop), which
reconciles every window after each poll or wait. In order, a boundary:

1. runs its native work, taking the reports made during it;
2. reads the capture latch without clearing it and folds it, then any fresh
   sample, into the current observation;
3. prepares a new revision if anything changed, or if a refresh or a close
   request was captured, even when every attribute is unchanged;
4. commits: clears the captures it folded, publishes the revision, and records
   it as the owner's current observation, in one masked step with no
   interruptible operation;
5. takes and rethrows a latched callback fault in one masked step, with its
   original type and context, annotated with the `window callback` operation
   and the `window`, `callback`, and `later-faults` identifiers.

A cancellation or failure before the commit leaves every capture, the fault
included, latched for the next boundary, and the snapshot and owner state
unchanged; nothing can land between the commit's three writes, so an
observation's revision always equals its snapshot cursor's. If a callback
recorded anything between the read and the commit, the fold starts again from
the newer captures.

An asynchronous exception is rethrown unannotated, so cancellation stays
cancellation. If the native work itself fails, its failure propagates and the
captures and fault stay latched for the next boundary. Preparation runs outside
the trampoline and outside `STM`.

### Close requests

A native close request never destroys the window and never exits the process.
It is latched and reconciled into `observedCloseRequest` as a `CloseRequest`
naming the window and a number issued in increasing order per window; several
requests before one boundary coalesce into the newest. The model's private
rejection transition clears a request only while it is still the latest, so
rejecting an older request never erases a newer one. What a request means is the
application's decision: the window host
[surfaces it to application policy](#close-requests-in-the-owner-loop), which may
reject it or honour it by beginning that window's close protocol. There is no
default close policy, and no request closes a window by itself.

### Release

| Order | Part | Release |
|---|---|---|
| 1 | `glfw window callbacks` | Marks the handle terminal, takes any callback fault latched since the last boundary, detaches every callback, then raises any report made during that call |
| 2 | `glfw window` | Destroys the native window, then raises any report made during that call |
| 3 | `glfw window callback storage` | Frees the wrappers if release stayed certain; otherwise keeps them and poisons the session |
| 4 | `glfw window observations` | Publishes the terminal observation and closes the snapshot in one transaction |

Detaching before destruction, after every borrowing scope has ended, is the
documented order. A callback fault nobody observed is taken before the detach,
so no detach outcome can abandon it: after a detach that succeeded it is the
release's own failure, and beside a detach that raised or reported an error it
is retained as a `glfw window callback fault` cleanup failure while the detach's
failure stays primary. A release-time native error whose call returned is checked after the call,
without logging or pumping events, and retained through
[the failure table](resources.md#the-failure-table). After a detach, release
stays certain. After a destroy, the window's destruction was not established,
so release becomes uncertain, as below.

Release becomes uncertain when detaching or destroying raises instead of
returning, when destroying reports an error, when a release runs off the owner thread or after the session ended,
or when attaching the callbacks raised during creation. Callback reachability is
then unknown, so the wrappers are kept rather than freed beneath native code,
the session refuses further windows with `SessionPoisoned`, keeps its own error
callback storage, and poisons its guard when it ends.

The terminal observation keeps the last observed attributes without querying the
destroyed window, advances the revision, and names the disposal's outcome:
`WindowReleased` when every part succeeded, `WindowDisposalFailed` when a part
failed while release stayed certain, and `WindowReleaseUncertain` when release
became uncertain. The phase is computed from two flags the parts set, never from
their exceptions: nothing is formatted or logged, and the failures stay on the
release's failure path as cleanup evidence. This happens on exceptional teardown
as on normal teardown. Readers holding the endpoint can still read it and
receive `EndOfStream` after it, under the snapshot contract.

### Lifecycle phases

| Phase | Published | Meaning |
|---|---|---|
| `WindowOpen` | At creation, revision zero | Live, not closing |
| `WindowClosing` | When an owner begins the window's close protocol, as its own revision, in the transaction that closes the window's admission | Live, callbacks attached, admission closed; not yet released |
| `WindowReleased` | By release, as the last revision | Disposed successfully |
| `WindowDisposalFailed` | By release, as the last revision | Disposal failed; release stayed certain |
| `WindowReleaseUncertain` | By release, as the last revision | Disposal failed; callback reachability unknown |

Reconciliation keeps a closing window's phase while its callbacks are still
attached. The terminal phase is always published before the snapshot closes, so
a reader that skipped intermediate revisions still receives the disposal's
outcome before `EndOfStream`. A lexically scoped window never passes through
`WindowClosing`, and neither does a window the host disposes at shutdown
without a close protocol having begun.

## Window commands

`Hetoimasia.GLFW.Command` admits prepared window commands through a bounded
port, gives each admitted command a persistent completion ticket, and settles
every one of them exactly once. It composes
[the bounded FIFO channel](messaging.md#bounded-fifo-channels) and
[prepared payloads](messaging.md#evaluation-guarantees) and adds the per-request
completion both deliberately leave out. It is a window-service protocol, not
generic request/reply machinery. The window host's
[owner loop](#the-window-host-and-owner-loop) is its only production executor;
the test seam's private executor drives the same protocol in CPU examples.

### Owner, thread, and lifetime

`newWindowCommandHost` checks, before anything else, that it runs on the
session's owner (`NotSessionOwner`) and that the session is live
(`SessionEnded`), then creates the host's channel, refusing a capacity
`newChannel` refuses. The owner keeps the `WindowCommandHost`: closure,
statistics, and direct performance. Clients receive the `WindowCommandPort`,
which can only submit, and the tickets their submissions return; any thread may
hold either. Neither carries a native handle, destruction authority, a channel
endpoint, or a completion cell. Queued commands are claimed and settled only on
the owner thread. A host lives while referenced. The window host closes its own
command host and every window's by quiescence, before the worker drain, a
window's also when its close protocol begins, and all of them again when it is
released; a command host created directly is closed by its application.

### Admission

A `WindowCommand` is an immutable value: a request to observe, control, or close
one window, or to create a window from a `WindowConfig`. Submitting it
issues a request identity, records a `CommandOrigin` beside it — the request,
the window it addresses if any, the submission site, and the caller's diagnostic context — and
prepares the message to normal form on the submitting thread. A failure raised
while preparing propagates and admits nothing. The submission site is the
outermost call-stack frame and the whole stack, under the failure module's
[caller attribution](failures.md#caller-attribution) policy.

`submitWindowCommand` never waits. It answers `SubmitAccepted` with a ticket,
`SubmitFull` when capacity commands are queued, or `SubmitClosed` once admission
has ended, and `SubmitClosed` takes precedence. `awaitSubmitWindowCommand` is
the separate wait for capacity. Cancelling it with an asynchronous exception
admits nothing, and closure ends it with `WaitClosed`.

The message and its completion cell are added in one transaction: the message
to the channel, and the cell, keyed by request, to the host's pending map. The
cell is never inside the message. `SubmitFull`, `SubmitClosed`, a rolled-back
admission, and a cancellation before that transaction commits leave neither. A
cancellation after it commits withdraws nothing: the command stays queued and
settles even if its caller never received the ticket. Request identities are
never reissued, even for a submission that was not admitted. They identify
requests and do not order them; order is the order admissions committed.

**The wake an admission owes.** Once the transaction has committed — through
either operation, on the host's port or a window's own — the admission wakes the
session's owner, so a command submitted while the owner sits in its idle native
wait ends that wait instead of waiting for it to run out. The command is
recorded first and the hint posted after, never the reverse. `SubmitFull`,
`SubmitClosed`, `WaitClosed`, and a rolled-back admission wake nothing, because
they admitted nothing.

The obligation is held from the commit onward, with no gap: the commit and the
wake run under a mask, and the wake itself runs uninterruptibly, so no
asynchronous exception delivered to the submitting thread can drop it. A
cancellation before the commit admits nothing and wakes nothing. One requested
after it takes effect only once the wake has been posted, and the command, whose
caller may never have received its ticket, still executes and still settles
exactly once.

The waiting operation stays cancellable under that same protection, because its
wait for capacity blocks in a transaction and a blocked transaction is an
interruptible operation even under a mask. A cancellation delivered while it
waits therefore aborts it and admits nothing, and nothing interruptible
separates the commit that ends the wait from the wake it owes. Cancelling that
waiter exactly as capacity frees is a race with two correct outcomes, and the
host's own bookkeeping, not the caller's answer, says which happened: either
nothing was admitted and nothing woke, or the command was admitted and its wake
posted, whether or not its caller lived to receive the ticket.

The submission's answer and its ticket never depend on the wake's outcome. A
wake that fails as an expected platform failure degrades the session's wake path
under [the degradation policy](#the-degradation-policy) and leaves the ticket
untouched; one that raises a programming or lifetime violation propagates to the
submitter with the command still admitted. Neither turns an accepted command
into a rejection, and neither resubmits it.

### Dispositions

| Disposition | When | Effects |
|---|---|---|
| `Performed result` | The command was performed or requested from the window system | Applied; `result` was prepared before settlement |
| `Rejected reason` | The executor serves no such window (`WindowNotServed`), the window has ended (`WindowAlreadyEnded`) or is closing (`WindowIsClosing`), a native call failed first (`WindowNativeFailure`), the executor or port cannot close or create (`CloseNotPermitted`, `CreationNotPermitted`), or a creation was refused (`WindowConfigInvalid`, `WindowCapacityReached`, `WindowCreationPoisoned`) or failed during construction with a clean rollback (`WindowCreationFailed`) | None applied; a failed construction was rolled back |
| `Rejected (ControlRejected window reason)` | A [window control](#window-controls) was refused by its mode transition or its validation | None applied |
| `Unsupported control` | The platform cannot perform a window control | None applied |
| `Attempted attempt` | A window control's native calls were made | Requested from the window system; its observations report what happened |
| `NotExecuted` | Closure settled it while it was still queued | None |
| `Interrupted request` | Its execution, or the preparation of its completion data, raised | May have been applied; nothing is replayed or rolled back |

A settled ticket never changes, and an admitted command never disappears. A
native failure is carried as copied data: the operation that raised it, whether
the call itself failed, and the reported codes and descriptions. An arbitrary
Haskell exception is never serialized into a ticket. The ticket names only the
interrupted request, and the exception propagates from the executor with its
own type and context. A construction whose rollback's own release failed is
never a `WindowCreationFailed` rejection — only a clean rollback is one: the
construction failure carries the rollback failure as retained cleanup evidence
and propagates, settling the command as `Interrupted` and ending the loop.

### The creation handoff

A creation that succeeds settles as `Performed (WindowCreated window)`: ordinary
data, prepared like every other disposition. The new window's `WindowClient` —
its own command port and its read-only observations — is not data. It is never
prepared and never put inside a message; it is written beside the prepared
disposition, in the settling transaction, and `pollWindowClient` reads it from
the ticket as often as desired once the creation has settled. The executor hands
it over only after the window was constructed, registered with its owner, and
published its initial observation. A `WindowClient` carries no native handle and
no release, retirement, or creation authority. A creation interrupted before
settlement, even after registration, settles as `Interrupted` with no
`WindowClient`, and its window's owner still owns it.

### Port scope

A host created with `newWindowCommandHost` serves every command. The window host
also gives each of its windows a private command host of its own, whose port the
window's `WindowClient` carries. That port can submit anything, but its executor
settles a creation as `CreationNotPermitted` and a command addressed to another
window as `WindowNotServed`, each without executing it, and each still costs its
dispatch attempt. Holding one window's port therefore grants no authority over
another window and none to create one.

### Tickets and waiting

`pollCompletion` reads a ticket in `STM` without waiting, as often as desired.
`awaitCompletion` waits for settlement and may be repeated; cancelling the wait
affects only the wait, and dropping a ticket cancels nothing. A ticket stays
readable after its cell has left the host's bookkeeping, and after closure.

The owner thread is the only thread that executes commands, so no public
operation waits for one there. On the owner thread, `awaitCompletion` of an
unsettled ticket and `awaitSubmitWindowCommand` on a full host fail with
`OwnerThreadWouldWait` instead of blocking; a settled ticket answers at once.
The owner uses `performWindowCommand`, the direct checked execution operation.
It checks the owner and liveness, involves no queue, cell, or ticket, answers
`NotExecuted` after closure, and lets a Haskell exception propagate unchanged.

### Execution

An executor claims queued commands in the order their admissions committed. A
claim receives the command and marks it active in one transaction, and its
protection begins with the claim, so no interruption can separate them. The
whole claimed lifetime is protected, including the preparation of completion
data. If anything raises, synchronous or asynchronous, the command settles as
`Interrupted` with its request identity before the original exception is
rethrown with its context. A synchronous failure gains the
`execute window command` operation context with the `request`, `window`,
`submitted-at`, and caller-context identifiers, so crossing the queue keeps
where the request came from while the failure's origin stays at the operation
that raised it. An asynchronous exception is rethrown unannotated. A settlement
never replaces a disposition already settled.

The executor protocol is private to the package. Its one production caller is
the window host's owner loop. The test seam's private executor also drives it:
it executes queued commands against the
seam windows it is given, can deliver an interruption immediately after the
claim, and can replace execution with a scripted step for simulated effects or
completion data that fails to prepare. It is a test seam, not a second
production executor.

### The observation request

`observeWindowCommand` asks for an observation. Executing it synchronizes the
addressed window at an owner boundary, which samples and publishes under the
[observation contract](#observations). It completes with
`ObservationPublished`, naming the revision of the committed observation that
followed the sample: a new revision if sampling changed anything, and otherwise
the published observation the sample matched. Publication commits before
settlement, so a reader that sees the disposition can already read that
revision. It never samples another window. A window the executor was not given
is `WindowNotServed`, an ended window is `WindowAlreadyEnded` without a native
call, and a sampling failure is `WindowNativeFailure` with nothing published.
A callback fault rethrown at that boundary is not a sampling failure: it
interrupts the command and propagates.

`closeWindowCommand` and `createWindowCommand` change which windows exist, so
only an executor that owns window lifetimes performs them: the window host's
owner loop, under [Dynamic windows](#dynamic-windows). Every other executor —
`performWindowCommand` and the test seam's, over lexically scoped windows —
settles a close of a window it was given as `CloseNotPermitted`, a close of any
other as `WindowNotServed`, and a creation as `CreationNotPermitted`.

### Bookkeeping and closure

The pending map holds one cell per queued or active command and nothing else,
so it never holds more than the capacity plus the commands being executed.
Settlement writes a cell and removes it in one transaction, and a cell is always
settled before it is removed. There is no result queue and no request history.
`commandStatistics` reads the capacity and the queued, active, and pending
counts in one transaction.

`closeWindowCommands` ends admission and, in the same transaction, settles every
command still queued at its commit as `NotExecuted` and removes it, returning how
many it settled. No queued command runs afterwards, every waiter on those
tickets wakes, blocked capacity waits end with `WaitClosed`, and later
submissions answer `SubmitClosed`. A command already claimed is active work:
closure neither waits for it nor reports it unexecuted, and it settles through
its execution. Closure is finite, never retries, and is idempotent. A raw
channel close alone would keep the backlog, and a raw abort would discard it
without settling tickets; there is no abort.

## Window controls

The control commands of `Hetoimasia.GLFW.Command` change an existing window:
its title; its logical size; its desktop position; its size constraints, a
minimum and a maximum logical size with an optional aspect ratio; showing and
hiding it; requesting input focus or the user's attention; and minimizing,
maximizing, and restoring it. Each is a prepared, immutable `WindowCommand`
addressed to one `WindowId`, admitted like any other command, and executed on
the owner thread: by the window host's [owner loop](#the-window-host-and-owner-loop)
from the host's port or the window's own, or directly by `performWindowCommand`.
None assumes a primary window. A control's representation lives in the private
`Hetoimasia.GLFW.Internal.Control`, and `SizeConstraints` is exported without its
constructor or fields, so a client builds a control only through the smart
constructors, and nothing it holds reaches a native window. The smart
constructors accept any values: validation happens when the command executes,
against the window's state at that moment.

### Execution

Executing a control makes no native call until each of these has passed, in
order:

1. **Addressing.** The window host answers `WindowNotServed` for a window it does
   not hold, never held or already retired, and `WindowIsClosing` for one whose
   close protocol has begun; a lexical executor answers `WindowNotServed` for a
   window it was not given. An ended window is `WindowAlreadyEnded`. The model
   also answers `WindowIsClosing` for a window whose observed phase is no longer
   `WindowOpen`.
2. **Reconciliation.** Pending callback captures are reconciled at the owner
   boundary, so validation reads the owner's latest observation, never one a
   client holds.
3. **Mode transition.** A window whose mode transition marker is set is
   `ControlRejected ModeTransitionInProgress`.
4. **Presentation.** An operation the window's applied presentation does not
   admit is `ControlRejected (ControlIneligibleInMode kind)`, or
   `ControlRejected ControlModeIndeterminate` while the applied presentation is
   indeterminate; see [Ordinary controls by presentation](#ordinary-controls-by-presentation).
5. **Capability.** An operation the session's `WindowCapabilities` names as
   unperformable is `Unsupported`, with the operation and a reason.
6. **Validation**, below, refusing with `ControlRejected` and a typed
   `ControlRejection`.

Then the control's native calls are made, each bracketed by the error capture,
and every attribute is sampled and published as a new revision, even when
nothing changed. Settlements from the first six steps carry no revision,
because nothing was called or sampled. A control never changes the window's
applied mode.

### Validation

| Control | Refused when | `ControlRejection` |
|---|---|---|
| Title | It contains a NUL, which the native UTF-8 C string would truncate | `ControlTitleRejected` |
| Size | A dimension is outside `1 .. 2147483647` | `ControlExtentRejected` |
| Size | The active constraints are indeterminate | `ActiveConstraintsIndeterminate` |
| Size | It lies outside the known minimum or maximum, or does not satisfy their aspect ratio exactly: width × denominator = height × numerator, compared without overflow | `SizeOutsideConstraints` |
| Position | A coordinate is outside the native `int` range | `ControlPlacementRejected` |
| Constraints | A minimum or maximum dimension is outside `1 .. 2147483647` | `ConstraintBoundRejected` |
| Constraints | The minimum exceeds the maximum in either dimension | `ConstraintBoundsInverted` |
| Constraints | An aspect ratio term is outside `1 .. 2147483647` | `AspectRatioRejected` |
| Constraints | The window's logical size is `Unavailable` | `CurrentSizeUnavailable` |
| Constraints | They do not admit the window's currently observed logical size, bounds and aspect ratio alike | `ConstraintsExcludeCurrentSize` |
| Show, hide, focus, attention, minimize, maximize, restore | Only by addressing, a mode transition, presentation, or capability | — |

The currently observed size is the owner's latest observation, reconciled when
the command executes. A size is checked against the window's preserved windowed
constraints only while the native constraints follow them; while a mode
transition has suspended them, or a suspension or restoration stopped part-way,
every size is `ActiveConstraintsIndeterminate`. A window starts in the fully
known unconstrained state, in
which a size needs only to be positive and representable. A size outside the
constraints is refused; it is never sent for the platform to clamp, and a caller
that wants tighter constraints resizes first. Every constraint set has both a
minimum and a maximum.

### Outcomes and observations

An attempted control settles as `Attempted` with a `ControlAttempt`:

| `attemptedOutcome` | Meaning |
|---|---|
| `ControlReturned` | Every native call returned without a report |
| `ControlNativeError` | The call returned but reported errors: the native operation's name and the copied reports |
| `ConstraintUpdateFailed` | A constraint update stopped at a call that reported errors; see below |

None of these says the window manager honoured the request. A native call that
raises instead of returning, or a callback fault rethrown at the boundary,
interrupts the command, which settles `Interrupted` while the exception
propagates from the executor.

`attemptedObservation` is `PostCallRevision revision`: the revision the sample
taken after the calls published. Because a new revision is published even when
nothing changed, the revision proves that the sample followed the call. It does
not promise that the window manager converged or that the requested state was
reached. A sample that reports errors publishes nothing and is
`PostCallSampleFailed` with the copied outcome and reports. Snapshots keep only
their latest value, so a client may find the snapshot already beyond the named
revision, and the named revision itself is not retrievable: compare revision
order and read the latest sampled state.

Reports made on the owner thread during a control's own native call belong to
that control, and its ticket's origin names the request, window, submission
site, and caller context. Reports from another thread, or from outside the call,
stay asynchronous under [the error capture](#native-error-evidence) and are never
attributed to whichever command is executing.

### Constraint updates and recovery

A constraint set is validated whole before its first call and applied in the
documented order `constraintCallOrder`: `glfwSetWindowSizeLimits` with the
minimum and maximum, then `glfwSetWindowAspectRatio` with the ratio, or
`GLFW_DONT_CARE` for none. The owner marks the window's constraint state
indeterminate before the first call, stops at the first call that reports an
error, and marks the set known only once every call has returned without a
report.

A call that reports an error settles as `ConstraintUpdateFailed`:
`constraintsReturned` lists the calls that returned before it, in order,
`constraintsFailed` names the call that reported, `constraintsUnattempted` lists
the calls not made, and `constraintReports` carries the reports. With calls
returned before the failure, it is a partial update. Nothing is rolled back, and
nothing claims the complete set was applied or that an earlier call was undone.
A call that raises leaves the state indeterminate as well.

While the state is indeterminate, every size control is refused with
`ActiveConstraintsIndeterminate` and no native call. A constraint update stays
admissible, and one that completes re-establishes a fully known state, after
which valid sizes are admitted again.

### Capabilities and platform restrictions

`sessionWindowCapabilities`, and the window host's `hostWindowCapabilities`,
describe what windows cannot perform or report on the session's backend, each
with a reason, as `backendWindowCapabilities` defines:

| Backend | Cannot perform | Cannot report |
|---|---|---|
| X11, Cocoa | — | — |
| Wayland | `SetPositionOperation`: no global window position; `FocusOperation`: only the compositor moves input focus; `BorderlessOperation`: no global window position to place over a monitor | `PlacementReport`: no global window position; `IconifiedReport`: no reliable iconified state |

No session selects Wayland. Its description keeps its restrictions explicit
rather than emulated, and the CPU examples model it through the seam. An
unperformable operation is `Unsupported`. An unreportable attribute is always
`Unavailable`: it is not queried, and its callback records nothing, so no
position, iconified state, or other value is fabricated. A query reporting
`GLFW_FEATURE_UNAVAILABLE` is `Unavailable` under the
[observation contract](#observations) as before.

Where a control is performable, the platform still decides its result. Focus is
a request a window manager or compositor may decline, and attention may be a
flash or a bounce. An X11 window manager applies size, position, visibility,
and state asynchronously, so the post-call sample may not yet show them; a later
observation will. Cocoa's content size limits bound only the user's resizing,
so a programmatic resize there is not clamped. A hidden window may ignore
minimize or maximize, and the Cocoa backend shows a window it is asked to
focus. The observations report what
happened.

### Mode transitions

Each window carries a private, owner-internal mode transition marker. A mode
transition sets it for its interval, and the seam's private
`seamSetModeTransition` sets it in the CPU examples; no public command does.
While it is set, every control is `ControlRejected ModeTransitionInProgress`
with no native call, and observation and close commands are unaffected. A
control never changes the saved windowed placement. See
[Window modes](#window-modes).

## Window modes

`Hetoimasia.GLFW.Mode` and `setWindowModeCommand` move an existing window
between windowed presentation, borderless placement over a selected monitor's
work area, and fullscreen on a selected monitor. The model is the private
`Hetoimasia.GLFW.Internal.Mode`, which is pure, and the window model's
`transitionWindow`, which executes a request on the owner thread; the session
holds the monitor claims. None of it assumes a primary window or a primary
monitor at the desktop origin.

### Requests

A `ModeRequest` is a `WindowMode` and a `ModeFallback`:

| Value | Built with | Meaning |
|---|---|---|
| `WindowMode` | `windowedMode` | Decorated, at the window's saved windowed placement |
| | `borderlessMode monitor` | Undecorated, placed over the monitor's work area, on no monitor |
| | `fullscreenMode monitor preference` | On the monitor, at a video mode |
| `VideoModePreference` | `currentVideoMode` | The monitor's current mode and refresh rate |
| | `exactVideoMode extent refresh` | A mode of exactly that size, and of that refresh rate if one is given, which the monitor reports |
| `ModeFallback` | `noModeFallback` | Settle with the failure |
| | `windowedFallback attempts` | After a recognized failure, return to windowed presentation at a reachable placement, at most `attempts` times, `1 .. maximumFallbackAttempts` (4) |
| `StartupMode` | `startupMode request requirement` | A request a window transitions to during creation, `ModeRequired` or `ModeOptional` |

None exports a constructor, and neither does the `ModeRecord` or the
`SavedPlacement` a window observation carries, so a client can neither build a
request that skips validation nor set a saved placement. Every request is
validated when it executes, against the window and the monitors reported then.

### Owner, thread, and the transition interval

A request executes at an owner boundary on the session's owner thread, from the
host's port, the window's own port, or `performWindowCommand`, like a control.
In order:

1. Pending callback captures are reconciled. A window whose close protocol has
   begun is `WindowIsClosing`, and an ended one `WindowAlreadyEnded`.
2. A window whose mode transition marker is set refuses with
   `ModeRejected TransitionAlreadyInProgress`.
3. The request's fallback budget and video mode preference are checked.
4. The marker is set, and stays set until the transition settles.
5. The monitor inventory is refreshed, so no decision uses a monitor a
   disconnection has since ended, and the window is sampled, and its applied
   mode and monitor claims are reconciled with the sample.
6. An inert request settles at once as `ModeInert`.
7. Otherwise the target is attempted under `Hetoimasia.Foundation.Recovery`'s
   `recover`, with a budget of one attempt plus the fallback's attempts; see
   [Recovery and fallback](#recovery-and-fallback).
8. The window is sampled again, the request and its outcome are recorded in
   the window's mode record, a new revision is published, and the command
   settles as `Transitioned`, naming that revision.

A request refused before any native call with no fallback to take, or refused
as `MonitorBusy`, which no fallback answers, settles as
`Rejected (ModeRejected window rejection)`, and a target the platform cannot
perform with no fallback as `Unsupported` with `BorderlessOperation` or
`FullscreenOperation`; neither is recorded.

The transition interval is steps 4 through 8, on the owner thread. Nothing else
executes a command inside it: the owner executes one command at a time, and
callbacks only record. The marker therefore guards owner work re-entered from
inside a native step. The CPU examples drive exactly that from a scripted step:
an ordinary control there is `ModeTransitionInProgress`, another mode request
`TransitionAlreadyInProgress`, and a command for another window is served; once
the transition settles, the window's controls are eligible again under its new
presentation.

A native call that raises instead of returning, a callback fault rethrown at a
boundary, a native failure a monitor refresh raises, and cancellation propagate,
and the command settles as `Interrupted`.

### Validation

Before any native call, a transition or one of its attempts refuses with a
typed `ModeRejection`:

| Refused when | `ModeRejection` |
|---|---|
| The marker is set | `TransitionAlreadyInProgress` |
| The fallback budget is outside `1 .. 4` | `FallbackAttemptsRejected` |
| A preferred width, height, or refresh rate is outside `1 .. 2147483647` | `VideoModeRejected` |
| The selected monitor's identity has ended, re-resolved immediately before use | `ModeMonitorDisconnected` |
| Another window claims the fullscreen monitor | `MonitorBusy` |
| The monitor does not report the preferred video mode | `VideoModeUnavailable` |
| The monitor's work area is unavailable or empty | `WorkAreaUnavailable` |
| A placement coordinate is outside the native `int` range, or a dimension outside `1 .. 2147483647` | `PlacementUnrepresentable` |
| There is no saved placement, or no current monitor with a nonempty work area | `NoReachablePlacement` |
| The preserved windowed constraints do not admit the windowed placement's size, bounds and aspect ratio alike | `PlacementExcluded` |
| A borderless or fullscreen entry, or a windowed return or fallback, while a partial constraint update left the preserved windowed constraints indeterminate: no placement is made without proving the constraints admit it, and no window leaves windowed presentation it could not validly return to | `WindowedConstraintsIndeterminate` |

The monitor is re-resolved through the inventory's own resolution, and a
fullscreen step receives the pointer that resolution's enumeration returned in
the same boundary. Negative desktop coordinates are valid. A fullscreen monitor
is reserved last, after every other check has passed.

### Plans and native steps

| Target | Steps, in order |
|---|---|
| Windowed | `DecorationStep True` (`glfwSetWindowAttrib` `GLFW_DECORATED`); `PlacementStep` (`glfwSetWindowMonitor` with no monitor, at the placement); then, when the native constraints do not follow the preserved windowed set, `SizeLimitsStep` and `AspectRatioStep` restoring it, or the two clearing steps when it has none |
| Borderless | `ClearSizeLimitsStep` and `ClearAspectRatioStep` (`GLFW_DONT_CARE`) unless there is nothing to suspend; `DecorationStep False`; `PlacementStep` at the work area's origin and size |
| Fullscreen | `MonitorStep` (`glfwSetWindowMonitor` on the monitor at the selected mode's size, and its refresh rate or `GLFW_DONT_CARE`) |

Decoration is set before placement because a platform may keep a window's frame
and change its content area when decoration changes. GLFW stores decoration set
on a fullscreen window and applies it when the window leaves the monitor, and
it ignores size limits while a window is on a monitor, so a fullscreen plan
leaves them installed. Each step is bracketed by the error capture and the plan
stops at the first step that reports an error, which settles the attempt as
`StoppedPartway` naming the steps that returned, the step that reported, the
steps not attempted, and the copied reports. Nothing is rolled back.

### Saved placement and inert requests

A window's saved placement is its windowed content position and logical size:

- seeded from the window's initial observation, before any startup transition;
- cached from the observed placement when a transition leaves an applied
  windowed presentation — the geometry the attempt departs from, retained
  whether the attempt's native steps all return, one reports partway, or the
  attempt is interrupted after a native step;
- never overwritten by a return to windowed, a change between borderless and
  fullscreen, a failed attempt's target placement, or a fallback's derived
  placement.

A request is inert only when it equals the recorded request completely — the
monitor identity and the video mode preference included — its last outcome
settled cleanly at the target, and the applied mode reconciled in step 5 against
the refreshed inventory still matches it: windowed with its constraints applied,
borderless exactly over that monitor's work area, or fullscreen on that monitor
at the observed size the preference selects there, with the monitor's current
video mode that size and, when the preference names one, that refresh rate. An inert request makes no
native call, so it never restores stale geometry over a window the user moved.
A request after a disconnect, a failure, or a fallback is never inert.

### Applied mode and observations

Every window sample now also reads the decoration GLFW holds for the window
and the monitor GLFW reports a fullscreen window on. `observedDecorated` and
`observedFullscreenMonitor` publish them; the monitor pointer is only compared
with the inventory's current connections, never refreshed there, so a monitor
no current identity names, or one whose change the callback captured but no
refresh folded, is `Unavailable`.

The applied mode is re-derived at every full sample: a synchronization, a
control's post-call sample, and a transition's samples. Between samples, a
position callback that moves a window applied borderless re-derives which
monitor's work area it is over, from its latest sampled decoration and
fullscreen monitor. A window manager that converges later is therefore
reflected, and eligibility follows it.

`observedMode` is the window's `ModeRecord`: `modeRequested` and `modeFallback`,
the last request that executed; `modeApplied`, an `AppliedMode`; the
`modeSavedPlacement`; and `modeLastOutcome`. The applied mode is derived from
the sample and never copied from a request:

| Sampled | `AppliedMode` |
|---|---|
| A fullscreen monitor | `AppliedFullscreen monitor` |
| No fullscreen monitor, decorated | `AppliedWindowed` |
| No fullscreen monitor, undecorated, content origin inside a current monitor's work area | `AppliedBorderless monitor`, the first such monitor |
| Anything else, or a sample that reported errors | `AppliedIndeterminate` |

A `Transitioned` settlement's `PostCallRevision` names the revision its final
sample published, which carries the applied mode and geometry actually sampled
then. That records the boundary, not a window manager's eventual
acknowledgement: an X11 window manager may apply placement later, and a later
observation reports it. A final sample that reports errors is
`PostCallSampleFailed`; the record's change is still published, without a
sample. Snapshots keep only their latest value, so a client that must inspect the
named revision itself reads the snapshot on the owner thread before any later
boundary, as the native examples do.

Minimize, temporary focus loss, and a zero framebuffer extent during or after a
transition are ordinary observations, not failures.

### Recovery and fallback

Each attempt is one complete owned operation under `recover`. The target attempt
plans, reserves, runs its steps, and samples; a `windowedFallback` attempt does
the same for a windowed return at a reachable placement, from whatever state the
previous attempt left, reconciled by its sample. An attempt that does not
complete fails with a `ModeAttemptFailure`, which the classifier recognizes — and
answers with the windowed fallback, while the budget lasts — when it is a refusal
other than `MonitorBusy` or `TransitionAlreadyInProgress`, an unsupported target,
or a stopped step. Every other failure propagates.

The reachable placement is the documented deterministic policy: the saved
placement as it is when its content origin lies inside a current monitor's work
area; otherwise its size, centred — clamped to the work area's origin when larger
— in the work area of the monitor the platform designates primary, or of the
first enumerated monitor with a nonempty work area when none is. With no saved
placement or no such monitor, including an empty or inconsistent inventory, no
placement is reachable. The derived placement is never saved.

An attempt's cleanup restores the preserved windowed constraints of a window the
attempt left windowed while its native constraints were suspended or
indeterminate, and only when that attempt made a native step itself — so a
windowed return that decorated the window but failed to place it still restores
them, while an attempt refused before any native call runs no cleanup call,
whatever state an earlier transition left. A restoration call that reports an error fails the cleanup, and,
as the recovery contract requires, a failure carrying cleanup evidence is never
retried: the transition settles as `ModeRecoveryStopped`, with every attempt and
the cleanup's reports, and no further native call is made. A cleanup that raises
instead of returning, or a cleanup failure beside a primary failure that is not a
mode attempt's, is not representable as data: it propagates with its evidence,
and the command settles as `Interrupted`.

| `ModeOutcome` | Meaning |
|---|---|
| `ModeInert` | The request matched the applied mode; no native call |
| `ModeApplied by steps earlier` | Every step of the `TargetAttempt` or `WindowedFallbackAttempt` returned; `earlier` lists the attempts that failed before it |
| `ModeFailed attempts` | No attempt completed: no fallback, or the budget was exhausted |
| `ModeRecoveryStopped attempts reports` | An attempt's constraint restoration failed, so recovery stopped |

A request through a command is optional: exhaustion is recorded and settled as
data, and the application keeps running. An optional startup mode refused before
any native call, or whose target the platform cannot perform, with no fallback,
creates the window and records the refusal as a failed target attempt. A `ModeRequired` startup mode follows
the required-service policy instead: exhaustion, an unrecognized failure, or a
cleanup failure propagates the failure with its context and recovery history,
and the window's creation rolls back.

After the owner loop refreshes the monitor inventory, it reconciles every window
that is not closing. A window whose recovery obligation names an ended monitor
identity takes its recorded windowed fallback at once, with no further command,
attempting it at most its configured number of times, and its outcome is
recorded; with no fallback it is only resampled, once — that resample answers
the obligation, so later turns do not sample the window again. The obligation is the monitor
identity the last settled request's own sample established the applied mode on —
fullscreen or borderless — and it survives every ordinary observation: GLFW
itself takes a fullscreen window off a disconnected monitor before the monitor
callback's refresh ends the identity, so a synchronization, an observation
command, or a control's post-call sample taken anywhere between the native
disconnect and the reconciliation reports the platform's truth — windowed at the
desktop origin, or indeterminate for a borderless window whose monitor's work
area is gone — without erasing the unresolved recovery. A recovery that settles,
applied or exhausted, is owed no longer; a later request that settles supersedes
it, while a request refused before any native call leaves it pending. A window
whose applied mode is indeterminate without an ended obligation is resampled. If
no placement is reachable the fallback reports exhaustion and the saved
placement is preserved.

A borderless window may legitimately be moved between two connected monitors —
by the user, or by a window manager's late placement — and its observations
follow it: a move callback or a full sample re-derives the applied mode as
borderless over the monitor whose work area now contains its content origin.
Its recovery obligation follows that move too, but only at the reconciliation
after a monitor refresh, and only when that refreshed inventory finds both the
monitor the recovery was owed to and the one the window now stands on live. The
reconciliation that confirms the move records the new obligation and publishes
the record, so disconnecting the window's current monitor afterwards triggers
the configured fallback, or the single answering resample without one, while
disconnecting the monitor it left does not: the window keeps its borderless
presentation on its connected monitor with no fallback and no setter. That
judgment tells legitimate movement apart from an observation made after a
disconnect: a move observed after a monitor's native disconnect and before the
refresh that ends its identity derives against the inventory the refresh has
not yet corrected, so it never re-points the obligation to an ended monitor,
and the recovery owed to that monitor still runs. An observation that derives
indeterminate — over no live work area — or windowed never re-points or clears
the obligation, and a fullscreen window's obligation stays on the monitor its
settlement established. A request that settles afterwards replaces a followed
obligation as it replaces any other.

### Fullscreen claims

The session holds at most one claim per monitor identity, recording the claiming
window and whether the claim is reserved, held, or uncertain:

- a fullscreen attempt reserves its monitor after every other check and before
  its first native call; a monitor another window claims — reserved, held, or
  uncertain — is `MonitorBusy`, and nothing is called;
- after every full sample of a window — a synchronization, a control's
  post-call sample, or a transition's sample — its claims are reconciled with its observed
  fullscreen monitor: that monitor is held and the window's other claims are
  released, because departure from them is confirmed or their reservation is
  proven unused; no fullscreen monitor releases them all; an unavailable report
  makes them all uncertain;
- switching monitors therefore reserves the destination first, keeps the source
  until the window is observed off it, and after a failed switch keeps whichever
  claim is still observed, releasing only a destination observed unused;
- iconifying a fullscreen window changes no claim;
- an attempt interrupted by anything other than its own failure — a native call
  that raises, a callback fault, or cancellation — releases a reservation it made
  before any native step as proven unused; after a native step it makes every
  claim of the window uncertain and its applied mode indeterminate, so the owner
  loop's mode reconciliation resamples it and releases what the sample proves
  unused; that protection is in place before the attempt plans, and a
  reservation commits together with the attempt's record of it, so a cancellation
  arriving at any point after the reservation, before the first native step
  included, releases it;
- a claim on an ended identity is dropped by every inventory refresh and
  resolution — `synchronizeMonitors`, `resolveMonitor`, the owner loop's monitor
  step — including one that commits and then rethrows a monitor callback fault,
  and whenever claims are consulted, so a disconnect releases it at once
  and the claims never outnumber the current monitors;
- a window's release drops its claims only when its disposal succeeded; any other
  release leaves them uncertain, and an uncertain claim is never available to
  another window.

Borderless windows claim nothing.

### Ordinary controls by presentation

After a transition settles, which ordinary controls are attempted depends on the
applied presentation:

| Applied | Refused with `ControlIneligibleInMode` | Eligible where supported |
|---|---|---|
| Windowed | — | Every control, validated as before |
| Borderless | Size, position, constraints, maximize | Title, show, hide, focus, attention, minimize, restore |
| Fullscreen | Size, position, constraints, show, hide, maximize | Title, focus, attention, minimize, restore |
| Indeterminate | Everything above as `ControlModeIndeterminate` | Title, focus, attention, minimize, restore |

A refused control makes no native call, so an ordinary resize never changes a
fullscreen monitor's video mode; geometry and video mode changes in borderless
or fullscreen presentation go through a mode request. Neither the requested mode
nor the previous presentation establishes eligibility: an indeterminate window
becomes eligible again once a later sample establishes its presentation.

### Windowed constraints

The window keeps its preserved windowed constraints apart from what the native
constraints currently hold. Only a windowed ordinary constraint update changes
the preserved set, under the controls' indeterminate-state rule. A borderless
entry suspends the native limits and aspect ratio for its own geometry, and a
windowed return restores the preserved set after placing the window, validated
against the placement first. While a suspension or restoration is incomplete,
sizes are refused as indeterminate, and a failed restoration is never reported as
a restored configuration: its steps and reports are the outcome, and a later
complete restoration or constraint update re-establishes known constraints.

### Platform restrictions

GLFW performs every transition on X11 and Cocoa. Wayland, which no session
selects, gives clients no global position, so `backendWindowCapabilities Wayland`
names `BorderlessOperation` unperformable: a borderless request settles as
`Unsupported`, or takes its configured windowed fallback, and is never reported
as fullscreen. On Cocoa and X11 alike, the platform decides what a request
achieves: a window manager may place a borderless window differently or later,
and the observations report what it did.

## Input feeds

`Hetoimasia.GLFW.Input` is the consumer's side of a window's ordered input. The
implementation and its full contract are the private
`Hetoimasia.GLFW.Internal.Input`; the window host creates one feed per window,
and the native callbacks that will produce into it arrive with GLFW-12. Until
then the only producer is the private one the CPU examples drive, which is the
same admission, reset, warning, and resumption code a native producer will call.

### Ownership and capabilities

A feed belongs to its window's owner, which creates it, produces into it,
attempts its overflow warning, resumes it, and closes it. Its one logical
consumer receives an `InputReader` — `readInput`, `awaitInput`,
`acknowledgeReset`, and `inputStatistics` — and the application an
`InputControl` — `enableInput` and `suspendInput` — both through the window's
`WindowClient`. Neither exposes the channel, its endpoints, the feed's state, or
production. Copies of a reader are the same consumer: they observe one reset and
one acknowledgement. Concurrent handlers over one feed need the application's
own coordination.

### Events and epochs

A delivered `InputEvent` carries its window, its `InputEpoch`, and one payload:
a key transition with its key code and scancode, a Unicode character, a button
transition, scroll offsets on both axes, or a focus transition. Epochs start at
one, advance by one per reset, and never wrap. A button transition carries the
cursor position and modifiers captured when it was produced — the producer's
latest cursor sample, which coalesces — so later cursor motion does not move a
click already produced. Scroll, text, key and button transitions, and focus
history are never coalesced. Each event is prepared to normal form in the
producer's `IO` before admission; no transaction here evaluates a payload, makes
a native call, logs, or runs a handler.

### Phases and gates

| Phase | Reads answer | Production | Leaves by |
|---|---|---|---|
| `InputRunning` | the next event, or `InputEmpty` | admitted through the gates below | overflow or suspension: `InputResetPending`; closure |
| `InputResetPending` | `InputResetRequired token`, until acknowledged | suppressed and counted | acknowledgement: `InputResetAcknowledged`; closure |
| `InputResetAcknowledged` | `InputPaused`; a wait keeps waiting | suppressed and counted | owner resumption into the reserved epoch: `InputRunning`; closure |
| `InputFeedClosed` | `InputClosed`, at once | `ProductionClosed` | never |

The phase is independent of the application's admission and of focus.
Admission starts `AwaitingReadiness`: input produced then is gated, and
`suspendInput` before readiness changes nothing. `enableInput` opens it. While
running, ordinary input is admitted only with admission enabled and the window
focused, and is otherwise counted as gated. A focus transition is admitted
whenever admission is enabled, so the focus loss that closes the focus gate is
itself delivered; while a reset is in progress a focus transition still updates
the gate and is counted as suppressed.

### Held state

The producer keeps a held-state baseline over the native key domain
`0 .. keyDomainLast` and button domain `0 .. buttonDomainLast`, never indexed by
scancode. Only an admitted press establishes held state. A repeat or release of
anything not held — a key outside the domain included — is suppressed as
unpaired: a release never invents a press, and a repeat never becomes one. An
admitted focus loss, every reset, and closure clear the baseline, so each epoch
begins with nothing held and a key still down from before a reset produces
nothing until it is pressed again. The consumer clears its own held keys,
buttons, and gestures when it reads a focus loss, before acknowledging a reset,
and at closure.

### The reset

An overflow of a running generation — the channel full when an event, a focus
transition included, is admitted, or native staging full when an ordered
callback cannot be recorded — commits one transaction that aborts the
channel, records the backlog it discarded from the channel's depth counter apart
from the one overflowing event never admitted, reserves the next epoch, clears
the held baseline, drops the aborted channel, and installs a reset with reason
`InputOverflowed` and an opaque token bound to the feed and that epoch. Staging
loss is checked before any captured prefix is published, so that prefix is
never replayed as if the gap happened after it. The foundation channel's own
statistics keep their meanings; staging's lost count is exact and is not
reported as channel telemetry.

`suspendInput` after readiness, while running, makes the same transition with
reason `AdmissionSuspended` and no unadmitted event. During a reset,
`enableInput` and `suspendInput` change only the application gate: they neither
replace the token nor advance the epoch, and never erase an overflow warning the
episode owes. Production during the reset allocates nothing, advances nothing,
replaces nothing, and owes no further warning; it only adds to counters.

Events dequeued before the reset's transaction are in flight. The consumer
finishes or abandons their handlers, clears its derived state, and acknowledges
the exact token; the feed undoes nothing and replays nothing. Reading the token
neither consumes nor acknowledges it, so a stalled or cancelled consumer leaves
the feed paused and closable, with no timeout that resumes it.

`acknowledgeReset` never retries, needs no command capacity, and allocates and
runs nothing. It answers, in order: `Left ForeignResetToken` for another feed's
token, whatever this feed's state; `AcknowledgementClosed` once the feed has
closed, even for the pending token; `StaleAcknowledgement` for an older reset's
token; `Acknowledged` for the pending token; and `AlreadyAcknowledged`, changing
nothing, for a reset already acknowledged or resumed.

### The overflow warning

An overflow episode owes one structured `Warning`, message
`Input overflowed; the feed was reset`, under the `glfw.input` component with
`window`, `epoch`, `discarded`, and `unadmitted` fields. The owner claims and
writes it with the private `attemptOverflowWarning` at a safe owner boundary,
outside callbacks, transactions, and release, through a logger it injects. The
obligation lives in the episode, apart from the queue, so an early
acknowledgement or further production cannot lose it. A sink failure propagates
to the caller, as every logging failure does, and a cancellation propagates as
itself; the episode records `WarningFailed` or `WarningInterrupted`, and the sink
is not tried again. A closed feed claims nothing, so a warning shutdown prevented
stays `WarningOwed` in the final statistics. A suspension owes no warning.

### Resumption and closure

The owner's private `resumeInput` allocates one fresh channel in `IO` and
installs it in one transaction only if the same reset is still acknowledged, no
warning is owed or in progress, the feed is open, admission is enabled, and the
window is focused; that transaction makes the reserved epoch running. Otherwise
the candidate is never published. The window's close protocol and host
quiescence close the feed, so an open feed belongs to a live window and host, and
a closure committed before the install always wins.

Closure is idempotent, finite, and never retries. It aborts a running channel,
counting its discards apart from reset discards, clears the held baseline, and
ends every read and wait at once — even during a reset, without first delivering
the obsolete reset, and without awaiting any acknowledgement. The phase, epoch,
counters, and last-reset summary then stay as they were, apart from an attempt
already in progress recording how it ended. Statistics keep only that summary and
cumulative counts, never a history of events, epochs, or channels.

## The window host and owner loop

`Hetoimasia.Runtime.GLFW`, in the public `runtime-glfw` sublibrary, which
re-exports the private `runtime-glfw-core` implementation, composes a
session, its windows, and their command bookkeeping with the runtime's
[application lifecycle](resources.md#the-application-runner). It follows the
[module authoring guide](logging.md#module-authoring-guide): it takes no logger
of its own. The owner loop writes the input overflow warning through the
`Logger` the application injects on `LoopHooks`, under `glfw.input`, at a safe
boundary after callbacks have been reconciled. Configuration rejection is
raised under `glfw.runtime` and `construct window host`; native failures under
GLFW's own operations; supervised failures as the runtime delivers them. The
runner makes the one terminal report.

### Construction and ownership

A `WindowHost` is an application dependency, built by `allocWindowHost` as a
`Scoped` value before supervision is entered, on the process main thread. It
validates its `HostConfig` first — both budgets at least one, an idle wait above
zero and at most 60 seconds, so a NaN or infinite wait is refused, a
live-window limit of at least one and at least the number of configured windows,
and an input capacity between one and the channel's maximum —
then enters the session, allocates a
[scoped collection](resources.md#scoped-resource-collections) with that limit,
creates the host's command port, and creates each configured window in order as
a collection member with its own port and its own input feed of
`hostInputCapacity`, focused if its initial observation observed focus. A failure at any stage releases what the
earlier stages acquired through ordinary scoped release, before any worker
exists. The host is never a service the startup callback returns: startup
receives it among the dependencies and hands workers only client capabilities —
`hostCommandPort`, a window's `WindowClient` with its input reader and admission
control, the monitor inventory's reader, and `hostActivity` — transferring no
native ownership. At registration the host attaches the window's input feed so
owner-boundary callbacks publish into it. `allocWindowHostIn` builds
the same host over a session scope the caller supplies, such as a test seam's or
a borrowed session; the host then owns the session only if that scope does.

`WindowHost` is exported without its constructor or fields. No session,
collection, member, command host, native handle, executor, or release authority
can be taken from it. The host holds its windows only through the collection:
`withHostWindow` lends one to an owner-thread callback it must not escape, and
the host's owner operations refuse other threads.

### Dynamic windows

The host's windows are created and closed while the application runs, in any
order, with no primary window. The collection owns every window until it is
retired or the host's scope ends, so a window's lifetime never escapes the host.

**Creation.** A `createWindowCommand` submitted through `hostCommandPort` — the
one port with creation authority — is executed by the owner loop. Before any
native effect it checks the configuration (`WindowConfigInvalid`), the live-window
limit (`WindowCapacityReached`, a typed rejection rather than a wait), and whether
a release failure has poisoned creation (`WindowCreationPoisoned`). The window is
then acquired through the window's own `Assembly` as a collection member, and,
with nothing interruptible in between, registered with the host beside a port of
its own. A native failure during construction is `WindowCreationFailed` once the
construction has rolled back exactly what it acquired: nothing is registered and
no capacity is consumed. A construction failure carrying retained cleanup
evidence — a rollback whose own release failed — is never downgraded to that
rejection: the original construction failure propagates unchanged as the host's
primary failure, the command's ticket settles as `Interrupted`, the owner loop
stops at that failure, and commands still queued settle through the quiescence
contract. The collection keeps the rollback failure as evidence through its
final exit, where the propagated primary retains it exactly once, and the latch
poisons any later creation. Anything else raised during construction — a
cancellation, a callback fault, any other exception — interrupts the command and
propagates with its cleanup evidence on the host's failure path. On success the ticket settles as
`WindowCreated` and hands over the window's `WindowClient`, as
[the creation handoff](#the-creation-handoff) describes.

A dropped or unawaited creation ticket neither destroys nor relinquishes its
window. `hostWindowIdentities` enumerates every window the host holds, in
registration order and bounded by the limit, and `hostWindowClient` returns the
capabilities of any of them; the host disposes every remaining window at
shutdown. Identities are never reissued within a session, so a retired window's
identity never names a later window.

**The close protocol.** A `closeWindowCommand` executed by the loop, through the
host's port or the window's own, `closeHostWindow` on the owner thread, and
`honourHostCloseRequest` for a surfaced close request that is still its window's
latest all begin the same protocol:

1. the window's closing observation is prepared; nothing has changed yet, so a
   cancellation here leaves the window open with its port admitting;
2. in one transaction, the window is marked closing, its port's admission
   closes, every command still queued there settles as `NotExecuted`, and its
   observations publish the `WindowClosing` phase; that transaction and the
   owner's record of the new observation run masked with nothing interruptible
   between them, so no cancellation can close the port without publishing the
   phase, or publish the phase without closing the port;
3. once no owner-thread borrow is in progress, the window is retired through the
   collection: callbacks detached, the native window destroyed, storage freed,
   and the terminal phase published before its snapshot closes.

A close command settles as `WindowCloseBegun` once step 2 has committed; its disposal is
reported by the window's observations, never by the ticket, because closed
admission alone proves nothing about native destruction. Beginning the protocol
again answers `CloseAlreadyStarted`, or `WindowIsClosing` for a command, and a
window the host no longer holds answers `CloseNotServed` or `WindowNotServed`.
Closing a window stops neither the session, the loop, nor any other window, and
closing the last window creates nothing and ends nothing.

Retirement never waits. While `withHostWindow` lends the closing window, the
collection answers the retirement as in use; while it lends another window, the
host does not attempt it. Either way the window stays registered, still
occupying its capacity, and every turn retries its retirement after native event
processing, when no borrow is in progress. Retaining a client port is not a
borrow and does not delay retirement. A retirement whose release fails is not
retried, at shutdown or ever: the window is forgotten with its
`WindowDisposalFailed` or `WindowReleaseUncertain` phase, and the collection
latches the failure, poisoning creation and keeping the failure as evidence for
its final exit. Unlike a construction rollback's failure — which propagates as
the host's primary failure and stops the loop — a retirement failure stays
non-fatal: the window was already built and serving when its release failed, so
the failure is latched and reported rather than thrown into the turn that
observed it.

**Retained handles.** Once a window has been retired, its port answers
`SubmitClosed`, and `WaitClosed` to a waiting submission; `withHostWindow`
answers `WindowEnded`; `closeHostWindow` answers `CloseNotServed`; a command for
it through the host's port is `WindowNotServed`; and its observation reader keeps
the terminal observation, then `EndOfStream`. None of these touches native state.

**Bookkeeping.** The host keeps one registry entry, one port, and at most one
surfaced close request per window it holds, plus one dispatch cursor.
`hostBookkeeping` reads those counts, the collection's live members, the
completion cells held across every port, and the windows borrowed, on the owner
thread. Every count is proportional to the live windows, never to how many were
ever created.

### The owner turn

`runOwnerLoop` runs on the session's owner thread — the application's action
calls it on the process main thread — and refuses any other thread with
`NotSessionOwner` before anything runs. Every turn performs, in order:

1. `checkRuntime`;
2. native event processing: `glfwPollEvents`, or on an idle turn
   `glfwWaitEventsTimeout` with the configured bound;
3. reconciliation at owner boundaries: the monitor inventory, refreshed only
   when its callback captured a change, then the retirement of every closing
   window no borrow defers, then every window's captured callbacks, collecting
   the close requests not yet surfaced for windows that are not closing, then
   each open feed's overflow warning claim and resumption;
4. `checkRuntime`;
5. command work: at most `hostCommandBudget` queued commands claimed, executed,
   and settled, across every port, then warning claim and resumption again,
   because a setter can invoke callbacks;
6. `checkRuntime`;
7. application event work: at most `hostEventBudget` calls of `loopEvent` that
   dispatched something, ending at the first that found nothing ready;
8. `checkRuntime`;
9. the application's update opportunity, `loopUpdate`, which receives the turn's
   `Turn` summary and answers `Continue` or `Finish`;
10. `checkRuntime`, before a `Finish` result is returned or the next turn begins.

A supervised failure latched at any point is rethrown by the next check, so no
dispatch begins once a check has seen it. A native failure, a callback fault
rethrown at reconciliation, a command's rethrown interruption, or a hook's
failure also ends the loop and propagates.

### Budgets

Budgets count attempted dispatches, not time. A rejected command — addressed to
a window the host does not serve, one that has ended, one outside its port's
scope, or a refused creation — costs its attempt exactly as a performed one
does. At most `max hostCommandBudget hostEventBudget`
dispatch attempts separate two consecutive checks, however continuously the
command queues and the application's event source are refilled. A budget does
not bound one native call or one event handler; long work belongs in a worker.

### Fair dispatch

Command work draws from several ports: the host's, and the port of every window
the host holds that is not closing. They are ordered with the host's port first
and then the windows' in registration order, and the host remembers the port
its last attempt served. Each attempt claims the oldest command of the first
port after that one, in cyclic order, that has a command queued. So:

- **FIFO within a port.** A port's commands run in the order their admissions
  committed. Nothing orders commands across ports.
- **One budget.** A turn attempts at most `hostCommandBudget` commands across all
  ports together, and a rejected attempt counts.
- **No starvation.** No port is attempted twice while another port with a
  command queued waits, however continuously the first is refilled.
- **A service bound.** Let `P` be the most ports dispatched from while a command
  waits, at most `1 + hostWindowLimit`, and `B` the budget. Each attempt on a
  port is followed by at most `P - 1` attempts on other ports before that port's
  next, so a command at position `k` of its port's queue when a turn's command
  work begins — the oldest is position one — is attempted within `⌈k · P / B⌉`
  turns' command work, counting that turn, assuming turns continue and every
  dispatch returns. The oldest command of every port with one queued is
  therefore attempted within `⌈P / B⌉` turns. A window created meanwhile takes
  its place behind the host's port, which the creation just served, so it never
  delays a port already waiting, and a closed window's port leaves the order.
  This is a bound in turns, not a wall-clock deadline, and it is separate from
  checkpoint reachability.

The scheduler's only state is the cursor, so its bookkeeping stays bounded
through creation, closure, and churn.

### Idle waits

A turn is idle when the turn before it attempted no command and dispatched no
application event, and no command is queued at its entry. Active turns poll.
Idle turns wait at most `hostIdleWait` seconds, so a checkpoint follows even when
no native input arrives. No wait is indefinite, a host with no windows waits on
each idle turn instead of spinning, and the bound is a latency rather than a
shutdown deadline.

A wait ends early when something wakes the owner: an
[admission](#admission) that committed, or a
[demand publication](#demand-slots). The turn that waited then goes on to its own
command work and its update opportunity, so a command admitted during the wait
is served by that same turn, subject to the budget and
[fair dispatch](#fair-dispatch), and a request published during it is there for
that turn's capture. A wake that arrives before the wait is entered ends the
wait it precedes, because the post outlives the call that made it; one that
arrives while the owner is consuming an earlier wake is seen by the next wait.
Wakes may be coalesced and may be spurious, and neither repeats a command's
execution or a capture: the queue and the slots are authoritative, and the wake
is only the hint that they changed. `hostIdleWait` remains the fallback bound
whatever happens to the wake — including after
[the wake path has degraded](#the-degradation-policy), when nothing is posted at
all and the bound alone keeps work moving.

Native waits are safe foreign calls, so background workers
run while the owner is inside one. `hostActivity` publishes the current turn and
whether its owner has begun its finite wait; the flag is set immediately before
the native call and cleared once it returns, so it signals a wait starting or in
progress rather than proving the call was entered.

### Demand slots

A worker that wants a turn — now, or by a deadline — says so through a
`DemandPublisher`: the application's, from `hostDemandPublisher`, or one
window's, from `clientDemandPublisher` on its `WindowClient`. `publishDemand`
combines the request into the slot, advances the slot's revision, and only then
wakes the owner, so the state that matters is authoritative before the hint that
announces it. The owner takes it with `captureHostDemand` or
`captureWindowDemand`, on its own thread.

There is one slot for the application and one per live window, created with the
window and closed in its closing transaction. There is never a slot per worker,
per request, or per deadline, so the notification state is bounded by the live
windows however many publishers there are and however often they publish.

- **Requests combine, they do not replace.** A `DemandRequest` states immediate
  demand, an absolute `Instant` deadline, or both, and requests combine as a
  monoid: immediate if any publisher asked for it, and the earliest deadline any
  of them requested. A later request can never postpone an earlier pending
  deadline, and one publisher's `noDemand` can never cancel another's request —
  it changes nothing and answers `NoDemandPublished`.
- **Capture is the acknowledgement.** `captureDemand` takes the pending request
  with its revision and clears exactly what it took, in one transaction. A
  publication that commits after that capture carries a newer revision and stays
  pending for the next one, so no acknowledgement of an older revision can erase
  a newer request and a continuously republishing worker cannot monopolize a
  turn: its republications coalesce into the one request the next capture takes.
- **Slots hold requests, not schedules.** An ongoing periodic schedule is the
  owner's own state, so a captured request never becomes permanent work. What
  the owner does with a captured request — including how it folds into the next
  wait — is the scheduled loop's, and is not part of this slice.
- **The same protection as an admission.** A cancellation before the publishing
  transaction commits publishes nothing. After it commits the request stays
  pending and its wake is owed uninterruptibly, even if the publisher never
  learns its own answer.
- **Closure is terminal.** A closed slot answers `DemandSlotClosed`, records
  nothing, and makes no native call, so a publisher retained after its window
  ended or its host quiesced is safe and can resurrect neither.

Deadlines are opaque `Instant` values in the publisher's own clock domain: this
package compares and stores them, reads no clock, and infers nothing about what
a deadline means.

### Close requests in the owner loop

A close request is captured by the window's own callbacks and reconciled into
its observation, as [Close requests](#close-requests) describes; the host adds no
second callback owner. After reconciliation, a request the host has not surfaced
before appears once in `turnCloseRequests`. The application decides:
`rejectHostCloseRequest` clears it while it is still that window's latest;
`honourHostCloseRequest` begins that window's
[close protocol](#dynamic-windows) while it is still the latest, answering
`CloseRequestSuperseded` otherwise; and leaving it latched is equally a decision.
A closing window's requests are not surfaced. The loop ends only when
`loopUpdate` answers `Finish`, so a close request — the last window's included —
ends neither the loop nor the runtime, and destroys nothing unless the
application honours it. The host supplies no default that finishes on, or
honours, a close request.

### Quiescence and shutdown order

`quiesceWindowHost` is the host's quiescence action for
[`runScopedApplicationWithQuiescence`](resources.md#quiescence), and
`runWindowApplication` is that runner with the action installed. In one finite,
non-retrying transaction it closes the admission of the host's port and of every
window's port, settles every command queued in any of them as `NotExecuted`,
closes every window's input feed, ending its reads even while a reset waits for
an acknowledgement, and closes the application's demand slot and every window's.
It destroys nothing, pumps nothing, waits on nothing, and repeating it changes
nothing. A window's close protocol closes that window's feed and its demand slot
in its closing transaction the same way.

Quiescence does not disable wake support: the session's capability stays usable
for the progress that still has to happen, and internal retirement keeps its own.
What closes is admission and publication, so a retained port or publisher
answers a typed rejection and makes no native call. A window whose creation was
claimed before quiescence and finishes after it is registered already closed —
its port, its feed, and its demand slot admit nothing, and the `WindowClient` its
ticket hands over revives none of them — while the window itself is still
disposed by the final exit. On every exit from the supervised region, the ordinary order is:

1. quiescence: every port's admission closes, queued callers settle as not
   executed, and every input feed closes;
2. supervision asks every live worker to stop and drains them, with every window
   still registered — closing ones included — live;
3. the dependency scope unwinds: the host closes every port's admission again, a
   no-op after quiescence; the collection's final exit releases each remaining
   window exactly once, newest registration first, keeping every cleanup failure
   — its latched ones included — under
   [the failure table](resources.md#the-failure-table); and then the session ends
   if the host owns it;
4. the terminal report, if the run failed, and the final flush.

A close queued behind quiescence settles as `NotExecuted`, and its window is
disposed once, by the final exit. A window whose earlier retirement failed is
not released again.

The runtime's two earlier orderings are unchanged: a fatal latch may request
worker stops before quiescence, and a worker whose managed startup is abandoned
or cancelled is drained before it. Quiescence neither precedes nor unblocks
either.

### What the owner and workers may wait on

No public owner-thread operation blocks on work only the owner turn can do. On
the owner thread, awaiting an unsettled ticket or capacity fails with
`OwnerThreadWouldWait`, and `runOwnerLoop` and `rejectHostCloseRequest` refuse
other threads. The owner may be starting or draining a worker instead of
turning, so a worker's startup and cleanup — rollback and finalizers included —
must not require a command's completion. A worker's acknowledged run action may
submit commands while the loop runs, composing its wait with its stop request:

```haskell
awaitOrStop ∷ StopToken → CompletionTicket → IO (Maybe Disposition)
awaitOrStop token ticket =
  atomically $
    (Just <$> (pollCompletion ticket >>= maybe retry pure))
      `orElse` (Nothing <$ awaitStopRequest token)
```

A worker never waits to publish demand: `publishDemand` records and answers
without blocking, whether the slot is open or closed.

These are obligations on application and worker code; the runtime's guarantee
is not broadened.

### CPU examples

The admission-wake, demand, and degradation examples (`--match "wake"`) drive
the production admission, publication, and notification code over the seam,
whose scripted platform counts an empty-event post as pending for the next
finite wait. Without sleeps they prove: a wake after each admission before,
during, and after the owner's wait, through both admission operations and both
port kinds; full and closed admission waking nothing; cancellation before a
commit admitting and waking nothing, and after one keeping the command, its
wake, and its single settlement, for both the immediate and the waiting
operation; publishers released together from one gate combining immediate demand and the
earliest deadline; twenty republications coalescing into one captured request; a
capture racing a publication in both orders, and a worker republishing
concurrently while the owner captures, every revision taken in order with what
fell between two captures coalesced; twenty rounds of a waiter cancelled exactly
as capacity frees, each leaving either no admission and no wake or an admitted
command with its own; a request demanding nothing and a closed
slot recording nothing; publication cancelled before and after its commit; an
expected platform failure degrading the session's path once, keeping every
ticket, and being skipped by a second host over the same session; two failures
overlapping inside their own posts degrading once and keeping one call's
evidence; the one
report written, filtered, and failed, each spending the attempt without
retrying or undoing the degradation; a lifetime violation staying a typed
failure with the command still admitted; and a retained port and publisher
answering a later session without a native call.

The host's own examples add, over whole applications: an idle turn's wait ended
by a worker's admitted command and served by that same turn; a wait ended by a
publication the same turn's update captures; a window's demand slot closed by its
close protocol and every slot by quiescence, with retained publishers rejected
afterwards; a creation claimed before quiescence registering a window whose port
and demand slot are already closed; the degradation warning written once through
the loop's injected logger while the finite idle bound continues; one
degradation and one warning shared by sequential hosts borrowing one session;
and a construction that rolls back lending nothing and waking nothing.

The host's CPU examples run whole applications over the test seam in
`glfw-tests`. The seam's native table scripts the poll and the finite
wait — recorded as `PollEvents` and `WaitEvents`, with `scriptPollEvents` and
`scriptWaitEvents` steps — and its private `seamQueueEvents` driver leaves
callback events, such as a close request, for the next poll or wait to deliver
from inside that call. They prove the turn order and the poll or wait choice,
the checks after saturated command and event batches, worker progress during a
wait, settlement through the loop, the owner-thread refusals, close-request
surfacing, a monitor change queued for the next poll refreshing the inventory
only on the turn that delivered it, quiescence, and the shutdown order on
startup failure, action return, failure, and cancellation, a
supervisor-detected failure, and an abandoned managed startup.

The dynamic window examples prove, over the same seam: the creation handoff —
prepared `WindowCreated` data, capabilities readable only after settlement and
after the initial observation, and a window port refused creation and other
windows; capacity and configuration rejections before any native call; a failed
construction rolled back with its native evidence and no consumed capacity; a
construction whose rollback's own release failed propagating its original
native failure as the host's primary failure — the rollback failure retained
exactly once as cleanup evidence, the failing command's ticket interrupted, the
command queued behind it settled as not executed, and the loop stopped before
that turn's update — with poisoning visible through that retained evidence; an
unawaited creation's window enumerable, live through the drain, and disposed at
shutdown; a cancellation delivered from another thread during construction
rolling it back with no registry entry and its capacity reclaimed, and one
pending across registration delivered before publication, leaving the window
registered and disposed; the middle of three
windows closed while the others observe and execute; close orders A-B-C and
C-A-B each disposing every window with callbacks detached before destruction;
retained ports, borrows, closes, and readers of a disposed window answering
typed terminal results with no native call; queued callers on a closing window
settled as not executed after its earlier commands ran; retirement deferred by a
borrow of the window and of another, with the closing phase and then the
disposal published, a slow reader receiving the disposal before `EndOfStream`; a
failed release latched as disposal failed, never retried, poisoning creation,
and primary at final exit, and retained beside a failing body's own failure;
bookkeeping bounded and identities never reissued across forty cycles of
creation and an honoured native close request; shutdown with a window closing
and closes racing it, every port closed before the drain and every window
released once after it; and fair dispatch with a replenished, partly rejected
port beside a waiting window port holding two commands and a host request,
through closure and creation, each command within its documented bound and
every turn within the budget. A host example closes one window while the other's
feed has a suspension reset pending: the closed window's reads end at once, the
other still requires its reset, and quiescence then ends it without an
acknowledgement.

### Input feed examples

The input feed examples in `glfw-tests` drive the feed model through
its private producer and through scripted native callbacks, with window
identities from a seam session and no GLFW.
Threads are coordinated with `MVar`s and STM; a wait is observed through
`orElse`. They prove: distinct, uncoalesced key, text, button, scroll, and focus
events tagged with window and epoch, from the private producer and from
scripted callbacks with cursor coalesced into the observation; gating before
readiness and while unfocused, no reset for pre-readiness disablement, and a
delivered focus loss that closes the focus gate; a click keeping its captured
position after later cursor motion; staging overflow setting the loss latch
while the buffer is full, beginning the same reset, and replaying no prefix;
a callback release synthesizing no press; one window's staging overflow leaving
another's feed running; focus loss and gain in native order, and a focus
transition that cannot be admitted starting the reset; focus loss clearing held
state; one stable token across twenty
thousand suppressed events with exact, non-wrapping counters and no channel,
epoch, or warning added; exact discard accounting apart from the unadmitted
event and delivered events; no old backlog after reset detection and no
new-epoch input before acknowledgement and resumption; foreign, duplicate,
stale, and closed acknowledgements; a consumer cancelled before acknowledging
leaving the feed paused and closable; closure during a pending or acknowledged
reset ending reads without the reset; resumption losing to a closure committed
after the candidate was allocated, publishing no channel; a key and button held
at a reset producing nothing in the new epoch until pressed again; two windows
overflowing independently; one warning per episode through the injected logger
blocking resumption until its attempt completes, a failing sink retained as
`WarningFailed` and never retried, and an attempt cancelled by shutdown retained
as `WarningInterrupted`, or left `WarningOwed` when shutdown came first; and, for
suspension, press → suspend → suppressed release → enable leaving no backlog or
held state and needing acknowledgement, resumption, and a fresh press,
acknowledgement before or after re-enabling, repeated toggles keeping one token
and epoch, suspension during an overflow reset keeping its token and warning
obligation, no warning for suspension alone, and closure winning every
suspension and resumption race while a suspension or focus loss leaves a
candidate unpublished.

## Window attachments

A graphics integration — a future surface and the work submitted through it —
depends on a window for longer than a borrow. The private
`Hetoimasia.GLFW.Internal.Attachment` module in the `model` sublibrary models
that dependency: which window an integration has attached to, where the
attachment is in its lifetime, what evidence retires it, and whether it still
vetoes the window's destruction. It is the LIFE-1 slice of
[the window and graphics lifetime design](window_graphics_lifetime_design.md)
(P-1, P-5, D-1, D-2, D-4).

**No public attachment exists yet.** No module under `packages/glfw/src/`
exports the model, an external client cannot import it, and no production
component uses it: the window host, its close protocol, retirement by borrow
count, and every public module behave exactly as before. The protected host
lifetime (LIFE-3) and the public attachment contract (LIFE-4) follow. The model
names no Vulkan, native, or GPU type, performs no native call, and owns no
thread; it is a pure state machine with bounded bookkeeping and one bounded
notice inbox.

### Ownership and trusted inputs

The host owns per-window registration and close state; the graphics integration
owns its dependent resources, their retirement work, and the evidence that none
can still use the window. The model does not establish its own premises; the
owning boundary supplies them and is responsible for them:

- the host identity is fresh, made from a `Unique` created for that host alone;
- the session identity is the session issuing the host's windows, and windows
  are registered in the order that session issued them;
- every operation taking the owner's authority runs on the owner thread. A pure
  transition cannot observe the executing OS thread, so the boundary checks it
  first, as window operations check theirs.

### Identities

An attachment identity binds four identities: the host, the session, the
`WindowId`, and an incarnation. A model issues incarnations from one, never
reissuing one, and its host identity is fresh, so together they name one
attachment in the process. Every operation carrying authority compares all four
against its target, and a mismatch in any is typed misuse that changes nothing:
a refused transition returns no model at all.

### Phases and transitions

| From | To | By |
|---|---|---|
| none | registering | attaching reserves an open, unoccupied window of this host and session |
| registering | active | construction succeeds; the only way a usable capability is represented |
| registering | retiring | detach, cancellation, the window beginning to close, or construction failing |
| active | retiring | detach, cancellation, or the window beginning to close |
| retiring | retired | the last missing retirement fact is recorded |

No other transition exists. Attaching to a window recorded as closing or ended,
to an unregistered window, to one already holding a live or retiring
attachment, with another host's identity, or with a window of another session is
refused before any incarnation is issued, so the boundary can refuse before any
acquisition effect. Retirement once begun is never undone: a construction that
succeeds afterwards publishes nothing, and its dependents stay registered for
retirement. Construction is tracked beside the phase, and while it is pending no
retirement fact is accepted, so a cancellation at any handoff — before
construction, after it created dependents but before publication, or after
publication — leaves no constructed dependent outside registration. A retired
attachment is removed, freeing the window's slot; attaching again yields a fresh
incarnation.

Failure evidence is stored beside the phase, never as one. A failed construction
records its original failure and its rollback outcome and moves the attachment
to retiring. A safe rollback establishes every retirement fact, explicitly
discharging obligations the construction never created, and retires the
attachment. An unsafe rollback records no fact: the attachment keeps its window
until each fact is certified. A failed disposal step is recorded without
establishing anything. The first failure is kept and later ones are counted;
cancellations are counted and establish nothing.

### Retirement facts

Three facts stay distinct: logical release (the application stops wanting a
frame), CPU-use retirement, and backend retirement. The model records the
latter two as four independent facts, each certifying an obligation that has
irrevocably ended:

| Fact | Certifies |
|---|---|
| CPU use retired | No retained capability or pending producer can submit another use |
| Submitted work ended | Work already submitted has completed |
| Presentation ended | Presentation obligations have ended |
| Dependents disposed | Dependent resources are disposed |

None is accepted before retirement begins, while further use is still possible.
An attachment is retired, and stops vetoing its window, only when all four are
recorded; the model reports which are missing. No single fact, elapsed time,
cancellation, body return, or failure stands in for another. A window with no
attachment veto is not thereby destroyable: destruction still requires the
host's close protocol and its ordinary CPU borrows.

### Acknowledgements

Attaching returns an acknowledgement bound to the new incarnation. It is the
integration's completion authority, taken with the target identity by every
attachment transition, and the two must name the same host, session, window, and
incarnation. It prevents accidental cross-window and cross-incarnation misuse;
it is not proof that a backend really finished, which the backend's own tested
contract supplies. A target resolves in order:

1. An acknowledgement naming another host, session, window, or incarnation is
   misuse.
2. A target of another host or session is misuse, as is an incarnation the model
   never issued.
3. If the window holds an attachment of another incarnation, the target was
   replaced, which is misuse. This identity mismatch takes precedence over
   terminal idempotence, so a late report never alters a replacement.
4. An absent target has retired, because an issued attachment leaves the
   bookkeeping only by retiring. Any report for it is accepted and changes
   nothing, and no entry is recreated.

Recording the same fact twice for a live incarnation is accepted and idempotent.

### The owner-thread rule and completion notices

Every operation that registers, closes, forgets, attaches, constructs, retires,
or removes takes the owner's authority value, which the model's creation
returns; another model's authority is misuse. Observation — an attachment's
status, a window's veto, and the counts — takes none.

Another thread never changes the model. It offers a completion notice to a
bounded inbox, which never waits and answers admitted, coalesced when an equal
notice is already pending, or rejected when the inbox holds its capacity of
distinct notices. An admitted notice stays pending until the owner takes the
inbox's notices and folds them, revalidating each exactly as a direct report,
so a notice queued for an attachment replaced before the fold is misuse and
never touches the replacement.

### Bookkeeping

The model holds one record per registered, not yet forgotten window — at most
the host's window limit — and at most one attachment per record. A window with
a live or retiring attachment cannot be forgotten. Stale identities are rejected
by comparing incarnations and local window numbers against the model's
counters, never by remembering them: a window numbered at or below the highest
registered with no record has ended. No set grows with the number of windows or
attachments ever made.

### Attachment model examples

The examples in `glfw-tests` (`--match "attachment"`) script pure transitions
over window identities from seam sessions, with no sleep. They prove every
refused attachment — closing, ended, unregistered, occupied, and retiring
windows, another host, another session, and another owner's authority — issuing
no incarnation; issue-order registration and the window limit; the transition
table, including closing during construction publishing nothing; the
acknowledgement of another window, of an earlier incarnation, of another host
or session, a replaced target, and an incarnation never issued, each changing
nothing; each retirement fact alone keeping the window vetoed and the full set
releasing it; cancellations and disposal failures releasing nothing while
keeping the first failure; a scripted owner whose render thread publishes CPU
retirement and submission completion through the inbox while presentation
stays owed and the window stays vetoed; duplicate completion idempotent before
and after retirement; failed construction with safe and with unsafe rollback;
cancellation at each handoff; two windows where only one can retire;
bookkeeping equal to the live count after five hundred attach-and-retire cycles
and forty window cycles; inbox admission, coalescing, capacity rejection, and
retention until taken; and a notice queued for a replaced attachment refused
when folded. The opacity examples compile an external client that imports the
model and is refused because its module belongs to a hidden private sublibrary.

## State

| State | Owner | Readers and writers | Thread | Lifetime | Reset or disposal |
|---|---|---|---|---|---|
| Guard occupancy and poison | The native library's table; process-wide in production | Entry claims it; the last release settles it | Any; atomic | The process | Vacant after a safe teardown; poisoned for the rest of the process otherwise |
| Error capture buckets | The session | The callback writes; owner operations and releases take | Callback: any; takes: owner | Construction until the callback is detached | Unread asynchronous reports become cleanup evidence |
| Callback storage | The session | Installed at entry; freed at teardown | Owner | Until detached | Freed after a safe detach; leaked when poisoned |
| Teardown safety flag | The session | Releases clear it; the guard release reads it | Owner | The session | Read once |
| Liveness | The session | Termination clears it; owner operations read it | Owner | The session | Never set again |
| Wake gate and admitted count | The session | Wake calls enter and leave; the first release closes and drains it | Any; STM | Construction until the first release | Closed and never reopened; a retained capability stays terminal |
| Wake path degradation | The session | The first expected platform failure of a notification degrades it; the owner's boundary claims and settles its one report | Any; STM | The session | Never healthy again; a later session has its own |
| Wake reports | The session's error capture | The callback writes on the wake call's OS thread; the call takes them | The wake call's OS thread | One wake call's native call | Removed when the call returns |
| Monitor capture latch | The session | The monitor callback writes; refreshes fold and clear it | Callback: inside owner calls; folds: owner | The session | Cleared by each committed refresh; a fault is taken when rethrown |
| Monitor identity counter | The session | Refreshes issue from it | Owner | The session | Never reissued |
| Monitor connections and current inventory | The session | Committed refreshes write them; resolution reads them | Owner | The session | Emptied when the inventory closes |
| Monitor inventory snapshot | The session | The owner publishes and closes; clients read | Publish: owner; read: any | While referenced | Closed first at teardown, holding the last descriptions; never reopened |
| Monitor callback storage | The session | Installed at entry; detached before termination; freed at teardown | Owner | Through the session's last native call | Freed after a safe teardown; leaked when poisoned |
| Window identity counter | The session | Window creation issues from it | Owner | The session | Never reissued |
| Native window | The window | Its parts create and destroy it; owner boundaries query it | Owner | The window's scope | Destroyed at release |
| Window callback storage | The window | Its parts allocate, attach, detach, and free it; GLFW invokes it | Owner | Through the window's final native use | Freed after a certain release; kept when uncertain |
| Capture latch | The window | Callbacks write; boundaries and release take | Callbacks: inside owner calls; takes: owner | The window | Emptied at each boundary |
| Input staging | The window | Input callbacks write; the owner boundary publishes or discards | Callbacks: inside owner calls; publish: owner | The window | Discarded on overflow or published, then emptied |
| Attached input feed | The window | The host attaches it; the owner boundary publishes into it | Owner | From attachment until the window ends | Closed with the window |
| Current observation and close counter | The window | Boundaries fold, then publish | Owner | The window | Final value retained in the closed snapshot |
| Observation snapshot | The window | The owner publishes and closes; clients read | Publish: owner; read: any | While referenced | Closed at release; never reopened |
| Window liveness | The window | Release clears it; every operation reads it | Owner; `windowEnded` any | The window | Never set again |
| Window constraint state | The window | Constraint updates write it; size and constraint validation read it | Owner | The window | Known and unconstrained at creation; indeterminate from an update's first call until the update completes |
| Mode transition marker | The window | A transition sets and clears it; controls and transitions read it | Owner | The window | Clear at creation; no public command sets it |
| Preserved windowed and native constraint states | The window | Windowed constraint updates write the preserved set; transitions suspend and restore the native constraints; size validation reads both | Owner | The window | Known, unconstrained, and followed at creation |
| Mode record | The window | Transitions, their samples, and mode reconciliation write it; observations publish it | Owner | The window | Seeded at creation; the final value retained in the closed snapshot |
| Monitor claims | The session | Fullscreen attempts reserve; samples settle; window release disposes | Owner | The session | Claims of ended identities dropped when consulted; at most one per current monitor |
| Release certainty | The window | Uncertain parts clear it; the storage and observation releases read it | Owner | The window | Read at release |
| Command channel | The command host | Ports admit; the executor claims; closure drains | Admit: any; claim and close: owner | While referenced | Closed by closure with its backlog settled; never reopened |
| Pending completion cells | The command host | Admission reserves; settlement and closure remove | Reserve: any; settle: owner | Admission until settlement | Removed at settlement |
| Active command count | The command host | Claims raise it; settlements lower it | Owner | The host | Zero whenever nothing is executing |
| Completion cell | Its tickets | Settled once; tickets read | Settle: owner; read: any | While a ticket references it | Never reset |
| Admission flag | The command host | Closure sets it; direct performance reads it | Owner | The host | Never cleared |
| Request counter | The command port | Submissions issue from it | Any; atomic | The host | Never reissued |
| Demand slots: the application's and one per window | The window host | Publishers combine into them; the owner captures and clears; the close protocol and quiescence close | Publish: any; capture and close: owner | The host, and a window's until it is forgotten | Cleared by each capture; closed and never reopened |
| Release failure | The window | A failing release part sets it; the observation release reads it | Owner | The window | Read at release |
| Host session and window collection | The window host | Construction creates them; creation acquires members; the close protocol retires them; the owner loop pumps and reconciles | Owner | The host's scope | Remaining windows released newest first by the collection's exit, then an owned session ended, when the scope unwinds |
| Window registry | The window host | Registration inserts; the close protocol marks closing; a retirement that succeeded or failed removes; ports, clients, and dispatch read | Write: owner; read: any | Registration until retirement | Emptied as windows retire; the collection's exit releases what remains |
| Per-window command hosts | The window host, for each window | The window's port admits; the loop executes; the close protocol and quiescence close | Admit: any; execute and close: owner | Registration until the window is forgotten | Closed at the close protocol or quiescence; never reopened |
| Borrow counts | The window host | `withHostWindow` and the loop's borrows raise and lower them; retirement reads them | Owner | The host | Each borrow drops its count on every exit |
| Dispatch cursor | The window host | Each dispatch attempt writes the port it served | Owner | The host | Never reset; may name a retired window's port |
| Surfaced close requests | The window host | The owner loop records the latest request surfaced per window | Owner | The host | Replaced by a newer request; removed when the window is forgotten |
| Host activity | The window host | The owner loop writes it around each event step; clients read it | Write: owner; read: any | While referenced | Left at the last turn |
| Per-window input feeds | The window host, for each window | The owner produces, warns, resumes, and closes; the consumer reads and acknowledges; the application enables and suspends | Owner operations: owner; capabilities: any | Registration until the window is forgotten | Closed at the close protocol, quiescence, or host release; frozen, never reopened |
| Input channel generation | The input feed | Production sends; reads receive; a reset or closure aborts and drops it; resumption installs the next | Produce and resume: owner; read: any | One generation | Aborted and dropped by a reset or closure |
| Input phase, epoch, gates, held baseline, episode, and counters | The input feed | Production, admission changes, acknowledgement, warning, resumption, and closure write; statistics read | Any, through the owner operations and capabilities | The feed | Held baseline cleared by focus loss, reset, and closure; the rest frozen at closure; counters never reset |
| Latest cursor sample | The input feed | The producer records it; button production copies it | Owner | The feed | Replaced by the next sample |
| Window attachment records | The owning host boundary; no production component yet | Owner transitions write; any holder observes | Owner | The host | A record is removed when its window is forgotten, an attachment when it retires; counters never reissued |
| Attachment completion inbox | The owning host boundary; no production component yet | Any thread offers; the owner takes and folds | Any; STM | While referenced | Emptied by each take |

The guard holds only occupancy and poison. None of this is application state.

## Linking

`hetoimasia-glfw:native` declares `pkgconfig-depends: glfw3 >=3.4 && <3.5`, the
range form of `3.4.*` that Cabal's pkg-config grammar accepts. Cabal therefore
resolves the private prefix that
[the native recipe](validation.md#the-native-glfw-recipe) prepares, and a missing
prefix is a configure failure. For an ordinary executable link, Cabal passes
only the archive flags, so the platform requirements that `glfw3.pc` keeps in
`Libs.private` are declared per operating system:

```cabal
if os(darwin)
    frameworks: Cocoa IOKit CoreFoundation
if os(linux)
    extra-libraries: rt m dl
```

The `GLFW link declarations` examples in `glfw-tests` compare these, for the
platform they run on, with the `libs_static` the native manifest recorded. Any
drift fails the suite. No GLFW library-path override is needed on either
platform. The [validation planner](validation.md#how-a-groups-inputs-are-derived)
accepts these link-only conditionals and follows the `package:library`
dependencies on the private sublibraries.

## Build and check

On macOS, once per native configuration (see
[Developer prerequisites and macOS](validation.md#developer-prerequisites-and-macos)):

```bash
brew install cmake pkgconf
python3 tools/native/native.py build
eval "$(python3 tools/native/native.py prepare)"
```

Inside the Linux CI image, `PKG_CONFIG_PATH` already names the image's prefix.
Then:

```bash
cabal build all
cabal test hetoimasia-glfw:glfw-tests --test-show-details=direct
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
```

`cabal.project` sets `tests: True` for this package alone. `cabal build all`
therefore compiles `glfw-tests` and `glfw-native-tests` from a clean
configuration without running either, and the dry run lists the native examples
without entering a session.
Running the native examples themselves takes the per-run consent
[the native suite](#the-native-suite) describes: the isolated display helper's
own on Linux, or a human's explicit approval on a real desktop.

- **`glfw-tests`** is the package's headless suite, rooted at one `GLFW` group,
  and initializes nothing, opens no window, and needs no display.
  It proves the session model through the seam, checks the link declarations,
  and compiles external clients against the package, including clients refused
  for naming a command host's, port's, or ticket's constructor or reaching for
  command execution, for constructing a monitor identity, description, or
  inventory or reaching for a native monitor pointer, and for naming the monitor
  drivers through the public seam, and for constructing a control command or its
  size constraints through their constructors or reaching for the private
  control representation, for naming a mode's, saved placement's, or mode
  record's constructor or reaching for the private mode module, and a supported
  client that submits and awaits a
  command, performs every control command constructor, reads the capability
  descriptions, requests modes and a startup mode, reads a mode record, and
  resolves monitors.
  The window model, command, control, host, dynamic window, monitor, input, and
  mode examples below are registered in the same tree, under the group names
  they always carried, so `--match "GLFW window modes"` or
  `--match "across the package boundary"` selects them, and a selector that
  matches nothing fails the suite. Because the suite belongs to
  `hetoimasia-glfw`, its own modules may import the private sublibraries; that
  access is not boundary evidence, which comes only from the external clients.
  The linking example reads `hetoimasia-glfw.cabal` from the package directory
  Cabal runs the suite in, and the manifest through `pkg-config`. It runs in the
  `test.glfw` validation group on the CPU worker.

  A new example that needs no native session — a model, seam, host, or boundary
  contract — belongs in `glfw-tests`, beside the component spec that owns it. An
  example that must initialize GLFW, open a real window, or observe the platform
  belongs in `glfw-native-tests` and its shared fixture.
- **The session wake examples** (`--match "GLFW session wake"`) use only the
  public seam. The seam records each post as `PostEmptyEvent` and makes the
  call's wake mark current on the posting thread while its scripted step runs.
  A scripted platform counts posts as pending for the next finite wait. Without
  sleeps, the examples prove: a wake before, during, and after the owner's wait,
  from unbound, bound, and owner threads; a scripted platform failure answered as
  that call's `WakeFailed`, posted once and not retried; `GLFW_NOT_INITIALIZED`,
  alone or beside a platform error, raised as a `NativeFailure` from `wake session`
  with the gate still admitting afterwards; two overlapping wakes each
  attributed their own platform-error report, beside a concurrent owner operation's report and
  an unrelated asynchronous one; one wake's reports bounded, truncated, and
  counted as the capture bounds them, and a callback fault inside the wake
  attributed to it, both raised as unclassifiable, with nothing left for a later
  owner read, asynchronous read, or teardown; a report whose mark could not be
  read raising from the error it left; an admitted wake finishing before scripted termination, which
  observes none in flight, while wakes during the drain answer `WakeTerminal`; a
  worker waking until terminal while the session closes, with every post
  recorded before teardown and wakes issued from termination and the error
  callback's detach answering `WakeTerminal`; a capability reused after close
  and against a later session; a construction rollback that never lends one; a
  waker cancelled inside its native call, and a wake completing with a
  cancellation pending, both leaving the gate; and an owner cancelled while its
  close drains an admitted wake, terminating only after the wake returns and
  leaving the guard vacant.
- **The window model examples** in the same suite use the seam's private
  drivers: `seamDrive` delivers scripted callbacks from inside a setter- or poll-origin
  owner step, `seamDriveCancelledBeforeCommit` delivers a cancellation at the
  reconciliation's preparation point, and `seamRejectCloseRequest` is the
  private close-request transition. None is a public command. They live in the
  private `seam-core` sublibrary, which the public seam does not re-export, so
  no package outside `hetoimasia-glfw` can name them; the `GLFW` opacity
  examples compile clients proving it. Each driver also refuses, with
  `ForeignSeamWindow`, a window its own seam did not create.
- **The window command examples** in the same suite drive the private
  command executor — `seamExecuteNext`, `seamExecuteNextInterrupted`, and
  `seamExecuteNextScripted` — and the admission hooks of `submitWith`, both
  also private to `seam-core`. Without sleeps, they prove immediate
  `SubmitFull` and `SubmitClosed`; cancellable capacity waits; FIFO claim in
  committed admission order; one disposition for repeated, cancelled, and
  owner-thread reads, after removal from the bookkeeping; closure settling queued
  commands and leaving a claimed one to its execution; interruptions after the
  claim, after effects, in preparation, and by cancellation, none replayed;
  bookkeeping bounded by capacity plus active work across repeated cycles;
  admission rollback and cancellation on both sides of the commit; origin
  metadata intact across the queue; a native failure as prepared data beside a
  Haskell exception with its context; owner-thread waits refused rather than
  blocking; and the observation request settling with a revision published
  first, while unserved and ended windows are rejected.
- **The window control examples** in the same suite submit the public
  control commands to the private command executor and to the window host's
  owner loop over seam sessions, whose native table records every control call
  with its window key and arguments and runs a scripted `scriptWindowControl`
  step. Without sleeps, they prove every invalid argument class — zero, negative,
  and overflowing sizes, unrepresentable positions, a NUL title, non-positive,
  overflowing, inverted, and degenerate constraints, constraints excluding the
  current size, and sizes outside known constraints or their exact aspect ratio
  — rejected with no native call and no revision; controls for unknown, closing,
  and closed windows rejected without native effect; every control, attention
  included, dispatched through the owner loop to its addressed window, each call
  followed by a sample and a strictly later revision, while a second window
  stays untouched, and a closed window's later control not served; controls
  refused during a mode transition set by `seamSetModeTransition`; the modeled
  Wayland capabilities settling position and focus as unsupported with a reason
  and keeping placement and iconified state `Unavailable` even after callbacks;
  a native error attributed to its own command and submission context while
  another thread's report stays asynchronous; partial and first-call constraint
  update failures naming their calls, refusing sizes while indeterminate, and a
  complete update restoring known state; and post-call revisions ordered while
  the latest snapshot moves beyond them.
- **The window mode examples** in the same suite submit mode requests to the
  private command executor and to the window host's owner loop over seam
  sessions whose native table tracks each window's decoration, monitor, size, and
  position, and takes windows off a disconnected monitor as GLFW does. Two
  monitors are scripted, one at a negative desktop origin with a work area offset
  from both origins. Without sleeps, they prove repeated requests inert with no
  native call, never restoring stale placement over a moved window; the saved
  placement kept across windowed, fullscreen, borderless, and windowed; seeding
  before a startup transition straight into fullscreen; a long chain ending at
  the original placement; a user's move and resize surviving a transition and
  return; inertness only on complete equality with a cleanly applied target;
  unrepresentable preferences, budgets, and placements and unreported video modes
  refused before any setter, with negative coordinates accepted; a disconnected
  selected monitor refused, or falling back to the windowed placement; a
  disconnect after fullscreen was applied falling back through the owner loop
  with no further command to a derived reachable placement while the off-screen
  saved placement is kept; exhaustion with no monitor left; borderless placement
  settling as unsupported on the modeled Wayland backend; a partial departure
  naming its steps and retaining the pre-departure geometry — restored through
  the configured fallback, a later explicit return, constraints admitting it
  while excluding the stale size, and an interruption after a native step; a
  failed constraint restoration stopping recovery; a required startup mode
  failing and rolling the
  window back while an optional one records its fallback; `MonitorBusy` for a
  second window without native effect, including while the first is iconified;
  independent claims released in both close orders; a claim invalidated by
  disconnect; claims kept uncertain after an unobserved transition and a failed
  disposal until reconciliation proves release; monitor switching reserving the
  destination first and releasing the source only after departure; the operation
  matrix after entering each mode with no setter for a refused control; controls
  refused while the presentation is indeterminate until reconciliation; commands
  refused inside a transition's interval, entered from a scripted native step,
  while another window is served; windowed constraints suspended and restored
  with a placement they exclude refused; and the named revision carrying the
  applied mode and geometry.
- **The window attachment model examples** in the same suite
  (`--match "attachment"`) drive the private attachment model's pure
  transitions over seam window identities; see
  [the attachment model examples](#attachment-model-examples).
- **The monitor inventory examples** in the same suite use the seam's
  private monitor drivers — `seamSetMonitorTopology`, `seamDeliverMonitorEvents`,
  and `seamQueueMonitorEvents` — over scripted monitors whose native pointers
  stand for scripted addresses, and the seam raises if the model queries an
  address its topology no longer lists. Without sleeps, they prove an empty
  inventory published as an observation; several monitors at negative and
  nonzero origins with the primary only an attribute; inconsistent numbers and
  enumerations becoming `Unavailable`; `GLFW_FEATURE_UNAVAILABLE` and other
  query reports; a disconnect ending an identity while its copied description
  stays readable; a reconnect at a reused address receiving a fresh identity
  within one boundary and across two, and reordering keeping identities; a stale
  identity answered disconnected before any native operation targets it; an
  identity from a completed session never resolving in a later one; a callback
  fault rethrown with its context and lost changes ending every identity; a fault
  latched after the last boundary raised from teardown; owner-thread refusals;
  and the inventory closing, waking its waiters, before the callback is detached
  ahead of termination and freed last.
- **`glfw-native-tests`** needs a windowing session: Cocoa locally, or an
  isolated X11 display, and per-run consent to enter it. It is not part of
  `glfw-tests` or the console smoke; it is the `test.glfw-native`
  validation group, which only the display worker runs. See
  [The native suite](#the-native-suite).

## The native suite

GLFW requires the process main thread, and Hspec runs examples on threads of its
own, so `glfw-native-tests` makes its process main thread the owner of one
shared production session and runs Hspec on a worker thread. An example reaches
the session through the test-only dispatcher in `Test.GLFW.Native.Fixture`: it
submits an operation, the main thread runs that operation against the session,
and the result or the original failure comes back to the example. This is a
test adapter over the production session, not a second supervisor or a general
test environment.

| Rule | How it holds |
| --- | --- |
| Selection | The Hspec tree is built, listed, and filtered before any example runs. A `--dry-run`, a listing, or a selection that never reaches a native operation acquires nothing, and a selection matching no example fails. |
| Acquisition | Lazily, by the first dispatched operation, and at most once. The run's last line reports how many times the shared session was acquired, and the run fails if that is more than once. |
| Windows | Every window example creates and releases its own private window inside one operation. No window is shared: no example yet demonstrates the reset and isolation a shared window would need. |
| Private sessions | Sessions entered and left in sequence, a forced initialization failure and its rollback, a session over a faulting native table, and wakes racing termination cannot coexist with the shared session, so each scenario runs in a child process of the same executable, started with `--private-session <scenario>`. No example ends the shared session. The parent starts no child without consent, the child inherits the parent's consent and is not asked again, and a child started directly from a shell without consent refuses on stderr with exit status 3 before it looks up its scenario; an unknown scenario under consent still exits 2. |
| Thread identity | Checked with the native main-thread shim, `isCurrentThreadBound`, and the owner's `ThreadId` at setup, inside every dispatched operation, before release, and after release. A failed check fails its operation or release, and the run. |
| Settlement | A waiting example also watches the owner, so an owner that fails wakes it with the owner's own failure. A cancelled example's queued operation is settled without running; one already running finishes and its reply is dropped. An acquisition failure answers every operation and is never retried. A failure crossing between the owner and an example is rethrown with the context it was raised with, so its failure evidence and retained cleanup failures survive. The session is released only once the Hspec run has finished, and a release failure beside a primary failure is kept as cleanup evidence. Once an owner failure or cancellation begins settlement, the owner's wait for the run stays interruptible but absorbs further owner cancellation — with or without a release failure — and the report keeps the failure that began the settlement as primary, including against a cancellation deferred through the uninterruptible release. |
| Consent | No native operation runs and no child starts without the run's consent, read once from `HETOIMASIA_NATIVE_SESSION` at startup. `desktop` is a human's approval for this one run on the local desktop; `isolated-x11:<display>` is what `tools/display/x11.sh` gives the command it runs, accepted only on Linux and only when it names the current `DISPLAY`. Anything else — the variable unset, empty, or another value, a bare `DISPLAY`, `CI` — refuses each example that uses the session or starts a child before its body runs, with `NativeSessionRefused`, so no body forks, waits, or dispatches without consent; any operation that still reaches the dispatcher is refused on the example's own thread before it is dispatched, and the owner's acquisition asks again before initializing GLFW. The session is never acquired and the report shows zero acquisitions. The run then ends with one line on stderr naming what was missing and the isolated alternative, and a non-zero exit, so its summary is never a pass. Building, listing, and filtering the tree, a dry run, and the examples that use only a scripted owner or a recorded launcher need no consent. |
| Platform | On Linux the session is entered only when `DISPLAY` names a display and `WAYLAND_DISPLAY` is absent, and it must select X11; on macOS it must select Cocoa. Anything else fails every native example with `DisplayUnavailable`: no other platform is selected instead. |

The fixture's settlement rules are proven against a scripted owner that records
its acquisition and release — lazy single acquisition, nothing acquired by a dry
run or an empty selection, a deliberately failing nested example, a cancelled
borrower with one operation in flight and one queued, an owner that fails while
a borrower waits, an owner cancelled again while it settles the first
cancellation, with the release succeeding and with it failing, an owner
cancelled once more while its release still runs, an owner with a cancellation
already pending at its acquisition's handoff to the borrower, cancelled again
during the release, an owner cancelled while its acquisition is blocked, and
an acquisition failure —
and the failing and cancelled cases again against the real shared session.
Every deliberate failure is inside a nested run or a forked borrower and is
asserted as expected, so the suite itself passes.

The consent gate is proven the same way, under `the native opt-in`, without a
session, a display, or a child: how consent is read from an environment on
each platform, including that a bare `DISPLAY`, `CI`, an empty value, an
unrecognized value, an isolated authorization for another display, and an
isolated authorization on macOS are each refused; that an unapproved run's
operations are refused before they are dispatched, so a scripted owner records
no acquisition, while a dry run and an empty selection still acquire nothing
and refuse nothing; that a consented example is refused before its body, so a
body that forks an operation and waits on it never starts, while a consented
run's body runs; that an approved run, under either consent, is served
with one acquisition; that a refusal reaching the real shared owner fails its
acquisition before the setup check, so before any native step; that the
private-session parent starts no child without consent and starts one with
it, through a recorded launcher; and that a directly invoked child refuses
before its scenario is looked up, keeping the unknown-scenario exit for an
approved one. Each refusal message names the variable, the approved command,
and the isolated alternative.

The native examples cover:

- the platform's backend selected explicitly, on an isolated X11 display under
  Linux;
- operations running on the bound process main thread that entered the session,
  never on the Hspec worker, and a single acquisition;
- nested entry on the owner thread, entry from a bound worker and from an
  unbound thread, and owner-only use from the Hspec worker, each rejected while
  the shared session keeps serving;
- the monitor inventory the display server exposes, read from the owner and
  from the Hspec worker, with exactly one primary monitor, and on the isolated
  X11 display exactly one monitor at the origin in a 1280 by 1024 mode; the run
  prints the exercised topology, which on Cocoa is its record of the local
  displays;
- every identity re-resolving to a live monitor on the owner thread, lending its
  pointer to a native step there, and keeping its identity across refreshes;
- a physical attach or detach observed as ended identities and a refreshed
  inventory, which is pending as unexercised unless
  `HETOIMASIA_MONITOR_HOTPLUG_SECONDS` asks a person to perform one during the
  run: no automated run can, and Xvfb cannot simulate it;
- a hidden non-focusing window's creation, nondegenerate initial framebuffer
  observation, release, terminal observation, and terminal handle;
- two live windows with a stray hint reset before the second's creation;
- a second window after a window's release in the same session;
- ordinary window controls on private hidden windows, performed on the owner
  thread with `performWindowCommand` and checked against the test-only
  owner-thread queries `windowSizeForCheck`, `windowPositionForCheck`,
  `windowTitleForCheck`, `sizeLimitsForCheck`, and `windowStateForCheck`, never
  against public commands: a title, a valid size, a position, and constraints
  applied to the addressed window while a second window stays unchanged;
  showing and then hiding reflected in observations; after constraints are
  installed, the platform holding exactly those limits for the addressed window
  and not for the other, a public out-of-constraint size refused, and the
  test-only native stimulus `setWindowSizeForCheck` resizing out of range, with
  the observation reporting the platform's actual size — clamped into the limits
  where the platform clamps programmatic resizes, or the unclamped request on
  Cocoa, whose content limits bound only the user's resizing; minimize, maximize, and restore each followed by
  an observation matching what the platform reports; focus and attention
  requests settling by their native call outcome without asserting that either
  was granted; and post-call revisions ordered while the latest snapshot has
  advanced beyond them. Each example waits for native events between
  observations, within 100 waits of at most 50 ms. On Cocoa, showing or focusing
  a window makes it briefly visible. Interactive focus, attention, and minimize
  behavior on a live desktop is optional evidence, not asserted;
- window modes on private hidden windows over the display server's primary
  monitor, performed on the owner thread with `performWindowCommand`: fullscreen
  and back restoring the observed windowed placement; borderless over the
  selected monitor's work area and back; fullscreen to borderless keeping the
  saved placement; each completion's named revision read from the snapshot on
  the owner thread before any event is processed, checked to be that revision,
  and compared at that point with `windowFullscreenForCheck` and
  `windowStateForCheck`'s decoration, which GLFW sets synchronously, while size
  and position, which X11 applies asynchronously, are compared only once the
  observation and the platform both reach the target within the event-wait
  bound, an example failing rather than passing when they do not; and a second
  window's
  request for the claimed monitor refused as `MonitorBusy` with the first
  window's fullscreen state, size, and the monitor's video mode unchanged, and an
  ordinary resize of the fullscreen window refused before its setter. The run
  prints the exercised monitor topology and records that no hotplug transition
  was exercised;
- a window host over the shared session running a whole application on the
  process main thread: a supervised worker's observation request executed by
  the real owner loop and settled with a published revision;
- a worker's production wake, `wakeSession` on an unbound thread, ending a
  production finite wait the owner thread entered and was blocked inside:
  `blockedWaitForCheck` observes that wait's sequence number around the kernel
  report, and the same wait returns woken before its 60-second bound;
- a worker's admitted command ending such a wait through the production
  admission path rather than a wake this example posts: the worker submits an
  ordinary command through an ordinary port once it has observed the wait
  blocked, the same wait returns woken before its bound, and closure then
  settles the command it announced as `NotExecuted`, so no window is created in
  the shared session;
- three wakes from a bound worker returning that blocked wait once, then a
  later wait that at most one spurious return precedes, blocking again until
  one more wake ends it; and three wakes the owner posts while no wait is in
  progress returning at most one wait early before the next wait blocks. Each
  example prints an evidence line with the sequence numbers observed blocked
  and returned woken, the spurious returns, and the time against the bound;
- in a private process, twenty sessions closed while four workers, on bound
  and unbound threads, wake them until each capability answers `WakeTerminal`.
  Immediately before `glfwTerminate`, every admitted wake has returned from
  `glfwPostEmptyEvent` (the calls entered equal those returned), and none
  enters it afterwards. A capability retained from a closed session stays
  terminal, entering nothing, during and after a later session. The run prints
  the child's report of both checks;
- a supervised worker progressing while the owner is blocked inside the
  production `glfwWaitEventsTimeout`: the worker's progress note lands only
  inside GLFW's own wait, as [the binding](#the-binding) describes, and wakes
  it with `glfwPostEmptyEvent`, and the loop reads back that a note landed in
  the wait it just returned from. On the suite's single capability, a wait that
  kept its capability would let no note land;
- a real close request — `performClose:` on Cocoa, a `WM_DELETE_WINDOW` client
  message on X11, sent by a test-only shim driver — reaching application policy
  without destroying the only window, the loop and a worker still running two
  turns later, and the window released only after that worker drained, with the
  run returning normally;
- dynamic windows through the real owner loop: three hidden windows created by a
  worker's requests and closed in the orders B-A-C and C-A-B, each window still
  open observing and executing through its own port after every close; a window
  closed while a worker holds its port, which then answers closed while another
  window executes; a real close request honoured by application policy through
  the close protocol, leaving the other window open; and every remaining window,
  a created one included, still open through the drain and disposed after it,
  with the run returning normally and so retaining no cleanup failure;
- native input callbacks invoked through the registered C trampolines
  (`hetoimasia_glfw_inject_*_for_check`), not the feed's private producer:
  tagged key, character, button, and scroll events; cursor coalesced into the
  observation; a button keeping captured coordinates after later motion; feed
  and staging saturation starting the same reset, with a fresh press after
  acknowledgement and no press for a key still held; one window's overflow
  leaving a second window receiving input; a fault inside a real input
  callback rethrown at the owner boundary; a close request visible while a
  feed is full; and callbacks removed before destruction. Hidden windows do
  not receive display-server events, so every scenario uses that fixture
  owner-thread path, which the suite records;
- in a private process, sessions entered and left in sequence, a real
  `GLFW_PLATFORM_UNAVAILABLE` initialization failure before any polling followed
  by a successful session, and a fault raised inside a real GLFW size callback,
  driven by `glfwSetWindowSize` and `glfwPollEvents`, rethrown at the owner
  boundary with its context. Cocoa calls that callback inside the resize, while
  X11 delivers it after a round trip to the server, so later boundaries wait
  for events with `glfwWaitEventsTimeout` — returning as soon as one arrives,
  within a bound of 100 boundaries of at most 50 ms — until the fault is
  rethrown;
- in a private process, the real monitor callback detached while it is still the
  callback GLFW holds, with none held afterwards, before `glfwTerminate`, and its
  storage freed after the error callback's detach, with the closed inventory
  readable after the session; and every identity from a completed real session
  answered `MonitorDisconnected` in the next.

Without consent, these list the examples and run the ones that never enter a
session, acquiring nothing and starting no child:

```bash
cabal test glfw-native-tests --test-show-details=direct --test-options='--dry-run'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "with a scripted owner"'
cabal test glfw-native-tests --test-show-details=direct --test-options='--match "the native opt-in"'
```

On Linux, run the native examples inside the display helper, exactly as the
display worker does. The helper starts a private X11 display and gives the
command, and only the command, the consent for that display, so this needs
no approval and touches no desktop:

```bash
bash tools/display/x11.sh -- cabal test glfw-native-tests --test-show-details=direct
```

On a real desktop — Cocoa on macOS, or an X11 desktop of a person's own — the
examples show, focus, resize, minimize, maximize, and take fullscreen windows
there. An agent first describes that disruption, asks the human user for
explicit approval, and waits for acceptance. The approved run then carries the
consent on its own command, and nowhere else:

```bash
HETOIMASIA_NATIVE_SESSION=desktop cabal test glfw-native-tests --test-show-details=direct
HETOIMASIA_NATIVE_SESSION=desktop cabal test glfw-native-tests --test-show-details=direct --test-options='--match "/GLFW native/the shared session/"'
```

The approval covers that one agreed session and is not reprompted during it;
it does not carry to a later run. An issue acceptance command, a PR approval,
a persistent shell setting, or a periodic testing request is not that
approval. Never set the variable in a shell profile or in a script an agent
runs on its own: the suite cannot tell that a conversation happened, only that
the command it was given carries the value. Without it, the full command
fails before initializing GLFW, with the refusal on stderr and zero
acquisitions in its report, and `--private-session <scenario>` invoked
directly refuses the same way. See
[validation.md](validation.md#the-display-worker).

Record native evidence with the manifest and compiler identities it ran under:

```bash
python3 tools/native/native.py toolchain
ghc --numeric-version && cabal --numeric-version
```
