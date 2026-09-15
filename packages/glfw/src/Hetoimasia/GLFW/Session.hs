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
-- "Hetoimasia.GLFW.Command", and it ends. There is no public event loop or input
-- operation yet.
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
  , UnsupportedBackend (..)
  , defaultSessionConfig
  , errorDescriptionLimit
  , errorEvidenceCapacity
  , glfwComponent
  , sessionAssembly
  , sessionBackend
  , takeAsynchronousReports
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
