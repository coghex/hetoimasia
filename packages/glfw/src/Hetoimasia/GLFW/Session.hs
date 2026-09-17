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

    -- * Waking the owner
  , SessionWake
  , sessionWake
  , wakeSession
  , WakeOutcome (..)

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
import Hetoimasia.GLFW.Internal.Session
  ( AsynchronousErrorsUnobserved (..)
  , Backend (..)
  , BackendNotSelected (..)
  , NativeError (..)
  , NativeFailure (..)
  , NativeOutcome (..)
  , ReportingThread (..)
  , Reports (..)
  , Session
  , SessionConfig (..)
  , SessionMisuse (..)
  , SessionWake
  , UnsupportedBackend (..)
  , WakeOutcome (..)
  , defaultSessionConfig
  , errorDescriptionLimit
  , errorEvidenceCapacity
  , glfwComponent
  , sessionAssembly
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
