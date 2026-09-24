-- | What a loader-aware session answers about Vulkan, written over the
-- integration capability's own operations.
--
-- A session entered through 'Hetoimasia.GLFW.Internal.Session.sessionAssemblyWith'
-- holds the 'SessionIntegration' it took, and the queries here go through it:
-- they make the same owner-thread and liveness checks every other owner
-- operation makes, before any native call, and they bracket each call with the
-- session's error capture, so what GLFW reports during it belongs to it.
--
-- A window-only session holds no capability, and these queries refuse it with
-- 'SessionNotLoaderAware' rather than asking GLFW — which would otherwise search
-- for a loader of its own, beside the one the Vulkan binding already uses.
--
-- Nothing here names a Vulkan type. The production operations live in the GLFW
-- package's Vulkan interop component; the test seam scripts them.
module Hetoimasia.GLFW.Internal.Interop
  ( -- * Instance extensions
    requiredInstanceExtensions
  , extensionsOperation

    -- * Refusals
  , InteropUnavailable (..)
  ) where

import Control.DeepSeq (force)
import Control.Exception (Exception, evaluate)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as ByteString
import Hetoimasia.Foundation.Failure (Operation, operation, throwFailure)
import Hetoimasia.GLFW.Internal.Capture
  ( NativeOutcome (..)
  , Reports
  , glfwComponent
  , raiseReported
  , settleStrayOwnerReports
  , takeOwnerReports
  )
import Hetoimasia.GLFW.Internal.Session
  ( IntegrationNative (..)
  , Session
  , integrationNativeOperations
  , ownerOperation
  , sessionCapture
  , sessionIntegration
  )

-- | Why a Vulkan query was refused.
data InteropUnavailable
  = SessionNotLoaderAware
    -- ^ The session was entered without a loader integration capability, so it
    -- asks GLFW nothing about Vulkan.
  | VulkanUnsupported !Reports
    -- ^ GLFW answered that it found no usable Vulkan loader, with whatever it
    -- reported during that call.
  | NoRequiredExtensions !Reports
    -- ^ GLFW answered no instance extensions for this platform's surfaces, with
    -- whatever it reported during that call.
  deriving (Eq, Show)

instance Exception InteropUnavailable

-- | The operation a query's failure is attributed to.
extensionsOperation ∷ Operation
extensionsOperation = operation "query required instance extensions"

-- | The instance extensions GLFW requires for this platform's window surfaces,
-- copied into storage the caller owns while the session is live.
--
-- It is an owner operation: another thread is refused with
-- 'Hetoimasia.GLFW.Internal.Session.NotSessionOwner' and an ended session with
-- 'Hetoimasia.GLFW.Internal.Session.SessionEnded', each before any native
-- call. A session with no capability is refused with 'SessionNotLoaderAware'.
-- Otherwise GLFW is asked first whether it has a Vulkan loader at all, and
-- 'VulkanUnsupported' answers a session where it has none; errors GLFW reports
-- during either call fail the query with their evidence.
--
-- Every name is fully copied, and forced, before this returns: nothing the
-- caller holds points into GLFW's storage, which termination frees, and no name
-- is cut to a fixed length.
requiredInstanceExtensions ∷ Session → IO [ByteString]
requiredInstanceExtensions session =
  ownerOperation session extensionsOperation [] $ do
    operations ← case sessionIntegration session of
      Nothing → throwFailure glfwComponent extensionsOperation [] SessionNotLoaderAware
      Just integration → pure (integrationNativeOperations integration)
    settleStrayOwnerReports capture
    supported ← integrationVulkanSupported operations
    supportReports ← takeOwnerReports capture
    unless supported $
      throwFailure glfwComponent extensionsOperation [] (VulkanUnsupported supportReports)
    raiseReported extensionsOperation [] NativeCallReturned supportReports
    settleStrayOwnerReports capture
    answered ← integrationRequiredExtensions operations
    reports ← takeOwnerReports capture
    raiseReported extensionsOperation [] NativeCallReturned reports
    case answered of
      Nothing → throwFailure glfwComponent extensionsOperation [] (NoRequiredExtensions reports)
      Just names → evaluate (force (map ByteString.copy names))
  where
    capture = sessionCapture session
