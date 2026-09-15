{-# LANGUAGE DeriveGeneric #-}

-- | Ordinary window controls: what they ask for, how they are validated before
-- any native call, what a platform cannot perform or report, and how an
-- attempted control settles.
--
-- This module is pure and holds no state. "Hetoimasia.GLFW.Internal.Window"
-- executes a control on the owner thread against the window's own constraint
-- state and latest observation, and "Hetoimasia.GLFW.Internal.Command" turns
-- the result into a disposition.
--
-- = Validation
--
-- 'validateControl' decides, before any native call, whether a control may be
-- attempted at all:
--
-- * a title must contain no NUL, which the native UTF-8 C string would
--   truncate;
-- * a size's dimensions must lie in @1 .. 2147483647@, and a placement's
--   coordinates in the native @int@ range;
-- * a size must lie inside the fully known active constraints — within the
--   minimum and maximum, and, with an aspect ratio, satisfying it exactly by
--   integer cross-multiplication — and is refused while the active constraints
--   are indeterminate;
-- * a constraint set's bounds must be positive and representable, its minimum
--   must not exceed its maximum in either dimension, its aspect ratio's terms
--   must be positive and representable, and it must admit the window's
--   currently observed logical size, which must therefore be known.
--
-- A refused control is a typed 'ControlRejection' and makes no native call.
-- There is no clamping and no rounding: a size outside the constraints is never
-- sent to the platform to adjust.
--
-- = Constraint updates
--
-- A constraint set is applied in the fixed order 'constraintCallOrder': the
-- size limits, then the aspect ratio, cleared when the set has none. The whole
-- set is validated before the first call. The owner marks its constraint state
-- indeterminate before that call and marks the set known only once every call
-- has returned without a report, so a failed or interrupted update never leaves
-- a state that claims more than was established. 'ConstraintUpdateFailed' names
-- the calls that returned, the call that reported the error, and the calls not
-- attempted; nothing is rolled back.
--
-- = Capabilities
--
-- 'WindowCapabilities' names what the platform and backend cannot perform or
-- report, each with a reason. A control whose operation is unperformable
-- settles as unsupported without a native call, and an unreportable attribute
-- is observed as 'Unavailable' rather than queried or guessed.
module Hetoimasia.GLFW.Internal.Control
  ( -- * Controls
    WindowControl (..)
  , controlOperation
  , controlOperationText

    -- * Size constraints
  , SizeConstraints
  , sizeConstraints
  , constraintMinimum
  , constraintMaximum
  , constraintAspectRatio
  , AspectRatio (..)

    -- * Validation
  , ConstraintState (..)
  , ControlRejection (..)
  , validateControl

    -- * Constraint updates
  , ConstraintCall (..)
  , constraintCallOrder
  , constraintCallText

    -- * Results
  , ControlOutcome (..)
  , PostCallObservation (..)
  , ControlResult (..)

    -- * Capabilities
  , WindowOperation (..)
  , WindowReport (..)
  , WindowCapabilities
  , windowCapabilities
  , fullWindowCapabilities
  , unperformableOperations
  , unreportableAttributes
  , operationGap
  , reportable
  ) where

import Control.DeepSeq (NFData (rnf))
import Data.Int (Int32)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), Extent (..))
import Hetoimasia.GLFW.Internal.Capture (NativeOutcome, Reports, rnfReports)
import Numeric.Natural (Natural)

-- ---------------------------------------------------------------------------
-- Controls

-- | One ordinary control of a window. Its representation is private: commands
-- are built by "Hetoimasia.GLFW.Command"'s smart constructors.
data WindowControl
  = TitleControl !Text
  | SizeControl !Int !Int
    -- ^ A logical width and height in screen coordinates.
  | PositionControl !Int !Int
    -- ^ The content area's upper-left corner in desktop screen coordinates.
  | ConstraintsControl !SizeConstraints
  | ShowControl
  | HideControl
  | FocusControl
  | AttentionControl
  | MinimizeControl
  | MaximizeControl
  | RestoreControl
  deriving (Eq, Show)

instance NFData WindowControl where
  rnf = \case
    TitleControl title → rnf title
    SizeControl width height → rnf width `seq` rnf height
    PositionControl x y → rnf x `seq` rnf y
    ConstraintsControl constraints → rnf constraints
    ShowControl → ()
    HideControl → ()
    FocusControl → ()
    AttentionControl → ()
    MinimizeControl → ()
    MaximizeControl → ()
    RestoreControl → ()

-- | Which window operation a control performs.
data WindowOperation
  = SetTitleOperation
  | SetSizeOperation
  | SetPositionOperation
  | SetConstraintsOperation
  | ShowOperation
  | HideOperation
  | FocusOperation
  | AttentionOperation
  | MinimizeOperation
  | MaximizeOperation
  | RestoreOperation
  deriving (Eq, Ord, Show, Enum, Bounded, Generic)

instance NFData WindowOperation

controlOperation ∷ WindowControl → WindowOperation
controlOperation = \case
  TitleControl _ → SetTitleOperation
  SizeControl _ _ → SetSizeOperation
  PositionControl _ _ → SetPositionOperation
  ConstraintsControl _ → SetConstraintsOperation
  ShowControl → ShowOperation
  HideControl → HideOperation
  FocusControl → FocusOperation
  AttentionControl → AttentionOperation
  MinimizeControl → MinimizeOperation
  MaximizeControl → MaximizeOperation
  RestoreControl → RestoreOperation

-- | The operation's name, as failures and native error data name it.
controlOperationText ∷ WindowOperation → Text
controlOperationText = \case
  SetTitleOperation → "set window title"
  SetSizeOperation → "set window size"
  SetPositionOperation → "set window position"
  SetConstraintsOperation → "set window size constraints"
  ShowOperation → "show window"
  HideOperation → "hide window"
  FocusOperation → "focus window"
  AttentionOperation → "request window attention"
  MinimizeOperation → "iconify window"
  MaximizeOperation → "maximize window"
  RestoreOperation → "restore window"

-- ---------------------------------------------------------------------------
-- Size constraints

-- | A width-to-height ratio.
data AspectRatio = AspectRatio
  { aspectNumerator ∷ !Int
  , aspectDenominator ∷ !Int
  }
  deriving (Eq, Show, Generic)

instance NFData AspectRatio

-- | A minimum and maximum logical size, and an optional aspect ratio. Its
-- representation is private; it is validated on the owner thread when a
-- command carrying it executes, not when it is built.
data SizeConstraints = SizeConstraints
  { constraintsMinimum ∷ !Extent
  , constraintsMaximum ∷ !Extent
  , constraintsAspect ∷ !(Maybe AspectRatio)
  }
  deriving (Eq, Show, Generic)

instance NFData SizeConstraints

-- | Constraints from a minimum size, a maximum size, and an optional aspect
-- ratio.
sizeConstraints ∷ Extent → Extent → Maybe AspectRatio → SizeConstraints
sizeConstraints = SizeConstraints

constraintMinimum, constraintMaximum ∷ SizeConstraints → Extent
constraintMinimum = constraintsMinimum
constraintMaximum = constraintsMaximum

constraintAspectRatio ∷ SizeConstraints → Maybe AspectRatio
constraintAspectRatio = constraintsAspect

-- ---------------------------------------------------------------------------
-- Validation

-- | What the owner knows about a window's active constraints.
data ConstraintState
  = ConstraintsKnown !(Maybe SizeConstraints)
    -- ^ Fully known: 'Nothing' is the unconstrained state a window starts in.
  | ConstraintsIndeterminate
    -- ^ A constraint update failed or was interrupted after its first call.
  deriving (Eq, Show)

-- | Why a control was refused before any native call.
data ControlRejection
  = ControlExtentRejected !Int !Int
    -- ^ A size dimension is not in @1 .. 2147483647@.
  | ControlPlacementRejected !Int !Int
    -- ^ A coordinate is not representable as a native @int@.
  | ControlTitleRejected
    -- ^ The title contains a NUL, which the native C string would truncate.
  | SizeOutsideConstraints !Extent !SizeConstraints
    -- ^ The size lies outside the active constraints, or does not satisfy their
    -- aspect ratio exactly.
  | ActiveConstraintsIndeterminate
    -- ^ The active constraints are indeterminate after a failed update, so no
    -- size can be checked against them.
  | ConstraintBoundRejected !Extent !Extent
    -- ^ A minimum or maximum dimension is not in @1 .. 2147483647@.
  | ConstraintBoundsInverted !Extent !Extent
    -- ^ The minimum exceeds the maximum in some dimension.
  | AspectRatioRejected !Int !Int
    -- ^ A ratio term is not in @1 .. 2147483647@.
  | ConstraintsExcludeCurrentSize !Extent !SizeConstraints
    -- ^ The constraints do not admit the window's currently observed logical
    -- size.
  | CurrentSizeUnavailable
    -- ^ The window's logical size is not observed, so constraints cannot be
    -- checked against it.
  | ModeTransitionInProgress
    -- ^ The window's mode is changing; ordinary controls wait for it to finish.
  deriving (Eq, Show, Generic)

instance NFData ControlRejection

-- | Check a control against the owner's constraint state and the window's
-- latest observed logical size, without any native call.
validateControl ∷ ConstraintState → Attribute Extent → WindowControl → Either ControlRejection ()
validateControl state current = \case
  TitleControl title
    | Text.elem '\NUL' title → Left ControlTitleRejected
    | otherwise → Right ()
  SizeControl width height
    | not (dimension width && dimension height) → Left (ControlExtentRejected width height)
    | otherwise → case state of
        ConstraintsIndeterminate → Left ActiveConstraintsIndeterminate
        ConstraintsKnown Nothing → Right ()
        ConstraintsKnown (Just constraints)
          | admits constraints requested → Right ()
          | otherwise → Left (SizeOutsideConstraints requested constraints)
      where
        requested = Extent width height
  PositionControl x y
    | coordinate x && coordinate y → Right ()
    | otherwise → Left (ControlPlacementRejected x y)
  ConstraintsControl constraints@(SizeConstraints lower upper aspect)
    | not (bound lower && bound upper) → Left (ConstraintBoundRejected lower upper)
    | extentWidth lower > extentWidth upper || extentHeight lower > extentHeight upper →
        Left (ConstraintBoundsInverted lower upper)
    | Just (AspectRatio numerator denominator) ← aspect
    , not (dimension numerator && dimension denominator) →
        Left (AspectRatioRejected numerator denominator)
    | otherwise → case current of
        Unavailable → Left CurrentSizeUnavailable
        Observed size
          | admits constraints size → Right ()
          | otherwise → Left (ConstraintsExcludeCurrentSize size constraints)
  ShowControl → Right ()
  HideControl → Right ()
  FocusControl → Right ()
  AttentionControl → Right ()
  MinimizeControl → Right ()
  MaximizeControl → Right ()
  RestoreControl → Right ()
  where
    bound (Extent width height) = dimension width && dimension height

-- | Whether constraints admit a size: within both bounds, and satisfying the
-- aspect ratio exactly.
admits ∷ SizeConstraints → Extent → Bool
admits (SizeConstraints lower upper aspect) (Extent width height) =
  extentWidth lower <= width
    && width <= extentWidth upper
    && extentHeight lower <= height
    && height <= extentHeight upper
    && maybe True ratioHolds aspect
  where
    -- Compared as Integer, so no product of representable terms overflows.
    ratioHolds (AspectRatio numerator denominator) =
      toInteger width * toInteger denominator == toInteger height * toInteger numerator

dimension ∷ Int → Bool
dimension value = value >= 1 && toInteger value <= toInteger (maxBound ∷ Int32)

coordinate ∷ Int → Bool
coordinate value = toInteger value >= toInteger (minBound ∷ Int32) && toInteger value <= toInteger (maxBound ∷ Int32)

-- ---------------------------------------------------------------------------
-- Constraint updates

-- | One native call of a constraint update.
data ConstraintCall
  = SizeLimitsCall
    -- ^ @glfwSetWindowSizeLimits@ with the minimum and maximum.
  | AspectRatioCall
    -- ^ @glfwSetWindowAspectRatio@ with the ratio, or @GLFW_DONT_CARE@ for none.
  deriving (Eq, Ord, Show, Enum, Bounded, Generic)

instance NFData ConstraintCall

-- | The documented order a constraint update makes its calls in.
constraintCallOrder ∷ [ConstraintCall]
constraintCallOrder = [SizeLimitsCall, AspectRatioCall]

constraintCallText ∷ ConstraintCall → Text
constraintCallText = \case
  SizeLimitsCall → "set window size limits"
  AspectRatioCall → "set window aspect ratio"

-- ---------------------------------------------------------------------------
-- Results

-- | How an attempted control's native calls returned. None of these says the
-- window manager honoured the request: that is what the observation that
-- followed reports.
data ControlOutcome
  = ControlReturned
    -- ^ Every native call returned without a report.
  | ControlNativeError
      { controlFailedOperation ∷ !Text
      , controlReports ∷ !Reports
        -- ^ The codes and descriptions GLFW reported during the call, copied.
      }
    -- ^ The native call returned, but reported errors.
  | ConstraintUpdateFailed
      { constraintsReturned ∷ ![ConstraintCall]
        -- ^ The calls that returned without a report, in order.
      , constraintsFailed ∷ !ConstraintCall
        -- ^ The call that reported errors.
      , constraintsUnattempted ∷ ![ConstraintCall]
        -- ^ The calls not attempted after it.
      , constraintReports ∷ !Reports
      }
    -- ^ A constraint update stopped at a call that reported errors. Nothing was
    -- rolled back, the complete set was not applied, and the owner's constraint
    -- state is indeterminate. With calls that returned before it, this is a
    -- partial update.
  deriving (Eq, Show)

instance NFData ControlOutcome where
  rnf = \case
    ControlReturned → ()
    ControlNativeError failed reports → rnf failed `seq` rnfReports reports
    ConstraintUpdateFailed returned failed unattempted reports →
      rnf returned `seq` rnf failed `seq` rnf unattempted `seq` rnfReports reports

-- | The observation sampled after an attempted control.
data PostCallObservation
  = PostCallRevision !Natural
    -- ^ The revision the post-call sample published. It proves the sample
    -- followed the call; it does not promise that the window manager converged
    -- or that the requested state was attained, and later revisions may already
    -- have replaced it.
  | PostCallSampleFailed
      { sampleOutcome ∷ !NativeOutcome
      , sampleReports ∷ !Reports
      }
    -- ^ Sampling reported errors, so nothing was published after the call.
  deriving (Eq, Show)

instance NFData PostCallObservation where
  rnf = \case
    PostCallRevision revision → rnf revision
    PostCallSampleFailed outcome reports → outcome `seq` rnfReports reports

-- | What executing a control on a live window produced.
data ControlResult
  = ControlWindowClosing
    -- ^ The window's close protocol has begun; nothing was attempted.
  | ControlRefused !ControlRejection
  | ControlUnsupported !WindowOperation !Text
  | ControlAttempted !ControlOutcome !PostCallObservation
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Capabilities

-- | An observation attribute a platform may be unable to report.
data WindowReport
  = LogicalExtentReport
  | FramebufferExtentReport
  | ContentScaleReport
  | PlacementReport
  | FocusedReport
  | IconifiedReport
  | MaximizedReport
  | VisibleReport
  deriving (Eq, Ord, Show, Enum, Bounded, Generic)

instance NFData WindowReport

-- | What the current platform and backend cannot perform or report, each with a
-- reason. Its representation is private.
data WindowCapabilities = WindowCapabilities
  { capabilitiesUnperformable ∷ ![(WindowOperation, Text)]
  , capabilitiesUnreportable ∷ ![(WindowReport, Text)]
  }
  deriving (Eq, Show)

-- | A description from the operations and attributes that are unavailable.
windowCapabilities ∷ [(WindowOperation, Text)] → [(WindowReport, Text)] → WindowCapabilities
windowCapabilities = WindowCapabilities

-- | Every operation performable and every attribute reportable.
fullWindowCapabilities ∷ WindowCapabilities
fullWindowCapabilities = WindowCapabilities [] []

-- | The operations the platform cannot perform, with why.
unperformableOperations ∷ WindowCapabilities → [(WindowOperation, Text)]
unperformableOperations = capabilitiesUnperformable

-- | The attributes the platform cannot report, with why.
unreportableAttributes ∷ WindowCapabilities → [(WindowReport, Text)]
unreportableAttributes = capabilitiesUnreportable

-- | Why an operation cannot be performed, if it cannot.
operationGap ∷ WindowCapabilities → WindowOperation → Maybe Text
operationGap capabilities wanted = lookup wanted (capabilitiesUnperformable capabilities)

reportable ∷ WindowCapabilities → WindowReport → Bool
reportable capabilities wanted = all ((/= wanted) . fst) (capabilitiesUnreportable capabilities)
