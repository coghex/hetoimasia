{-# LANGUAGE DeriveGeneric #-}

-- | Window modes: what a mode request asks for, the placement a window keeps
-- for its windowed presentation, how a transition is planned and validated
-- before any native call, which monitors a window claims, and how a transition
-- settles.
--
-- This module is pure and holds no state. "Hetoimasia.GLFW.Internal.Window"
-- executes a transition on the owner thread, the session keeps the monitor
-- claims, and "Hetoimasia.GLFW.Internal.Command" turns the result into a
-- disposition.
--
-- = Requests
--
-- A 'WindowMode' is one requested presentation: windowed, borderless over a
-- selected monitor's work area, or fullscreen on a selected monitor with a
-- 'VideoModePreference'. A 'ModeRequest' pairs it with a 'ModeFallback': none,
-- or a finite number of attempts to return the window to usable windowed
-- operation. Their representations are private; a request is only validated
-- when it executes, against the window's state and the monitors reported then.
--
-- = The mode record
--
-- The owner keeps, for each window, a 'ModeRecord': the requested mode and its
-- fallback, the 'AppliedMode' reconciled from observation, the saved windowed
-- placement, the last settled 'ModeOutcome', and the monitor identity the
-- recorded recovery is owed to ('modeRecoveryObligation'). They are distinct:
-- the applied mode is derived from what the platform reported — the window's
-- fullscreen monitor, its decoration, and its placement against the monitors'
-- work areas ('deriveApplied') — and never copied from a request, while the
-- recovery obligation is established by a settlement's own sample
-- ('recordSettled') and moved only by a reconciliation against a refreshed
-- inventory that finds a borderless window confirmed on another live monitor
-- ('followedMonitor'), so an ordinary observation that follows the monitor's
-- native departure reports the truth without erasing the unresolved recovery.
-- A window reporting no fullscreen monitor and decoration is windowed; one
-- reporting a fullscreen monitor is fullscreen on it; an undecorated one
-- without a fullscreen monitor
-- is borderless over the first monitor whose work area contains its content
-- origin. Anything else, including an unavailable report or a fullscreen
-- monitor whose identity is not current, is 'AppliedIndeterminate'.
--
-- = Saved placement
--
-- 'SavedPlacement' is the windowed content position and logical size a window
-- returns to:
--
-- * it is seeded from the window's initial observation, before any startup
--   transition;
-- * it is cached from the observed placement when a transition leaves an applied
--   windowed presentation — the geometry the attempt departs from, retained
--   whether the attempt's native steps all return, one reports partway, or the
--   attempt is interrupted after a native step;
-- * it is never overwritten on a return to windowed, on a change between
--   borderless and fullscreen, by a failed attempt's target placement, or by a
--   fallback's derived placement.
--
-- A repeated request is inert ('inertRequest') only when it equals the recorded
-- request completely — the monitor identity and the video mode preference
-- included — the last outcome settled cleanly at the target, and the applied
-- mode, reconciled immediately before against a refreshed inventory, still
-- matches it: windowed with its constraints applied, borderless exactly over that
-- monitor's work area, or fullscreen on that monitor at the observed size the
-- preference selects there, with the monitor's current video mode that size and,
-- when the preference names one, that refresh rate. An inert request makes no native call, so it
-- never restores saved geometry over a window the user has moved since.
--
-- = Windowed placement and fallback
--
-- 'windowedPlacement' is the documented deterministic policy for returning to
-- windowed presentation. The saved placement is used as it is when its content
-- origin lies inside the work area of a current monitor. Otherwise its size is
-- kept and it is centred, clamped to the work area's origin when larger, in the
-- work area of the monitor the platform designates primary, or of the first
-- enumerated monitor with a nonempty work area when none is. With no saved
-- placement, or no such monitor — an empty or inconsistent inventory — no
-- placement is reachable. The derived placement is never saved.
--
-- = Validation
--
-- Before any native call a transition refuses, as a typed 'ModeRejection':
-- an unrepresentable fallback budget or video mode preference; a monitor whose
-- identity has ended; a video mode the monitor does not report; a work area
-- that is unavailable or empty; a placement whose coordinates are outside the
-- native @int@ range or whose size is outside @1 .. 2147483647@; a windowed
-- placement the preserved windowed constraints do not admit, bounds and aspect
-- ratio alike; a borderless or fullscreen entry, or a windowed return, while the
-- preserved windowed constraints are indeterminate after a partial update, so
-- no placement is ever made without proving the constraints admit it and no
-- window leaves windowed presentation it could not validly return to; and a
-- fullscreen monitor another window claims. Negative desktop coordinates are valid.
--
-- = Plans
--
-- A 'ModePlan' is an ordered list of 'ModeStep's:
--
-- * windowed: set decorated, place the content area with no monitor, and then,
--   if the native constraints are not the preserved windowed set, restore it;
-- * borderless: clear the native size limits and aspect ratio if the preserved
--   windowed set is not already absent or suspended, set undecorated, and place
--   the content area over the work area with no monitor;
-- * fullscreen: set the monitor, at the selected mode's size and refresh rate.
--
-- Decoration is set before placement, because a platform may keep the frame
-- and change the content area when decoration changes. GLFW stores decoration
-- set on a fullscreen window and applies it when the window leaves the monitor.
-- Fullscreen leaves the native constraints installed: GLFW ignores them while a
-- window is on a monitor.
--
-- = Claims
--
-- A session holds at most one 'WindowClaim' per monitor identity. A fullscreen
-- target is reserved ('reserveClaim') before the first native call, and a claim
-- held by another window refuses with 'MonitorBusy'. After a transition
-- 'settleClaims' reconciles the window's claims with its observed fullscreen
-- monitor: that monitor is held and every other claim of the window is released
-- — its departure is confirmed, or its reservation proven unused; no fullscreen
-- monitor releases them all; an unavailable report makes them all uncertain.
-- Iconification changes no claim. An attempt interrupted by an exception other
-- than its own failure settles its claims with 'abandonClaims': a reservation it
-- made before any native step is released as proven unused, and after a native
-- step every claim of the window becomes uncertain. 'pruneClaims' drops the
-- claims of ended identities, and a window's release drops its claims only when disposal
-- succeeded ('disposeClaims'). An uncertain claim is never available to another
-- window.
--
-- = Outcomes
--
-- A transition that makes native calls settles as a 'ModeOutcome' naming the
-- steps that returned, the step that reported an error, and those not attempted.
-- Nothing is rolled back; a fallback is a separate attempt from the state the
-- previous one left, reconciled first.
module Hetoimasia.GLFW.Internal.Mode
  ( -- * Requests
    WindowMode
  , windowedMode
  , borderlessMode
  , fullscreenMode
  , modePresentation
  , modeMonitor
  , modeVideoPreference
  , VideoModePreference
  , currentVideoMode
  , exactVideoMode
  , preferredVideoMode
  , ModeFallback
  , noModeFallback
  , windowedFallback
  , fallbackAttempts
  , maximumFallbackAttempts
  , ModeRequest
  , modeRequest
  , requestedMode
  , requestedFallback
  , ModeRequirement (..)
  , StartupMode
  , startupMode
  , startupRequest
  , startupRequirement

    -- * The mode record
  , SavedPlacement
  , savedPlacement
  , savedPosition
  , savedExtent
  , AppliedMode (..)
  , appliedPresentation
  , ModeRecord
  , initialModeRecord
  , modeRequested
  , modeFallback
  , modeApplied
  , modeSavedPlacement
  , modeLastOutcome
  , modeRecoveryObligation
  , followedMonitor
  , recordApplied
  , recordSaved
  , recordRecoveryCleared
  , recordRecoveryFollowed
  , recordSettled
  , deriveApplied
  , inertRequest

    -- * Validation and planning
  , ModeRejection (..)
  , validateRequest
  , selectVideoMode
  , borderlessPlacement
  , windowedPlacement
  , workAreaContains
  , NativeConstraints (..)
  , effectiveConstraints
  , ModeStep (..)
  , modeStepText
  , ModePlan (..)
  , windowedPlan
  , borderlessPlan
  , fullscreenPlan

    -- * Claims
  , ClaimState (..)
  , WindowClaim (..)
  , MonitorClaims
  , pruneClaims
  , reserveClaim
  , settleClaims
  , abandonClaims
  , disposeClaims

    -- * Outcomes
  , ModeAttemptKind (..)
  , ModeFailure (..)
  , ModeAttemptFailure (..)
  , ModeOutcome (..)
  , settledCleanly
  , ModeResult (..)
  ) where

import Control.Applicative ((<|>))
import Control.DeepSeq (NFData (rnf))
import Control.Exception (Exception)
import Data.Int (Int32)
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import GHC.Generics (Generic)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Capture (Reports, rnfReports)
import Hetoimasia.GLFW.Internal.Control
  ( AspectRatio
  , ConstraintState (..)
  , PostCallObservation
  , PresentationKind (..)
  , PresentationState (..)
  , SizeConstraints
  , constraintAspectRatio
  , constraintMaximum
  , constraintMinimum
  , constraintsAdmit
  )
import Hetoimasia.GLFW.Internal.Monitor
  ( MonitorDescription
  , MonitorId
  , VideoMode (..)
  , WorkArea (..)
  , monitorCurrentMode
  , monitorIdentity
  , monitorPrimary
  , monitorVideoModes
  , monitorWorkArea
  )
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Requests

-- | Which video mode a fullscreen window asks its monitor for. Its
-- representation is private.
data VideoModePreference
  = CurrentVideoMode
  | ExactVideoMode !Int !Int !(Maybe Int)
  deriving (Eq, Show, Generic)

instance NFData VideoModePreference

-- | The monitor's current video mode, at its current refresh rate.
currentVideoMode ∷ VideoModePreference
currentVideoMode = CurrentVideoMode

-- | A video mode of exactly this size, and of this refresh rate in hertz if one
-- is given, which the monitor must report among its modes.
exactVideoMode ∷ Extent → Maybe Int → VideoModePreference
exactVideoMode (Extent width height) = ExactVideoMode width height

-- | The size and refresh rate an exact preference names; 'Nothing' for the
-- monitor's current mode.
preferredVideoMode ∷ VideoModePreference → Maybe (Extent, Maybe Int)
preferredVideoMode = \case
  CurrentVideoMode → Nothing
  ExactVideoMode width height refresh → Just (Extent width height, refresh)

-- | One requested presentation. Its representation is private.
data WindowMode
  = WindowedMode
  | BorderlessMode !MonitorId
  | FullscreenMode !MonitorId !VideoModePreference
  deriving (Eq, Show)

instance NFData WindowMode where
  rnf = \case
    WindowedMode → ()
    BorderlessMode monitor → rnf monitor
    FullscreenMode monitor preference → rnf monitor `seq` rnf preference

-- | A decorated window at its saved placement.
windowedMode ∷ WindowMode
windowedMode = WindowedMode

-- | An undecorated window placed over the monitor's work area.
borderlessMode ∷ MonitorId → WindowMode
borderlessMode = BorderlessMode

-- | A fullscreen window on the monitor, in the preferred video mode.
fullscreenMode ∷ MonitorId → VideoModePreference → WindowMode
fullscreenMode = FullscreenMode

modePresentation ∷ WindowMode → PresentationKind
modePresentation = \case
  WindowedMode → WindowedPresentation
  BorderlessMode _ → BorderlessPresentation
  FullscreenMode _ _ → FullscreenPresentation

-- | The monitor a borderless or fullscreen mode selects.
modeMonitor ∷ WindowMode → Maybe MonitorId
modeMonitor = \case
  WindowedMode → Nothing
  BorderlessMode monitor → Just monitor
  FullscreenMode monitor _ → Just monitor

modeVideoPreference ∷ WindowMode → Maybe VideoModePreference
modeVideoPreference = \case
  FullscreenMode _ preference → Just preference
  _ → Nothing

-- | What a transition does when its target cannot be reached. Its
-- representation is private.
data ModeFallback
  = NoModeFallback
  | WindowedFallback !Int
  deriving (Eq, Show, Generic)

instance NFData ModeFallback

-- | Settle with the failure; attempt nothing else.
noModeFallback ∷ ModeFallback
noModeFallback = NoModeFallback

-- | After a recognized failure, return to windowed presentation at a reachable
-- placement, attempting that at most this many times. Validated when the
-- request executes: @1 .. 'maximumFallbackAttempts'@.
windowedFallback ∷ Int → ModeFallback
windowedFallback = WindowedFallback

-- | How many fallback attempts follow the first; zero for none.
fallbackAttempts ∷ ModeFallback → Int
fallbackAttempts = \case
  NoModeFallback → 0
  WindowedFallback attempts → attempts

maximumFallbackAttempts ∷ Int
maximumFallbackAttempts = 4

-- | A mode and its fallback. Its representation is private.
data ModeRequest = ModeRequest !WindowMode !ModeFallback
  deriving (Eq, Show)

instance NFData ModeRequest where
  rnf (ModeRequest mode fallback) = rnf mode `seq` rnf fallback

modeRequest ∷ WindowMode → ModeFallback → ModeRequest
modeRequest = ModeRequest

requestedMode ∷ ModeRequest → WindowMode
requestedMode (ModeRequest mode _) = mode

requestedFallback ∷ ModeRequest → ModeFallback
requestedFallback (ModeRequest _ fallback) = fallback

-- | Whether a window's startup mode is required.
data ModeRequirement
  = ModeRequired
    -- ^ Exhaustion propagates the last failure, and the window is not created.
  | ModeOptional
    -- ^ Exhaustion is recorded as the window's last outcome, and the window is
    -- created in whatever presentation it was left.
  deriving (Eq, Show, Generic)

instance NFData ModeRequirement

-- | A mode a window transitions to during its creation. Its representation is
-- private.
data StartupMode = StartupMode !ModeRequest !ModeRequirement
  deriving (Eq, Show)

instance NFData StartupMode where
  rnf (StartupMode request requirement) = rnf request `seq` rnf requirement

startupMode ∷ ModeRequest → ModeRequirement → StartupMode
startupMode = StartupMode

startupRequest ∷ StartupMode → ModeRequest
startupRequest (StartupMode request _) = request

startupRequirement ∷ StartupMode → ModeRequirement
startupRequirement (StartupMode _ requirement) = requirement

-- ---------------------------------------------------------------------------
-- The mode record

-- | A windowed content position and logical size. Its representation is
-- private: only the owner saves one.
data SavedPlacement = SavedPlacement !Placement !Extent
  deriving (Eq, Show)

instance NFData SavedPlacement where
  rnf (SavedPlacement position extent) = rnf position `seq` rnf extent

savedPlacement ∷ Placement → Extent → SavedPlacement
savedPlacement = SavedPlacement

savedPosition ∷ SavedPlacement → Placement
savedPosition (SavedPlacement position _) = position

savedExtent ∷ SavedPlacement → Extent
savedExtent (SavedPlacement _ extent) = extent

-- | The presentation reconciled from what the platform reported.
data AppliedMode
  = AppliedWindowed
  | AppliedBorderless !MonitorId
  | AppliedFullscreen !MonitorId
  | AppliedIndeterminate
    -- ^ What the platform reported does not establish a presentation.
  deriving (Eq, Show)

instance NFData AppliedMode where
  rnf = \case
    AppliedWindowed → ()
    AppliedBorderless monitor → rnf monitor
    AppliedFullscreen monitor → rnf monitor
    AppliedIndeterminate → ()

appliedPresentation ∷ AppliedMode → PresentationState
appliedPresentation = \case
  AppliedWindowed → PresentationKnown WindowedPresentation
  AppliedBorderless _ → PresentationKnown BorderlessPresentation
  AppliedFullscreen _ → PresentationKnown FullscreenPresentation
  AppliedIndeterminate → PresentationIndeterminate

-- | What the owner keeps about a window's mode. Its representation is private.
data ModeRecord = ModeRecord
  { recRequested ∷ !WindowMode
  , recFallback ∷ !ModeFallback
  , recApplied ∷ !AppliedMode
  , recSaved ∷ !(Maybe SavedPlacement)
  , recLast ∷ !(Maybe ModeOutcome)
  , recRecovery ∷ !(Maybe MonitorId)
    -- ^ The monitor identity the recorded recovery is owed to, established by
    -- the last settlement's own sample. Ordinary observations rewrite the
    -- applied mode without touching it, so one that follows the monitor's
    -- native departure cannot erase an unresolved recovery. It moves only
    -- when a reconciliation against a refreshed inventory confirms a
    -- borderless window on another live monitor ('followedMonitor').
  }
  deriving (Eq, Show)

instance NFData ModeRecord where
  rnf (ModeRecord requested fallback applied saved lastOutcome recovery) =
    rnf requested `seq` rnf fallback `seq` rnf applied `seq` rnf saved `seq` rnf lastOutcome `seq` rnf recovery

-- | A window's record at creation: windowed requested, no fallback, the applied
-- mode its initial observation established, the placement seeded from it, and
-- no recovery owed — only a request that executes and settles establishes one.
initialModeRecord ∷ AppliedMode → Maybe SavedPlacement → ModeRecord
initialModeRecord applied saved = ModeRecord WindowedMode NoModeFallback applied saved Nothing Nothing

-- | The last mode request that executed, whatever it settled as. A request
-- refused before any native call is not recorded.
modeRequested ∷ ModeRecord → WindowMode
modeRequested = recRequested

modeFallback ∷ ModeRecord → ModeFallback
modeFallback = recFallback

modeApplied ∷ ModeRecord → AppliedMode
modeApplied = recApplied

modeSavedPlacement ∷ ModeRecord → Maybe SavedPlacement
modeSavedPlacement = recSaved

modeLastOutcome ∷ ModeRecord → Maybe ModeOutcome
modeLastOutcome = recLast

-- | The monitor identity whose end obliges the recorded windowed fallback:
-- the one the last settlement's own sample established the applied mode on,
-- or the live monitor a borderless window was since confirmed on
-- ('recordRecoveryFollowed'). 'Nothing' owes no recovery.
modeRecoveryObligation ∷ ModeRecord → Maybe MonitorId
modeRecoveryObligation = recRecovery

-- | The live monitor a borderless window's recovery obligation follows, judged
-- against the monitors a refresh just observed: the settled borderless request
-- owes its recovery to one live monitor, and the applied mode is borderless on
-- another live monitor, so the window legitimately moved between two connected
-- monitors and its recovery is owed to the one it now stands on. 'Nothing'
-- leaves the obligation where it is: an applied mode observed before the
-- refresh that ends the owed monitor derives against the stale inventory, so
-- an owed monitor that is not live keeps the obligation, as does an observed
-- monitor that is not live, an indeterminate or windowed observation, and a
-- fullscreen request, whose obligation stays on the monitor its settlement
-- established.
followedMonitor ∷ [MonitorId] → ModeRecord → Maybe MonitorId
followedMonitor live record = case (recRequested record, recRecovery record, recApplied record) of
  (BorderlessMode _, Just owed, AppliedBorderless observed)
    | observed /= owed && owed `elem` live && observed `elem` live → Just observed
  _ → Nothing

recordApplied ∷ AppliedMode → ModeRecord → ModeRecord
recordApplied applied record = record {recApplied = applied}

recordSaved ∷ SavedPlacement → ModeRecord → ModeRecord
recordSaved saved record = record {recSaved = Just saved}

-- | Answer a recovery obligation without a transition: the resample that
-- publishes the platform's post-disconnect truth when no fallback is
-- configured consumes it, so the owner loop's reconciliation does not resample
-- the window on every later turn.
recordRecoveryCleared ∷ ModeRecord → ModeRecord
recordRecoveryCleared record = record {recRecovery = Nothing}

-- | Owe the recovery to the monitor 'followedMonitor' answered: the
-- reconciliation that confirmed the move records it, so the disconnect of the
-- monitor the window now stands on triggers the recovery, and the disconnect
-- of the one it left does not.
recordRecoveryFollowed ∷ MonitorId → ModeRecord → ModeRecord
recordRecoveryFollowed monitor record = record {recRecovery = Just monitor}

-- | Record a request that executed and how it settled. The settlement's sample
-- has already been folded into the record, so the recovery now owed is the one
-- the settled applied mode stands on: a newer settled request thereby replaces
-- a pending recovery, whatever its outcome, and a followed obligation alike,
-- while a request refused before any native call is never recorded here and
-- leaves one pending.
recordSettled ∷ ModeRequest → ModeOutcome → ModeRecord → ModeRecord
recordSettled (ModeRequest mode fallback) outcome record =
  record
    { recRequested = mode
    , recFallback = fallback
    , recLast = Just outcome
    , recRecovery = obligatedMonitor (recApplied record)
    }

-- | The monitor identity a settled applied mode owes its configured recovery
-- to: the monitor a fullscreen or borderless presentation stands on.
obligatedMonitor ∷ AppliedMode → Maybe MonitorId
obligatedMonitor = \case
  AppliedBorderless monitor → Just monitor
  AppliedFullscreen monitor → Just monitor
  _ → Nothing

-- | The applied mode established by a window's reported fullscreen monitor,
-- decoration, and content position, against the current monitors.
deriveApplied ∷ Attribute [MonitorDescription] → Attribute (Maybe MonitorId) → Attribute Bool → Attribute Placement → AppliedMode
deriveApplied monitors fullscreen decorated placement = case (fullscreen, decorated, placement, monitors) of
  (Observed (Just monitor), _, _, _) → AppliedFullscreen monitor
  (Observed Nothing, Observed True, _, _) → AppliedWindowed
  (Observed Nothing, Observed False, Observed (Placement x y), Observed described) →
    maybe AppliedIndeterminate (AppliedBorderless . monitorIdentity) (find (over x y) described)
  _ → AppliedIndeterminate
  where
    over x y description = case monitorWorkArea description of
      Observed area → workAreaContains x y area
      Unavailable → False

-- | Whether a request is inert for the recorded state, reconciled immediately
-- before: equal to the recorded request, last settled cleanly, and still
-- applied.
inertRequest
  ∷ ModeRecord → NativeConstraints → Attribute [MonitorDescription] → Attribute Placement → Attribute Extent → WindowMode → Bool
inertRequest record native monitors placement extent mode =
  recRequested record == mode && maybe True settledCleanly (recLast record) && applied
  where
    applied = case mode of
      WindowedMode → recApplied record == AppliedWindowed && native == NativeFollowsWindowed
      BorderlessMode monitor →
        recApplied record == AppliedBorderless monitor
          && case (monitorsOf monitors >>= either (const Nothing) Just . borderlessPlacement, placement, extent) of
            (Just (SavedPlacement over size), Observed at, Observed observed) → over == at && size == observed
            _ → False
        where
          monitorsOf (Observed described) = find ((== monitor) . monitorIdentity) described
          monitorsOf Unavailable = Nothing
      FullscreenMode monitor preference →
        recApplied record == AppliedFullscreen monitor
          && case (monitorsOf monitors >>= either (const Nothing) Just . selectVideoMode preference, monitorsOf monitors, extent) of
            (Just (selected, refresh), Just description, Observed observed) →
              observed == selected && case monitorCurrentMode description of
                Observed current →
                  Extent (modeWidth current) (modeHeight current) == selected
                    && all (\rate → modeRefreshRate current == Observed rate) refresh
                Unavailable → False
            _ → False
        where
          monitorsOf (Observed described) = find ((== monitor) . monitorIdentity) described
          monitorsOf Unavailable = Nothing

-- ---------------------------------------------------------------------------
-- Validation

-- | Why a transition, or one of its attempts, was refused before any native
-- call.
data ModeRejection
  = TransitionAlreadyInProgress
    -- ^ Another transition of the window has not settled.
  | FallbackAttemptsRejected !Int
    -- ^ The fallback budget is not in @1 .. 'maximumFallbackAttempts'@.
  | VideoModeRejected !Int !Int !(Maybe Int)
    -- ^ A preferred width, height, or refresh rate is not in @1 .. 2147483647@.
  | ModeMonitorDisconnected !MonitorId
    -- ^ The selected monitor's identity has ended.
  | MonitorBusy !MonitorId
    -- ^ Another window claims the monitor for fullscreen.
  | VideoModeUnavailable !MonitorId !VideoModePreference
    -- ^ The monitor does not report the preferred video mode.
  | WorkAreaUnavailable !MonitorId
    -- ^ The monitor's work area is unavailable or empty.
  | PlacementUnrepresentable !Placement !Extent
    -- ^ A coordinate is outside the native @int@ range, or a dimension outside
    -- @1 .. 2147483647@.
  | NoReachablePlacement
    -- ^ There is no saved placement, or no current monitor with a nonempty work
    -- area to place it in.
  | PlacementExcluded !Extent !SizeConstraints
    -- ^ The preserved windowed constraints do not admit the placement's size.
  | WindowedConstraintsIndeterminate
    -- ^ The preserved windowed constraints are indeterminate, so no windowed
    -- placement can be validated against them, and they can be neither
    -- suspended safely nor restored.
  deriving (Eq, Show)

instance NFData ModeRejection where
  rnf = \case
    TransitionAlreadyInProgress → ()
    FallbackAttemptsRejected attempts → rnf attempts
    VideoModeRejected width height refresh → rnf width `seq` rnf height `seq` rnf refresh
    ModeMonitorDisconnected monitor → rnf monitor
    MonitorBusy monitor → rnf monitor
    VideoModeUnavailable monitor preference → rnf monitor `seq` rnf preference
    WorkAreaUnavailable monitor → rnf monitor
    PlacementUnrepresentable position extent → rnf position `seq` rnf extent
    NoReachablePlacement → ()
    PlacementExcluded extent constraints → rnf extent `seq` rnf constraints
    WindowedConstraintsIndeterminate → ()

-- | Check what a request carries, independently of any window or monitor.
validateRequest ∷ ModeRequest → Either ModeRejection ()
validateRequest (ModeRequest mode fallback) = do
  case fallback of
    WindowedFallback attempts
      | attempts < 1 || attempts > maximumFallbackAttempts → Left (FallbackAttemptsRejected attempts)
    _ → Right ()
  case mode of
    FullscreenMode _ (ExactVideoMode width height refresh)
      | not (dimension width && dimension height && all dimension refresh) → Left (VideoModeRejected width height refresh)
    _ → Right ()

-- | The size and refresh rate a preference selects on a monitor; 'Nothing' as
-- the refresh rate leaves it to the platform.
selectVideoMode ∷ VideoModePreference → MonitorDescription → Either ModeRejection (Extent, Maybe Int)
selectVideoMode preference description = case preference of
  CurrentVideoMode → case monitorCurrentMode description of
    Observed current → Right (Extent (modeWidth current) (modeHeight current), refreshOf current)
    Unavailable → unavailable
  ExactVideoMode width height refresh → case monitorVideoModes description of
    Observed modes | any (matches width height refresh) modes → Right (Extent width height, refresh)
    _ → unavailable
  where
    unavailable = Left (VideoModeUnavailable (monitorIdentity description) preference)
    matches width height refresh candidate =
      modeWidth candidate == width
        && modeHeight candidate == height
        && all (\rate → modeRefreshRate candidate == Observed rate) refresh
    refreshOf current = case modeRefreshRate current of
      Observed rate → Just rate
      Unavailable → Nothing

-- | The placement a borderless window takes: the monitor's work area.
borderlessPlacement ∷ MonitorDescription → Either ModeRejection SavedPlacement
borderlessPlacement description = case monitorWorkArea description of
  Observed (WorkArea x y width height)
    | width > 0 && height > 0 → representable (SavedPlacement (Placement x y) (Extent width height))
  _ → Left (WorkAreaUnavailable (monitorIdentity description))

-- | The placement a window returns to windowed presentation at, under the
-- module's windowed placement policy, validated against the preserved windowed
-- constraints.
windowedPlacement ∷ ConstraintState → Maybe SavedPlacement → Attribute [MonitorDescription] → Either ModeRejection SavedPlacement
windowedPlacement constraints saved monitors = do
  SavedPlacement (Placement x y) extent@(Extent width height) ← maybe (Left NoReachablePlacement) Right saved
  placement ←
    if any (workAreaContains x y) areas
      then Right (SavedPlacement (Placement x y) extent)
      else case primary <|> listToMaybe areas of
        Just (WorkArea areaX areaY areaWidth areaHeight) →
          Right
            ( SavedPlacement
                (Placement (areaX + max 0 ((areaWidth - width) `quot` 2)) (areaY + max 0 ((areaHeight - height) `quot` 2)))
                extent
            )
        Nothing → Left NoReachablePlacement
  _ ← representable placement
  case constraints of
    ConstraintsKnown (Just preserved)
      | not (constraintsAdmit preserved extent) → Left (PlacementExcluded extent preserved)
    ConstraintsIndeterminate → Left WindowedConstraintsIndeterminate
    _ → Right placement
  where
    described = case monitors of
      Observed descriptions → descriptions
      Unavailable → []
    usable description = case monitorWorkArea description of
      Observed area@(WorkArea _ _ areaWidth areaHeight) | areaWidth > 0 && areaHeight > 0 → Just area
      _ → Nothing
    areas = mapMaybe usable described
    primary = listToMaybe [area | description ← described, monitorPrimary description == Observed True, Just area ← [usable description]]

-- | Whether a desktop point lies inside a work area.
workAreaContains ∷ Int → Int → WorkArea → Bool
workAreaContains x y (WorkArea areaX areaY width height) =
  toInteger x >= toInteger areaX
    && toInteger x < toInteger areaX + toInteger width
    && toInteger y >= toInteger areaY
    && toInteger y < toInteger areaY + toInteger height

representable ∷ SavedPlacement → Either ModeRejection SavedPlacement
representable placement@(SavedPlacement position@(Placement x y) extent@(Extent width height))
  | coordinate x && coordinate y && dimension width && dimension height = Right placement
  | otherwise = Left (PlacementUnrepresentable position extent)

dimension ∷ Int → Bool
dimension value = value >= 1 && toInteger value <= toInteger (maxBound ∷ Int32)

coordinate ∷ Int → Bool
coordinate value = toInteger value >= toInteger (minBound ∷ Int32) && toInteger value <= toInteger (maxBound ∷ Int32)

-- ---------------------------------------------------------------------------
-- Plans

-- | What the native size limits and aspect ratio hold, relative to the
-- preserved windowed constraints.
data NativeConstraints
  = NativeFollowsWindowed
    -- ^ The native constraints are the preserved windowed set, whatever the
    -- owner knows of it.
  | NativeSuspended
    -- ^ A transition cleared them for its own geometry.
  | NativeIndeterminate
    -- ^ A suspension or restoration stopped after its first call.
  deriving (Eq, Show)

-- | The constraint state a size control validates against: the preserved
-- windowed set while the native constraints follow it, and indeterminate
-- otherwise.
effectiveConstraints ∷ NativeConstraints → ConstraintState → ConstraintState
effectiveConstraints native windowed = case native of
  NativeFollowsWindowed → windowed
  _ → ConstraintsIndeterminate

-- | One native call of a transition.
data ModeStep
  = ClearSizeLimitsStep
    -- ^ @glfwSetWindowSizeLimits@ with @GLFW_DONT_CARE@ throughout.
  | ClearAspectRatioStep
    -- ^ @glfwSetWindowAspectRatio@ with @GLFW_DONT_CARE@.
  | DecorationStep !Bool
    -- ^ @glfwSetWindowAttrib@ with @GLFW_DECORATED@.
  | PlacementStep !Placement !Extent
    -- ^ @glfwSetWindowMonitor@ with no monitor, at this content position and
    -- size.
  | MonitorStep !MonitorId !Extent !(Maybe Int)
    -- ^ @glfwSetWindowMonitor@ on the monitor, at this size and refresh rate, or
    -- @GLFW_DONT_CARE@.
  | SizeLimitsStep !Extent !Extent
    -- ^ @glfwSetWindowSizeLimits@ restoring the preserved minimum and maximum.
  | AspectRatioStep !(Maybe AspectRatio)
    -- ^ @glfwSetWindowAspectRatio@ restoring the preserved ratio, or none.
  deriving (Eq, Show)

instance NFData ModeStep where
  rnf = \case
    ClearSizeLimitsStep → ()
    ClearAspectRatioStep → ()
    DecorationStep decorated → rnf decorated
    PlacementStep position extent → rnf position `seq` rnf extent
    MonitorStep monitor extent refresh → rnf monitor `seq` rnf extent `seq` rnf refresh
    SizeLimitsStep lower upper → rnf lower `seq` rnf upper
    AspectRatioStep ratio → rnf ratio

modeStepText ∷ ModeStep → Text
modeStepText = \case
  ClearSizeLimitsStep → "clear window size limits"
  ClearAspectRatioStep → "clear window aspect ratio"
  DecorationStep _ → "set window decoration"
  PlacementStep _ _ → "place window"
  MonitorStep {} → "set window monitor"
  SizeLimitsStep _ _ → "restore window size limits"
  AspectRatioStep _ → "restore window aspect ratio"

-- | A transition's steps, and the native constraint state they establish once
-- every step has returned; 'Nothing' when they change no constraint.
data ModePlan = ModePlan
  { planSteps ∷ ![ModeStep]
  , planConstraints ∷ !(Maybe NativeConstraints)
  }
  deriving (Eq, Show)

-- | Return to windowed presentation at a validated placement.
windowedPlan ∷ NativeConstraints → ConstraintState → SavedPlacement → Either ModeRejection ModePlan
windowedPlan native windowed (SavedPlacement position extent) = case native of
  NativeFollowsWindowed
    | windowed == ConstraintsIndeterminate → Left WindowedConstraintsIndeterminate
    | otherwise → Right (ModePlan placing Nothing)
  _ → case windowed of
    ConstraintsKnown (Just preserved) →
      Right
        ( ModePlan
            (placing <> [SizeLimitsStep (constraintMinimum preserved) (constraintMaximum preserved), AspectRatioStep (constraintAspectRatio preserved)])
            (Just NativeFollowsWindowed)
        )
    ConstraintsKnown Nothing → Right (ModePlan (placing <> [ClearSizeLimitsStep, ClearAspectRatioStep]) (Just NativeFollowsWindowed))
    ConstraintsIndeterminate → Left WindowedConstraintsIndeterminate
  where
    placing = [DecorationStep True, PlacementStep position extent]

-- | Place an undecorated window over a work area, suspending the native
-- constraints first unless there are none to suspend.
borderlessPlan ∷ NativeConstraints → ConstraintState → SavedPlacement → Either ModeRejection ModePlan
borderlessPlan native windowed (SavedPlacement position extent) = case (windowed, native) of
  (ConstraintsIndeterminate, _) → Left WindowedConstraintsIndeterminate
  (_, NativeSuspended) → Right (ModePlan placing Nothing)
  (ConstraintsKnown Nothing, NativeFollowsWindowed) → Right (ModePlan placing Nothing)
  _ → Right (ModePlan ([ClearSizeLimitsStep, ClearAspectRatioStep] <> placing) (Just NativeSuspended))
  where
    placing = [DecorationStep False, PlacementStep position extent]

-- | Put the window on a monitor at a selected video mode.
fullscreenPlan ∷ MonitorId → Extent → Maybe Int → ModePlan
fullscreenPlan monitor extent refresh = ModePlan [MonitorStep monitor extent refresh] Nothing

-- ---------------------------------------------------------------------------
-- Claims

-- | How firmly a window claims a monitor.
data ClaimState
  = ClaimReserved
    -- ^ Reserved before a fullscreen transition's first native call.
  | ClaimHeld
    -- ^ The window was observed fullscreen on the monitor.
  | ClaimUncertain
    -- ^ What the window's native effects left is unknown.
  deriving (Eq, Show, Generic)

instance NFData ClaimState

-- | A claim, by the local identity of the claiming window.
data WindowClaim = WindowClaim
  { claimWindow ∷ !Natural
  , claimState ∷ !ClaimState
  }
  deriving (Eq, Show)

-- | A session's claims, at most one per monitor identity.
type MonitorClaims = Map MonitorId WindowClaim

-- | Drop the claims of identities that are no longer current.
pruneClaims ∷ [MonitorId] → MonitorClaims → MonitorClaims
pruneClaims live = Map.filterWithKey (\monitor _ → monitor `elem` live)

-- | Reserve a monitor for a window, or answer the monitor another window
-- claims.
reserveClaim ∷ Natural → MonitorId → MonitorClaims → Either MonitorId MonitorClaims
reserveClaim window monitor claims = case Map.lookup monitor claims of
  Nothing → Right (Map.insert monitor (WindowClaim window ClaimReserved) claims)
  Just (WindowClaim holder _)
    | holder == window → Right claims
    | otherwise → Left monitor

-- | Reconcile a window's claims with its observed fullscreen monitor.
settleClaims ∷ Natural → Attribute (Maybe MonitorId) → MonitorClaims → MonitorClaims
settleClaims window observed claims = case observed of
  Observed (Just on) →
    Map.alter hold on (Map.filterWithKey (\monitor claim → claimWindow claim /= window || monitor == on) claims)
  Observed Nothing → Map.filter ((/= window) . claimWindow) claims
  Unavailable → Map.map (\claim → if claimWindow claim == window then claim {claimState = ClaimUncertain} else claim) claims
  where
    hold = \case
      Just claim | claimWindow claim /= window → Just claim
      _ → Just (WindowClaim window ClaimHeld)

-- | Settle a window's claims when an attempt was interrupted by something other
-- than its own failure: before any native step, the monitor the attempt
-- reserved, if it still holds only that reservation, is released as proven
-- unused; after a native step, every claim of the window becomes uncertain.
abandonClaims ∷ Natural → Maybe MonitorId → Bool → MonitorClaims → MonitorClaims
abandonClaims window reserved stepped claims
  | stepped = Map.map (\claim → if claimWindow claim == window then claim {claimState = ClaimUncertain} else claim) claims
  | otherwise = maybe claims (\monitor → Map.update unused monitor claims) reserved
  where
    unused claim
      | claimWindow claim == window && claimState claim == ClaimReserved = Nothing
      | otherwise = Just claim

-- | Settle a released window's claims: dropped when its disposal succeeded,
-- uncertain otherwise.
disposeClaims ∷ Natural → Bool → MonitorClaims → MonitorClaims
disposeClaims window disposed
  | disposed = Map.filter ((/= window) . claimWindow)
  | otherwise = Map.map (\claim → if claimWindow claim == window then claim {claimState = ClaimUncertain} else claim)

-- ---------------------------------------------------------------------------
-- Outcomes

-- | Which operation an attempt ran.
data ModeAttemptKind
  = TargetAttempt
    -- ^ The requested mode.
  | WindowedFallbackAttempt
    -- ^ The return to windowed presentation at a reachable placement.
  deriving (Eq, Show, Generic)

instance NFData ModeAttemptKind

-- | Why one attempt did not complete.
data ModeFailure
  = RefusedBeforeMutation !ModeRejection
    -- ^ Refused before any native call.
  | UnsupportedTarget !Text
    -- ^ The platform cannot perform the target, for this reason; no native call
    -- was made.
  | StoppedPartway
      { stoppedReturned ∷ ![ModeStep]
        -- ^ The steps that returned without a report, in order.
      , stoppedAt ∷ !ModeStep
        -- ^ The step that reported errors.
      , stoppedUnattempted ∷ ![ModeStep]
      , stoppedReports ∷ !Reports
      }
    -- ^ A native step reported errors. Nothing was rolled back.
  deriving (Eq, Show)

instance NFData ModeFailure where
  rnf = \case
    RefusedBeforeMutation rejection → rnf rejection
    UnsupportedTarget reason → rnf reason
    StoppedPartway returned at unattempted reports → rnf returned `seq` rnf at `seq` rnf unattempted `seq` rnfReports reports

-- | One failed attempt, as recovery sees and reports it.
data ModeAttemptFailure = ModeAttemptFailure
  { failedAttempt ∷ !ModeAttemptKind
  , failedHow ∷ !ModeFailure
  }
  deriving (Eq, Show)

instance NFData ModeAttemptFailure where
  rnf (ModeAttemptFailure kind how) = rnf kind `seq` rnf how

instance Exception ModeAttemptFailure

-- | How a transition that executed settled.
data ModeOutcome
  = ModeInert
    -- ^ The request matched the applied mode; no native call was made.
  | ModeApplied
      { appliedBy ∷ !ModeAttemptKind
        -- ^ The target itself, or the windowed fallback.
      , appliedSteps ∷ ![ModeStep]
        -- ^ Every step it made, each of which returned without a report.
      , appliedAfter ∷ ![ModeAttemptFailure]
        -- ^ The attempts that failed before it, oldest first.
      }
    -- ^ The native steps returned. The window's observation reports what was
    -- reached.
  | ModeFailed
      { failedAttempts ∷ ![ModeAttemptFailure]
        -- ^ Every attempt, oldest first.
      }
    -- ^ No attempt completed: without a fallback, or with its budget exhausted.
  | ModeRecoveryStopped
      { stoppedAttempts ∷ ![ModeAttemptFailure]
        -- ^ Every attempt, oldest first.
      , stoppedCleanup ∷ !Reports
        -- ^ What the failed restoration of the windowed constraints reported.
      }
    -- ^ An attempt's cleanup — restoring the preserved windowed constraints of a
    -- window left windowed — failed, so no further attempt was made.
  deriving (Eq, Show)

instance NFData ModeOutcome where
  rnf = \case
    ModeInert → ()
    ModeApplied kind steps earlier → rnf kind `seq` rnf steps `seq` rnf earlier
    ModeFailed attempts → rnf attempts
    ModeRecoveryStopped attempts reports → rnf attempts `seq` rnfReports reports

-- | Whether an outcome settled at its target: inert, or applied by the target
-- attempt with no failure before it.
settledCleanly ∷ ModeOutcome → Bool
settledCleanly = \case
  ModeInert → True
  ModeApplied TargetAttempt _ [] → True
  _ → False

-- | What executing a mode request on a live window produced.
data ModeResult
  = ModeWindowClosing
    -- ^ The window's close protocol has begun; nothing was attempted.
  | ModeRefused !ModeRejection
    -- ^ Refused before any native call, with no fallback to take.
  | ModeUnsupported !Text
    -- ^ The platform cannot perform the target, with no fallback to take.
  | ModeSettled !ModeOutcome !PostCallObservation
    -- ^ The revision a sample taken after the transition published.
  deriving (Eq, Show)
