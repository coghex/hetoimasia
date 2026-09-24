-- | The GLFW session: the one scoped owner of GLFW's process-wide state.
--
-- 'allocSession' enters a session for the rest of the enclosing
-- 'Hetoimasia.Foundation.Resource.withScoped' scope, and 'withSession' is that
-- scope on its own. Entry must happen on the process main thread under the
-- threaded runtime; see "Hetoimasia.GLFW.Internal.Session"'s contract, repeated
-- in prose in @docs/glfw.md@, for the entry order, the owner-thread rules,
-- native error attribution, teardown, and poisoning.
--
-- A session is entered, its asynchronous error reports read, windows created
-- in it through "Hetoimasia.GLFW.Window" and commanded through
-- "Hetoimasia.GLFW.Command", and it ends. The window host's owner loop in
-- "Hetoimasia.Runtime.GLFW" processes its native events.
--
-- 'sessionWake' lends the session's wake capability: any thread may pass it to
-- 'wakeSession' to end the owner's native event wait. A wake is a hint, answered
-- with a typed 'WakeOutcome', and the capability is terminal once its session
-- begins closing; see the internal module's /Waking the owner/ and /Wake
-- lifetime/ sections.
--
-- @
-- main ∷ IO ()
-- main = withSession defaultSessionConfig $ \\session → do
--   print (sessionBackend session)
--   reports ← takeAsynchronousReports session
--   print reports
-- @
module Hetoimasia.GLFW.Session
  ( -- * Sessions
    Session
  , allocSession
  , withSession
  , sessionBackend
  , takeAsynchronousReports

    -- * Loader-aware sessions
  , SessionIntegration
  , allocIntegratedSession
  , withIntegratedSession
  , IntegrationUse (..)
  , readIntegrationUse
  , IntegrationRefused (..)
  , IntegrationStillInstalled (..)

    -- * Waking the owner
  , SessionWake
  , sessionWake
  , wakeSession
  , WakeOutcome (..)
  , WakePath (..)
  , DegradationReport (..)
  , DegradationAttempt (..)

    -- * Configuration
  , SessionConfig (..)
  , defaultSessionConfig
  , Backend (..)

    -- * Native error evidence
  , Reports (..)
  , NativeError (..)
  , ReportingThread (..)
  , errorEvidenceCapacity
  , errorDescriptionLimit

    -- * Failures
  , glfwComponent
  , SessionMisuse (..)
  , UnsupportedBackend (..)
  , BackendNotSelected (..)
  , NativeOutcome (..)
  , NativeFailure (..)
  , AsynchronousErrorsUnobserved (..)
  ) where

import Hetoimasia.Foundation.Resource (Scoped, allocComposite, withScoped)
import Hetoimasia.GLFW.Internal.Native (productionNative)
import Hetoimasia.GLFW.Internal.Notify (DegradationAttempt (..))
import Hetoimasia.GLFW.Internal.Session
  ( AsynchronousErrorsUnobserved (..)
  , Backend (..)
  , BackendNotSelected (..)
  , DegradationReport (..)
  , NativeError (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , ReportingThread (..)
  , Reports (..)
  , IntegrationRefused (..)
  , IntegrationStillInstalled (..)
  , IntegrationUse (..)
  , Session
  , SessionConfig (..)
  , SessionIntegration
  , SessionMisuse (..)
  , SessionWake
  , UnsupportedBackend (..)
  , WakeOutcome (..)
  , WakePath (..)
  , defaultSessionConfig
  , errorDescriptionLimit
  , errorEvidenceCapacity
  , glfwComponent
  , readIntegrationUse
  , sessionAssembly
  , sessionAssemblyWith
  , sessionBackend
  , sessionWake
  , takeAsynchronousReports
  , wakeSession
  )

-- | Enter a GLFW session for the rest of the enclosing scope.
--
-- A failure at any stage of entry releases exactly what was acquired before it
-- and propagates with its evidence; the session is released when the enclosing
-- continuation returns or throws.
allocSession ∷ SessionConfig → Scoped Session
allocSession = allocComposite . sessionAssembly productionNative

-- | Enter a GLFW session, lend it to the body, and end it.
withSession ∷ SessionConfig → (Session → IO r) → IO r
withSession config = withScoped (allocSession config)

-- | Enter a loader-aware GLFW session for the rest of the enclosing scope: the
-- additive constructor beside 'allocSession'.
--
-- The capability is opaque and single-use, and only the package's Vulkan
-- interop component constructs one, from the loader entry point the Vulkan
-- binding dispatches through. It is admitted after the session's guard is
-- claimed and before any native call — a stale, foreign, or already-used one is
-- refused there with 'IntegrationRefused' — handed to GLFW between the
-- initialization hints and @glfwInit@, and GLFW's default loader search is
-- restored after termination or a failed initialization, before the guard is
-- settled. 'SessionConfig' is unchanged and carries no part of it; a
-- window-only session makes no loader call at all. See
-- "Hetoimasia.GLFW.Internal.Session"'s /Loader-aware sessions/ section and
-- @docs/glfw.md@.
allocIntegratedSession ∷ SessionIntegration → SessionConfig → Scoped Session
allocIntegratedSession integration config =
  allocComposite (sessionAssemblyWith productionNative config integration)

-- | Enter a loader-aware GLFW session, lend it to the body, and end it.
withIntegratedSession ∷ SessionIntegration → SessionConfig → (Session → IO r) → IO r
withIntegratedSession integration config = withScoped (allocIntegratedSession integration config)
