-- | Sampling a window's attributes, and reading the reports one native call
-- made.
--
-- Every operation here runs on the session's owner thread, at an owner
-- boundary, and brackets each native call with the session's error capture so
-- its reports belong to that call alone. A 'Sample' is a value the caller
-- folds; this module holds no state.
module Hetoimasia.GLFW.Internal.Window.Sample
  ( Sample (..)
  , sampleAll
  , sampleOperation
  , reportsDuring
  ) where

import Control.Exception (evaluate)
import Data.Text (Text)
import Foreign.Ptr (Ptr)
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.GLFW.Internal.Attribute (Attribute (..), ContentScale (..), Extent (..), Placement (..))
import Hetoimasia.GLFW.Internal.Capture
  ( NativeError (..)
  , Reports (..)
  , hasReports
  , settleStrayOwnerReports
  , takeOwnerReports
  )
import Hetoimasia.GLFW.Internal.Control (WindowReport (..), reportable)
import Hetoimasia.GLFW.Internal.Monitor (MonitorId, NativeMonitor)
import Hetoimasia.GLFW.Internal.Session
  ( Native (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , NativeWindow
  , Session
  , WindowAttribute (..)
  , glfwComponent
  , identifyWindowMonitor
  , sessionCapture
  , sessionNative
  , sessionWindowCapabilities
  )

-- | Samples taken together at one boundary.
data Sample = Sample
  { sampleLogical ∷ !(Attribute Extent)
  , sampleFramebuffer ∷ !(Attribute Extent)
  , sampleScale ∷ !(Attribute ContentScale)
  , samplePlacement ∷ !(Attribute Placement)
  , sampleFocused ∷ !(Attribute Bool)
  , sampleIconified ∷ !(Attribute Bool)
  , sampleMaximized ∷ !(Attribute Bool)
  , sampleVisible ∷ !(Attribute Bool)
  , sampleDecorated ∷ !(Attribute Bool)
  , sampleMonitor ∷ !(Attribute (Maybe MonitorId))
  }

sampleOperation ∷ Operation
sampleOperation = operation "sample window"

-- | Sample every attribute, each query bracketed by the error capture. An
-- attribute the platform cannot report is 'Unavailable' without a query.
sampleAll ∷ Session → [(Text, Text)] → Ptr NativeWindow → IO Sample
sampleAll session identifiers handle =
  Sample
    <$> gated LogicalExtentReport (uncurry Extent <$> nativeWindowSize native handle)
    <*> gated FramebufferExtentReport (uncurry Extent <$> nativeFramebufferSize native handle)
    <*> gated ContentScaleReport (uncurry ContentScale <$> nativeContentScale native handle)
    <*> gated PlacementReport (uncurry Placement <$> nativeWindowPosition native handle)
    <*> gated FocusedReport (nativeWindowAttribute native handle FocusedAttribute)
    <*> gated IconifiedReport (nativeWindowAttribute native handle IconifiedAttribute)
    <*> gated MaximizedReport (nativeWindowAttribute native handle MaximizedAttribute)
    <*> gated VisibleReport (nativeWindowAttribute native handle VisibleAttribute)
    <*> sampled (nativeWindowAttribute native handle DecoratedAttribute)
    <*> (sampled (nativeWindowMonitor native handle) >>= identified)
  where
    identified ∷ Attribute (Ptr NativeMonitor) → IO (Attribute (Maybe MonitorId))
    identified = \case
      Observed pointer → identifyWindowMonitor session pointer
      Unavailable → pure Unavailable
    native = sessionNative session
    capture = sessionCapture session
    gated ∷ WindowReport → IO a → IO (Attribute a)
    gated report query
      | reportable (sessionWindowCapabilities session) report = sampled query
      | otherwise = pure Unavailable
    sampled ∷ IO a → IO (Attribute a)
    sampled query = do
      settleStrayOwnerReports capture
      value ← query
      reports ← takeOwnerReports capture
      if not (hasReports reports)
        then Observed <$> evaluate value
        else
          if onlyUnavailable reports
            then pure Unavailable
            else throwFailure glfwComponent sampleOperation identifiers (NativeFailure NativeCallReturned reports)
    onlyUnavailable reports =
      reportsLost reports == 0
        && callbackFaults reports == 0
        && all ((== nativeFeatureUnavailable native) . nativeErrorCode) (reportedErrors reports)

-- | The reports made on the owner thread during one native call.
reportsDuring ∷ Session → IO () → IO Reports
reportsDuring session call = do
  settleStrayOwnerReports capture
  call
  takeOwnerReports capture
  where
   capture = sessionCapture session
